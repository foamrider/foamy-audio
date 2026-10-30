#!/usr/bin/env python3
"""Load Foamy Audio offscreen under both hosts (4.0.6 installed, 4.5 reference)
with the foamy-kit harness: isolated HOME/XDG/runtime dirs, no Wayland or
Hyprland, no PipeWire or Pulse reachable. Checks tests/qml/Runtime.qml plus
`qs ipc call foamy.audio status` answered by the leader.

FOAMY_KIT (default ~/GitHub/Personal/foamy-kit) provides the harness;
FOAMY_HOST_40 / FOAMY_HOST_45 override the host shells."""
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
sys.path.insert(0, str(KIT / "preview"))
import harness  # noqa: E402


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
    r = harness.Run(host, shell, plugin=PLUGIN, language=lang, prefix=f"foamy-audio-runtime-{host}-{lang}-")
    r.env.update(FOAMY_LANG=lang, FOAMY_HOLD_MS="3000")
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
    ok = "FOAMY DONE" in log and not failures and leader
    print(f"{'PASS' if ok else 'FAIL'} runtime {host} {lang}: {result}; ipc status from leader: {leader}")
    if not ok:
        print("\n".join("    " + line for line in (failures or log.splitlines()[-40:])))
    else:
        r.cleanup()
    return ok


if __name__ == "__main__":
    cases = [("4.0", "en"), ("4.5", "en"), ("4.5", "no"), ("4.5", "ar")]
    results = [run(host, lang) for host, lang in cases]
    raise SystemExit(0 if all(results) else 1)
