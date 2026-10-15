import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'diagnostics'))

import json
import unittest

import diagnosis as d


class FindingsTests(unittest.TestCase):
    def report(self, state='Up', **extra):
        return dict(windows_state=state, headset_state='unknown', headset_warning='unknown',
                    counts={'reset_outside': 0}, stream_metrics_recent=True, warnings=[], **extra)

    def codes(self, report, probe='verified', raw=None):
        return {f['code'] for f in d.findings(report, probe, d.configuration(raw))}

    def test_up_does_not_claim_stream_healthy(self):
        report = self.report()
        found = d.findings(report, 'verified', d.configuration({}))
        self.assertIn('windows_connected', {f['code'] for f in found})
        self.assertIn('evidence_limits', {f['code'] for f in found})
        self.assertFalse(any(f['code'] in ('healthy', 'fixed', 'driver_defective') for f in found))

    def test_failed_probe_is_not_missing_hardware(self):
        self.assertIn('identity_unknown', self.codes(self.report(), 'query_failed'))
        self.assertNotIn('identity_unresolved', self.codes(self.report(), 'query_failed'))
        self.assertIn('identity_unresolved', self.codes(self.report(), 'not_found'))

    def test_verified_disabled_and_disconnected(self):
        self.assertIn('adapter_disabled', self.codes(self.report('Disabled')))
        self.assertIn('adapter_disconnected', self.codes(self.report('Disconnected')))
        self.assertNotIn('adapter_disabled', self.codes(self.report('Disabled'), 'query_failed'))

    def test_inactive_is_user_observation_not_network_cause(self):
        report = self.report()
        report['headset_warning'] = 'inactive'
        codes = self.codes(report)
        self.assertIn('reported_inactive', codes)
        self.assertFalse({'firewall_block', 'driver_defective'} & codes)

    def test_idle_resets_do_not_imply_gameplay_failure(self):
        report = self.report()
        report['counts']['reset_outside'] = 3
        self.assertNotIn('stream_resets', self.codes(report))
        report['headset_state'] = 'awake_streaming'
        self.assertIn('stream_resets', self.codes(report))

    def test_configuration_is_allowlisted_and_unknowns_preserved(self):
        secret = 'private_ssid_password_192.168.1.9'
        config = d.configuration(dict(profile=secret, six_ghz=secret, usb_mode=secret,
                                     power_query='unavailable', device_power_off=secret, SSID=secret))
        self.assertNotIn(secret, json.dumps(config))
        self.assertEqual(config['device_power_off'], 'unknown')
        self.assertEqual(config['usb_mode'], 'unknown')
        codes = self.codes(self.report(), raw=dict(profile='Public', six_ghz='ax'))
        self.assertIn('profile_public', codes)
        self.assertIn('protocol_already_ax', codes)
        self.assertIn('power_unknown', codes)


