#!/usr/bin/env python3

import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest


MODULE_PATH = Path(__file__).resolve().parents[1] / "airplay_bridge.py"
SPEC = importlib.util.spec_from_file_location("airplay_bridge", MODULE_PATH)
assert SPEC and SPEC.loader
BRIDGE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(BRIDGE)


class FakeRunner:
    def __init__(self, responses):
        self.responses = list(responses)
        self.commands = []

    def __call__(self, command):
        self.commands.append(list(command))
        return self.responses.pop(0)


def completed(stdout="", stderr="", returncode=0):
    return subprocess.CompletedProcess([], returncode, stdout, stderr)


class AirPlayBridgeTest(unittest.TestCase):
    def test_module_listing_accepts_pulse_and_native_raop_names(self):
        output = """
536870916\tmodule-raop-discover
27 libpipewire-module-raop-discover { }
not-an-id module-raop-discover
"""
        self.assertEqual(BRIDGE.parse_module_ids(output), [536870916, 27])

    def test_avahi_utf8_byte_escapes_decode_as_one_character(self):
        self.assertEqual(BRIDGE.decode_avahi(r"Kj\195\184kken"), "Kjøkken")

    def test_avahi_records_become_deduplicated_receiver_metadata(self):
        output = r'''
=;eth0;IPv6;020000000002\064Stue;AirTunes Remote Audio;local;Sonos-020000000002.local;192.0.2.17;7000;"cn=0,1" "am=Beam"
=;eth0;IPv4;020000000002\064Stue;AirTunes Remote Audio;local;Sonos-020000000002.local;192.0.2.17;7000;"cn=0,1" "am=Beam"
'''
        self.assertEqual(BRIDGE.parse_avahi_receivers(output), [{
            "name": "Stue",
            "hostname": "Sonos-020000000002.local",
            "address": "192.0.2.17",
            "port": 7000,
            "vendor": "Sonos",
            "model": "Beam",
        }])

    def test_start_loads_one_owned_module_and_remembers_local_output(self):
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory) / "state.json"
            module = Path(directory) / "libpipewire-module-raop-discover.so"
            module.touch()
            runner = FakeRunner([
                completed(),
                completed("536870916\n"),
                completed(),
            ])

            payload, return_code = BRIDGE.start_discovery(
                "62",
                "alsa_output.creative",
                runner=runner,
                path=state,
                module_path=module,
            )

            self.assertEqual(return_code, 0)
            self.assertTrue(payload["ok"])
            self.assertTrue(payload["owned"])
            self.assertEqual(payload["moduleId"], 536870916)
            self.assertEqual(runner.commands[1], ["pactl", "load-module", "module-raop-discover"])
            self.assertEqual(runner.commands[-1], ["avahi-browse", "-rtp", "_raop._tcp"])
            self.assertEqual(json.loads(state.read_text())["restoreName"], "alsa_output.creative")

    def test_start_reuses_external_module_without_claiming_ownership(self):
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory) / "state.json"
            runner = FakeRunner([
                completed("27\tlibpipewire-module-raop-discover\n"),
                completed(),
            ])

            payload, return_code = BRIDGE.start_discovery(
                "62",
                "alsa_output.creative",
                runner=runner,
                path=state,
            )

            self.assertEqual(return_code, 0)
            self.assertFalse(payload["owned"])
            self.assertEqual(payload["moduleId"], 27)
            self.assertEqual(len(runner.commands), 2)

    def test_stop_restores_audio_before_unloading_owned_module(self):
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory) / "state.json"
            state.write_text(json.dumps({
                "moduleId": 536870916,
                "owned": True,
                "restoreId": "62",
                "restoreName": "alsa_output.creative",
            }))
            runner = FakeRunner([
                completed(),
                completed("536870916\tmodule-raop-discover\n"),
                completed(),
            ])

            payload, return_code = BRIDGE.stop_discovery(runner=runner, path=state)

            self.assertEqual(return_code, 0)
            self.assertTrue(payload["ok"])
            self.assertEqual(runner.commands, [
                ["omarchy-audio-output-set-default", "62", "alsa_output.creative"],
                ["pactl", "list", "modules", "short"],
                ["pactl", "unload-module", "536870916"],
            ])
            self.assertFalse(state.exists())

    def test_missing_pipewire_support_is_actionable(self):
        with tempfile.TemporaryDirectory() as directory:
            runner = FakeRunner([completed()])
            payload, return_code = BRIDGE.start_discovery(
                "",
                "",
                runner=runner,
                path=Path(directory) / "state.json",
                module_path=Path(directory) / "missing.so",
            )

            self.assertEqual(return_code, 2)
            self.assertEqual(payload["error"], "AirPlay support is not installed (pipewire-zeroconf)")


if __name__ == "__main__":
    unittest.main()
