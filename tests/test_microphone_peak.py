import importlib.util
import os
from pathlib import Path
import select
import signal
import struct
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'microphone_peak.py'
SPEC = importlib.util.spec_from_file_location('microphone_peak', SCRIPT)
assert SPEC and SPEC.loader
PEAK = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PEAK)


class PeakTest(unittest.TestCase):
    def test_aux_mono_stereo_and_invalid_maps(self):
        for value in ['AUX0', 'MONO', 'FL,FR', 'AUX0,AUX1']:
            self.assertEqual(PEAK.channel_map(value), value.split(','))
        for value in ['', 'AUX64', 'FL,', '--help', 'FL;exit', 'AUX0\n']:
            with self.assertRaises(ValueError):
                PEAK.channel_map(value)

    def test_peak_scaling_and_bad_samples(self):
        self.assertAlmostEqual(PEAK.peak_level(struct.pack('<3f', 0, -0.125, 0.01)), 0.5)
        self.assertEqual(PEAK.peak_level(struct.pack('<f', 0)), 0)
        self.assertEqual(PEAK.peak_level(struct.pack('<f', 8)), 1)
        with self.assertRaises(ValueError):
            PEAK.peak_level(struct.pack('<f', float('nan')))

    def test_capture_uses_map_and_reaps_child_on_close(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            child_pid = root / 'pid'
            fake = root / 'pw-record'
            fake.write_text(f'''#!{sys.executable}
import os,sys,struct,time
from pathlib import Path
assert sys.argv[sys.argv.index('--channel-map')+1]=='[ AUX0 ]'
assert sys.argv[sys.argv.index('--target')+1]=='fixture microphone'
Path({str(child_pid)!r}).write_text(str(os.getpid()))
while True:
 sys.stdout.buffer.write(struct.pack('<800f', *([0.125]*800)));sys.stdout.buffer.flush();time.sleep(0.05)
''')
            fake.chmod(0o755)
            proc = subprocess.Popen([sys.executable, str(SCRIPT), 'fixture microphone', 'AUX0'],
                                    env={**os.environ, 'PATH': str(root) + ':' + os.environ['PATH']},
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            try:
                self.assertTrue(select.select([proc.stdout], [], [], 3)[0], 'no level received')
                self.assertEqual(float(proc.stdout.readline()), 0.5)
                pid = int(child_pid.read_text())
                proc.send_signal(signal.SIGTERM)
                self.assertEqual(proc.wait(timeout=3), 0)
                with self.assertRaises(ProcessLookupError):
                    os.kill(pid, 0)
            finally:
                if proc.poll() is None:
                    proc.kill()
                proc.communicate()

    def test_missing_capture_tool_fails_with_actionable_error(self):
        with tempfile.TemporaryDirectory() as folder:
            proc = subprocess.run([sys.executable, str(SCRIPT), 'fixture', 'AUX0'],
                                  env={**os.environ, 'PATH': folder}, capture_output=True, text=True, timeout=3)
            self.assertNotEqual(proc.returncode, 0)
            self.assertIn('Microphone level unavailable', proc.stderr)
            self.assertEqual(proc.stdout, '')


if __name__ == '__main__':
    unittest.main()
