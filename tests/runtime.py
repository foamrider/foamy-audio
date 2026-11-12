#!/usr/bin/env python3
"""Load Foamy Audio offscreen on Omarchy 4.5
with the foamy-kit harness: isolated HOME/XDG/runtime dirs, no Wayland or
Hyprland, no PipeWire or Pulse reachable. Checks tests/qml/Runtime.qml plus
`qs ipc call foamy.audio status` answered by the leader.

The audio tools the plugin and the host shell run (pactl, avahi-browse,
pw-record, pw-link, wpctl and the omarchy-audio-* scripts) are logging fakes
that fail like an unreachable server. The harness isolates the rest: no
Omarchy bin directory or $APPDIR on PATH or LD_LIBRARY_PATH, every other
omarchy command a logging stub (the test fails if one ran), PULSE_SERVER and
PIPEWIRE_REMOTE at dead sockets. So the live PipeWire graph, its modules and
the microphone stay out of reach even when the caller's environment names a
server.

FOAMY_KIT (default ~/GitHub/Personal/foamy-kit) provides the harness.
The host is Omarchy 4.5: FOAMY_HOST_45, else $OMARCHY_TEST_ROOT/shell, else
the installed /usr/share/omarchy/shell."""

import json
import os
from pathlib import Path
import subprocess
import sys

PLUGIN = Path(__file__).resolve().parents[1]
KIT = Path(os.environ.get("FOAMY_KIT", Path.home() / "GitHub/Personal/foamy-kit"))
if not (KIT / "preview/harness.py").exists():
    print(f"SKIP: foamy-kit harness not found at {KIT} (set FOAMY_KIT)")
    raise SystemExit(0)
# Set before the harness reads its hosts.
if not os.environ.get("FOAMY_HOST_45"):
    _root = os.environ.get("OMARCHY_TEST_ROOT")
    os.environ["FOAMY_HOST_45"] = str(Path(_root) / "shell") if _root else "/usr/share/omarchy/shell"
sys.path.insert(0, str(KIT / "preview"))
import harness  # noqa: E402
import hostenv  # noqa: E402


# Fails like pactl and friends without a server; the AirPlay helper reports
# the last stderr line, which Runtime.qml checks (FAKE_ERROR).
FAKE_ERROR = "fake audio tool: no server in tests"
FAKE = f"""#!/bin/sh
printf '%s\\n' "${{0##*/}} $*" >> "$FOAMY_OUT/calls.log"
echo "{FAKE_ERROR}" >&2
exit 1
"""
FAKES = (
    "pactl",
    "avahi-browse",
    "pw-record",
    "pw-link",
    "wpctl",
    "omarchy-audio-output-sink",
    "omarchy-audio-sink-availability",
    "omarchy-audio-tuning",
    "omarchy-audio-output-set-default",
    "omarchy-audio-input-set-default",
)


def ipc_status(run):
    """The leader's `status` reply once the scene logged FOAMY READY, or None."""
    if not run.wait_for_log("FOAMY READY", 60):
        print("    no FOAMY READY before the IPC call")
        return None
    by_id = Path(run.env["XDG_RUNTIME_DIR"]) / "quickshell/by-id"
    ids = [p.name for p in by_id.iterdir()] if by_id.is_dir() else []
    if not ids:
        print("    no quickshell instance to call")
        return None
    result = subprocess.run(
        ["qs", "ipc", "-i", ids[0], "call", "foamy.audio", "status"],
        env=run.env,
        capture_output=True,
        text=True,
        timeout=10,
    )
    if result.returncode != 0:
        print("    qs ipc failed: " + result.stderr.strip()[-300:])
        return None
    return result.stdout.strip()


