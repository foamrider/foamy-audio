import importlib.util
import contextlib
import io
import json
from pathlib import Path
import subprocess
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location('ufw_check', Path(__file__).resolve().parents[1] / 'ufw_check.py')
CHECK = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECK)


def status(*rules):
    return 'Status: active\nTo                         Action      From\n--                         ------      ----\n' + '\n'.join(rules)


class UfwCheckTest(unittest.TestCase):
    def test_apply_requests_authorization_once_without_implicit_verification(self):
        output = io.StringIO()
        with patch('sys.argv', ['ufw_check.py', 'open']), \
             patch.object(CHECK, 'run_ufw', return_value='Rule added\n') as run, \
             patch.object(CHECK, 'verify') as verify, contextlib.redirect_stdout(output):
            self.assertEqual(CHECK.main(), 0)
        run.assert_called_once_with(CHECK.OPEN_COMMAND)
        verify.assert_not_called()
        self.assertEqual(json.loads(output.getvalue())['state'], 'applied')

    def test_apply_cancellation_does_not_verify_or_claim_success(self):
        output = io.StringIO()
        with patch('sys.argv', ['ufw_check.py', 'open']), \
             patch.object(CHECK, 'run_ufw', side_effect=RuntimeError('Administrator authorization was cancelled or denied.')) as run, \
             patch.object(CHECK, 'verify') as verify, contextlib.redirect_stdout(output):
            self.assertEqual(CHECK.main(), 1)
        run.assert_called_once_with(CHECK.OPEN_COMMAND)
        verify.assert_not_called()
        self.assertEqual(json.loads(output.getvalue())['state'], 'error')

    def test_separate_ports_and_ipv6_are_accepted(self):
        result = CHECK.inspect_status(status(
            '6001/udp                   ALLOW IN    Anywhere',
            '6002/udp                   ALLOW IN    Anywhere',
            '6001:6002/udp (v6)         ALLOW IN    Anywhere (v6)'))
        self.assertEqual(result['state'], 'open')

    def test_missing_ipv6_is_not_reported_as_open(self):
        text = status('6001:6002/udp              ALLOW IN    Anywhere')
        self.assertEqual(CHECK.inspect_status(text)['state'], 'missing')
        self.assertEqual(CHECK.inspect_status(text, False)['state'], 'open')

    def test_restricted_receiver_or_interface_is_not_global_access(self):
        for rule in ('6001:6002/udp on br0       ALLOW IN    192.0.2.39',
                     '6001:6002/udp              ALLOW IN    192.0.2.0/24',
                     '6001:6002/udp on br0       ALLOW IN    Anywhere'):
            self.assertEqual(CHECK.inspect_status(status(rule))['state'], 'restricted')

    def test_commented_rule_and_long_destination_are_parsed(self):
        text = status('6001:6002/udp on br0       ALLOW IN    192.0.2.39              # AirPlay')
        self.assertEqual(CHECK.inspect_status(text)['state'], 'restricted')
        text = status('192.0.2.10 6001:6002/udp on ethernet0 DENY IN 192.0.2.39 # Block',
                      '6001:6002/udp ALLOW IN Anywhere')
        self.assertEqual(CHECK.inspect_status(text, False)['state'], 'conflict')

    def test_destination_ip_is_not_unrestricted(self):
        text = status('192.0.2.10 6001:6002/udp ALLOW IN Anywhere')
        self.assertEqual(CHECK.inspect_status(text, False)['state'], 'restricted')

    def test_tcp_and_output_rules_do_not_satisfy_udp_input(self):
        text = status('6001:6002/tcp              ALLOW IN    Anywhere',
                      '6001:6002/udp              ALLOW OUT   Anywhere')
        self.assertEqual(CHECK.inspect_status(text)['state'], 'missing')

    def test_blocking_rule_prevents_success_claim(self):
        text = status('6002/udp                   DENY IN     192.0.2.0/24',
                      '6001:6002/udp              ALLOW IN    Anywhere')
        self.assertEqual(CHECK.inspect_status(text, False)['state'], 'conflict')

    def test_inactive_and_unrecognized_status(self):
        self.assertEqual(CHECK.inspect_status('Status: inactive')['state'], 'inactive')
        with self.assertRaises(ValueError):
            CHECK.inspect_status('permission denied')

    def test_authorization_cancellation_is_explicit(self):
        with patch.object(CHECK.subprocess, 'run', return_value=subprocess.CompletedProcess([],126,'','')):
            with self.assertRaisesRegex(RuntimeError, 'cancelled or denied'):
                CHECK.run_ufw(CHECK.STATUS_COMMAND)

    def test_only_system_ufw_is_elevated_and_open_rule_is_unrestricted(self):
        self.assertEqual(CHECK.OPEN_COMMAND,
                         ['/usr/bin/pkexec','/usr/bin/ufw','allow','6001:6002/udp','comment','Foamy Audio AirPlay'])
        with patch.object(CHECK.subprocess, 'run', return_value=subprocess.CompletedProcess([],0,'Status: inactive','')) as run:
            CHECK.run_ufw(CHECK.STATUS_COMMAND)
            self.assertEqual(run.call_args.args[0], ['/usr/bin/pkexec','/usr/bin/ufw','status','verbose'])
            self.assertEqual(run.call_args.kwargs['env']['LC_ALL'], 'C')


if __name__ == '__main__':
    unittest.main()
