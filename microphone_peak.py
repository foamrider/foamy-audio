#!/usr/bin/env python3
"""Emit microphone levels only; audio samples stay in memory and are never saved."""

import argparse
from array import array
import math
import os
import re
import selectors
import signal
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
    # array() decodes the float32 block in C; a 64-channel AUX device stays cheap.
    samples = array("f", data)
    if sys.byteorder != "little":
        samples.byteswap()
    if not samples:
        return 0.0
    # A float32 block cannot overflow a double sum, so only NaN or Inf makes it non-finite.
    if not math.isfinite(sum(samples)):
        raise ValueError("invalid microphone sample")
    return min(1.0, math.cbrt(max(max(samples), -min(samples))))


def sample_rate(channel_count: int) -> int:
    # A level meter needs no more than 8 kHz; wide AUX devices halve the work per second.
    return 16000 if channel_count <= 8 else 8000


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
    rate = sample_rate(len(channels))
    command = ["pw-record", "--raw", "--format", "f32", "--rate", str(rate),
               "--channels", str(len(channels)), "--channel-map", "[ " + " ".join(channels) + " ]",
               "--target", target, "--properties", properties, "-"]
    # Match the source layout explicitly: unconstrained captures negotiate stereo
    # even for Pro Audio AUX microphones. This does not reconfigure the device.
    child = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE)
    assert child.stdout is not None
    selector = selectors.DefaultSelector()
    selector.register(child.stdout, selectors.EVENT_READ)
    pending = b""
    # 20 level updates per second whatever the rate.
    block_size = rate // 20 * len(channels) * 4
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
