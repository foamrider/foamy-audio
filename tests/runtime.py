#!/usr/bin/env python3
"""Load Foamy Audio offscreen on Omarchy 4.5
with the foamy-kit harness: isolated HOME/XDG/runtime dirs, no Wayland or
Hyprland, no PipeWire or Pulse reachable. Checks tests/qml/Runtime.qml plus
the leader's IPC handler (`settings`, `close`, `status` through `qs ipc call`)
once the scene logged FOAMY READY.

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
import shutil
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
# Each fake also notes its parent process (parents.log): the host scripts
# behind pactl must run under `timeout`, so a wedged pipewire-pulse cannot
# hold them forever.
NOTE_PARENT = (
    'read -r parent < "/proc/$PPID/comm"; printf \'%s %s\\n\' "${0##*/}" "$parent" >> "$FOAMY_OUT/parents.log"'
)
FAKE = f"""#!/bin/sh
printf '%s\\n' "${{0##*/}} $*" >> "$FOAMY_OUT/calls.log"
{NOTE_PARENT}
echo "{FAKE_ERROR}" >&2
exit 1
"""
# Answers alsa_output.fake.<n> for its n-th run, after 2 s: Runtime.qml asks
# again while the first run is still going, so the first answer is stale.
OUTPUT_SINK = f"""#!/bin/sh
printf '%s\\n' "${{0##*/}} $*" >> "$FOAMY_OUT/calls.log"
{NOTE_PARENT}
n=$(grep -c '^omarchy-audio-output-sink' "$FOAMY_OUT/calls.log")
sleep 2
echo "alsa_output.fake.$n"
"""
DEADLINED = ("omarchy-audio-output-sink", "omarchy-audio-sink-availability")
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


def ipc(run, call):
    """`qs ipc call foamy.audio <call>` on the run's one instance; its stdout, or None."""
    by_id = Path(run.env["XDG_RUNTIME_DIR"]) / "quickshell/by-id"
    ids = [p.name for p in by_id.iterdir()] if by_id.is_dir() else []
    if not ids:
        print("    no quickshell instance to call")
        return None
    result = subprocess.run(
        ["qs", "ipc", "-i", ids[0], "call", "foamy.audio", call],
        env=run.env,
        capture_output=True,
        text=True,
        timeout=10,
    )
    if result.returncode != 0:
        print(f"    qs ipc {call} failed: " + result.stderr.strip()[-300:])
        return None
    return result.stdout.strip()


def ipc_status_until(run, **wanted):
    """The leader's `status` once it shows the wanted values (at most 10 s), or the last one seen."""
    seen = {}

    def matches():
        reply = ipc(run, "status")
        try:
            seen["status"] = json.loads(reply) if reply else None
        except ValueError:
            seen["status"] = None
        status = seen["status"]
        return status is not None and all(status.get(key) == value for key, value in wanted.items())

    harness.wait_for(matches, 10, interval=0.2)
    return seen.get("status")


def ipc_flow(r, failures):
    """Settings opens the popup from closed on the Settings page; close resets it."""
    opened = ipc(r, "settings") is not None and ipc_status_until(r, open=True, settings=True, leader=True)
    if not (opened and opened.get("open") and opened.get("settings") and opened.get("leader")):
        failures.append(f"FOAMY FAIL ipc settings: status from the leader {opened}")
    closed = ipc(r, "close") is not None and ipc_status_until(r, open=False, settings=False)
    if not (closed and closed.get("open") is False and closed.get("settings") is False):
        failures.append(f"FOAMY FAIL ipc close: status {closed}")


def lines(path):
    return path.read_text().splitlines() if path.exists() else []


