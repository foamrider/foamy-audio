import importlib.util
import contextlib
import io
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location('ufw_check', Path(__file__).resolve().parents[1] / 'ufw_check.py')
CHECK = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECK)

LAN = {'interface': 'wlan0', 'network': '192.0.2.0/24'}
SPEAKER = {'address': '192.0.2.39', 'interface': 'wlan0'}


def status(*rules):
    return 'Status: active\nTo                         Action      From\n--                         ------      ----\n' + '\n'.join(rules)


def network(routes, addresses=None):
    """A fake `ip -j` runner: route get answers, addr show lists wlan0."""
    calls = []

    def run(command):
        calls.append(list(command))
        if command[:3] == ['ip', '-j', 'route']:
            return json.dumps([routes[command[-1]]])
        return json.dumps(addresses if addresses is not None else [{'ifname': 'wlan0', 'addr_info': [
            {'family': 'inet', 'local': '192.0.2.10', 'prefixlen': 24}]}])
    run.calls = calls
    return run


class ScopeTest(unittest.TestCase):
    def test_on_link_speaker_is_scoped_to_its_subnet_and_interface(self):
        run = network({'192.0.2.39': {'dst': '192.0.2.39', 'dev': 'wlan0', 'prefsrc': '192.0.2.10'}})
        self.assertEqual(CHECK.scope_for('192.0.2.39', run), LAN)
        self.assertEqual(run.calls[1], ['ip', '-j', '-4', 'addr', 'show', 'dev', 'wlan0'])

    def test_routed_speaker_gets_a_single_address_rule(self):
        run = network({'198.51.100.7': {'dst': '198.51.100.7', 'gateway': '192.0.2.1', 'dev': 'wlan0'}})
        self.assertEqual(CHECK.scope_for('198.51.100.7', run), {'interface': 'wlan0', 'network': '198.51.100.7/32'})

    def test_bad_addresses_and_interfaces_are_refused(self):
        with self.assertRaises(ValueError):
            CHECK.scope_for('192.0.2.39; rm -rf /', network({}))
        run = network({'192.0.2.39': {'dst': '192.0.2.39', 'dev': 'wlan0 from any'}})
        with self.assertRaises(RuntimeError):
            CHECK.scope_for('192.0.2.39', run)

    def test_allow_and_delete_commands_elevate_only_ufw_with_a_scoped_rule(self):
        rule = ['in', 'on', 'wlan0', 'proto', 'udp', 'from', '192.0.2.0/24', 'to', 'any', 'port', '6001:6002']
        self.assertEqual(CHECK.allow_command(LAN), ['/usr/bin/pkexec', '/usr/bin/ufw', 'allow'] + rule
                         + ['comment', 'Foamy Audio AirPlay'])
        self.assertEqual(CHECK.delete_command(LAN), ['/usr/bin/pkexec', '/usr/bin/ufw', 'delete', 'allow'] + rule)
        self.assertNotIn('Anywhere', ' '.join(CHECK.allow_command(LAN)))


