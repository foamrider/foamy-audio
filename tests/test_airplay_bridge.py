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
    def test_select_local_removes_group_but_keeps_discovery_and_peers(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "state.json"
            state = {"moduleId": 50, "owned": True, "peers": [{"name": "Speaker"}],
                     "groupModuleId": 51, "groupName": "foamy_airplay_group_1",
                     "selectedNames": ["raop_sink.a", "raop_sink.b"],
                     "restoreName": "alsa_output.old"}
            path.write_text(json.dumps(state))
            runner = FakeRunner([
                completed(json.dumps([{"index": 62, "name": "alsa_output.local"}])),
                completed("foamy_airplay_group_1"), completed(),
                completed("alsa_output.local"), completed("[]"),
                completed("50\tmodule-raop-discover\n51\tmodule-combine-sink\tsink_name=foamy_airplay_group_1\n"),
                completed(),
            ])
            payload, code = BRIDGE.select_outputs([], local_name="alsa_output.local", runner=runner, path=path)
            self.assertEqual(code, 0)
            self.assertEqual(payload["selectedNames"], [])
            saved = json.loads(path.read_text())
            self.assertEqual(saved["moduleId"], 50)
            self.assertTrue(saved["owned"])
            self.assertEqual(saved["peers"], state["peers"])
            self.assertEqual(saved["restoreName"], "alsa_output.local")
            self.assertEqual(saved["restoreId"], "62")
            self.assertNotIn("groupModuleId", saved)
            self.assertNotIn("groupName", saved)
            self.assertEqual([command for command in runner.commands if "unload-module" in command],
                             [["pactl", "unload-module", "51"]])

    def test_missing_local_output_preserves_session_and_routing(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "state.json"
            original = json.dumps({"moduleId": 50, "selectedNames": ["raop_sink.a"]})
            path.write_text(original)
            runner = FakeRunner([completed("[]")])
            payload, code = BRIDGE.select_outputs([], local_name="alsa_output.missing", runner=runner, path=path)
            self.assertEqual(code, 1)
            self.assertIn("no longer available", payload["error"])
            self.assertEqual(len(runner.commands), 1)
            self.assertEqual(path.read_text(), original)

    def test_unavailable_selection_does_not_change_routing(self):
        with tempfile.TemporaryDirectory() as directory:
            runner = FakeRunner([completed("[]")])
            payload, code = BRIDGE.select_outputs(
                ["raop_sink.missing"], runner=runner, path=Path(directory) / "state.json")
            self.assertEqual(code, 1)
            self.assertFalse(payload["ok"])
            self.assertEqual(len(runner.commands), 1)

    def test_failed_default_verification_is_reported_before_moving_apps(self):
        runner = FakeRunner([completed()] + [completed("some_other_sink")] * 20)
        with self.assertRaisesRegex(RuntimeError, "did not become the default"):
            BRIDGE.route_output("raop_sink.test", runner)
        self.assertEqual(len(runner.commands), 21)

    def test_default_verification_waits_for_wireplumber(self):
        runner = FakeRunner([completed(), completed("previous"), completed("speaker"), completed("[]")])
        BRIDGE.route_output("speaker", runner)
        self.assertEqual(len(runner.commands), 4)

    def test_route_preserves_processing_streams(self):
        streams = [{"index": 1, "properties": {}},
                   {"index": 2, "properties": {"application.name": "EasyEffects"}},
                   {"index": 3, "properties": {"application.name": "Music"}}]
        runner = FakeRunner([completed(), completed("speaker"), completed(json.dumps(streams)), completed()])
        BRIDGE.route_output("speaker", runner)
        self.assertEqual(runner.commands[3:], [["pactl", "move-sink-input", "3", "speaker"]])

    def test_group_cleanup_never_unloads_reused_module_id(self):
        runner = FakeRunner([completed("42\tmodule-combine-sink\tsink_name=someone_else\n")])
        BRIDGE.remove_group({"groupModuleId": 42, "groupName": "foamy_airplay_group_1"}, runner)
        self.assertEqual(len(runner.commands), 1)

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
                completed("alsa_output.creative"),
                completed("[]"),
                completed("536870916\tmodule-raop-discover\n"),
                completed(),
            ])

            payload, return_code = BRIDGE.stop_discovery(runner=runner, path=state)

            self.assertEqual(return_code, 0)
            self.assertTrue(payload["ok"])
            self.assertEqual(runner.commands, [
                ["pactl", "set-default-sink", "alsa_output.creative"],
                ["pactl", "get-default-sink"],
                ["pactl", "-f", "json", "list", "sink-inputs"],
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