def run(host, lang):
    shell = (PLUGIN / "tests/qml/Runtime.qml").read_text()
    # The prefix names the run's temp dir. qs's IPC socket is not under it: the
    # harness keeps the runtime dir and bus sockets in its own short directory
    # (Run.sockets), so a long TMPDIR can't push them past 107 bytes.
    fakes = {name: FAKE for name in FAKES} | {"omarchy-audio-output-sink": OUTPUT_SINK}
    r = harness.Run(host, shell, plugin=PLUGIN, language=lang, prefix=f"fa-rt-{lang}-", fakebin=fakes)
    # The harness drops Omarchy's bin dirs and $APPDIR, stubs every other
    # omarchy command and points PULSE_SERVER/PIPEWIRE_REMOTE at dead sockets.
    r.env.update(FOAMY_LANG=lang, FOAMY_FAKE_ERROR=FAKE_ERROR)
    failures = []
    r.start()
    try:
        ready = r.wait_for_log("FOAMY READY", 60)
        # The runs the scene saw: it logs the volume sink just before READY,
        # and the IPC calls below may start more.
        sink_runs = sum(line.startswith("omarchy-audio-output-sink") for line in lines(r.out / "calls.log"))
        if ready:
            ipc_flow(r, failures)
        else:
            failures.append("FOAMY FAIL no FOAMY READY before the IPC calls")
    finally:
        r.stop()
    log = r.log
    result = next(
        (line.split("FOAMY RESULT ", 1)[1] for line in log.splitlines() if "FOAMY RESULT" in line), "no result"
    )
    failures += r.failures()
    calls = lines(r.out / "calls.log")
    # The AirPlay helper ran pactl, and it was the fake.
    if "pactl list modules short" not in calls:
        failures.append(f"FOAMY FAIL the fake pactl never ran: {calls}")
    # A resolve asked for during a run reruns the script; the last answer wins.
    sink = next(
        (line.split("FOAMY VOLUME SINK ", 1)[1] for line in log.splitlines() if "FOAMY VOLUME SINK" in line), ""
    )
    if sink_runs < 2 or sink != f"alsa_output.fake.{sink_runs}":
        failures.append(f"FOAMY FAIL volume sink {sink!r} after {sink_runs} runs of omarchy-audio-output-sink")
    parents = [line.split(" ", 1) for line in lines(r.out / "parents.log")]
    for name in DEADLINED:
        seen = [parent for tool, parent in parents if tool == name]
        if not seen or any(parent != "timeout" for parent in seen):
            failures.append(f"FOAMY FAIL {name} must run under timeout: parents {seen}")
    # Every host command the plugin runs has a fake; nothing reached a stub.
    if r.host_commands():
        failures.append(f"FOAMY FAIL host commands ran without a fake: {r.host_commands()}")
    ok = "FOAMY DONE" in log and not failures
    print(f"{'PASS' if ok else 'FAIL'} runtime {host} {lang}: {result}; ipc from the leader")
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


