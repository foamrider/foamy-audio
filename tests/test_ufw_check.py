"""Black-box tests of the UFW check (see blackbox.py). Every test runs the
helper in a private mount namespace in which /usr/bin/pkexec and
/usr/bin/ufw are fakes, with a fake `ip`; nothing reaches the real firewall
or Polkit."""

import json
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
from blackbox import PKEXEC, UFW, Fakes, needs_namespace, reply  # noqa: E402

LAN = {"interface": "wlan0", "network": "192.0.2.0/24"}
RULE = ["in", "on", "wlan0", "proto", "udp", "from", "192.0.2.0/24", "to", "any", "port", "6001:6002"]
ALLOW = [PKEXEC, UFW, "allow", *RULE, "comment", "Foamy Audio AirPlay"]
DELETE = [PKEXEC, UFW, "delete", "allow", *RULE]
LEGACY_DELETE = [PKEXEC, UFW, "delete", "allow", "6001:6002/udp"]
STATUS = [PKEXEC, UFW, "status", "verbose"]
ON_LINK = {"192.0.2.39": {"dst": "192.0.2.39", "dev": "wlan0", "prefsrc": "192.0.2.10"},
           "192.0.2.40": {"dst": "192.0.2.40", "dev": "wlan0"}}
CANCELLED = "Administrator authorization was cancelled or denied."


def status(*rules):
    return ("Status: active\nLogging: on (low)\nDefault: deny (incoming), allow (outgoing), disabled (routed)\n"
            "New profiles: skip\n\nTo                         Action      From\n"
            "--                         ------      ----\n" + "\n".join(rules) + "\n\n")


