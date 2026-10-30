#!/usr/bin/env python3
"""Check, add and remove UFW rules that let AirPlay speakers reach PipeWire.

PipeWire's RAOP sink receives timing/control traffic from each speaker on UDP
6001-6002. The rule this helper adds is scoped to the speakers' network: only
the local subnet (on the interface that reaches them) may send to those ports,
so the ports stay closed on any other network the computer joins later.
Only /usr/bin/ufw is elevated (pkexec), always with arguments built here.
"""

from __future__ import annotations

import argparse
import ipaddress
import json
import os
from pathlib import Path
import re
import subprocess
from typing import Any, Callable, Sequence

PORTS = (6001, 6002)
PORT_RANGE = "6001:6002"
COMMENT = "Foamy Audio AirPlay"
PKEXEC_UFW = ["/usr/bin/pkexec", "/usr/bin/ufw"]
STATUS_COMMAND = PKEXEC_UFW + ["status", "verbose"]
# The unrestricted rule earlier versions added (from anywhere, every interface).
LEGACY_DELETE_COMMAND = PKEXEC_UFW + ["delete", "allow", "6001:6002/udp"]
INTERFACE = re.compile(r"[A-Za-z0-9_.-]{1,15}")
Runner = Callable[[Sequence[str]], str]


def state_path() -> Path:
    base = os.environ.get("XDG_STATE_HOME") or str(Path.home() / ".local/state")
    return Path(os.environ.get("FOAMY_AUDIO_FIREWALL_STATE", Path(base) / "foamy-audio/firewall.json"))


def valid_scope(scope: Any) -> bool:
    if not isinstance(scope, dict) or not INTERFACE.fullmatch(str(scope.get("interface", ""))):
        return False
    try:
        ipaddress.ip_network(str(scope.get("network", "")))
    except ValueError:
        return False
    return True


def read_rules(path: Path) -> list[dict[str, str]]:
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return []
    rules = payload.get("rules", []) if isinstance(payload, dict) else []
    return [{"interface": rule["interface"], "network": rule["network"]} for rule in rules if valid_scope(rule)]


