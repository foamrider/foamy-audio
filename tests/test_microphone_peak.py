"""Black-box tests of the microphone level meter (see blackbox.py): a fake
`pw-record` on a PATH that holds nothing else streams float32 samples the
test chooses, so no real microphone is ever opened."""

import json
import math
import os
from pathlib import Path
import random
import select
import signal
import struct
import subprocess
import sys
import tempfile
import time
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
from blackbox import helper  # noqa: E402

# The fake logs its argv and pid, checks that standard input is /dev/null,
# then writes the blocks of samples.json ([[float, ...], ...]; null = NaN,
# "inf"/"-inf"), sleeping `pause` seconds after each, and then either exits
# (`exit`) or sleeps `idle` seconds and repeats the last block forever.
PW_RECORD = '''#!{python} -I
import json, os, stat, struct, sys, time
here = {here!r}
config = json.load(open(os.path.join(here, "samples.json")))
with open(os.path.join(here, "calls.jsonl"), "a") as log:
    log.write(json.dumps({{"argv": ["pw-record", *sys.argv[1:]], "pid": os.getpid(),
                           "stdin_null": stat.S_ISCHR(os.fstat(0).st_mode)}}) + "\\n")
def value(v):
    return float("nan") if v is None else float(v)
def emit(block):
    sys.stdout.buffer.write(struct.pack("<%df" % len(block), *map(value, block)))
    sys.stdout.buffer.flush()
for block in config["blocks"]:
    emit(block)
    time.sleep(config.get("pause", 0))
if config.get("exit"):
    sys.exit(config.get("code", 0))
time.sleep(config.get("idle", 0))
while True:
    emit(config["blocks"][-1])
    time.sleep(0.05)
'''


