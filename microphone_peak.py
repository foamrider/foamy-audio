#!/usr/bin/env python3
"""Emit microphone levels only; audio samples stay in memory and are never saved."""

import argparse
import math
import os
import re
import selectors
import signal
import struct
import subprocess
import sys
import time


def channel_map(value: str) -> list[str]:
    channels = value.split(",")
    if not 1 <= len(channels) <= 64 or any(
        not re.fullmatch(r"(?:MONO|FL|FR|FC|LFE|RL|RR|SL|SR|RC|FLC|FRC|TC|TFL|TFC|TFR|TRL|TRC|TRR|AUX(?:[0-9]|[1-5][0-9]|6[0-3]))", c)
        for c in channels
    ):
        raise ValueError("unsupported microphone channel map")
    return channels


def peak_level(data: bytes) -> float:
    samples = [sample[0] for sample in struct.iter_unpack("<f", data)]
    if any(not math.isfinite(value) for value in samples):
        raise ValueError("invalid microphone sample")
    return min(1.0, math.cbrt(max((abs(value) for value in samples), default=0.0)))


def monitor(target: str, layout: str, passive: bool = False) -> None:
    channels = channel_map(layout)
    stopped = False

    def stop(_signum: int, _frame: object) -> None:
        nonlocal stopped
        stopped = True

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    properties = "media.category=Monitor stream.monitor=true"
    if passive:
        # Do not wake an idle microphone and move network playback to its clock.
        properties += " node.passive=true"
    command = ["pw-record", "--raw", "--format", "f32", "--rate", "16000",
               "--channels", str(len(channels)), "--channel-map", "[ " + " ".join(channels) + " ]",
               "--target", target, "--properties", properties, "-"]
    # Match the source layout explicitly: unconstrained captures negotiate stereo
    # even for Pro Audio AUX microphones. This does not reconfigure the device.
    child = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE)
    assert child.stdout is not None
    selector = selectors.DefaultSelector()
    selector.register(child.stdout, selectors.EVENT_READ)
    pending = b""
    block_size = 800 * len(channels) * 4
    last_data = time.monotonic()
    try:
        while not stopped:
            if not selector.select(0.25):
                if child.poll() is not None:
                    raise RuntimeError("microphone capture exited")
                if passive:
                    # An unused microphone produces no samples; clear the last level.
                    pending = b""
                    print("0.000000", flush=True)
                    continue
                if time.monotonic() - last_data > 5:
                    raise RuntimeError("microphone capture timed out")
                continue
            chunk = os.read(child.stdout.fileno(), block_size)
            if not chunk:
                raise RuntimeError("microphone capture ended")
            pending += chunk
            last_data = time.monotonic()
            while len(pending) >= block_size:
                print(f"{peak_level(pending[:block_size]):.6f}", flush=True)
                pending = pending[block_size:]
    finally:
        # Closing the panel or switching sources must release capture promptly.
        selector.close()
        child.terminate()
        try:
            child.wait(timeout=1)
        except subprocess.TimeoutExpired:
            child.kill()
            child.wait()
        child.stdout.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("target")
    parser.add_argument("channels")
    parser.add_argument("--passive", action="store_true")
    args = parser.parse_args()
    try:
        monitor(args.target, args.channels, args.passive)
    except (OSError, ValueError, RuntimeError) as error:
        print(f"Microphone level unavailable: {error}", file=sys.stderr)
        sys.exit(1)