# The helper as a scripted fake for tests/qml/Helper.qml: each call is logged
# with its arguments joined by "|" (so empty ones show). The first start,
# the kitchen choice and verify are slow (1-1.5 s), so the scene can act
# while they run; the answers cover refusals and replies that are not JSON.
# The cancel text is the one ufw.rs sends and Panel.qml matches (CANCELLED in
# tests/test_ufw_check.py).
HELPER = """#!/bin/sh
(IFS='|'; printf '%s\\n' "$*") >> "$FOAMY_OUT/helper.log"
case "$1 $2" in
  "airplay status") echo '{"ok":true,"active":false,"error":""}' ;;
  "airplay start")
    if [ ! -e "$FOAMY_OUT/started" ]; then : > "$FOAMY_OUT/started"; sleep 1.5; fi
    echo '{"ok":true,"error":"","moduleId":7,"owned":true,"peers":[{"name":"Kitchen","address":"192.0.2.39"},{"name":"Hall","address":"192.0.2.40"}]}' ;;
  "airplay stop") echo '{"ok":true,"error":"","restoreName":""}' ;;
  "airplay select")
    case "$3" in
      raop_sink.gone) echo '{"ok":false,"error":"An AirPlay speaker is no longer available. Reopen the panel."}'; exit 1 ;;
      raop_sink.garbage) echo oops ;;
      --local-name) echo "{\\"ok\\":true,\\"error\\":\\"\\",\\"selectedNames\\":[],\\"target\\":\\"$4\\"}" ;;
      raop_sink.kitchen) sleep 1; echo '{"ok":true,"error":"","selectedNames":["raop_sink.kitchen"],"target":"raop_sink.kitchen"}' ;;
      *) echo "{\\"ok\\":true,\\"error\\":\\"\\",\\"selectedNames\\":[\\"$3\\"],\\"target\\":\\"$3\\"}" ;;
    esac ;;
  "ufw verify") sleep 1; echo '{"state":"wide","message":"m","details":"d","legacy":true}' ;;
  "ufw remove")
    if [ "$3" = --legacy ]; then echo '{"state":"removed","message":"m","details":"d"}'; else echo 'not json'; fi ;;
  "ufw open")
    echo '{"state":"error","message":"Could not apply UFW rules.","details":"Administrator authorization was cancelled or denied."}'
    exit 1 ;;
  *) echo '{"ok":false,"error":"fake helper: unexpected call"}'; exit 1 ;;
esac
"""
START = "airplay|start|--restore-id||--restore-name|"
STOP = "airplay|stop|--skip-restore"
PEERS = "--peer|192.0.2.39|--peer|192.0.2.40"
# Without the startup `airplay|status`. A second select or firewall action
# sent while one runs must not show up. The last stop is the one the service
# sends when the scene removes its only panel.
HELPER_CALLS = [
    START,
    STOP,
    START,
    "airplay|select|raop_sink.kitchen",
    "ufw|verify|" + PEERS,
    "ufw|remove|--legacy",
    "ufw|remove",
    "ufw|open|" + PEERS,
    "airplay|select|raop_sink.gone",
    "airplay|select|--local-name|alsa_output.usb",
    "airplay|select|raop_sink.garbage",
    STOP,
    START,
    STOP,
]


def run_helper(mode):
    """tests/qml/Helper.qml: the helper protocol, or (nohelper) no helper for this CPU."""
    r = harness.Run(
        "4.5",
        (PLUGIN / "tests/qml/Helper.qml").read_text(),
        plugin=None,
        language="no",
        prefix=f"fa-hp-{mode}-",
        fakebin={name: FAKE for name in FAKES},
    )
    plugin = hostenv.fake_helper_plugin(PLUGIN, r.base / "plugin-copy", "foamy-audio-helper", HELPER)
    if mode == "nohelper":
        shutil.rmtree(plugin / "bin")
    (r.root / "plugin").symlink_to(plugin, target_is_directory=True)
    r.env.update(FOAMY_MODE=mode, FOAMY_FAKE_ERROR=FAKE_ERROR)
    r.run(60)
    failures = r.failures()
    log = r.out / "helper.log"
    expected = HELPER_CALLS if mode == "helper" else []
    # The stop after the panel is gone runs detached: it can land after qs quit.
    harness.wait_for(lambda: [call for call in lines(log) if call != "airplay|status"] == expected, 5)
    calls = lines(log)
    status = [call for call in calls if call == "airplay|status"]
    rest = [call for call in calls if call != "airplay|status"]
    if len(status) != (1 if expected else 0) or rest != expected:
        failures.append(f"FOAMY FAIL helper calls: {calls}")
    if r.host_commands():
        failures.append(f"FOAMY FAIL host commands ran without a fake: {r.host_commands()}")
    result = next(
        (line.split("FOAMY RESULT ", 1)[1] for line in r.log.splitlines() if "FOAMY RESULT" in line), "no result"
    )
    ok = "FOAMY DONE" in r.log and not failures
    print(f"{'PASS' if ok else 'FAIL'} runtime helper {mode}: {result}")
    if not ok:
        print("\n".join("    " + line for line in (failures or r.log.splitlines()[-40:])))
    else:
        r.cleanup()
    return ok


if __name__ == "__main__":
    cases = [("4.5", "en"), ("4.5", "no"), ("4.5", "ar")]
    results = [run(host, lang) for host, lang in cases] + [run_leftover(), run_helper("helper"), run_helper("nohelper")]
    raise SystemExit(0 if all(results) else 1)
