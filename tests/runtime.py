#!/usr/bin/env python3
"""Load Foamy Audio offscreen on Omarchy 4.5
with the foamy-kit harness: isolated HOME/XDG/runtime dirs, no Wayland or
Hyprland, no PipeWire or Pulse reachable. Checks tests/qml/Runtime.qml plus
`qs ipc call foamy.audio status` answered by the leader.

The audio tools the plugin and the host shell run (pactl, avahi-browse,
pw-record, pw-link, wpctl and the omarchy-audio-* scripts) are logging fakes
that fail like an unreachable server; Omarchy's bin directories are dropped
from PATH, PULSE_SERVER and PIPEWIRE_REMOTE point nowhere, and an AppImage's
LD_LIBRARY_PATH ($APPDIR) is dropped. So the live PipeWire graph, its modules
and the microphone stay out of reach even when the caller's environment names
a server.

FOAMY_KIT (default ~/GitHub/Personal/foamy-kit) provides the harness.
The host is Omarchy 4.5: FOAMY_HOST_45, else $OMARCHY_TEST_ROOT/shell, else
the installed /usr/share/omarchy/shell."""
import json
import os
from pathlib import Path
import subprocess
import sys
import time

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


# Fails like pactl and friends without a server; the AirPlay helper reports
# the last stderr line, which Runtime.qml checks (FAKE_ERROR).
FAKE_ERROR = "fake audio tool: no server in tests"
FAKE = f"""#!/bin/sh
printf '%s\\n' "${{0##*/}} $*" >> "$FOAMY_OUT/calls.log"
echo "{FAKE_ERROR}" >&2
exit 1
"""
FAKES = ("pactl", "avahi-browse", "pw-record", "pw-link", "wpctl", "omarchy-audio-output-sink",
         "omarchy-audio-sink-availability", "omarchy-audio-tuning", "omarchy-audio-output-set-default",
         "omarchy-audio-input-set-default")


def isolate(env, host):
    """Drops Omarchy's bin directories and an AppImage's libraries; no audio server is named."""
    bins = {os.path.realpath("/usr/share/omarchy/bin"), os.path.realpath(Path(host).parent / "bin")}
    env["PATH"] = ":".join(p for p in env["PATH"].split(":") if p and os.path.realpath(p) not in bins)
    appdir = os.environ.get("APPDIR", "").rstrip("/")
    env["LD_LIBRARY_PATH"] = ":".join(p for p in env.get("LD_LIBRARY_PATH", "").split(":")
                                      if p and not (appdir and (p == appdir or p.startswith(appdir + "/"))))
    env.update(PULSE_SERVER=f"unix:{env['XDG_RUNTIME_DIR']}/no-pulse", PIPEWIRE_REMOTE="no-pipewire",
               FOAMY_FAKE_ERROR=FAKE_ERROR)


def ipc_status(run):
    by_id = Path(run.env["XDG_RUNTIME_DIR"]) / "quickshell/by-id"
    for _ in range(100):
        ids = [p.name for p in by_id.iterdir()] if by_id.is_dir() else []
        if ids and "FOAMY READY" in (run.base / "qs.log").read_text(errors="replace"):
            break
        time.sleep(0.1)
    else:
        return None
    result = subprocess.run(["qs", "ipc", "-i", ids[0], "call", "foamy.audio", "status"], env=run.env,
                            capture_output=True, text=True, timeout=10)
    return result.stdout.strip() if result.returncode == 0 else None


def run(host, lang):
    shell = (PLUGIN / "tests/qml/Runtime.qml").read_text()
    r = harness.Run(host, shell, plugin=PLUGIN, language=lang, prefix=f"foamy-audio-runtime-{host}-{lang}-",
                    fakebin={name: FAKE for name in FAKES})
    r.env.update(FOAMY_LANG=lang, FOAMY_HOLD_MS="3000")
    isolate(r.env, r.host)
    log_path = r.base / "qs.log"
    process = subprocess.Popen(["qs", "-p", str(r.root), "--no-color"], env=r.env, stdout=log_path.open("w"),
                               stderr=subprocess.STDOUT, start_new_session=True)
    try:
        status = ipc_status(r)
        process.wait(timeout=60)
    finally:
        if process.poll() is None:
            process.kill()
    log = log_path.read_text(errors="replace")
    result = next((line.split("FOAMY RESULT ", 1)[1] for line in log.splitlines() if "FOAMY RESULT" in line), "no result")
    failures = [line for line in log.splitlines() if "FOAMY FAIL" in line or any(m in line for m in harness.FAILURE_MARKERS)]
    try:
        leader = status is not None and json.loads(status).get("leader") is True
    except ValueError:
        leader = False
    # The AirPlay helper ran pactl, and it was the fake.
    calls_log = r.out / "calls.log"
    calls = calls_log.read_text().splitlines() if calls_log.exists() else []
    if "pactl list modules short" not in calls:
        failures.append(f"FOAMY FAIL the fake pactl never ran: {calls}")
    ok = "FOAMY DONE" in log and not failures and leader
    print(f"{'PASS' if ok else 'FAIL'} runtime {host} {lang}: {result}; ipc status from leader: {leader}")
    if not ok:
        print("\n".join("    " + line for line in (failures or log.splitlines()[-40:])))
    else:
        r.cleanup()
    return ok


if __name__ == "__main__":
    cases = [("4.5", "en"), ("4.5", "no"), ("4.5", "ar")]
    results = [run(host, lang) for host, lang in cases]
    raise SystemExit(0 if all(results) else 1)