def write_rules(path: Path, rules: list[dict[str, str]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps({"rules": rules}, separators=(",", ":")), encoding="utf-8")
    temporary.replace(path)


def run_local(command: Sequence[str]) -> str:
    result = subprocess.run(list(command), capture_output=True, text=True, timeout=10,
                            env={**os.environ, "LC_ALL": "C"}, check=False)
    if result.returncode:
        raise RuntimeError((result.stderr or result.stdout).strip() or f"{command[0]} failed")
    return result.stdout


def scope_for(address: str, runner: Runner = run_local) -> dict[str, str]:
    """The interface and network through which this computer reaches a speaker."""
    peer = ipaddress.ip_address(address)
    routes = json.loads(runner(["ip", "-j", "route", "get", str(peer)]))
    route = routes[0] if routes else {}
    interface = str(route.get("dev", "")).split("@", 1)[0]
    if not INTERFACE.fullmatch(interface):
        raise RuntimeError(f"No local interface reaches {peer}.")
    # A routed speaker (not on the local subnet) gets a rule for its address only.
    network = ipaddress.ip_network(f"{peer}/{peer.max_prefixlen}")
    if "gateway" not in route:
        family = "-6" if peer.version == 6 else "-4"
        for link in json.loads(runner(["ip", "-j", family, "addr", "show", "dev", interface])):
            for info in link.get("addr_info", []):
                try:
                    local = ipaddress.ip_interface(f"{info['local']}/{info['prefixlen']}")
                except (KeyError, ValueError):
                    continue
                if peer in local.network:
                    network = local.network
    return {"interface": interface, "network": str(network)}


def rule_arguments(scope: dict[str, str]) -> list[str]:
    return ["in", "on", scope["interface"], "proto", "udp", "from", scope["network"],
            "to", "any", "port", PORT_RANGE]


def allow_command(scope: dict[str, str]) -> list[str]:
    return PKEXEC_UFW + ["allow"] + rule_arguments(scope) + ["comment", COMMENT]


def delete_command(scope: dict[str, str]) -> list[str]:
    return PKEXEC_UFW + ["delete", "allow"] + rule_arguments(scope)


def covers_ports(destination: str) -> tuple[set[int], str]:
    """The ports of PORTS a rule destination covers, and its interface ("" = any)."""
    value = destination.replace(" (v6)", "")
    interface = ""
    if " on " in value:
        value, interface = value.split(" on ", 1)
        interface = interface.strip()
    # A destination address can precede the port; it still matters for denies.
    if " " in value:
        value = value.rsplit(" ", 1)[-1]
    if value.endswith("/tcp"):
        return set(), interface
    value = value.removesuffix("/udp")
    if value == "Anywhere":
        return set(PORTS), interface
    result = set()
    for part in value.split(","):
        if re.fullmatch(r"\d+(?::\d+)?", part):
            bounds = [int(number) for number in part.split(":")]
            result.update(port for port in PORTS if bounds[0] <= port <= bounds[-1])
    return result, interface


def parse_rules(output: str) -> list[dict[str, Any]]:
    rules = []
    for line in output.splitlines():
        rule, _, comment = line.partition(" # ")
        match = re.fullmatch(r"(.+?)\s+(ALLOW|DENY|REJECT|LIMIT)\s+(IN|OUT|FWD)\s+(.+)", rule.strip())
        if not match or match.group(3) != "IN":
            continue
        destination, action, _direction, source = match.groups()
        ports, interface = covers_ports(destination)
        if not ports:
            continue
        source_value = source.replace(" (v6)", "").strip()
        try:
            network = None if source_value == "Anywhere" else ipaddress.ip_network(source_value, strict=False)
        except ValueError:
            continue
        rules.append({
            "action": action, "ports": ports, "interface": interface, "network": network,
            "v6": "(v6)" in destination or "(v6)" in source,
            # A destination address limits which local address is reachable.
            "plainDestination": bool(re.fullmatch(r"(?:Anywhere|[\d:,]+)(?:/udp)?(?: on \S+)?(?: \(v6\))?",
                                                  destination.strip())),
            "owned": comment.strip() == COMMENT,
        })
    return rules


def rule_applies(rule: dict[str, Any], peer: dict[str, str]) -> bool:
    address = ipaddress.ip_address(peer["address"])
    if rule["interface"] and rule["interface"] != peer.get("interface"):
        return False
    if rule["network"] is None:
        return rule["v6"] == (address.version == 6)
    return address.version == rule["network"].version and address in rule["network"]


def inspect_status(output: str, peers: Sequence[dict[str, str]] = ()) -> dict[str, Any]:
    """peers: [{"address", "interface"}] for every speaker to check."""
    if "Status: inactive" in output:
        return {"state": "inactive", "message": "UFW is inactive.", "details": output.strip(), "legacy": False}
    if "Status: active" not in output:
        raise ValueError("UFW returned an unrecognized status.")
    rules = parse_rules(output)
    legacy = any(rule["owned"] and rule["network"] is None for rule in rules)
    owned = any(rule["owned"] and rule["network"] is not None for rule in rules)
    state, message = "missing", "No rule lets the speakers reach UDP 6001–6002."
    if not peers:
        if any(rule["action"] != "ALLOW" for rule in rules):
            state, message = "conflict", "A blocking UFW rule may affect AirPlay."
        elif owned:
            state, message = "present", "A Foamy Audio rule exists. Find speakers to check it."
        elif any(rule["network"] is None and rule["plainDestination"] and not rule["interface"] for rule in rules):
            state, message = "wide", "UDP 6001–6002 is open to every network."
    else:
        scoped_ok = wide_ok = True
        blocked = False
        for peer in peers:
            scoped: set[int] = set()
            wide: set[int] = set()
            for rule in (rule for rule in rules if rule_applies(rule, peer)):
                if rule["action"] != "ALLOW":
                    # Do not promise access when a deny/limit may precede an allow.
                    blocked = True
                elif rule["plainDestination"]:
                    (wide if rule["network"] is None else scoped).update(rule["ports"])
            scoped_ok = scoped_ok and set(PORTS) <= scoped
            wide_ok = wide_ok and set(PORTS) <= scoped | wide
        if blocked:
            state, message = "conflict", "A blocking UFW rule may affect AirPlay."
        elif scoped_ok:
            state, message = "open", "The speakers can reach UDP 6001–6002."
        elif wide_ok:
            state, message = "wide", "UDP 6001–6002 is open to every network."
    return {"state": state, "message": message, "details": output.strip(), "legacy": legacy}


def run_ufw(command: Sequence[str]) -> str:
    # Elevate only the system-owned UFW executable, never this writable helper.
    result = subprocess.run(list(command), capture_output=True, text=True, timeout=120,
                            env={**os.environ, "LC_ALL": "C"}, check=False)
    if result.returncode in (126, 127):
        raise RuntimeError("Administrator authorization was cancelled or denied.")
    if result.returncode:
        raise RuntimeError((result.stderr or result.stdout).strip() or "UFW failed.")
    return result.stdout


def verify(peers: Sequence[str], *, runner: Runner = run_local, ufw: Runner = run_ufw) -> dict[str, Any]:
    checked = [{"address": address, **scope_for(address, runner)} for address in peers]
    return inspect_status(ufw(STATUS_COMMAND), checked)


def apply(peers: Sequence[str], *, runner: Runner = run_local, ufw: Runner = run_ufw,
          path: Path | None = None) -> dict[str, Any]:
    if not peers:
        return {"state": "nopeers", "message": "No AirPlay speakers found.", "details": ""}
    path = path or state_path()
    scopes: list[dict[str, str]] = []
    for address in peers:
        scope = scope_for(address, runner)
        if scope not in scopes:
            scopes.append(scope)
    recorded = read_rules(path)
    details = []
    # One authorization per network; nearly always a single home subnet.
    for scope in scopes:
        details.append(ufw(allow_command(scope)).strip())
        if scope not in recorded:
            recorded.append(scope)
            write_rules(path, recorded)
    return {"state": "applied", "message": "Rules applied. Verify to check.",
            "details": "\n".join(details), "rules": scopes}


def remove(legacy: bool, *, ufw: Runner = run_ufw, path: Path | None = None) -> dict[str, Any]:
    path = path or state_path()
    recorded = read_rules(path)
    if not recorded and not legacy:
        return {"state": "none", "message": "No Foamy Audio rules to remove.", "details": ""}
    details = []
    for scope in list(recorded):
        # "Could not delete non-existent rule" exits 0 too: the rule is gone either way.
        details.append(ufw(delete_command(scope)).strip())
        recorded.remove(scope)
        write_rules(path, recorded)
    if legacy:
        details.append(ufw(LEGACY_DELETE_COMMAND).strip())
    return {"state": "removed", "message": "Rules removed.", "details": "\n".join(details)}


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("verify", "open", "remove"))
    parser.add_argument("--peer", action="append", default=[], help="speaker address (repeatable)")
    parser.add_argument("--legacy", action="store_true", help="also remove the unrestricted rule of earlier versions")
    args = parser.parse_args(argv)
    try:
        peers = [str(ipaddress.ip_address(address)) for address in dict.fromkeys(args.peer)]
        if args.action == "open":
            # Verification is a separate action so applying asks for authorization once.
            payload = apply(peers)
        elif args.action == "remove":
            payload = remove(args.legacy)
        else:
            payload = verify(peers)
    except (OSError, subprocess.SubprocessError, ValueError, RuntimeError, KeyError) as error:
        message = {"open": "Could not apply UFW rules.", "remove": "Could not remove UFW rules."}.get(
            args.action, "Could not complete the UFW check.")
        print(json.dumps({"state": "error", "message": message, "details": str(error)}))
        return 1
    print(json.dumps(payload))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
