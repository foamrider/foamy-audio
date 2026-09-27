#!/usr/bin/env python3
"""Inspect UFW's live status for unrestricted AirPlay timing/control rules."""

from __future__ import annotations

import json
import argparse
import os
from pathlib import Path
import re
import subprocess

PORTS = (6001, 6002)
STATUS_COMMAND = ["/usr/bin/pkexec", "/usr/bin/ufw", "status", "verbose"]
OPEN_COMMAND = ["/usr/bin/pkexec", "/usr/bin/ufw", "allow", "6001:6002/udp", "comment", "Foamy Audio AirPlay"]


def covers_ports(destination: str) -> set[int]:
    value = destination.replace(" (v6)", "")
    if " on " in value:
        value = value.split(" on ", 1)[0]
    # A destination address can precede the port; it still matters for denies.
    if " " in value:
        value = value.rsplit(" ", 1)[-1]
    if value.endswith("/tcp"):
        return set()
    value = value.removesuffix("/udp")
    if value == "Anywhere":
        return set(PORTS)
    result = set()
    for part in value.split(","):
        if re.fullmatch(r"\d+(?::\d+)?", part):
            bounds = [int(number) for number in part.split(":")]
            result.update(port for port in PORTS if bounds[0] <= port <= bounds[-1])
    return result


def inspect_status(output: str, ipv6_enabled: bool = True) -> dict:
    if "Status: inactive" in output:
        return {"state": "inactive", "message": "UFW is inactive.", "details": output.strip()}
    if "Status: active" not in output:
        raise ValueError("UFW returned an unrecognized status.")
    allowed = {False: set(), True: set()}
    restricted = False
    blocked = False
    for line in output.splitlines():
        rule = line.split(" # ", 1)[0].strip()
        match = re.fullmatch(r"(.+?)\s+(ALLOW|DENY|REJECT|LIMIT)\s+(IN|OUT|FWD)\s+(.+)", rule)
        if not match:
            continue
        destination, action, direction, source = match.groups()
        if direction != "IN":
            continue
        ports = covers_ports(destination)
        if not ports:
            continue
        if action != "ALLOW":
            # Do not promise access when a deny/limit may precede an allow.
            blocked = True
        elif (source in {"Anywhere", "Anywhere (v6)"}
              and re.fullmatch(r"(?:Anywhere|[\d:,]+)(?:/udp)?(?: \(v6\))?", destination)):
            allowed["(v6)" in source or "(v6)" in destination].update(ports)
        else:
            restricted = True
    ready = set(PORTS) <= allowed[False] and (not ipv6_enabled or set(PORTS) <= allowed[True])
    if blocked:
        state, message = "conflict", "A blocking UFW rule may affect AirPlay. Review the rules below."
    elif ready:
        state, message = "open", "UDP ports 6001–6002 are allowed without IP or interface restrictions."
    elif restricted:
        state, message = "restricted", "AirPlay rules are restricted. UDP ports 6001–6002 are not open to all sources."
    else:
        state, message = "missing", "Unrestricted rules for UDP ports 6001–6002 were not found."
    return {"state": state, "message": message, "details": output.strip()}


def run_ufw(command: list[str]) -> str:
    # Elevate only the system-owned UFW executable, never this writable helper.
    result = subprocess.run(command, capture_output=True, text=True, timeout=120,
                            env={**os.environ, "LC_ALL": "C"}, check=False)
    if result.returncode in (126, 127):
        raise RuntimeError("Administrator authorization was cancelled or denied.")
    if result.returncode:
        raise RuntimeError((result.stderr or result.stdout).strip() or "Could not read UFW status.")
    return result.stdout


def verify() -> dict:
    output = run_ufw(STATUS_COMMAND)
    defaults = Path("/etc/default/ufw").read_text()
    ipv6_enabled = not re.search(r'^IPV6=["\']?no["\']?\s*$', defaults, re.MULTILINE)
    return inspect_status(output, ipv6_enabled)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("verify", "open"))
    args = parser.parse_args()
    try:
        if args.action == "open":
            output = run_ufw(OPEN_COMMAND)
            # Verification is a separate action so applying asks for authorization once.
            payload = {"state": "applied", "message": "Rules applied. Verify to check.", "details": output.strip()}
        else:
            payload = verify()
    except (OSError, subprocess.SubprocessError, ValueError, RuntimeError) as error:
        message = "Could not apply UFW rules." if args.action == "open" else "Could not complete the UFW check."
        print(json.dumps({"state": "error", "message": message, "details": str(error)}))
        return 1
    print(json.dumps(payload))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
