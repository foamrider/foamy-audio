#!/usr/bin/env python3
"""Black-box tests of the AirPlay bridge (see blackbox.py): fake pactl and
avahi-browse, the session state in a temporary XDG_RUNTIME_DIR."""

import json
import os
from pathlib import Path
import signal
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
from blackbox import RAOP_DIR, Fakes, needs_namespace, reply  # noqa: E402

AVAHI = ["avahi-browse", "-rtp", "_raop._tcp"]
MODULES = ["pactl", "list", "modules", "short"]
SINKS = ["pactl", "-f", "json", "list", "sinks"]
STREAMS = ["pactl", "-f", "json", "list", "sink-inputs"]
GET_DEFAULT = ["pactl", "get-default-sink"]
ECHO_DEFAULT = {"echo_default": True}
GROUP_LEFT = "Output changed, but an earlier AirPlay group could not be removed."


class AirPlayBridgeTest(unittest.TestCase):
    def setUp(self):
        self.fakes = Fakes()
        self.addCleanup(self.fakes.close)
        self.state = self.fakes.runtime / "foamy-audio-airplay.json"

    def write_state(self, payload):
        self.state.write_text(json.dumps(payload))

    def saved(self):
        return json.loads(self.state.read_text())

    def run_bridge(self, *args, **kwargs):
        return self.fakes.run("airplay", *args, **kwargs)

    def assertNothingLeft(self):
        for tool in ("pactl", "avahi-browse"):
            self.assertEqual(self.fakes.leftover(tool), [], f"unused {tool} responses")

    # ---- select ------------------------------------------------------------

    def test_select_local_removes_group_but_keeps_discovery_and_peers(self):
        state = {
            "moduleId": 50,
            "owned": True,
            "peers": [{"name": "Speaker"}],
            "groupModuleId": 51,
            "groupName": "foamy_airplay_group_1",
            "selectedNames": ["raop_sink.a", "raop_sink.b"],
            "restoreName": "alsa_output.old",
        }
        self.write_state(state)
        self.fakes.queue(
            "pactl",
            json.dumps([{"index": 62, "name": "alsa_output.local"}]),
            "foamy_airplay_group_1",
            "",
            "alsa_output.local",
            "[]",
            "50\tmodule-raop-discover\n51\tmodule-combine-sink\tsink_name=foamy_airplay_group_1\n",
            "",
            "50\tmodule-raop-discover\n",
        )
        result = self.run_bridge("select", "--local-name", "alsa_output.local")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(reply(result), {"ok": True, "error": "", "selectedNames": [], "target": "alsa_output.local"})
        saved = self.saved()
        self.assertEqual(saved["moduleId"], 50)
        self.assertTrue(saved["owned"])
        self.assertEqual(saved["peers"], state["peers"])
        self.assertEqual(saved["restoreName"], "alsa_output.local")
        self.assertEqual(saved["restoreId"], "62")
        self.assertEqual(saved["selectedNames"], [])
        self.assertNotIn("groupModuleId", saved)
        self.assertNotIn("groupName", saved)
        self.assertEqual(
            self.fakes.argvs(),
            [
                SINKS,
                GET_DEFAULT,
                ["pactl", "set-default-sink", "alsa_output.local"],
                GET_DEFAULT,
                STREAMS,
                MODULES,
                ["pactl", "unload-module", "51"],
                MODULES,
            ],
        )
        self.assertNothingLeft()

    def test_missing_local_output_preserves_session_and_routing(self):
        original = json.dumps({"moduleId": 50, "selectedNames": ["raop_sink.a"]})
        self.state.write_text(original)
        self.fakes.queue("pactl", "[]")
        result = self.run_bridge("select", "--local-name", "alsa_output.missing")
        self.assertEqual(result.returncode, 1)
        self.assertEqual(reply(result), {"ok": False, "error": "The local output is no longer available."})
        self.assertEqual(self.fakes.argvs(), [SINKS])
        self.assertEqual(self.state.read_text(), original)

    def test_an_airplay_sink_is_not_a_local_output(self):
        self.fakes.queue("pactl", json.dumps([{"index": 70, "name": "raop_sink.a"}]))
        result = self.run_bridge("select", "--local-name", "raop_sink.a")
        self.assertEqual(result.returncode, 1)
        self.assertEqual(reply(result)["error"], "The local output is no longer available.")

    def test_unavailable_selection_does_not_change_routing(self):
        self.fakes.queue("pactl", json.dumps([{"index": 3, "name": "alsa_output.local"}]))
        result = self.run_bridge("select", "raop_sink.missing")
        self.assertEqual(result.returncode, 1)
        self.assertEqual(
            reply(result), {"ok": False, "error": "An AirPlay speaker is no longer available. Reopen the panel."}
        )
        self.assertEqual(self.fakes.argvs(), [SINKS])
        self.assertFalse(self.state.exists())

    def test_an_output_named_like_the_help_option_is_a_value(self):
        # A rule in the user's PipeWire config can set any node.name.
        self.fakes.queue("pactl", json.dumps([{"index": 62, "name": "-h"}]), "alsa_output.old", "", "-h", "[]", "")
        result = self.run_bridge("select", "--local-name", "-h")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(reply(result), {"ok": True, "error": "", "selectedNames": [], "target": "-h"})
        self.assertEqual(self.saved(), {"selectedNames": [], "restoreName": "-h", "restoreId": "62"})
        self.assertNothingLeft()

    def test_a_speaker_name_after_the_option_end_is_a_name(self):
        self.fakes.queue("pactl", json.dumps([{"index": 70, "name": "raop_sink.a"}]))
        result = self.run_bridge("select", "--", "--help")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual(
            reply(result), {"ok": False, "error": "An AirPlay speaker is no longer available. Reopen the panel."}
        )
        self.assertEqual(self.fakes.argvs(), [SINKS])

    def test_help_prints_the_usage_only_in_an_option_position(self):
        for args in (("-h",), ("--help",), ("select", "-h"), ("status", "--help"), ("stop", "--skip-restore", "-h")):
            result = self.run_bridge(*args)
            self.assertEqual(result.returncode, 0, args)
            self.assertEqual(result.stdout, "usage: foamy-audio-helper airplay {start,stop,status,select} …\n", args)
        self.assertEqual(self.fakes.calls(), [])

    def test_local_and_speakers_together_are_refused_before_any_command(self):
        result = self.run_bridge("select", "raop_sink.a", "--local-name", "alsa_output.local")
        self.assertEqual(result.returncode, 1)
        self.assertEqual(reply(result), {"ok": False, "error": "Choose a local output or AirPlay speakers, not both."})
        self.assertEqual(self.fakes.calls(), [])

    def test_select_without_names_returns_to_the_remembered_output(self):
        # Unticking the last speaker: apps go back to the remembered output,
        # then the group goes; discovery stays on.
        self.write_state(
            {
                "moduleId": 50,
                "owned": True,
                "restoreName": "alsa_output.local",
                "groupModuleId": 51,
                "groupName": "foamy_airplay_group_1",
                "selectedNames": ["raop_sink.a", "raop_sink.b"],
            }
        )
        self.fakes.queue(
            "pactl",
            json.dumps([{"index": 62, "name": "alsa_output.local"}]),
            "foamy_airplay_group_1",
            "",
            "alsa_output.local",
            json.dumps([{"index": 9, "properties": {"application.name": "Music"}}]),
            "",
            "50\tmodule-raop-discover\n51\tmodule-combine-sink\tsink_name=foamy_airplay_group_1\n",
            "",
            "50\tmodule-raop-discover\n",
        )
        result = self.run_bridge("select")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(reply(result), {"ok": True, "error": "", "selectedNames": [], "target": "alsa_output.local"})
        self.assertEqual(
            self.fakes.argvs(),
            [
                SINKS,
                GET_DEFAULT,
                ["pactl", "set-default-sink", "alsa_output.local"],
                GET_DEFAULT,
                STREAMS,
                ["pactl", "move-sink-input", "9", "alsa_output.local"],
                MODULES,
                ["pactl", "unload-module", "51"],
                MODULES,
            ],
        )
        self.assertEqual(
            self.saved(), {"moduleId": 50, "owned": True, "restoreName": "alsa_output.local", "selectedNames": []}
        )
        self.assertNothingLeft()

    def test_no_target_without_a_remembered_output(self):
        self.fakes.queue("pactl", "[]")
        result = self.run_bridge("select")
        self.assertEqual(result.returncode, 1)
        self.assertEqual(reply(result), {"ok": False, "error": "No local output is available"})

    def test_failed_default_verification_is_reported_and_rolled_back(self):
        self.fakes.queue("pactl", json.dumps([{"index": 70, "name": "raop_sink.test"}]), "alsa_output.local", "")
        self.fakes.queue("pactl", *["some_other_sink"] * 20)
        self.fakes.queue("pactl", "", "alsa_output.local", "[]")
        result = self.run_bridge("select", "raop_sink.test")
        self.assertEqual(result.returncode, 1)
        self.assertEqual(
            reply(result),
            {"ok": False, "error": "AirPlay helper failed: The selected output did not become the default"},
        )
        argvs = self.fakes.argvs()
        self.assertEqual(argvs[:3], [SINKS, GET_DEFAULT, ["pactl", "set-default-sink", "raop_sink.test"]])
        self.assertEqual(argvs[3:23], [GET_DEFAULT] * 20)
        # The rollback restores the previous default and never moves streams to the speaker.
        self.assertEqual(argvs[23:], [["pactl", "set-default-sink", "alsa_output.local"], GET_DEFAULT, STREAMS])
        self.assertFalse(self.state.exists())
        self.assertNothingLeft()

    def test_default_verification_waits_for_wireplumber(self):
        self.fakes.queue(
            "pactl",
            json.dumps([{"index": 70, "name": "raop_sink.speaker"}]),
            "previous",
            "",
            "previous",
            "raop_sink.speaker",
            "[]",
            "",
        )
        result = self.run_bridge("select", "raop_sink.speaker")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            reply(result),
            {"ok": True, "error": "", "selectedNames": ["raop_sink.speaker"], "target": "raop_sink.speaker"},
        )
        self.assertEqual(self.fakes.argvs()[3:5], [GET_DEFAULT, GET_DEFAULT])
        self.assertEqual(self.saved(), {"selectedNames": ["raop_sink.speaker"]})
        self.assertNothingLeft()

    def test_route_preserves_processing_streams(self):
        streams = [
            {"index": 1, "properties": {}},
            {"index": 2, "properties": {"application.name": "EasyEffects"}},
            {"index": 3, "properties": {"application.name": "Music"}},
            {"index": 4},
            {"index": 5, "properties": {"application.name": ""}},
        ]
        self.fakes.queue(
            "pactl",
            json.dumps([{"index": 70, "name": "raop_sink.speaker"}]),
            "previous",
            "",
            "raop_sink.speaker",
            json.dumps(streams),
            "",
            "",
        )
        result = self.run_bridge("select", "raop_sink.speaker")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.fakes.argvs()[5:], [["pactl", "move-sink-input", "3", "raop_sink.speaker"], MODULES])
        self.assertNothingLeft()

    def test_a_failed_stream_move_rolls_back_to_the_previous_output(self):
        streams = [{"index": 3, "properties": {"application.name": "Music"}}]
        self.fakes.queue(
            "pactl",
            json.dumps([{"index": 70, "name": "raop_sink.speaker"}]),
            "alsa_output.local",
            "",
            ECHO_DEFAULT,
            json.dumps(streams),
            {"stderr": "Failure: No such entity\n", "code": 1},
            "",
            ECHO_DEFAULT,
            json.dumps(streams),
            "",
        )
        result = self.run_bridge("select", "raop_sink.speaker")
        self.assertEqual(result.returncode, 1)
        self.assertEqual(reply(result), {"ok": False, "error": "AirPlay helper failed: Failure: No such entity"})
        self.assertEqual(
            self.fakes.argvs()[6:],
            [
                ["pactl", "set-default-sink", "alsa_output.local"],
                GET_DEFAULT,
                STREAMS,
                ["pactl", "move-sink-input", "3", "alsa_output.local"],
            ],
        )
        self.assertNothingLeft()

    def test_several_speakers_route_to_one_combine_group_and_record_it(self):
        sinks = [{"index": 70, "name": "raop_sink.a"}, {"index": 71, "name": "raop_sink.b"}]
        self.write_state(
            {
                "moduleId": 50,
                "owned": True,
                "restoreName": "alsa_output.local",
                "groupModuleId": 40,
                "groupName": "foamy_airplay_group_7",
            }
        )
        self.fakes.queue(
            "pactl",
            json.dumps(sinks),
            "536870920\n",
            "alsa_output.local",
            "",
            ECHO_DEFAULT,
            json.dumps([{"index": 9, "properties": {"application.name": "Music"}}]),
            "",
            "40\tmodule-combine-sink\tsink_name=foamy_airplay_group_7 sinks=raop_sink.c\n",
            "",
            # The new group is recorded now, so it stays.
            {"group_listing": 536870920},
        )
        result = self.run_bridge("select", "raop_sink.a", "raop_sink.b", "raop_sink.a")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        payload = reply(result)
        group = payload["target"]
        self.assertRegex(group, r"^foamy_airplay_group_\d+$")
        self.assertEqual(payload["selectedNames"], ["raop_sink.a", "raop_sink.b"])
        self.assertEqual(
            self.fakes.argvs(),
            [
                SINKS,
                [
                    "pactl",
                    "load-module",
                    "module-combine-sink",
                    "sink_name=" + group,
                    "sinks=raop_sink.a,raop_sink.b",
                    "latency_compensate=true",
                    'sink_properties=device.description="AirPlay group"',
                ],
                GET_DEFAULT,
                ["pactl", "set-default-sink", group],
                GET_DEFAULT,
                STREAMS,
                ["pactl", "move-sink-input", "9", group],
                MODULES,
                ["pactl", "unload-module", "40"],
                MODULES,
            ],
        )
        self.assertEqual(
            self.saved(),
            {
                "moduleId": 50,
                "owned": True,
                "restoreName": "alsa_output.local",
                "groupModuleId": 536870920,
                "groupName": group,
                "selectedNames": ["raop_sink.a", "raop_sink.b"],
            },
        )
        self.assertNothingLeft()

    def test_a_speaker_name_that_would_split_the_module_arguments_is_refused(self):
        # PipeWire's raop_sink.<host>.<ip>.<port> with Avahi's escape for a space
        # in the host name; pactl would pass the backslash to pipewire-pulse,
        # which reads it as an escape and changes the name.
        odd = "raop_sink.Living\\032Room.local.192.0.2.7.7000"
        self.fakes.queue("pactl", json.dumps([{"index": 70, "name": "raop_sink.a"}, {"index": 71, "name": odd}]))
        result = self.run_bridge("select", "raop_sink.a", odd)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(reply(result), {"ok": False, "error": "An AirPlay speaker's name can't be used in a group."})
        self.assertEqual(self.fakes.argvs(), [SINKS])
        self.assertFalse(self.state.exists())

    def test_a_group_that_cannot_become_the_default_is_removed_again(self):
        sinks = [{"index": 70, "name": "raop_sink.a"}, {"index": 71, "name": "raop_sink.b"}]
        self.fakes.queue(
            "pactl",
            json.dumps(sinks),
            "88\n",
            "alsa_output.local",
            {"stderr": "Failure: busy\n", "code": 1},
            "",
            "alsa_output.local",
            "[]",
            {"group_listing": 88},
            "",
        )
        result = self.run_bridge("select", "raop_sink.a", "raop_sink.b")
        self.assertEqual(result.returncode, 1)
        self.assertEqual(reply(result), {"ok": False, "error": "AirPlay helper failed: Failure: busy"})
        argvs = self.fakes.argvs()
        self.assertRegex(argvs[1][3], r"^sink_name=foamy_airplay_group_\d+$")
        # Apps go back to the previous output first, then the new group is unloaded.
        self.assertEqual(
            argvs[4:],
            [
                ["pactl", "set-default-sink", "alsa_output.local"],
                GET_DEFAULT,
                STREAMS,
                MODULES,
                ["pactl", "unload-module", "88"],
            ],
        )
        self.assertFalse(self.state.exists())
        self.assertNothingLeft()

    def test_a_group_whose_previous_output_cannot_be_read_is_removed_again(self):
        sinks = [{"index": 70, "name": "raop_sink.a"}, {"index": 71, "name": "raop_sink.b"}]
        self.fakes.queue(
            "pactl",
            json.dumps(sinks),
            "88\n",
            {"stderr": "Connection failure\n", "code": 1},
            {"group_listing": 88},
            "",
        )
        result = self.run_bridge("select", "raop_sink.a", "raop_sink.b")
        self.assertEqual(result.returncode, 1)
        self.assertEqual(reply(result), {"ok": False, "error": "AirPlay helper failed: Connection failure"})
        # The default never changed, so nothing routes back; the new group goes.
        self.assertEqual(self.fakes.argvs()[2:], [GET_DEFAULT, MODULES, ["pactl", "unload-module", "88"]])
        self.assertFalse(self.state.exists())
        self.assertNothingLeft()

    def test_a_group_is_removed_again_when_the_previous_group_cannot_be(self):
        sinks = [{"index": 70, "name": "raop_sink.a"}, {"index": 71, "name": "raop_sink.b"}]
        previous = {"groupModuleId": 40, "groupName": "foamy_airplay_group_7", "selectedNames": ["raop_sink.c"]}
        self.write_state(previous)
        self.fakes.queue(
            "pactl",
            json.dumps(sinks),
            "88\n",
            "alsa_output.local",
            "",
            ECHO_DEFAULT,
            "[]",
            {"stderr": "Failure: busy\n", "code": 1},
            "",
            "alsa_output.local",
            "[]",
            {"group_listing": 88},
            "",
        )
        result = self.run_bridge("select", "raop_sink.a", "raop_sink.b")
        self.assertEqual(result.returncode, 1)
        self.assertEqual(reply(result), {"ok": False, "error": "AirPlay helper failed: Failure: busy"})
        # Apps go back to the previous output, then the new group is unloaded;
        # the previous group stays recorded for the next select or stop.
        self.assertEqual(
            self.fakes.argvs()[6:],
            [
                MODULES,
                ["pactl", "set-default-sink", "alsa_output.local"],
                GET_DEFAULT,
                STREAMS,
                MODULES,
                ["pactl", "unload-module", "88"],
            ],
        )
        self.assertEqual(self.saved(), previous)
        self.assertNothingLeft()

    # Without a new group the select routes first and is not undone when a
    # later step fails: the reply says the output changed and what failed.

    def test_a_switch_whose_previous_group_cannot_be_removed_says_the_output_changed(self):
        previous = {"groupModuleId": 40, "groupName": "foamy_airplay_group_7", "selectedNames": ["raop_sink.a"]}
        self.write_state(previous)
        self.fakes.queue(
            "pactl",
            json.dumps([{"index": 70, "name": "raop_sink.a"}]),
            "foamy_airplay_group_7",
            "",
            ECHO_DEFAULT,
            "[]",
            "40\tmodule-combine-sink\tsink_name=foamy_airplay_group_7 sinks=raop_sink.a,raop_sink.b\n",
            {"stderr": "Failure: busy\n", "code": 1},
        )
        result = self.run_bridge("select", "raop_sink.a")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual(reply(result), {"ok": False, "error": GROUP_LEFT, "details": "Failure: busy"})
        # The speaker stays the output, and the group stays recorded for the
        # next select or stop.
        self.assertEqual(self.fakes.argvs()[2], ["pactl", "set-default-sink", "raop_sink.a"])
        self.assertEqual(self.fakes.argvs()[-2:], [MODULES, ["pactl", "unload-module", "40"]])
        self.assertEqual(self.saved(), previous)
        self.assertNothingLeft()

    def test_a_switch_whose_session_cannot_be_saved_says_the_output_changed(self):
        blocked = self.fakes.root / "a-file"
        blocked.write_text("")
        self.fakes.queue(
            "pactl", json.dumps([{"index": 62, "name": "alsa_output.local"}]), "raop_sink.a", "", ECHO_DEFAULT, "[]"
        )
        result = self.run_bridge(
            "select",
            "--local-name",
            "alsa_output.local",
            env={"FOAMY_AUDIO_AIRPLAY_STATE": str(blocked / "state.json")},
        )
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        payload = reply(result)
        self.assertEqual(
            (payload["ok"], payload["error"]), (False, "Output changed, but the AirPlay session could not be saved.")
        )
        self.assertTrue(payload["details"].startswith("cannot create "), payload)
        # The local output stays: nothing routes back to the speaker.
        self.assertEqual(
            self.fakes.argvs()[2:], [["pactl", "set-default-sink", "alsa_output.local"], GET_DEFAULT, STREAMS]
        )
        self.assertNothingLeft()

    def test_a_switch_whose_unrecorded_groups_cannot_be_removed_says_the_output_changed(self):
        self.fakes.queue(
            "pactl",
            json.dumps([{"index": 70, "name": "raop_sink.a"}]),
            "alsa_output.local",
            "",
            ECHO_DEFAULT,
            "[]",
            "88\tmodule-combine-sink\tsink_name=foamy_airplay_group_9 sinks=raop_sink.a,raop_sink.b\n",
            {"stderr": "Failure: busy\n", "code": 1},
        )
        result = self.run_bridge("select", "raop_sink.a")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual(reply(result), {"ok": False, "error": GROUP_LEFT, "details": "Failure: busy"})
        # The switch is done and saved; only the old group is left.
        self.assertEqual(self.saved(), {"selectedNames": ["raop_sink.a"]})
        self.assertEqual(self.fakes.argvs()[-2:], [MODULES, ["pactl", "unload-module", "88"]])
        self.assertNothingLeft()

    # ---- groups no state records -------------------------------------------
    # A select can leave a combine sink loaded that no state names: the next
    # select or stop unloads it.

    def loaded_group(self):
        """The sink_name argument of the group the last load-module asked for."""
        return (self.fakes.fake / "group-sink").read_text()

    def assertNextStopUnloads(self, module_id):
        self.fakes.queue("pactl", {"group_listing": module_id}, "")
        result = self.run_bridge("stop", "--skip-restore")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(
            self.fakes.argvs()[-2:],
            [MODULES, ["pactl", "unload-module", str(module_id)]],
            "the next stop did not unload the group no state records",
        )
        self.assertFalse(self.state.exists())
        self.assertNothingLeft()

    def test_the_group_a_stopped_select_replaced_goes_at_the_next_select(self):
        # The shell quits or reloads after the select saved its new group and
        # before it unloaded the previous one, which no state names then.
        sinks = [
            {"index": 70, "name": "raop_sink.a"},
            {"index": 71, "name": "raop_sink.b"},
            {"index": 62, "name": "alsa_output.local"},
        ]
        self.write_state(
            {
                "restoreName": "alsa_output.local",
                "groupModuleId": 40,
                "groupName": "foamy_airplay_group_7",
                "selectedNames": ["raop_sink.c", "raop_sink.d"],
            }
        )
        self.fakes.queue(
            "pactl", json.dumps(sinks), "88\n", "foamy_airplay_group_7", "", ECHO_DEFAULT, "[]", {"stop_helper": True}
        )
        result = self.run_bridge("select", "raop_sink.a", "raop_sink.b")
        self.assertEqual(result.returncode, -signal.SIGKILL, result.stdout + result.stderr)
        new = self.loaded_group()
        self.assertEqual("sink_name=" + self.saved()["groupName"], new)
        old_line = "40\tmodule-combine-sink\tsink_name=foamy_airplay_group_7 sinks=raop_sink.c,raop_sink.d\n"
        new_line = f"88\tmodule-combine-sink\t{new} sinks=raop_sink.a,raop_sink.b\n"
        # Then the local output is chosen: the recorded group goes, then the other.
        self.fakes.queue(
            "pactl",
            json.dumps(sinks),
            new.removeprefix("sink_name="),
            "",
            ECHO_DEFAULT,
            "[]",
            old_line + new_line,
            "",
            old_line,
            "",
        )
        result = self.run_bridge("select", "--local-name", "alsa_output.local")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(
            self.fakes.argvs()[-4:],
            [MODULES, ["pactl", "unload-module", "88"], MODULES, ["pactl", "unload-module", "40"]],
            "the group the stopped select replaced is still loaded",
        )
        self.assertEqual(self.saved()["restoreName"], "alsa_output.local")
        self.assertNothingLeft()

    def leave_a_group_whose_id_was_never_read(self, load, error):
        sinks = [{"index": 70, "name": "raop_sink.a"}, {"index": 71, "name": "raop_sink.b"}]
        self.fakes.queue("pactl", json.dumps(sinks), load)
        result = self.run_bridge("select", "raop_sink.a", "raop_sink.b")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn(error, reply(result)["error"])
        self.assertFalse(self.state.exists())

    def test_a_group_whose_load_printed_no_id_goes_at_the_next_stop(self):
        self.leave_a_group_whose_id_was_never_read("not a number\n", "invalid literal for int()")
        self.assertNextStopUnloads(88)

    def test_a_group_whose_load_answer_was_lost_goes_at_the_next_stop(self):
        # A load-module past its 12 s deadline ends the same way: the helper
        # never reads an id, while the server may still load the group. One
        # byte over the 4 MiB output bound takes that path without the wait.
        self.leave_a_group_whose_id_was_never_read({"stdout": "x" * ((4 << 20) + 1)}, "printed more than")
        self.assertNextStopUnloads(88)

    def test_a_group_whose_cleanup_failed_goes_at_the_next_stop(self):
        # The group cannot become the default, and unloading it fails too.
        sinks = [{"index": 70, "name": "raop_sink.a"}, {"index": 71, "name": "raop_sink.b"}]
        self.fakes.queue(
            "pactl",
            json.dumps(sinks),
            "88\n",
            "alsa_output.local",
            {"stderr": "Failure: busy\n", "code": 1},
            "",
            ECHO_DEFAULT,
            "[]",
            {"stderr": "Connection failure\n", "code": 1},
        )
        result = self.run_bridge("select", "raop_sink.a", "raop_sink.b")
        self.assertEqual(reply(result), {"ok": False, "error": "AirPlay helper failed: Connection failure"})
        self.assertFalse(self.state.exists())
        self.assertNextStopUnloads(88)

    # ---- stop and status ---------------------------------------------------

    def test_group_cleanup_never_unloads_reused_module_id(self):
        self.write_state({"groupModuleId": 42, "groupName": "foamy_airplay_group_1"})
        # The recorded group, then any group no state records: neither is this one.
        self.fakes.queue("pactl", *["42\tmodule-combine-sink\tsink_name=someone_else\n"] * 2)
        result = self.run_bridge("stop", "--skip-restore")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(reply(result), {"ok": True, "error": "", "restoreName": ""})
        self.assertEqual(self.fakes.argvs(), [MODULES, MODULES])
        self.assertFalse(self.state.exists())

    def test_stop_restores_audio_before_unloading_owned_module(self):
        self.write_state(
            {"moduleId": 536870916, "owned": True, "restoreId": "62", "restoreName": "alsa_output.creative"}
        )
        self.fakes.queue("pactl", "", "alsa_output.creative", "[]", *["536870916\tmodule-raop-discover\n"] * 2, "")
        result = self.run_bridge("stop")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(reply(result), {"ok": True, "error": "", "restoreName": "alsa_output.creative"})
        self.assertEqual(
            self.fakes.argvs(),
            [
                ["pactl", "set-default-sink", "alsa_output.creative"],
                GET_DEFAULT,
                STREAMS,
                MODULES,
                MODULES,
                ["pactl", "unload-module", "536870916"],
            ],
        )
        self.assertFalse(self.state.exists())

    def test_stop_restores_the_requested_output_and_keeps_state_on_failure(self):
        self.write_state({"moduleId": 30, "owned": True, "restoreName": "alsa_output.old"})
        self.fakes.queue(
            "pactl",
            "",
            "alsa_output.new",
            "[]",
            "30\tmodule-raop-discover\n",
            "30\tmodule-raop-discover\n",
            {"stderr": "Failure: Access denied\n", "code": 1},
        )
        result = self.run_bridge("stop", "--restore-id", "9", "--restore-name", "alsa_output.new")
        self.assertEqual(result.returncode, 1)
        self.assertEqual(
            reply(result), {"ok": False, "error": "Failure: Access denied", "restoreName": "alsa_output.new"}
        )
        self.assertEqual(self.fakes.argvs()[0], ["pactl", "set-default-sink", "alsa_output.new"])
        # Ownership is kept so a retry can clean up.
        self.assertEqual(self.saved()["moduleId"], 30)

    def test_stop_leaves_a_module_it_did_not_load(self):
        self.write_state({"moduleId": 27, "owned": False})
        self.fakes.queue("pactl", "27\tmodule-raop-discover\n")
        result = self.run_bridge("stop", "--skip-restore")
        self.assertEqual(result.returncode, 0, result.stderr)
        # Only the listing that looks for groups no state records.
        self.assertEqual(self.fakes.argvs(), [MODULES])
        self.assertFalse(self.state.exists())

    def test_stop_leaves_a_discovery_module_whose_id_was_reused(self):
        # After a server restart the remembered id can name another module.
        self.write_state({"moduleId": 30, "owned": True})
        self.fakes.queue("pactl", *["30\tmodule-null-sink\n"] * 2)
        result = self.run_bridge("stop", "--skip-restore")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(reply(result), {"ok": True, "error": "", "restoreName": ""})
        self.assertEqual(self.fakes.argvs(), [MODULES, MODULES])
        self.assertFalse(self.state.exists())

    def test_module_listing_accepts_pulse_and_native_raop_names(self):
        listing = "\n536870916\tmodule-raop-discover\n27 libpipewire-module-raop-discover { }\nnot-an-id module-raop-discover\n"
        for module_id in (536870916, 27):
            self.write_state({"moduleId": module_id, "owned": True, "peers": []})
            self.fakes.queue("pactl", listing)
            result = self.run_bridge("status")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(
                reply(result),
                {"ok": True, "active": True, "error": "", "moduleId": module_id, "owned": True, "peers": []},
            )
            self.assertTrue(self.state.exists())

    def test_status_forgets_a_session_whose_module_is_gone(self):
        self.write_state({"moduleId": 12, "owned": True})
        self.fakes.queue("pactl", "13\tmodule-raop-discover\n")
        result = self.run_bridge("status")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(reply(result), {"ok": True, "active": False, "error": ""})
        self.assertFalse(self.state.exists())

    def test_status_reports_the_last_line_of_a_pactl_failure(self):
        # A failed listing proves nothing about the module: the session stays.
        self.write_state({"moduleId": 12, "owned": True})
        saved = self.state.read_text()
        self.fakes.queue(
            "pactl", {"stdout": "ignored", "stderr": "Connection failure\nConnection refused\n", "code": 1}
        )
        result = self.run_bridge("status")
        self.assertEqual(result.returncode, 1)
        self.assertEqual(reply(result), {"ok": False, "active": False, "error": "Connection refused"})
        self.assertEqual(self.state.read_text(), saved)

    def test_corrupt_state_is_an_empty_session(self):
        self.state.write_text("{not json")
        self.fakes.queue("pactl", "")
        result = self.run_bridge("status")
        self.assertEqual(reply(result), {"ok": True, "active": False, "error": ""})
        self.assertTrue(self.state.exists())

    def test_a_missing_tool_still_answers_in_json(self):
        os.unlink(self.fakes.bin / "pactl")
        self.write_state({"restoreName": "alsa_output.local", "moduleId": 1, "owned": True})
        result = self.run_bridge("stop")
        self.assertEqual(result.returncode, 1)
        payload = reply(result)
        self.assertFalse(payload["ok"])
        self.assertTrue(payload["error"].startswith("AirPlay helper failed: "), payload)
        self.assertTrue(self.state.exists())

    def test_status_keeps_the_session_when_pactl_cannot_run(self):
        # pactl missing (or past its deadline) says nothing about the module:
        # forgetting the session would leave the owned module loaded for good.
        self.write_state({"moduleId": 12, "owned": True})
        saved = self.state.read_text()
        os.unlink(self.fakes.bin / "pactl")
        result = self.run_bridge("status")
        self.assertEqual(result.returncode, 1)
        payload = reply(result)
        self.assertFalse(payload["ok"])
        self.assertTrue(payload["error"].startswith("AirPlay helper failed: "), payload)
        self.assertEqual(self.state.read_text(), saved)

    # ---- start and discovery -----------------------------------------------

    def test_start_reuses_external_module_without_claiming_ownership(self):
        self.fakes.queue("pactl", "27\tlibpipewire-module-raop-discover\n")
        self.fakes.queue("avahi-browse", "")
        result = self.run_bridge("start", "--restore-id", "62", "--restore-name", "alsa_output.creative")
        self.assertEqual(result.returncode, 0, result.stderr)
        payload = reply(result)
        self.assertEqual(
            payload,
            {
                "ok": True,
                "error": "",
                "moduleId": 27,
                "owned": False,
                "restoreId": "62",
                "restoreName": "alsa_output.creative",
                "peers": [],
            },
        )
        self.assertEqual(self.fakes.argvs(), [MODULES, AVAHI])
        self.assertEqual(self.saved(), {k: v for k, v in payload.items() if k not in ("ok", "error")})

    def test_start_keeps_remembered_ownership_group_and_restore_target(self):
        self.write_state(
            {
                "moduleId": 31,
                "owned": True,
                "restoreId": "5",
                "restoreName": "alsa_output.kept",
                "groupModuleId": 32,
                "groupName": "foamy_airplay_group_3",
                "selectedNames": ["raop_sink.a"],
                "peers": [{"name": "old"}],
                "extra": 1,
            }
        )
        self.fakes.queue("pactl", "30\tmodule-raop-discover\n31\tmodule-raop-discover\n")
        self.fakes.queue("avahi-browse", {"stdout": "", "code": 255})
        result = self.run_bridge("start", "--restore-id", "", "--restore-name", "")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            self.saved(),
            {
                "moduleId": 31,
                "owned": True,
                "restoreId": "5",
                "restoreName": "alsa_output.kept",
                "peers": [],
                "groupModuleId": 32,
                "groupName": "foamy_airplay_group_3",
                "selectedNames": ["raop_sink.a"],
            },
        )

    def test_avahi_records_become_deduplicated_receiver_metadata(self):
        output = (
            "+;eth0;IPv4;020000000002\\064Stue;AirTunes Remote Audio;local\n"
            "=;eth0;IPv6;020000000002\\064Stue;AirTunes Remote Audio;local;Sonos-020000000002.local;"
            'fe80::1;7000;"cn=0,1" "am=Beam"\n'
            "=;eth0;IPv4;020000000002\\064Stue;AirTunes Remote Audio;local;Sonos-020000000002.local;"
            '192.0.2.17;7000;"cn=0,1" "am=Beam"\n'
            "=;eth0;IPv4;Kj\\195\\184kken;AirTunes Remote Audio;local;kitchen.local;192.0.2.18;7000;"
            '"am=One" "x=a\\"b"\n'
            '=;eth0;IPv6;KJ\\195\\184KKEN;AirTunes Remote Audio;local;kitchen.local;fe80::2;7000;"am=Two"\n'
            '=;eth0;IPv4;Hall\\999;AirTunes Remote Audio;local;hall.local;192.0.2.19;+7001;"am=A" "am=B;C"\n'
        )
        self.fakes.queue("pactl", "27\tmodule-raop-discover\n")
        self.fakes.queue("avahi-browse", output)
        result = self.run_bridge("start")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            reply(result)["peers"],
            [
                {
                    "name": "Stue",
                    "hostname": "Sonos-020000000002.local",
                    "address": "192.0.2.17",
                    "port": 7000,
                    "vendor": "Sonos",
                    "model": "Beam",
                },
                {
                    "name": "Kjøkken",
                    "hostname": "kitchen.local",
                    "address": "192.0.2.18",
                    "port": 7000,
                    "vendor": "",
                    "model": "One",
                },
                {
                    "name": "Hall\\999",
                    "hostname": "hall.local",
                    "address": "192.0.2.19",
                    "port": 7001,
                    "vendor": "",
                    "model": "B;C",
                },
            ],
        )

    def test_malformed_avahi_record_is_skipped_not_fatal(self):
        output = (
            '=;eth0;IPv4;Kitchen;AirTunes Remote Audio;local;kitchen.local;192.0.2.20;notaport;"am=One"\n'
            '=;eth0;IPv4;Hall;AirTunes Remote Audio;local;hall.local;192.0.2.21;99999;"am=One"\n'
            '=;eth0;IPv4;Zero;AirTunes Remote Audio;local;zero.local;192.0.2.22;0;"am=One"\n'
            "=;eth0;IPv4;Short;record\n"
            '=;eth0;IPv4;Stue;AirTunes Remote Audio;local;stue.local;192.0.2.17;7000;"am=Beam"\n'
        )
        self.fakes.queue("pactl", "27\tmodule-raop-discover\n")
        self.fakes.queue("avahi-browse", output)
        peers = reply(self.run_bridge("start"))["peers"]
        self.assertEqual([peer["name"] for peer in peers], ["Stue"])
        self.assertEqual(peers[0]["port"], 7000)

    def test_remembered_outputs_named_like_the_help_option_are_values(self):
        self.fakes.queue("pactl", "27\tmodule-raop-discover\n")
        self.fakes.queue("avahi-browse", "")
        result = self.run_bridge("start", "--restore-id", "-h", "--restore-name", "--help")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        payload = reply(result)
        self.assertEqual((payload["restoreId"], payload["restoreName"]), ("-h", "--help"))

    def test_inspecting_modules_failure_is_reported(self):
        self.fakes.queue("pactl", {"code": 1})
        result = self.run_bridge("start")
        self.assertEqual(result.returncode, 1)
        self.assertEqual(reply(result), {"ok": False, "error": "Could not inspect PipeWire modules"})

    @needs_namespace(RAOP_DIR)
    def test_start_loads_one_owned_module_and_remembers_local_output(self):
        self.fakes.bind_raop(installed=True)
        self.fakes.queue("pactl", "", "536870916\n")
        self.fakes.queue("avahi-browse", "")
        result = self.run_bridge("start", "--restore-id", "62", "--restore-name", "alsa_output.creative")
        self.assertEqual(result.returncode, 0, result.stderr)
        payload = reply(result)
        self.assertTrue(payload["ok"])
        self.assertTrue(payload["owned"])
        self.assertEqual(payload["moduleId"], 536870916)
        self.assertEqual(self.fakes.argvs(), [MODULES, ["pactl", "load-module", "module-raop-discover"], AVAHI])
        self.assertEqual(self.saved()["restoreName"], "alsa_output.creative")

    @needs_namespace(RAOP_DIR)
    def test_a_scan_that_cannot_run_leaves_the_loaded_module_to_the_next_stop(self):
        # avahi-browse is optional, and it can also time out: the start fails
        # after it loaded discovery, and only the state file tells a later
        # stop that the module is this plugin's to unload.
        self.fakes.bind_raop(installed=True)
        os.unlink(self.fakes.bin / "avahi-browse")
        self.fakes.queue("pactl", "", "536870916\n")
        result = self.run_bridge("start", "--restore-id", "62", "--restore-name", "alsa_output.creative")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("avahi-browse", reply(result)["error"])
        self.fakes.queue("pactl", *["536870916\tmodule-raop-discover\n"] * 2, "")
        result = self.run_bridge("stop", "--skip-restore")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(
            self.fakes.argvs()[2:],
            [MODULES, MODULES, ["pactl", "unload-module", "536870916"]],
            "the next stop did not unload the discovery module the failed start loaded",
        )
        self.assertFalse(self.state.exists())
        self.assertNothingLeft()

    @needs_namespace(RAOP_DIR)
    def test_a_start_that_cannot_save_its_session_unloads_the_module_again(self):
        # Without a record no later stop would unload it.
        self.fakes.bind_raop(installed=True)
        blocked = self.fakes.root / "a-file"
        blocked.write_text("")
        self.fakes.queue("pactl", "", "536870916\n", "")
        result = self.run_bridge("start", env={"FOAMY_AUDIO_AIRPLAY_STATE": str(blocked / "state.json")})
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertTrue(reply(result)["error"].startswith("AirPlay helper failed: cannot create "), result.stdout)
        self.assertEqual(
            self.fakes.argvs(),
            [MODULES, ["pactl", "load-module", "module-raop-discover"], ["pactl", "unload-module", "536870916"]],
            "a discovery module that could not be recorded stayed loaded",
        )
        self.assertNothingLeft()

    @needs_namespace(RAOP_DIR)
    def test_failed_module_load_passes_on_pactl_status(self):
        self.fakes.bind_raop(installed=True)
        self.fakes.queue("pactl", "", {"stderr": "Failure: Module initialization failed\n", "code": 3})
        result = self.run_bridge("start")
        self.assertEqual(result.returncode, 3)
        self.assertEqual(reply(result), {"ok": False, "error": "Failure: Module initialization failed"})
        self.assertFalse(self.state.exists())

    @needs_namespace(RAOP_DIR)
    def test_invalid_module_id_is_reported(self):
        self.fakes.bind_raop(installed=True)
        self.fakes.queue("pactl", "", "not a number\n")
        result = self.run_bridge("start")
        self.assertEqual(result.returncode, 1)
        self.assertEqual(reply(result), {"ok": False, "error": "PipeWire returned an invalid AirPlay module id"})

    @needs_namespace(RAOP_DIR)
    def test_missing_pipewire_support_is_actionable(self):
        self.fakes.bind_raop(installed=False)
        self.fakes.queue("pactl", "")
        result = self.run_bridge("start")
        self.assertEqual(result.returncode, 2)
        self.assertEqual(reply(result), {"ok": False, "error": "AirPlay support is not installed (pipewire-zeroconf)"})
        self.assertEqual(self.fakes.argvs(), [MODULES])


if __name__ == "__main__":
    unittest.main()
