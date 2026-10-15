import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'diagnostics'))

import datetime as dt
import json
from pathlib import Path
import tempfile
import unittest

import frame_diagnostics as fd

class DiagnosticsTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.log = self.root / "steam.txt"
        self.actions = self.root / "actions"
        self.actions.mkdir()
        self.capture = {
            "history_started": "2026-10-14T00:00:00.0000000-05:00",
            "capture_finished": "2026-10-14T01:00:00.0000000-05:00",
            "utc_offset": "-05:00", "system": {"os": "Windows"},
            "adapter_samples": [{"timestamp": "2026-10-14T01:00:00-05:00", "status": "Up"}],
            "wlan_events": [], "warnings": [],
        }
    def action(self, name, began, ended, **extra):
        record = {"Operation": "Adapter restarted.", "Success": True,
                  "Before": {"Timestamp": began, "Status": "Up"},
                  "After": {"Timestamp": ended, "Status": "Disconnected"}, **extra}
        (self.actions / name).write_text(json.dumps(record), encoding="utf-8")
    def report(self, lines=""):
        self.log.write_text(lines, encoding="utf-8")
        return fd.build_report(self.capture, self.log, self.actions)

    def test_dotnet_timestamps_and_offsets(self):
        value = fd.timestamp("2026-10-14T00:33:35.4326728-05:00")
        self.assertEqual(value.microsecond, 432672)
        self.assertEqual(value.utcoffset(), dt.timedelta(hours=-5))
        with self.assertRaises(ValueError):
            fd.timestamp("2026-10-14T00:33:35")
    def test_recovery_overlap_is_not_spontaneous_failure(self):
        self.action("one.json", "2026-10-14T00:40:58-05:00", "2026-10-14T00:41:20-05:00")
        report = self.report(
            "Wed Oct 14 2026 00:41:03.000 [Info] - Reset video stream because we had a stream reset request\n"
            "Wed Oct 14 2026 00:10:03.000 [Info] - Reset video stream because frame ID was not what we expected\n")
        self.assertEqual(report["counts"]["reset_overlap"], 1)
        self.assertEqual(report["counts"]["reset_outside"], 1)
        self.assertEqual(report["attribution"], "temporal_overlap_only")
    def test_completion_and_observation_are_separate(self):
        self.action("new.json", "2026-10-14T00:40:58-05:00", "2026-10-14T00:41:30-05:00",
                    ActionStarted="2026-10-14T00:40:58-05:00",
                    ActionCompleted="2026-10-14T00:41:10-05:00")
        report = self.report("Wed Oct 14 2026 00:41:34.000 [Info] - Reset video stream because we had a stream reset request\n")
        self.assertEqual(report["counts"]["reset_overlap"], 1)
        self.assertEqual(report["actions"][0]["completed"], "2026-10-14T00:41:10-05:00")
    def test_next_connection_is_not_given_to_an_earlier_action(self):
        self.action("one.json", "2026-10-14T00:40:00-05:00", "2026-10-14T00:40:10-05:00")
        self.action("two.json", "2026-10-14T00:41:00-05:00", "2026-10-14T00:41:10-05:00")
        self.capture["wlan_events"] = [{"timestamp":"2026-10-14T00:41:20-05:00", "event_id":8001, "frame_network":True}]
        report = self.report()
        self.assertIsNone(report["actions"][0]["next_connection"])
        self.assertEqual(report["actions"][1]["connection_delay_s"], 20)
    def test_sensitive_text_is_not_exported(self):
        secret = "SECRET_123_private_ssid_192.168.7.8"
        self.action("one.json", "2026-10-14T00:40:00-05:00", "2026-10-14T00:40:10-05:00",
                    Message=secret, token=secret)
        self.capture["system"]["password"] = secret
        self.capture["wlan_events"] = [{"timestamp":"2026-10-14T00:41:20-05:00",
                                        "event_id":8001,"SSID":secret,"Message":secret}]
        report = self.report(
            f"Wed Oct 14 2026 00:41:03.000 [Info] - password={secret}\n"
            f"Wed Oct 14 2026 00:41:04.000 [Info] - Reset video stream because we had a stream reset request {secret}\n")
        self.assertNotIn(secret, json.dumps(report))
        self.assertNotIn(secret, fd.markdown(report))
    def test_unrecognized_log_is_not_zero_failures(self):
        report = self.report('unknown log format\n')
        self.assertIn('steam_log_unrecognized', report['warnings'])
        self.assertIsNone(report['counts']['reset_outside'])

    def test_sampling_end_does_not_include_later_log_query(self):
        self.capture['sampling_finished'] = '2026-10-14T00:59:30-05:00'
        report = self.report()
        self.assertEqual(report['sampling_window']['end'], self.capture['sampling_finished'])
        self.assertNotEqual(report['sampling_window']['end'], report['period']['end'])

    def test_unreadable_log_is_missing_evidence(self):
        from unittest.mock import patch
        self.log.write_text('example', encoding='utf-8')
        with patch.object(Path, 'open', side_effect=PermissionError):
            events, latest = fd.read_stream(self.log, fd.offset('-05:00'),
                fd.timestamp(self.capture['history_started']), fd.timestamp(self.capture['capture_finished']), warnings := [])
        self.assertEqual(events, [])
        self.assertIsNone(latest)
        self.assertEqual(warnings, ['steam_log_unavailable'])

    def test_warning_text_is_allowlisted(self):
        self.capture['warnings'] = ['private_network_password', 'power_query_unavailable']
        report = self.report()
        self.assertNotIn('private_network_password', json.dumps(report))
        self.assertIn('power_query_unavailable', report['warnings'])

    def test_stale_metrics_do_not_mark_stream_recent(self):
        report = self.report("Wed Oct 14 2026 00:10:00.000 [Info] - Link BW: Est 200.0 Mbit/s (auto: 1)\n")
        self.assertEqual(report["windows_state"], "Up")
        self.assertFalse(report["stream_metrics_recent"])
    def test_missing_source_is_not_zero_failures(self):
        report = fd.build_report(self.capture, self.log, self.actions)
        self.assertIsNone(report["counts"]["reset_outside"])
        self.assertIn("steam_log_unavailable", report["warnings"])
        self.capture["warnings"] = ["wlan_events_unavailable"]
        report = self.report()
        self.assertIsNone(report["counts"]["wlan_disconnect_outside"])
    def test_bad_records_do_not_break_good_evidence(self):
        (self.actions / "broken.json").write_text("{", encoding="utf-8")
        report = self.report("Wed Oct 14 2026 00:59:50.000 [Info] - Bad link event: d=19.1 ms 232.0 mbit/s -> 229.2 mbit/s, ping 2.2 ms, holdoff 1, auto 1\n")
        self.assertTrue(report["stream_metrics_recent"])
        self.assertEqual(report["bad_link_max_d_ms"], 19.1)
        self.assertIn("recovery_record_invalid", report["warnings"])
    def test_month_and_midnight(self):
        event = fd.parse_line("Sat Feb 28 2026 23:59:59.001 [Info] - Connection inactive", fd.offset("+01:00"))
        self.assertEqual(event["timestamp"], "2026-02-28T23:59:59.001000+01:00")
        self.assertIsNone(fd.parse_line("Sat Feb 31 2026 23:59:59.001 [Info] - Connection inactive", fd.offset("+01:00")))
    def test_grace_boundary_and_utc_wlan_time(self):
        self.action("one.json", "2026-10-14T00:40:00-05:00", "2026-10-14T00:40:10-05:00")
        self.capture["wlan_events"] = [{"timestamp":"2026-10-14T05:40:15+00:00", "event_id":8003}]
        report = self.report()
        self.assertEqual(report["counts"]["wlan_disconnect_overlap"], 1)
    def test_bom_and_bad_metric(self):
        bom = self.root / "bom.json"
        bom.write_text(json.dumps(self.capture), encoding="utf-8-sig")
        self.assertEqual(fd.load_json(bom)["utc_offset"], "-05:00")
        self.assertIsNone(fd.parse_line("Wed Oct 14 2026 00:59:50.000 [Info] - Bad link event: d=nan ms 232.0 mbit/s -> 229.2 mbit/s, ping 2.2 ms, holdoff 1, auto 1", fd.offset("-05:00")))


    def test_settling_margin_separates_reconnect_resets(self):
        self.capture["wlan_events"] = [{"timestamp":"2026-10-14T00:42:30-05:00", "event_id":8001, "frame_network":True}]
        report = self.report(
            "Wed Oct 14 2026 00:42:31.000 [Info] - Reset video stream because we had a stream reset request\n"
            "Wed Oct 14 2026 00:43:00.000 [Info] - Reset video stream because frame ID was not what we expected\n")
        self.assertEqual(report["after_last_connection"]["reset_entries"], 1)
    def test_preflight_record_is_not_a_network_action(self):
        self.action("preflight.json", "2026-10-14T00:40:00-05:00", "2026-10-14T00:40:10-05:00",
                    ActionStarted=None, RequestedOperation="")
        report = self.report()
        self.assertEqual(report["actions"], [])
    def test_non_frame_connection_is_not_matched(self):
        self.action("one.json", "2026-10-14T00:40:00-05:00", "2026-10-14T00:40:10-05:00")
        self.capture["wlan_events"] = [{"timestamp":"2026-10-14T00:40:20-05:00", "event_id":8001, "frame_network":False}]
        report = self.report()
        self.assertIsNone(report["actions"][0]["next_connection"])
        self.assertIsNone(report["after_last_connection"])
    def test_changed_offset_is_flagged(self):
        self.capture["history_started"] = "2026-10-14T00:00:00-06:00"
        report = self.report()
        self.assertIn("utc_offset_changed", report["warnings"])


    def test_release_launcher_and_packaged_example(self):
        import hashlib
        import subprocess
        import sys
        import zipfile
        builder = Path(__file__).resolve().parents[1] / "build.py"
        subprocess.run([sys.executable, "-B", str(builder), "--output", str(self.root / "release")],
                       check=True, capture_output=True)
        package = self.root / f"release/FrameAdapter-{fd.VERSION}.zip"
        with zipfile.ZipFile(package) as archive:
            launcher = archive.read("Start.cmd")
            self.assertIn(rb"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe", launcher)
            self.assertIn(rb"%~dp0FrameAdapter.ps1", launcher)
            self.assertNotIn(b"\x0c", launcher)
            self.assertNotIn(b"\x0b", launcher)
            self.assertFalse(any(name.startswith(("context/", "research/", "docs/")) for name in archive.namelist()))
            manifest = json.loads(archive.read("source-manifest.json"))
            for name, digest in manifest.items():
                self.assertEqual(hashlib.sha256(archive.read(name)).hexdigest(), digest)
            archive.extractall(self.root / "unpacked")
        module = self.root / "unpacked/diagnostics"
        out = self.root / "example-report"
        subprocess.run([sys.executable, "-B", str(module / "frame_diagnostics.py"),
                        "--capture", str(self.root / "unpacked/examples/capture.json"),
                        "--steam-log", str(self.root / "unpacked/examples/steam.txt"),
                        "--recovery-dir", str(self.root / "unpacked/examples/recovery"),
                        "--output", str(out)], check=True, capture_output=True)
        report = json.loads((out / "report.json").read_text(encoding="utf-8"))
        self.assertEqual(report["counts"]["reset_overlap"], 1)
        self.assertEqual(report["counts"]["reset_outside"], 1)
        self.assertEqual(report["after_last_connection"]["reset_entries"], 0)
        trial = self.root / 'unpacked/examples/trial'
        subprocess.run([sys.executable, '-B', str(module / 'diagnosis.py'),
                        '--trial', str(trial / 'trial.json'), '--baseline', str(trial / 'baseline.json'),
                        '--after', str(trial / 'after.json'), '--output', str(out / 'trial')],
                       check=True, capture_output=True)
        comparison = json.loads((out / 'trial/comparison.json').read_text(encoding='utf-8'))
        self.assertTrue(comparison['comparable'])
        self.assertEqual(comparison['recovery_requests'], 0)

if __name__ == "__main__":
    unittest.main()