class MicrophonePeakTest(unittest.TestCase):
    def setUp(self):
        self._temp = tempfile.TemporaryDirectory(prefix="foamy-audio-mic-")
        self.addCleanup(self._temp.cleanup)
        self.root = Path(self._temp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.home = self.root / "home"
        self.home.mkdir()
        (self.root / "calls.jsonl").write_text("")
        fake = self.bin / "pw-record"
        fake.write_text(PW_RECORD.format(python=sys.executable, here=str(self.root)))
        fake.chmod(0o755)
        self.env = {"PATH": str(self.bin), "HOME": str(self.home), "XDG_RUNTIME_DIR": str(self.home),
                    "LANG": "C.UTF-8", "PIPEWIRE_REMOTE": str(self.root / "no-pipewire")}

    def samples(self, blocks, **options):
        (self.root / "samples.json").write_text(json.dumps({"blocks": blocks, **options}))

    def calls(self):
        return [json.loads(line) for line in (self.root / "calls.jsonl").read_text().splitlines() if line]

    def start(self, *args):
        return subprocess.Popen(helper("microphone-peak") + list(args), env=self.env, cwd=self.home,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)

    def run_meter(self, *args, timeout=15):
        return subprocess.run(helper("microphone-peak") + list(args), env=self.env, cwd=self.home,
                              capture_output=True, text=True, timeout=timeout)

    def stop(self, proc):
        if proc.poll() is None:
            proc.kill()
        proc.communicate()

    def levels(self, proc, count, wait=3):
        levels = []
        while len(levels) < count:
            self.assertTrue(select.select([proc.stdout], [], [], wait)[0], f"no level after {levels}")
            line = proc.stdout.readline()
            self.assertTrue(line, f"meter exited after {levels}: {proc.stderr.read() if proc.poll() is not None else ''}")
            levels.append(line)
        return levels

    def test_capture_argv_matches_the_source_layout(self):
        for layout, rate in (("MONO", 16000), ("FL,FR", 16000), ("FL,FR,FC,LFE,RL,RR,SL,SR", 16000),
                             ("AUX0,AUX1,AUX2,AUX3,AUX4,AUX5,AUX6,AUX7,AUX8", 8000)):
            with self.subTest(layout=layout):
                (self.root / "calls.jsonl").write_text("")
                channels = layout.split(",")
                self.samples([[0.0] * (rate // 20 * len(channels))], exit=True)
                result = self.run_meter("alsa_input.fixture mic", layout)
                self.assertEqual(result.returncode, 1)
                self.assertEqual(result.stdout, "0.000000\n")
                self.assertEqual(result.stderr.strip(), "Microphone level unavailable: microphone capture ended")
                call = self.calls()[0]
                self.assertEqual(call["argv"], [
                    "pw-record", "--raw", "--format", "f32", "--rate", str(rate), "--channels", str(len(channels)),
                    "--channel-map", "[ " + " ".join(channels) + " ]", "--target", "alsa_input.fixture mic",
                    "--properties", "media.category=Monitor stream.monitor=true", "-"])
                self.assertTrue(call["stdin_null"])

    def test_passive_capture_asks_not_to_wake_the_microphone(self):
        self.samples([[0.0] * 800], exit=True)
        self.run_meter("fixture", "AUX0", "--passive")
        self.assertEqual(self.calls()[0]["argv"][-2], "media.category=Monitor stream.monitor=true node.passive=true")

    def test_aux_mono_stereo_and_invalid_maps(self):
        for value in ["AUX0", "MONO", "FL,FR", "AUX0,AUX1", "AUX63", "TFL,TFC,TFR,TRL,TRC,TRR,FLC,FRC,RC,TC"]:
            with self.subTest(value=value):
                (self.root / "calls.jsonl").write_text("")
                self.samples([[0.0] * 10], exit=True)
                self.run_meter("fixture", value)
                self.assertEqual(self.calls()[0]["argv"][9], "[ " + " ".join(value.split(",")) + " ]")
        for value in ["", "AUX64", "AUX01", "FL,", "--help", "FL;exit", "AUX0\n", "fl", ",".join(["MONO"] * 65)]:
            with self.subTest(value=value):
                (self.root / "calls.jsonl").write_text("")
                result = self.run_meter("fixture", "--", value)
                self.assertEqual(result.returncode, 1)
                self.assertEqual(result.stdout, "")
                self.assertEqual(result.stderr.strip(), "Microphone level unavailable: unsupported microphone channel map")
                self.assertEqual(self.calls(), [])
        # 64 channels is the most a source can have.
        self.samples([[0.0] * 10], exit=True)
        self.run_meter("fixture", ",".join(["MONO"] * 64))
        self.assertEqual(self.calls()[-1]["argv"][5:8], ["8000", "--channels", "64"])

    def test_peak_scaling_and_bad_samples(self):
        block = [0.0] * 800
        self.samples([[0.0, -0.125, 0.01] + block[3:], block, [8.0] + block[1:], [0.001] * 800, [-1.0] + block[1:]],
                     exit=True)
        result = self.run_meter("fixture", "AUX0")
        self.assertEqual(result.stdout.splitlines(), ["0.500000", "0.000000", "1.000000", "0.100000", "1.000000"])
        # NaN or Inf anywhere in the block is rejected, not skipped by max().
        for bad in (None, "inf", "-inf"):
            with self.subTest(bad=bad):
                self.samples([[0.5] * 800, [0.1, bad, 0.2] + block[3:]], exit=True)
                result = self.run_meter("fixture", "AUX0")
                self.assertEqual(result.returncode, 1)
                self.assertEqual(result.stdout, "0.793701\n")
                self.assertEqual(result.stderr.strip(), "Microphone level unavailable: invalid microphone sample")

    def test_partial_blocks_are_joined_before_a_level(self):
        # 1200 samples then 400: one level per complete 800-sample block, the
        # second block spanning both writes.
        self.samples([[0.125] * 1200, [0.0] * 300 + [1.0] * 100], pause=0.2, exit=True)
        result = self.run_meter("fixture", "MONO")
        self.assertEqual(result.stdout.splitlines(), ["0.500000", "1.000000"])

    def test_peak_matches_reference_for_wide_layouts(self):
        rng = random.Random(7)
        for channels in (1, 2, 8, 9, 64):
            with self.subTest(channels=channels):
                rate = 16000 if channels <= 8 else 8000
                values = [rng.uniform(-1, 1) for _ in range(rate // 20 * channels)]
                stored = struct.unpack("<%df" % len(values), struct.pack("<%df" % len(values), *values))
                expected = min(1.0, math.cbrt(max(abs(v) for v in stored)))
                self.samples([values], exit=True)
                result = self.run_meter("fixture", ",".join(f"AUX{i}" for i in range(channels)))
                self.assertEqual(result.stdout, f"{expected:.6f}\n")

    def test_capture_uses_map_and_reaps_child_on_close(self):
        for stop in (signal.SIGTERM, signal.SIGINT):
            with self.subTest(signal=stop):
                (self.root / "calls.jsonl").write_text("")
                self.samples([[0.125] * 800], pause=0.05)
                proc = self.start("fixture microphone", "AUX0")
                try:
                    self.assertEqual([float(line) for line in self.levels(proc, 2)], [0.5, 0.5])
                    call = self.calls()[0]
                    self.assertEqual(call["argv"][call["argv"].index("--channel-map") + 1], "[ AUX0 ]")
                    self.assertEqual(call["argv"][call["argv"].index("--target") + 1], "fixture microphone")
                    proc.send_signal(stop)
                    self.assertEqual(proc.wait(timeout=3), 0)
                    with self.assertRaises(ProcessLookupError):
                        os.kill(call["pid"], 0)
                finally:
                    self.stop(proc)

    def test_samples_stay_in_memory(self):
        self.samples([[0.125] * 800], pause=0.05)
        proc = self.start("fixture", "AUX0")
        try:
            self.levels(proc, 3)
            proc.terminate()
            self.assertEqual(proc.wait(timeout=3), 0)
        finally:
            self.stop(proc)
        self.assertEqual(sorted(p.name for p in self.home.rglob("*")), [])
        self.assertEqual(sorted(p.name for p in self.root.iterdir()), ["bin", "calls.jsonl", "home", "samples.json"])

    def test_missing_capture_tool_fails_with_actionable_error(self):
        os.unlink(self.bin / "pw-record")
        result = self.run_meter("fixture", "AUX0", timeout=3)
        self.assertEqual(result.returncode, 1)
        self.assertTrue(result.stderr.startswith("Microphone level unavailable: "), result.stderr)
        self.assertEqual(result.stdout, "")

    def test_capture_that_exits_or_stalls_ends_the_meter(self):
        self.samples([[0.125] * 800], exit=True, code=3)
        result = self.run_meter("fixture", "AUX0")
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, "0.500000\n")
        self.assertIn(result.stderr.strip(), ("Microphone level unavailable: microphone capture ended",
                                              "Microphone level unavailable: microphone capture exited"))
        # An active meter gives up after 5 s without samples, and reaps the capture.
        self.samples([[0.125] * 800], idle=30)
        started = time.monotonic()
        result = self.run_meter("fixture", "AUX0")
        elapsed = time.monotonic() - started
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stderr.strip(), "Microphone level unavailable: microphone capture timed out")
        self.assertTrue(5 <= elapsed < 8, elapsed)
        with self.assertRaises(ProcessLookupError):
            os.kill(self.calls()[-1]["pid"], 0)

    def test_passive_meter_clears_level_while_idle_and_resumes_without_timeout(self):
        self.samples([[0.125] * 800], idle=6)
        proc = self.start("fixture", "AUX0", "--passive")
        try:
            deadline = time.monotonic() + 9
            levels = []
            while time.monotonic() < deadline:
                levels.append(float(self.levels(proc, 1, wait=2)[0]))
                if len(levels) > 1 and levels[-1] == 0.5:
                    break
            self.assertEqual(levels[0], 0.5)
            self.assertIn(0.0, levels)
            self.assertEqual(levels[-1], 0.5)
            # About four zero levels a second while idle.
            self.assertGreater(levels.count(0.0), 15)
            proc.terminate()
            self.assertEqual(proc.wait(timeout=3), 0)
        finally:
            self.stop(proc)


if __name__ == "__main__":
    unittest.main()