@needs_namespace(PKEXEC, UFW)
class UfwTest(unittest.TestCase):
    def setUp(self):
        self.fakes = Fakes(tools=())
        self.addCleanup(self.fakes.close)
        self.fakes.bind_ufw()
        self.fakes.routes(ON_LINK)
        self.record = self.fakes.state / "foamy-audio/firewall.json"

    def ufw(self, *args, env=None):
        return self.fakes.run("ufw", *args, env=env)

    def pkexec_calls(self):
        calls = self.fakes.calls("pkexec")
        for call in calls:
            # Elevation always goes through the absolute pkexec path, in the C locale.
            self.assertEqual(call["path"], PKEXEC)
            self.assertEqual(call["lc_all"], "C")
        self.assertEqual(self.fakes.calls("ufw-direct"), [])
        return [[PKEXEC, *call["argv"][1:]] for call in calls]

    def verify(self, text, *peers):
        self.fakes.queue("pkexec", text)
        args = []
        for peer in peers:
            args += ["--peer", peer]
        result = self.ufw("verify", *args)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        payload = reply(result)
        self.assertEqual(payload["details"], text.strip())
        return payload

    # ---- scope -------------------------------------------------------------

    def test_on_link_speaker_is_scoped_to_its_subnet_and_interface(self):
        self.fakes.queue("pkexec", "Rule added\nRule added (v6)\n")
        result = self.ufw("open", "--peer", "192.0.2.39")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(reply(result), {"state": "applied", "message": "Rules applied. Verify to check.",
                                         "details": "Rule added\nRule added (v6)", "rules": [LAN]})
        ip = self.fakes.calls("ip")
        self.assertEqual([call["argv"] for call in ip], [["ip", "-j", "route", "get", "192.0.2.39"],
                                                         ["ip", "-j", "-4", "addr", "show", "dev", "wlan0"]])
        self.assertEqual({call["lc_all"] for call in ip}, {"C"})
        self.assertEqual(self.pkexec_calls(), [ALLOW])

    def test_routed_speaker_gets_a_single_address_rule(self):
        self.fakes.routes({"198.51.100.7": {"dst": "198.51.100.7", "gateway": "192.0.2.1", "dev": "wlan0"}})
        self.fakes.queue("pkexec", "")
        result = self.ufw("open", "--peer", "198.51.100.7")
        self.assertEqual(reply(result)["rules"], [{"interface": "wlan0", "network": "198.51.100.7/32"}])
        self.assertEqual(self.fakes.argvs("ip"), [["ip", "-j", "route", "get", "198.51.100.7"]])
        self.assertEqual(self.pkexec_calls()[0][9], "198.51.100.7/32")

    def test_ipv6_speakers_use_the_v6_family_and_canonical_addresses(self):
        self.fakes.routes({"2001:db8::7": {"dst": "2001:db8::7", "dev": "eth0@if3"}},
                          [{"ifname": "eth0", "addr_info": [
                              {"family": "inet6", "local": "2001:db8::1", "prefixlen": 64},
                              {"family": "inet6", "local": "fe80::1", "prefixlen": 64},
                              {"family": "inet6", "prefixlen": 64}]}])
        self.fakes.queue("pkexec", "")
        result = self.ufw("open", "--peer", "2001:DB8:0:0::7")
        self.assertEqual(reply(result)["rules"], [{"interface": "eth0", "network": "2001:db8::/64"}])
        self.assertEqual(self.fakes.argvs("ip"), [["ip", "-j", "route", "get", "2001:db8::7"],
                                                  ["ip", "-j", "-6", "addr", "show", "dev", "eth0"]])

    def test_bad_addresses_and_interfaces_are_refused(self):
        result = self.ufw("open", "--peer", "192.0.2.39; rm -rf /")
        self.assertEqual(result.returncode, 1)
        self.assertEqual(reply(result)["state"], "error")
        self.assertEqual(self.fakes.calls(), [])
        self.fakes.routes({"192.0.2.39": {"dst": "192.0.2.39", "dev": "wlan0 from any"}})
        result = self.ufw("open", "--peer", "192.0.2.39")
        self.assertEqual(result.returncode, 1)
        self.assertEqual(reply(result), {"state": "error", "message": "Could not apply UFW rules.",
                                         "details": "No local interface reaches 192.0.2.39."})
        self.assertEqual(self.pkexec_calls(), [])

    def test_unreachable_speaker_reports_the_ip_error(self):
        result = self.ufw("verify", "--peer", "203.0.113.5")
        self.assertEqual(result.returncode, 1)
        self.assertEqual(reply(result), {"state": "error", "message": "Could not complete the UFW check.",
                                         "details": "RTNETLINK answers: Network is unreachable"})
        self.assertEqual(self.pkexec_calls(), [])

    def test_cli_refuses_non_address_peers(self):
        for peer in ("0.0.0.0/0", "192.0.2.039", "", "192.0.2.39 "):
            result = self.ufw("open", "--peer=" + peer)
            self.assertEqual(result.returncode, 1, peer)
            payload = reply(result)
            self.assertEqual(payload["state"], "error")
            self.assertEqual(payload["message"], "Could not apply UFW rules.")
            self.assertEqual(payload["details"], f"'{peer}' does not appear to be an IPv4 or IPv6 address")
        result = self.ufw("remove", "--peer", "nope")
        self.assertEqual(reply(result)["message"], "Could not remove UFW rules.")
        self.assertEqual(self.fakes.calls(), [])

    # ---- open and remove ---------------------------------------------------

    def test_apply_adds_one_rule_per_network_and_records_it(self):
        self.fakes.queue("pkexec", "Rule added\n")
        result = self.ufw("open", "--peer", "192.0.2.39", "--peer", "192.0.2.40", "--peer", "192.0.2.39")
        self.assertEqual(reply(result)["state"], "applied")
        self.assertEqual(self.pkexec_calls(), [ALLOW])
        self.assertEqual(json.loads(self.record.read_text()), {"rules": [LAN]})
        # Applying again does not duplicate the record.
        self.fakes.queue("pkexec", "Skipping adding existing rule\n")
        self.assertEqual(reply(self.ufw("open", "--peer", "192.0.2.39"))["state"], "applied")
        self.assertEqual(json.loads(self.record.read_text()), {"rules": [LAN]})

    def test_apply_records_each_network_once_in_order(self):
        self.fakes.routes({**ON_LINK, "198.51.100.7": {"dst": "198.51.100.7", "gateway": "192.0.2.1", "dev": "wlan0"}})
        self.record.parent.mkdir(parents=True)
        self.record.write_text(json.dumps({"rules": [{"interface": "eth0", "network": "10.0.0.0/8"}]}))
        self.fakes.queue("pkexec", "a\n", "b\n")
        result = self.ufw("open", "--peer", "198.51.100.7", "--peer", "192.0.2.39")
        routed = {"interface": "wlan0", "network": "198.51.100.7/32"}
        self.assertEqual(reply(result), {"state": "applied", "message": "Rules applied. Verify to check.",
                                         "details": "a\nb", "rules": [routed, LAN]})
        self.assertEqual(json.loads(self.record.read_text()),
                         {"rules": [{"interface": "eth0", "network": "10.0.0.0/8"}, routed, LAN]})

    def test_apply_without_speakers_asks_for_nothing(self):
        result = self.ufw("open")
        self.assertEqual(result.returncode, 0)
        self.assertEqual(reply(result), {"state": "nopeers", "message": "No AirPlay speakers found.", "details": ""})
        self.assertEqual(self.fakes.calls(), [])

    def test_remove_deletes_recorded_and_legacy_rules(self):
        self.record.parent.mkdir(parents=True)
        self.record.write_text(json.dumps({"rules": [LAN, {"interface": "bad iface", "network": "x"},
                                                     {"interface": "eth0", "network": "192.0.2.5/24"}]}))
        self.fakes.queue("pkexec", "Rule deleted\n", "Rule deleted\nRule deleted (v6)\n")
        result = self.ufw("remove", "--legacy")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(reply(result), {"state": "removed", "message": "Rules removed.",
                                         "details": "Rule deleted\nRule deleted\nRule deleted (v6)"})
        self.assertEqual(self.pkexec_calls(), [DELETE, LEGACY_DELETE])
        self.assertEqual(json.loads(self.record.read_text()), {"rules": []})
        result = self.ufw("remove")
        self.assertEqual(reply(result), {"state": "none", "message": "No Foamy Audio rules to remove.", "details": ""})
        self.assertEqual(len(self.pkexec_calls()), 2)

    def test_legacy_rule_alone_is_removed_without_a_record(self):
        self.fakes.queue("pkexec", "Could not delete non-existent rule\n")
        result = self.ufw("remove", "--legacy")
        self.assertEqual(reply(result)["state"], "removed")
        self.assertEqual(self.pkexec_calls(), [LEGACY_DELETE])
        self.assertFalse(self.record.exists())

    def test_failed_delete_keeps_the_record_for_a_retry(self):
        self.record.parent.mkdir(parents=True)
        self.record.write_text(json.dumps({"rules": [LAN]}))
        self.fakes.queue("pkexec", {"code": 126})
        result = self.ufw("remove")
        self.assertEqual(result.returncode, 1)
        self.assertEqual(reply(result), {"state": "error", "message": "Could not remove UFW rules.", "details": CANCELLED})
        self.assertEqual(json.loads(self.record.read_text()), {"rules": [LAN]})

    def test_cli_cancellation_reports_an_error_without_claiming_success(self):
        self.fakes.queue("pkexec", {"code": 127, "stderr": "Not authorized\n"})
        result = self.ufw("open", "--peer", "192.0.2.39")
        self.assertEqual(result.returncode, 1)
        self.assertEqual(reply(result), {"state": "error", "message": "Could not apply UFW rules.", "details": CANCELLED})
        # No verification follows: one authorization prompt, then the error.
        self.assertEqual(self.pkexec_calls(), [ALLOW])
        self.assertFalse(self.record.exists())

    def test_ufw_failure_reports_its_output(self):
        self.fakes.queue("pkexec", {"code": 1, "stdout": "partial\n", "stderr": "ERROR: Bad port\n"})
        result = self.ufw("open", "--peer", "192.0.2.39")
        self.assertEqual(reply(result)["details"], "ERROR: Bad port")
        self.fakes.queue("pkexec", {"code": 1, "stdout": " only stdout \n"})
        self.assertEqual(reply(self.ufw("verify"))["details"], "only stdout")
        self.fakes.queue("pkexec", {"code": 1})
        self.assertEqual(reply(self.ufw("verify"))["details"], "UFW failed.")

    def test_state_path_override(self):
        other = self.fakes.root / "record.json"
        self.fakes.queue("pkexec", "")
        self.ufw("open", "--peer", "192.0.2.39", env={"FOAMY_AUDIO_FIREWALL_STATE": str(other)})
        self.assertEqual(json.loads(other.read_text()), {"rules": [LAN]})
        self.assertFalse(self.record.exists())

    # ---- verify ------------------------------------------------------------

    def test_status_runs_system_ufw_in_the_c_locale(self):
        self.verify("Status: inactive\n")
        self.assertEqual(self.pkexec_calls(), [STATUS])

    def test_authorization_cancellation_is_explicit(self):
        self.fakes.queue("pkexec", {"code": 126})
        result = self.ufw("verify", "--peer", "192.0.2.39")
        self.assertEqual(result.returncode, 1)
        self.assertEqual(reply(result), {"state": "error", "message": "Could not complete the UFW check.",
                                         "details": CANCELLED})

    def test_inactive_and_unrecognized_status(self):
        self.assertEqual(self.verify("Status: inactive"),
                         {"state": "inactive", "message": "UFW is inactive.", "details": "Status: inactive",
                          "legacy": False})
        self.fakes.queue("pkexec", "permission denied")
        result = self.ufw("verify")
        self.assertEqual(result.returncode, 1)
        self.assertEqual(reply(result), {"state": "error", "message": "Could not complete the UFW check.",
                                         "details": "UFW returned an unrecognized status."})

    def test_scoped_rule_covering_the_speaker_is_open(self):
        text = status("6001:6002/udp on wlan0      ALLOW IN    192.0.2.0/24               # Foamy Audio AirPlay")
        result = self.verify(text, "192.0.2.39")
        self.assertEqual(result["state"], "open")
        self.assertEqual(result["message"], "The speakers can reach UDP 6001–6002.")
        self.assertFalse(result["legacy"])

    def test_separate_ports_and_single_addresses_count(self):
        text = status("6001/udp                   ALLOW IN    192.0.2.39",
                      "6002/udp on wlan0          ALLOW IN    192.0.2.0/25")
        self.assertEqual(self.verify(text, "192.0.2.39")["state"], "open")
        text = status("6000,6001,7000:8000/udp    ALLOW IN    192.0.2.39",
                      "6002:6001/udp              ALLOW IN    192.0.2.39",
                      "6002                       ALLOW IN    192.0.2.0/255.255.255.0")
        self.assertEqual(self.verify(text, "192.0.2.39")["state"], "open")

    def test_unrestricted_legacy_rule_is_reported_as_wide(self):
        text = status("6001:6002/udp              ALLOW IN    Anywhere                   # Foamy Audio AirPlay",
                      "6001:6002/udp (v6)         ALLOW IN    Anywhere (v6)              # Foamy Audio AirPlay")
        result = self.verify(text, "192.0.2.39")
        self.assertEqual(result["state"], "wide")
        self.assertEqual(result["message"], "UDP 6001–6002 is open to every network.")
        self.assertTrue(result["legacy"])
        self.assertEqual(self.verify(text)["state"], "wide")

    def test_wide_rule_is_reported_even_next_to_a_scoped_rule(self):
        # An upgrade that applied the scoped rule but kept the 1.0 rule is still open everywhere.
        text = status("6001:6002/udp on wlan0      ALLOW IN    192.0.2.0/24               # Foamy Audio AirPlay",
                      "6001:6002/udp              ALLOW IN    Anywhere                   # Foamy Audio AirPlay",
                      "6001:6002/udp (v6)         ALLOW IN    Anywhere (v6)              # Foamy Audio AirPlay")
        result = self.verify(text, "192.0.2.39")
        self.assertEqual(result["state"], "wide")
        self.assertTrue(result["legacy"])
        self.assertEqual(self.verify(text)["state"], "wide")
        # A wide rule for another interface still exposes the ports there.
        text = status("6001:6002/udp on wlan0      ALLOW IN    192.0.2.0/24",
                      "6001:6002/udp on eth0       ALLOW IN    Anywhere")
        self.assertEqual(self.verify(text, "192.0.2.39")["state"], "wide")
        self.assertFalse(self.verify(text, "192.0.2.39")["legacy"])

    def test_rules_for_another_network_or_interface_do_not_cover(self):
        for rule in ("6001:6002/udp on eth0       ALLOW IN    192.0.2.0/24",
                     "6001:6002/udp              ALLOW IN    198.51.100.0/24",
                     "6001:6002/udp (v6)         ALLOW IN    Anywhere (v6)",
                     "6001:6002/udp              ALLOW IN    2001:db8::/32",
                     "192.0.2.10 6001:6002/udp   ALLOW IN    192.0.2.0/24",
                     "6001:6002/udp              ALLOW IN    not-a-network",
                     "6001:6002/udp              ALLOW FWD   192.0.2.0/24"):
            with self.subTest(rule=rule):
                self.assertEqual(self.verify(status(rule), "192.0.2.39")["state"], "missing")

    def test_every_speaker_must_be_covered(self):
        text = status("6001:6002/udp on wlan0      ALLOW IN    192.0.2.39")
        self.assertEqual(self.verify(text, "192.0.2.39", "192.0.2.40")["state"], "missing")
        self.assertEqual(self.verify(text, "192.0.2.39")["state"], "open")

    def test_blocking_rule_prevents_success_claim(self):
        text = status("6002/udp                   DENY IN     192.0.2.0/24",
                      "6001:6002/udp on wlan0     ALLOW IN    192.0.2.0/24")
        self.assertEqual(self.verify(text, "192.0.2.39")["state"], "conflict")
        # A deny for another network does not affect these speakers.
        text = status("6002/udp                   DENY IN     198.51.100.0/24",
                      "6001:6002/udp on wlan0     ALLOW IN    192.0.2.0/24")
        self.assertEqual(self.verify(text, "192.0.2.39")["state"], "open")
        # A limit or reject with a destination address still counts as blocking.
        text = status("192.0.2.10 6001/udp        LIMIT IN    Anywhere",
                      "6001:6002/udp on wlan0     ALLOW IN    192.0.2.0/24")
        self.assertEqual(self.verify(text, "192.0.2.39")["state"], "conflict")
        self.assertEqual(self.verify(status("6001/udp REJECT IN Anywhere"))["message"],
                         "A blocking UFW rule may affect AirPlay.")

    def test_tcp_and_output_rules_do_not_satisfy_udp_input(self):
        text = status("6001:6002/tcp              ALLOW IN    192.0.2.0/24",
                      "6001:6002/udp              ALLOW OUT   192.0.2.0/24")
        self.assertEqual(self.verify(text, "192.0.2.39")["state"], "missing")

    def test_anywhere_destination_and_bare_ports_cover(self):
        text = status("Anywhere on wlan0          ALLOW IN    192.0.2.0/24",
                      "6001:6002                  ALLOW IN    192.0.2.0/24")
        self.assertEqual(self.verify(text, "192.0.2.39")["state"], "open")

    def test_without_speakers_owned_rules_are_reported(self):
        text = status("6001:6002/udp on wlan0      ALLOW IN    192.0.2.0/24               # Foamy Audio AirPlay")
        payload = self.verify(text)
        self.assertEqual(payload["state"], "present")
        self.assertEqual(payload["message"], "A Foamy Audio rule exists. Find speakers to check it.")
        missing = self.verify(status())
        self.assertEqual(missing["state"], "missing")
        self.assertEqual(missing["message"], "No rule lets the speakers reach UDP 6001–6002.")

    def test_verify_resolves_each_speaker_interface(self):
        self.fakes.routes({"192.0.2.39": {"dst": "192.0.2.39", "dev": "wlan0"},
                           "192.0.2.41": {"dst": "192.0.2.41", "dev": "eth1"}},
                          [{"ifname": "x", "addr_info": [{"local": "192.0.2.10", "prefixlen": 24}]}])
        text = status("6001:6002/udp on wlan0      ALLOW IN    192.0.2.0/24")
        self.assertEqual(self.verify(text, "192.0.2.39")["state"], "open")
        self.assertEqual(self.verify(text, "192.0.2.41")["state"], "missing")
        self.assertEqual(self.fakes.argvs("ip")[-2:], [["ip", "-j", "route", "get", "192.0.2.41"],
                                                       ["ip", "-j", "-4", "addr", "show", "dev", "eth1"]])


if __name__ == "__main__":
    unittest.main()