def run(host, lang):
    shell = (PLUGIN / "tests/qml/Runtime.qml").read_text()
    # The prefix names the run's temp dir. qs's IPC socket is not under it: the
    # harness keeps the runtime dir and bus sockets in its own short directory
    # (Run.sockets), so a long TMPDIR can't push them past 107 bytes.
    r = harness.Run(
        host, shell, plugin=PLUGIN, language=lang, prefix=f"fa-rt-{lang}-", fakebin={name: FAKE for name in FAKES}
    )
    # The harness drops Omarchy's bin dirs and $APPDIR, stubs every other
    # omarchy command and points PULSE_SERVER/PIPEWIRE_REMOTE at dead sockets.
    r.env.update(FOAMY_LANG=lang, FOAMY_HOLD_MS="3000", FOAMY_FAKE_ERROR=FAKE_ERROR)
    r.start()
    try:
        status = ipc_status(r)
        r.wait(60)
    finally:
        r.stop()
    log = r.log
    result = next(
        (line.split("FOAMY RESULT ", 1)[1] for line in log.splitlines() if "FOAMY RESULT" in line), "no result"
    )
    failures = r.failures()
    try:
        leader = status is not None and json.loads(status).get("leader") is True
    except ValueError:
        leader = False
    # The AirPlay helper ran pactl, and it was the fake.
    calls_log = r.out / "calls.log"
    calls = calls_log.read_text().splitlines() if calls_log.exists() else []
    if "pactl list modules short" not in calls:
        failures.append(f"FOAMY FAIL the fake pactl never ran: {calls}")
    # Every host command the plugin runs has a fake; nothing reached a stub.
    if r.host_commands():
        failures.append(f"FOAMY FAIL host commands ran without a fake: {r.host_commands()}")
    ok = "FOAMY DONE" in log and not failures and leader
    print(f"{'PASS' if ok else 'FAIL'} runtime {host} {lang}: {result}; ipc status from leader: {leader}")
    if not ok:
        print("\n".join("    " + line for line in (failures or log.splitlines()[-40:])))
    else:
        r.cleanup()
    return ok


# The helper as a fake: `status` reports a session a crashed shell left
# active, `stop` succeeds; every call is logged.
LEFTOVER_HELPER = """#!/bin/sh
printf '%s\\n' "$*" >> "$FOAMY_OUT/helper.log"
case "$1 $2" in
  "airplay status") echo '{"ok":true,"active":true,"error":"","peers":[],"selectedNames":[]}' ;;
  "airplay stop") echo '{"ok":true,"error":""}' ;;
  *) echo '{"ok":false,"error":"fake helper: unexpected call"}'; exit 1 ;;
esac
"""


def run_leftover():
    """Discovery a crashed shell left running stops only under a local output."""
    r = harness.Run(
        "4.5",
        (PLUGIN / "tests/qml/Leftover.qml").read_text(),
        plugin=None,
        prefix="fa-lo-",
        fakebin={name: FAKE for name in FAKES},
    )
    plugin = hostenv.fake_helper_plugin(PLUGIN, r.base / "plugin-copy", "foamy-audio-helper", LEFTOVER_HELPER)
    (r.root / "plugin").symlink_to(plugin, target_is_directory=True)
    r.env.update(FOAMY_FAKE_ERROR=FAKE_ERROR)
    r.run(60)
    calls_log = r.out / "helper.log"
    calls = calls_log.read_text().splitlines() if calls_log.exists() else []
    failures = r.failures()
    if calls != ["airplay status", "airplay stop --skip-restore"]:
        failures.append(f"FOAMY FAIL helper calls: {calls}")
    if r.host_commands():
        failures.append(f"FOAMY FAIL host commands ran without a fake: {r.host_commands()}")
    result = next(
        (line.split("FOAMY RESULT ", 1)[1] for line in r.log.splitlines() if "FOAMY RESULT" in line), "no result"
    )
    ok = "FOAMY DONE" in r.log and not failures
    print(f"{'PASS' if ok else 'FAIL'} runtime leftover discovery: {result}")
    if not ok:
        print("\n".join("    " + line for line in (failures or r.log.splitlines()[-40:])))
    else:
        r.cleanup()
    return ok


if __name__ == "__main__":
    cases = [("4.5", "en"), ("4.5", "no"), ("4.5", "ar")]
    results = [run(host, lang) for host, lang in cases] + [run_leftover()]
    raise SystemExit(0 if all(results) else 1)
