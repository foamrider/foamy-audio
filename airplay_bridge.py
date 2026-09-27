#!/usr/bin/env python3

"""Lifecycle-safe PipeWire AirPlay discovery for the Quickshell audio panel."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time
from typing import Any, Callable, Sequence


PULSE_MODULE = "module-raop-discover"
PIPEWIRE_MODULE = "libpipewire-module-raop-discover"
MODULE_PATH = Path("/usr/lib/pipewire-0.3/libpipewire-module-raop-discover.so")
CommandRunner = Callable[[Sequence[str]], subprocess.CompletedProcess[str]]
AVAHI_ESCAPE = re.compile(r"\\(\d{3})")
TXT_FIELD = re.compile(r'"([^"=]+)=([^"\\]*(?:\\.[^"\\]*)*)"')


def emit(payload: dict[str, Any]) -> None:
    print(json.dumps(payload, ensure_ascii=False, separators=(",", ":")), flush=True)


def run_command(command: Sequence[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        list(command),
        capture_output=True,
        check=False,
        text=True,
        timeout=12,
    )


def state_path() -> Path:
    runtime_dir = os.environ.get("XDG_RUNTIME_DIR") or f"/run/user/{os.getuid()}"
    return Path(os.environ.get("FOAMY_AUDIO_AIRPLAY_STATE", Path(runtime_dir) / "foamy-audio-airplay.json"))


def parse_module_ids(output: str) -> list[int]:
    module_ids: list[int] = []
    for raw_line in output.splitlines():
        fields = raw_line.split()
        if len(fields) < 2 or fields[1] not in {PULSE_MODULE, PIPEWIRE_MODULE}:
            continue
        try:
            module_ids.append(int(fields[0]))
        except ValueError:
            continue
    return module_ids


def decode_avahi(text: str) -> str:
    decoded = bytearray()
    cursor = 0
    for match in AVAHI_ESCAPE.finditer(text):
        decoded.extend(text[cursor:match.start()].encode("utf-8"))
        value = int(match.group(1), 10)
        if value <= 255:
            decoded.append(value)
        else:
            decoded.extend(match.group(0).encode("utf-8"))
        cursor = match.end()

    decoded.extend(text[cursor:].encode("utf-8"))
    # Avahi escapes each byte, so decode the reconstructed byte stream once.
    return decoded.decode("utf-8", errors="replace")


def parse_avahi_receivers(output: str) -> list[dict[str, Any]]:
    receivers: dict[str, dict[str, Any]] = {}
    for raw_line in output.splitlines():
        fields = raw_line.split(";", 9)
        if len(fields) < 10 or fields[0] != "=":
            continue

        service_name = decode_avahi(fields[3])
        hostname = decode_avahi(fields[6])
        address = fields[7]
        txt = {key: decode_avahi(value) for key, value in TXT_FIELD.findall(fields[9])}
        room = service_name.split("@", 1)[-1] if "@" in service_name else service_name
        vendor = "Sonos" if hostname.lower().startswith("sonos-") else ""
        key = service_name.lower()
        current = receivers.get(key)
        receiver = {
            "name": room,
            "hostname": hostname,
            "address": address,
            "port": int(fields[8]),
            "vendor": vendor,
            "model": txt.get("am", ""),
        }
        # Prefer the IPv4 record because PipeWire includes that address in the
        # generated RAOP node name for discovered receivers.
        if current is None or (":" in current["address"] and ":" not in address):
            receivers[key] = receiver
    return list(receivers.values())


def discover_receivers(runner: CommandRunner) -> list[dict[str, Any]]:
    result = runner(["avahi-browse", "-rtp", "_raop._tcp"])
    return parse_avahi_receivers(result.stdout) if result.returncode == 0 else []


def read_state(path: Path) -> dict[str, Any]:
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        return {}
    return payload if isinstance(payload, dict) else {}


def write_state(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(payload, separators=(",", ":")), encoding="utf-8")
    temporary.replace(path)


def command_error(result: subprocess.CompletedProcess[str], fallback: str) -> str:
    detail = (result.stderr or result.stdout or "").strip()
    return detail.splitlines()[-1] if detail else fallback


def checked(runner: CommandRunner, command: Sequence[str]) -> str:
    result = runner(command)
    if result.returncode:
        raise RuntimeError(command_error(result, f"{command[0]} failed"))
    return result.stdout.strip()


def route_output(name: str, runner: CommandRunner) -> None:
    checked(runner, ["pactl", "set-default-sink", name])
    # WirePlumber applies default metadata asynchronously after pactl returns.
    for _ in range(20):
        if checked(runner, ["pactl", "get-default-sink"]) == name:
            break
        time.sleep(0.1)
    else:
        raise RuntimeError("The selected output did not become the default")
    streams = json.loads(checked(runner, ["pactl", "-f", "json", "list", "sink-inputs"]))
    for stream in streams:
        app = stream.get("properties", {}).get("application.name")
        # Processing and combine streams must stay on their physical targets.
        if app and app != "EasyEffects":
            checked(runner, ["pactl", "move-sink-input", str(stream["index"]), name])


def remove_group(state: dict[str, Any], runner: CommandRunner) -> None:
    module_id = state.get("groupModuleId")
    if not isinstance(module_id, int):
        return
    modules = checked(runner, ["pactl", "list", "modules", "short"])
    # IDs can be reused after a server restart; verify our unique sink name too.
    for line in modules.splitlines():
        fields = line.split("\t")
        if (len(fields) >= 3 and fields[0] == str(module_id) and fields[1] == "module-combine-sink"
                and f"sink_name={state.get('groupName')}" in fields[2].split()):
            checked(runner, ["pactl", "unload-module", str(module_id)])


def select_outputs(
    names: list[str], *, local_name: str = "", runner: CommandRunner = run_command, path: Path | None = None,
) -> tuple[dict[str, Any], int]:
    path = path or state_path()
    state = read_state(path)
    names = list(dict.fromkeys(names))
    if local_name and names:
        return {"ok": False, "error": "Choose a local output or AirPlay speakers, not both."}, 1
    sinks = json.loads(checked(runner, ["pactl", "-f", "json", "list", "sinks"]))
    if local_name and not any(sink["name"] == local_name
                              and not local_name.startswith(("raop_sink.", "foamy_airplay_group_")) for sink in sinks):
        return {"ok": False, "error": "The local output is no longer available."}, 1
    available = {sink["name"] for sink in sinks if sink["name"].startswith("raop_sink.")}
    if any(name not in available for name in names):
        return {"ok": False, "error": "An AirPlay speaker is no longer available. Reopen the panel."}, 1
    target = names[0] if names else local_name or state.get("restoreName", "")
    if not target:
        return {"ok": False, "error": "No local output is available"}, 1
    group: dict[str, Any] = {}
    if len(names) > 1:
        group_name = f"foamy_airplay_group_{os.getpid()}"
        module_id = int(checked(runner, [
            "pactl", "load-module", "module-combine-sink", f"sink_name={group_name}",
            "sinks=" + ",".join(names), "latency_compensate=true",
            'sink_properties=device.description="AirPlay group"',
        ]))
        group = {"groupModuleId": module_id, "groupName": group_name}
        target = group_name
    previous = checked(runner, ["pactl", "get-default-sink"])
    try:
        route_output(target, runner)
    except (RuntimeError, OSError, subprocess.SubprocessError):
        # Roll back before removing a new group so apps never target a dead sink.
        try:
            route_output(previous, runner)
        finally:
            remove_group(group, runner)
        raise
    remove_group(state, runner)
    state.pop("groupModuleId", None)
    state.pop("groupName", None)
    state.update(group)
    state["selectedNames"] = names
    if local_name:
        state["restoreName"] = local_name
        state["restoreId"] = str(next(sink["index"] for sink in sinks if sink["name"] == local_name))
    write_state(path, state)
    return {"ok": True, "error": "", "selectedNames": names, "target": target}, 0


def module_ids(runner: CommandRunner) -> tuple[list[int], str]:
    result = runner(["pactl", "list", "modules", "short"])
    if result.returncode != 0:
        return [], command_error(result, "Could not inspect PipeWire modules")
    return parse_module_ids(result.stdout), ""


def start_discovery(
    restore_id: str,
    restore_name: str,
    *,
    runner: CommandRunner = run_command,
    path: Path | None = None,
    module_path: Path = MODULE_PATH,
) -> tuple[dict[str, Any], int]:
    path = path or state_path()
    current_state = read_state(path)
    existing_ids, error = module_ids(runner)
    if error:
        return {"ok": False, "error": error}, 1

    remembered_id = current_state.get("moduleId")
    remembered_owned = current_state.get("owned") is True
    if remembered_id in existing_ids:
        module_id = int(remembered_id)
        owned = remembered_owned
    elif existing_ids:
        # Reuse a module enabled elsewhere, but never unload what this panel
        # did not create.
        module_id = existing_ids[0]
        owned = False
    else:
        if not module_path.is_file():
            return {
                "ok": False,
                "error": "AirPlay support is not installed (pipewire-zeroconf)",
            }, 2
        result = runner(["pactl", "load-module", PULSE_MODULE])
        if result.returncode != 0:
            return {
                "ok": False,
                "error": command_error(result, "Could not start AirPlay discovery"),
            }, result.returncode or 1
        try:
            module_id = int(result.stdout.strip())
        except ValueError:
            return {"ok": False, "error": "PipeWire returned an invalid AirPlay module id"}, 1
        owned = True

    peers = discover_receivers(runner)
    payload = {
        "moduleId": module_id,
        "owned": owned,
        "restoreId": str(restore_id or current_state.get("restoreId") or ""),
        "restoreName": str(restore_name or current_state.get("restoreName") or ""),
        "peers": peers,
    }
    for key in ("groupModuleId", "groupName", "selectedNames"):
        if key in current_state:
            payload[key] = current_state[key]
    write_state(path, payload)
    return {"ok": True, "error": "", **payload}, 0


def stop_discovery(
    restore_id: str = "",
    restore_name: str = "",
    *,
    skip_restore: bool = False,
    runner: CommandRunner = run_command,
    path: Path | None = None,
) -> tuple[dict[str, Any], int]:
    path = path or state_path()
    current_state = read_state(path)
    target_name = str(restore_name or current_state.get("restoreName") or "")
    errors: list[str] = []

    if not skip_restore and target_name:
        route_output(target_name, runner)

    remove_group(current_state, runner)

    module_id = current_state.get("moduleId")
    if current_state.get("owned") is True and isinstance(module_id, int):
        existing_ids, error = module_ids(runner)
        if error:
            errors.append(error)
        elif module_id in existing_ids:
            result = runner(["pactl", "unload-module", str(module_id)])
            if result.returncode != 0:
                errors.append(command_error(result, "Could not stop AirPlay discovery"))

    # Keep ownership information when teardown fails so a retry can clean up.
    if not errors:
        try:
            path.unlink(missing_ok=True)
        except OSError as error:
            errors.append(f"Could not clear AirPlay session state: {error}")

    return {
        "ok": not errors,
        "error": "; ".join(errors),
        "restoreName": target_name,
    }, 0 if not errors else 1


def discovery_status(
    *,
    runner: CommandRunner = run_command,
    path: Path | None = None,
) -> tuple[dict[str, Any], int]:
    path = path or state_path()
    current_state = read_state(path)
    existing_ids, error = module_ids(runner)
    if error:
        return {"ok": False, "active": False, "error": error}, 1

    module_id = current_state.get("moduleId")
    active = isinstance(module_id, int) and module_id in existing_ids
    if current_state and not active:
        path.unlink(missing_ok=True)
        current_state = {}
    return {"ok": True, "active": active, "error": "", **current_state}, 0


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    start = subparsers.add_parser("start", help="Start or reuse RAOP discovery")
    start.add_argument("--restore-id", default="")
    start.add_argument("--restore-name", default="")

    stop = subparsers.add_parser("stop", help="Restore local audio and stop owned discovery")
    stop.add_argument("--restore-id", default="")
    stop.add_argument("--restore-name", default="")
    stop.add_argument("--skip-restore", action="store_true")

    subparsers.add_parser("status", help="Report a recoverable discovery session")
    select = subparsers.add_parser("select", help="Route applications to selected AirPlay speakers")
    select.add_argument("names", nargs="*")
    select.add_argument("--local-name", default="", help="Select a local output while keeping discovery active")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        if args.command == "start":
            payload, return_code = start_discovery(args.restore_id, args.restore_name)
        elif args.command == "stop":
            payload, return_code = stop_discovery(
                args.restore_id,
                args.restore_name,
                skip_restore=args.skip_restore,
            )
        elif args.command == "select":
            payload, return_code = select_outputs(args.names, local_name=args.local_name)
        else:
            payload, return_code = discovery_status()
    except (OSError, subprocess.SubprocessError, RuntimeError, ValueError) as error:
        payload, return_code = {"ok": False, "error": f"AirPlay helper failed: {error}"}, 1
    emit(payload)
    return return_code


if __name__ == "__main__":
    raise SystemExit(main())