class TrialTests(unittest.TestCase):
    def setUp(self):
        self.trial = dict(phase_seconds=30, same_workload=True, markers=[])
        self.before = self.phase('00:00:00', '00:00:31')
        self.after = self.phase('00:01:00', '00:01:33')

    def phase(self, start, end):
        return dict(sampling_window=dict(start='2026-10-14T' + start + '-05:00',
                                         end='2026-10-14T' + end + '-05:00'),
                    timeline=[], warnings=[], stream_metrics_recent=True, headset_state='awake_streaming', actions=[], windows_state='Up', stream_path_user_reported='adapter')

    def summary(self):
        return d.summarize_trial(self.trial, self.before, self.after)

    def marker(self, kind, time='00:00:40'):
        self.trial['markers'].append(dict(kind=kind, timestamp='2026-10-14T' + time + '-05:00'))

    def test_equal_windows_exclude_history_and_end_boundary(self):
        for time in ('00:00:00', '00:00:29', '00:00:30'):
            self.before['timeline'].append(dict(kind='stream_reset', timestamp='2026-10-14T' + time + '-05:00'))
        result = self.summary()
        self.assertTrue(result['comparable'])
        self.assertEqual(result['phases'][0]['counts']['stream_reset'], 2)
        self.assertEqual([p['seconds'] for p in result['phases']], [30, 30])
        self.assertIn('does not prove causation', result['interpretation'])

    def test_missing_or_truncated_source_is_not_zero(self):
        for warning in ('steam_log_unavailable', 'wlan_events_unavailable', 'timeline_truncated', 'steam_log_tail_only'):
            self.after['warnings'] = [warning]
            result = self.summary()
            self.assertFalse(result['comparable'])
            self.assertIsNone(result['phases'][1]['counts']['stream_reset'])

    def test_missing_or_stale_stream_evidence_is_incomplete(self):
        self.after['stream_metrics_recent'] = False
        result = self.summary()
        self.assertFalse(result['comparable'])
        self.assertIsNone(result['phases'][1]['counts']['stream_reset'])

    def test_short_capture_is_incomplete(self):
        self.after['sampling_window']['end'] = '2026-10-14T00:01:20-05:00'
        self.assertFalse(self.summary()['comparable'])

    def test_unconfirmed_workload_or_headset_blocks_comparison(self):
        self.trial['same_workload'] = False
        self.assertFalse(self.summary()['comparable'])
        self.trial['same_workload'] = True
        self.after['headset_state'] = 'unknown'
        self.assertFalse(self.summary()['comparable'])

    def test_other_change_or_multiple_actions_confounds(self):
        self.marker('other_change')
        self.assertFalse(self.summary()['comparable'])
        self.trial['markers'] = []
        self.marker('recovery_requested')
        self.marker('recovery_requested', '00:00:45')
        self.assertFalse(self.summary()['comparable'])

    def test_requested_recovery_needs_matching_completed_journal(self):
        self.marker('recovery_requested')
        self.assertFalse(self.summary()['comparable'])
        action = dict(timestamp='2026-10-14T00:00:41-05:00', completed='2026-10-14T00:00:50-05:00', kind='restart', operation_succeeded=True)
        self.after['actions'] = [action]
        self.assertTrue(self.summary()['comparable'])
        action['operation_succeeded'] = False
        self.assertFalse(self.summary()['comparable'])
        action['operation_succeeded'] = True
        action['open_at_capture'] = True
        self.assertFalse(self.summary()['comparable'])

    def test_unannounced_action_invalidates_control(self):
        self.after['actions'] = [dict(timestamp='2026-10-14T00:00:41-05:00', kind='restart', operation_succeeded=True)]
        self.assertFalse(self.summary()['comparable'])

    def test_marker_privacy_and_out_of_window_clearance(self):
        self.marker('private_password_192.168.1.1')
        self.marker('warning_cleared', '00:02:00')
        result = self.summary()
        self.assertFalse(result['warning_clearance_reported'])
        self.assertNotIn('private_password', json.dumps(result))
        self.assertFalse(result['comparable'])
        self.assertIn('marker_outside_observation_period', result['warnings'])

    def test_overlap_rejected(self):
        self.after = self.phase('00:00:15', '00:01:00')
        with self.assertRaises(ValueError):
            self.summary()

    def test_unknown_or_changed_path_blocks_comparison(self):
        self.after['stream_path_user_reported'] = 'unknown'
        self.assertFalse(self.summary()['comparable'])
        self.assertIn('stream_path_unknown_or_changed', self.summary()['warnings'])
        self.after['stream_path_user_reported'] = 'home_wifi'
        self.assertFalse(self.summary()['comparable'])

    def test_operation_must_occur_between_phases_after_request(self):
        self.marker('recovery_requested')
        action = dict(timestamp='2026-10-14T00:00:41-05:00', completed='2026-10-14T00:00:50-05:00', kind='restart', operation_succeeded=True)
        self.after['actions'] = [action]
        self.assertTrue(self.summary()['comparable'])
        action['completed'] = '2026-10-14T00:01:10-05:00'
        self.assertFalse(self.summary()['comparable'])
        action['completed'] = '2026-10-14T00:00:50-05:00'
        action['timestamp'] = '2026-10-14T00:00:20-05:00'
        self.assertFalse(self.summary()['comparable'])

    def test_version_or_known_configuration_change_confounds(self):
        self.before['system'] = dict(adapter_driver='1.0')
        self.after['system'] = dict(adapter_driver='2.0')
        self.assertFalse(self.summary()['comparable'])
        self.assertEqual(self.summary()['detected_configuration_changes'], ['system.adapter_driver'])
        self.after['system']['adapter_driver'] = 'unknown'
        self.assertTrue(self.summary()['comparable'])

    def test_invalid_duration_rejected(self):
        for seconds in (True, 0, 181, '30'):
            self.trial['phase_seconds'] = seconds
            with self.assertRaises(ValueError):
                self.summary()


if __name__ == '__main__':
    unittest.main()