class ApplyRemoveTest(unittest.TestCase):
    def test_apply_adds_one_rule_per_network_and_records_it(self):
        run = network({'192.0.2.39': {'dst': '192.0.2.39', 'dev': 'wlan0'},
                       '192.0.2.40': {'dst': '192.0.2.40', 'dev': 'wlan0'}})
        ufw = []
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'state/firewall.json'
            result = CHECK.apply(['192.0.2.39', '192.0.2.40'], runner=run,
                                 ufw=lambda c: ufw.append(c) or 'Rule added\n', path=path)
            self.assertEqual(result['state'], 'applied')
            self.assertEqual(ufw, [CHECK.allow_command(LAN)])
            self.assertEqual(json.loads(path.read_text()), {'rules': [LAN]})
            # Applying again does not duplicate the record.
            CHECK.apply(['192.0.2.39'], runner=run, ufw=lambda c: '', path=path)
            self.assertEqual(json.loads(path.read_text()), {'rules': [LAN]})

    def test_apply_without_speakers_asks_for_nothing(self):
        result = CHECK.apply([], runner=network({}), ufw=lambda c: self.fail('no elevation'))
        self.assertEqual(result['state'], 'nopeers')

    def test_remove_deletes_recorded_and_legacy_rules(self):
        ufw = []
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'firewall.json'
            path.write_text(json.dumps({'rules': [LAN, {'interface': 'bad iface', 'network': 'x'}]}))
            result = CHECK.remove(True, ufw=lambda c: ufw.append(c) or 'Rule deleted\n', path=path)
            self.assertEqual(result['state'], 'removed')
            self.assertEqual(ufw, [CHECK.delete_command(LAN), CHECK.LEGACY_DELETE_COMMAND])
            self.assertEqual(json.loads(path.read_text()), {'rules': []})
            self.assertEqual(CHECK.remove(False, ufw=lambda c: self.fail('no elevation'), path=path)['state'], 'none')

    def test_failed_delete_keeps_the_record_for_a_retry(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'firewall.json'
            path.write_text(json.dumps({'rules': [LAN]}))

            def refuse(_command):
                raise RuntimeError('Administrator authorization was cancelled or denied.')
            with self.assertRaises(RuntimeError):
                CHECK.remove(False, ufw=refuse, path=path)
            self.assertEqual(json.loads(path.read_text()), {'rules': [LAN]})

    def test_cli_cancellation_reports_an_error_without_claiming_success(self):
        output = io.StringIO()
        with patch.object(CHECK, 'apply', side_effect=RuntimeError('Administrator authorization was cancelled or denied.')), \
             patch.object(CHECK, 'verify') as verify, contextlib.redirect_stdout(output):
            self.assertEqual(CHECK.main(['open', '--peer', '192.0.2.39']), 1)
        verify.assert_not_called()
        self.assertEqual(json.loads(output.getvalue())['state'], 'error')

    def test_cli_refuses_non_address_peers(self):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            self.assertEqual(CHECK.main(['open', '--peer=0.0.0.0/0']), 1)
        self.assertEqual(json.loads(output.getvalue().splitlines()[-1])['state'], 'error')


class InspectTest(unittest.TestCase):
    def test_scoped_rule_covering_the_speaker_is_open(self):
        text = status('6001:6002/udp on wlan0      ALLOW IN    192.0.2.0/24               # Foamy Audio AirPlay')
        result = CHECK.inspect_status(text, [SPEAKER])
        self.assertEqual(result['state'], 'open')
        self.assertFalse(result['legacy'])

    def test_separate_ports_and_single_addresses_count(self):
        text = status('6001/udp                   ALLOW IN    192.0.2.39',
                      '6002/udp on wlan0          ALLOW IN    192.0.2.0/25')
        self.assertEqual(CHECK.inspect_status(text, [SPEAKER])['state'], 'open')

    def test_unrestricted_legacy_rule_is_reported_as_wide(self):
        text = status('6001:6002/udp              ALLOW IN    Anywhere                   # Foamy Audio AirPlay',
                      '6001:6002/udp (v6)         ALLOW IN    Anywhere (v6)              # Foamy Audio AirPlay')
        result = CHECK.inspect_status(text, [SPEAKER])
        self.assertEqual(result['state'], 'wide')
        self.assertTrue(result['legacy'])
        self.assertEqual(CHECK.inspect_status(text)['state'], 'wide')

    def test_wide_rule_is_reported_even_next_to_a_scoped_rule(self):
        # An upgrade that applied the scoped rule but kept the 1.0 rule is still open everywhere.
        text = status('6001:6002/udp on wlan0      ALLOW IN    192.0.2.0/24               # Foamy Audio AirPlay',
                      '6001:6002/udp              ALLOW IN    Anywhere                   # Foamy Audio AirPlay',
                      '6001:6002/udp (v6)         ALLOW IN    Anywhere (v6)              # Foamy Audio AirPlay')
        result = CHECK.inspect_status(text, [SPEAKER])
        self.assertEqual(result['state'], 'wide')
        self.assertTrue(result['legacy'])
        self.assertEqual(CHECK.inspect_status(text)['state'], 'wide')
        # A wide rule for another interface still exposes the ports there.
        text = status('6001:6002/udp on wlan0      ALLOW IN    192.0.2.0/24',
                      '6001:6002/udp on eth0       ALLOW IN    Anywhere')
        self.assertEqual(CHECK.inspect_status(text, [SPEAKER])['state'], 'wide')

    def test_rules_for_another_network_or_interface_do_not_cover(self):
        for rule in ('6001:6002/udp on eth0       ALLOW IN    192.0.2.0/24',
                     '6001:6002/udp              ALLOW IN    198.51.100.0/24',
                     '6001:6002/udp (v6)         ALLOW IN    Anywhere (v6)',
                     '192.0.2.10 6001:6002/udp   ALLOW IN    192.0.2.0/24'):
            self.assertEqual(CHECK.inspect_status(status(rule), [SPEAKER])['state'], 'missing', rule)

    def test_every_speaker_must_be_covered(self):
        text = status('6001:6002/udp on wlan0      ALLOW IN    192.0.2.39')
        other = {'address': '192.0.2.40', 'interface': 'wlan0'}
        self.assertEqual(CHECK.inspect_status(text, [SPEAKER, other])['state'], 'missing')

    def test_blocking_rule_prevents_success_claim(self):
        text = status('6002/udp                   DENY IN     192.0.2.0/24',
                      '6001:6002/udp on wlan0     ALLOW IN    192.0.2.0/24')
        self.assertEqual(CHECK.inspect_status(text, [SPEAKER])['state'], 'conflict')
        # A deny for another network does not affect these speakers.
        text = status('6002/udp                   DENY IN     198.51.100.0/24',
                      '6001:6002/udp on wlan0     ALLOW IN    192.0.2.0/24')
        self.assertEqual(CHECK.inspect_status(text, [SPEAKER])['state'], 'open')

    def test_tcp_and_output_rules_do_not_satisfy_udp_input(self):
        text = status('6001:6002/tcp              ALLOW IN    192.0.2.0/24',
                      '6001:6002/udp              ALLOW OUT   192.0.2.0/24')
        self.assertEqual(CHECK.inspect_status(text, [SPEAKER])['state'], 'missing')

    def test_without_speakers_owned_rules_are_reported(self):
        text = status('6001:6002/udp on wlan0      ALLOW IN    192.0.2.0/24               # Foamy Audio AirPlay')
        self.assertEqual(CHECK.inspect_status(text)['state'], 'present')
        self.assertEqual(CHECK.inspect_status(status())['state'], 'missing')

    def test_inactive_and_unrecognized_status(self):
        self.assertEqual(CHECK.inspect_status('Status: inactive')['state'], 'inactive')
        with self.assertRaises(ValueError):
            CHECK.inspect_status('permission denied')

    def test_verify_resolves_each_speaker_interface(self):
        run = network({'192.0.2.39': {'dst': '192.0.2.39', 'dev': 'wlan0'}})
        text = status('6001:6002/udp on wlan0      ALLOW IN    192.0.2.0/24')
        self.assertEqual(CHECK.verify(['192.0.2.39'], runner=run, ufw=lambda c: text)['state'], 'open')

    def test_authorization_cancellation_is_explicit(self):
        with patch.object(CHECK.subprocess, 'run', return_value=subprocess.CompletedProcess([], 126, '', '')):
            with self.assertRaisesRegex(RuntimeError, 'cancelled or denied'):
                CHECK.run_ufw(CHECK.STATUS_COMMAND)

    def test_status_runs_system_ufw_in_the_c_locale(self):
        with patch.object(CHECK.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, 'Status: inactive', '')) as run:
            CHECK.run_ufw(CHECK.STATUS_COMMAND)
            self.assertEqual(run.call_args.args[0], ['/usr/bin/pkexec', '/usr/bin/ufw', 'status', 'verbose'])
            self.assertEqual(run.call_args.kwargs['env']['LC_ALL'], 'C')


if __name__ == '__main__':
    unittest.main()
