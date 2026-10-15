"""Steam Frame host-log correlation. Python 3.10+, standard library only."""
import argparse
import datetime as dt
import json
import math
from pathlib import Path
import re
from diagnosis import configuration, findings

VERSION = "0.1.0"
MONTHS = {m: i for i, m in enumerate(
    ("Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"), 1)}
STAMP = re.compile(r"^[A-Za-z]{3} ([A-Za-z]{3})\s+(\d{1,2}) (\d{4}) (\d{2}):(\d{2}):(\d{2})\.(\d{3}) \[Info\] - (.*)$")
BAD = re.compile(r"Bad link event: d=([\d.]+) ms ([\d.]+) mbit/s -> ([\d.]+) mbit/s, ping ([\d.]+) ms, holdoff (\d+), auto ([01])$")
BANDWIDTH = re.compile(r"Link BW: Est ([\d.]+) Mbit/s \(auto: ([01])\)$")
MAX_LOG_BYTES = 8 * 1024 * 1024
MAX_JSON_BYTES = 2 * 1024 * 1024
KNOWN_WARNINGS = {
    'adapter_snapshot_unavailable', 'profile_query_unavailable', 'advanced_properties_unavailable',
    'power_query_unavailable', 'system_metadata_incomplete', 'wlan_event_limit',
    'wlan_events_unavailable', 'wlan_interface_unknown', 'steam_log_unavailable',
    'steam_log_unrecognized', 'steam_log_tail_only', 'recovery_history_unavailable',
    'recovery_file_limit', 'recovery_record_invalid', 'wlan_record_invalid',
    'adapter_sample_invalid', 'timeline_truncated', 'utc_offset_changed',
}

def timestamp(value):
    value = re.sub(r'(\.\d{6})\d+', r'\1', value)
    parsed = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        raise ValueError("Timestamp requires a UTC offset")
    return parsed

def offset(value):
    if not re.fullmatch(r"[+-]\d{2}:\d{2}", value):
        raise ValueError("UTC offset must be +HH:MM or -HH:MM")
    hours, minutes = map(int, value[1:].split(":"))
    if hours > 14 or minutes > 59 or (hours == 14 and minutes):
        raise ValueError("UTC offset is out of range")
    delta = dt.timedelta(hours=hours, minutes=minutes)
    return dt.timezone(delta if value[0] == "+" else -delta)

def load_json(path):
    if path.stat().st_size > MAX_JSON_BYTES:
        raise ValueError("JSON input exceeds size limit")
    return json.loads(path.read_text(encoding="utf-8-sig"))

def parse_line(line, zone):
    match = STAMP.fullmatch(line.rstrip("\r\n"))
    if not match or match[1] not in MONTHS:
        return None
    try:
        when = dt.datetime(int(match[3]), MONTHS[match[1]], int(match[2]),
                           int(match[4]), int(match[5]), int(match[6]),
                           int(match[7]) * 1000, tzinfo=zone)
    except ValueError:
        return None
    message = match[8]
    result = {"timestamp": when.isoformat(), "source": "steam"}
    if message.startswith("Reset video stream because we had a stream reset request"):
        result.update(kind="stream_reset", reason="reset_request")
    elif message.startswith("Reset video stream because frame ID was not what we expected"):
        result.update(kind="stream_reset", reason="frame_id")
    elif message == "Connection inactive":
        result.update(kind="connection_inactive")
    elif found := BAD.fullmatch(message):
        values = [float(found[i]) for i in range(1, 5)]
        if not all(math.isfinite(v) and v >= 0 for v in values):
            return None
        result.update(kind="bad_link", d_ms=values[0], rate_before_mbps=values[1],
                      rate_after_mbps=values[2], ping_ms=values[3])
    elif found := BANDWIDTH.fullmatch(message):
        value = float(found[1])
        if not math.isfinite(value):
            return None
        result.update(kind="bandwidth", estimate_mbps=value)
    else:
        return None
    return result

def read_stream(path, zone, start, end, warnings):
    try:
        size = path.stat().st_size
        with path.open("rb") as handle:
            if size > MAX_LOG_BYTES:
                handle.seek(size - MAX_LOG_BYTES)
                handle.readline()
                warnings.append("steam_log_tail_only")
            lines = handle.read(MAX_LOG_BYTES).decode("utf-8", errors="replace").splitlines()
    except OSError:
        warnings.append("steam_log_unavailable")
        return [], None
    events = []
    latest = None
    for line in lines:
        parsed = parse_line(line, zone)
        if parsed:
            when = timestamp(parsed["timestamp"])
            if when <= end and (latest is None or when > latest):
                latest = when
            if start <= when <= end:
                events.append(parsed)
    if latest is None:
        warnings.append('steam_log_unrecognized')
    return events, latest

def read_actions(directory, start, end, grace_seconds, warnings):
    actions = []
    if not directory.exists():
        warnings.append("recovery_history_unavailable")
        return actions
    files = sorted(directory.glob("*.json"))
    if len(files) > 2000:
        warnings.append("recovery_file_limit")
        files = sorted(files, key=lambda p: p.stat().st_mtime)[-2000:]
    for path in files:
        try:
            raw = load_json(path)
            if "ActionStarted" in raw and not raw["ActionStarted"]:
                continue
            before = raw.get("Before") or {}
            after = raw.get("After") or {}
            began = timestamp(raw.get("ActionStarted") or before["Timestamp"])
            finished_value = raw.get("ActionCompleted") or after.get("Timestamp")
            finished = timestamp(finished_value) if finished_value else end
            observed_value = after.get("Timestamp")
            observed = timestamp(observed_value) if observed_value else finished
            window_end = max(finished, observed) + dt.timedelta(seconds=grace_seconds)
            if finished < began:
                raise ValueError("Recovery end precedes start")
            if window_end < start or began > end:
                continue
            operation = str(raw.get("RequestedOperation") or raw.get("Operation", "")).lower()
            kind = "restart" if "restart" in operation else "enable" if "enabl" in operation else "unknown"
            before_state = before.get("Status")
            actions.append({
                "timestamp": began.isoformat(), "source": "recovery", "kind": kind,
                "completed": finished.isoformat(),
                "window_end": window_end.isoformat(),
                "timing": "command_and_observation" if raw.get("ActionCompleted") else "legacy_observation",
                "before_state": before_state if before_state in ("Up", "Disconnected", "Disabled") else "unknown",
                "operation_succeeded": raw.get("Success") is True,
                "open_at_capture": finished_value is None,
            })
        except (OSError, ValueError, KeyError, TypeError, AttributeError):
            warnings.append("recovery_record_invalid")
    return sorted(actions, key=lambda e: e["timestamp"])

def sanitize_windows(raw_events, start, end, warnings):
    events = []
    for raw in raw_events:
        try:
            when = timestamp(raw["timestamp"])
            event_id = int(raw["event_id"])
            if event_id not in (8001, 8002, 8003) or not start <= when <= end:
                continue
            reason = raw.get("reason")
            events.append({
                "timestamp": when.isoformat(), "source": "windows",
                "kind": {8001: "wlan_connected", 8002: "wlan_connect_failed", 8003: "wlan_disconnected"}[event_id],
                "reason": reason if reason in ("target_unavailable", "driver_reported", "user_request", "other") else "unknown",
                "frame_network": raw.get("frame_network") is True,
            })
        except (ValueError, TypeError, KeyError, AttributeError):
            warnings.append("wlan_record_invalid")
    return events

def state_label(samples):
    if not samples:
        return "unknown"
    state = samples[-1].get("status")
    return state if state in ("Up", "Disconnected", "Disabled") else "unknown"

def assess(events, actions):
    counts = {"reset_overlap": 0, "reset_outside": 0, "bad_link_overlap": 0,
              "bad_link_outside": 0, "wlan_disconnect_overlap": 0, "wlan_disconnect_outside": 0}
    for event in events:
        when = timestamp(event["timestamp"])
        overlaps = [i + 1 for i, action in enumerate(actions)
                    if timestamp(action["timestamp"]) <= when <= timestamp(action["window_end"])]
        event["recovery_overlap"] = overlaps
        prefix = {"stream_reset": "reset", "bad_link": "bad_link", "wlan_disconnected": "wlan_disconnect"}.get(event["kind"])
        if prefix:
            counts[prefix + ("_overlap" if overlaps else "_outside")] += 1
    return counts

def build_report(capture, stream_path, recovery_path, grace_seconds=5):
    start, end = timestamp(capture["history_started"]), timestamp(capture["capture_finished"])
    if end < start:
        raise ValueError("Capture end precedes history start")
    warnings = list(capture.get("warnings") or [])
    if timestamp(capture["history_started"]).utcoffset() != end.utcoffset():
        warnings.append("utc_offset_changed")
    warnings = [w for w in warnings if isinstance(w, str) and w in KNOWN_WARNINGS]
    zone = offset(capture["utc_offset"])
    events, latest_stream = read_stream(stream_path, zone, start, end, warnings)
    actions = read_actions(recovery_path, start, end, grace_seconds, warnings)
    events.extend(sanitize_windows(capture.get("wlan_events") or [], start, end, warnings))
    events.sort(key=lambda e: (timestamp(e["timestamp"]), e["source"], e["kind"]))
    counts = assess(events, actions)
    if any(w in warnings for w in ('steam_log_unavailable', 'steam_log_unrecognized')):
        for name in counts:
            if name.startswith(("reset_", "bad_link_")):
                counts[name] = None
    if any(w in warnings for w in ("wlan_events_unavailable", "wlan_interface_unknown")):
        counts["wlan_disconnect_overlap"] = counts["wlan_disconnect_outside"] = None
    metrics = [e for e in events if e["kind"] in ("bandwidth", "bad_link")]
    latest_metric = timestamp(metrics[-1]["timestamp"]) if metrics else None
    metric_age = max(0, (end - latest_metric).total_seconds()) if latest_metric else None
    bad = [e for e in events if e["kind"] == "bad_link"]
    summaries = []
    for index, action in enumerate(actions):
        connected = next((e for e in events if e["kind"] == "wlan_connected" and
                          e["frame_network"] and timestamp(e["timestamp"]) >= timestamp(action["timestamp"])), None)
        next_start = timestamp(actions[index + 1]["timestamp"]) if index + 1 < len(actions) else end
        if connected and index + 1 < len(actions) and timestamp(connected["timestamp"]) >= next_start:
            connected = None
        summaries.append({
            **action,
            "next_connection": connected["timestamp"] if connected else None,
            "connection_delay_s": round((timestamp(connected["timestamp"]) - timestamp(action["timestamp"])).total_seconds(), 3) if connected else None,
        })
    samples = []
    for raw in capture.get("adapter_samples") or []:
        try:
            when = timestamp(raw["timestamp"])
            status = raw.get("status")
            if start <= when <= end:
                samples.append({"timestamp": when.isoformat(),
                                "status": status if status in ("Up", "Disconnected", "Disabled") else "unknown"})
        except (KeyError, ValueError, TypeError):
            warnings.append("adapter_sample_invalid")
    samples.sort(key=lambda s: timestamp(s["timestamp"]))
    connections = [e for e in events if e["kind"] == "wlan_connected" and e.get("frame_network")]
    settled = None
    if connections:
        connected_at = timestamp(connections[-1]["timestamp"])
        settled_start = connected_at + dt.timedelta(seconds=grace_seconds)
        settled_events = [e for e in events if timestamp(e["timestamp"]) >= settled_start]
        settled_bad = [e for e in settled_events if e["kind"] == "bad_link"]
        settled = {
            "connected_at": connected_at.isoformat(), "from": settled_start.isoformat(),
            "reset_entries": sum(e["kind"] == "stream_reset" for e in settled_events),
            "wlan_disconnects": sum(e["kind"] == "wlan_disconnected" for e in settled_events),
            "connection_inactive_entries": sum(e["kind"] == "connection_inactive" for e in settled_events),
            "max_d_ms": max((e["d_ms"] for e in settled_bad), default=None),
        }
        if any(w in warnings for w in ('steam_log_unavailable', 'steam_log_unrecognized')):
            settled["reset_entries"] = settled["connection_inactive_entries"] = None
        if any(w in warnings for w in ("wlan_events_unavailable", "wlan_interface_unknown")):
            settled["wlan_disconnects"] = None
    metadata = {}
    for name in ("os", "os_version", "os_build", "steamvr_version", "steamvr_build", "adapter_driver", "gpu", "gpu_driver"):
        value = str(capture.get("system", {}).get(name, "unknown"))
        # Only bounded product/version fields are exported; no raw collector/log fields.
        metadata[name] = re.sub(r"[^A-Za-z0-9 ._()-]", "", value)[:100]
    if len(events) > 2000:
        warnings.append("timeline_truncated")
    report = {
        "schema_version": 1, "tool_version": VERSION,
        "sampling_window": {"start": timestamp(capture.get("capture_started") or
            (samples[0]["timestamp"] if samples else end.isoformat())).isoformat(),
            "end": timestamp(capture.get('sampling_finished') or end.isoformat()).isoformat()},
        "period": {"start": start.isoformat(), "end": end.isoformat()},
        "system": metadata,
        "windows_state": state_label(samples),
        "headset_state": capture.get("headset_state") if capture.get("headset_state") in
            ("unknown", "awake_streaming", "idle") else "unknown",
        "stream_metric_age_s": round(metric_age, 3) if metric_age is not None else None,
        "stream_metrics_recent": metric_age is not None and metric_age <= 45,
        "latest_recognized_stream_event": latest_stream.isoformat() if latest_stream else None,
        "counts": counts,
        "bad_link_max_d_ms": max((e["d_ms"] for e in bad), default=None),
        "bad_link_max_ping_ms": max((e["ping_ms"] for e in bad), default=None),
        "recovery_grace_s": grace_seconds, "after_last_connection": settled,
        "actions": summaries, "adapter_samples": samples, "timeline": events[:2000],
        "warnings": sorted(set(warnings)),
        "attribution": "temporal_overlap_only",
    }
    report['configuration'] = configuration(capture.get('configuration'))
    report['headset_warning'] = capture.get('headset_warning') if capture.get('headset_warning') in ('inactive', 'cleared') else 'unknown'
    report['stream_path_user_reported'] = capture.get('stream_path') if capture.get('stream_path') in ('adapter', 'home_wifi', 'multilink') else 'unknown'
    report['findings'] = findings(report, capture.get('adapter_probe'), report['configuration'])
    return report

def markdown(report):
    rows = ["# Frame diagnostic report", "",
            f"History: {report['period']['start']} to {report['period']['end']}",
            f"Adapter sampling: {report['sampling_window']['start']} to {report['sampling_window']['end']}", "",
            f"Windows adapter: {report['windows_state']}",
            f"Headset state: {report['headset_state']}",
            f"Recent Steam stream metrics: {'yes' if report['stream_metrics_recent'] else 'no'}",
            f"Latest metric age: {report['stream_metric_age_s']} seconds", "",
            "Windows connection and recent Steam metrics do not establish the active network path or stable gameplay.",
            "", "## Findings", ""]
    for finding in report['findings']:
        rows.extend([f"### {finding['title']}", '', *[f"- {e}" for e in finding['evidence']],
                     f"Next check: {finding['next_check']}", ''])
    rows.extend(['## Configuration checks (read-only)', '',
                 *[f'- {key}: {value}' for key, value in report['configuration'].items()], '',
                 f"Stream path (user-reported): {report['stream_path_user_reported']}",
                 f"Headset warning (user-reported at start): {report['headset_warning']}",
            "", "## Stream and WLAN events", "",
            "| Event | Overlaps recorded recovery | Outside recorded recovery |",
            "| --- | ---: | ---: |"])
    for label, prefix in (("Stream reset entries", "reset"), ("Bad-link entries", "bad_link"), ("WLAN disconnects", "wlan_disconnect")):
        rows.append(f"| {label} | {report['counts'][prefix + '_overlap'] if report['counts'][prefix + '_overlap'] is not None else 'unavailable'} | {report['counts'][prefix + '_outside'] if report['counts'][prefix + '_outside'] is not None else 'unavailable'} |")
    rows.extend(["", f"Maximum reported d: {report['bad_link_max_d_ms']} ms.",
                 f"Maximum reported ping: {report['bad_link_max_ping_ms']} ms.", "",
                 "The d and ping fields are Steam log values, not measured motion-to-photon latency.",
                 "", "## Recovery attempts", "",
                 "| Start | Before | Action | Timing | Next Frame WLAN connection | Delay |",
                 "| --- | --- | --- | --- | --- | --- |"])
    for action in report["actions"]:
        rows.append(f"| {action['timestamp']} | {action['before_state']} | {action['kind']} | {action['timing']} | {action['next_connection'] or 'not observed'} | {str(action['connection_delay_s']) + ' s' if action['connection_delay_s'] is not None else 'not observed'} |")
    if report["after_last_connection"]:
        settled = report["after_last_connection"]
        rows.extend(["", "## After last recorded Frame WLAN connection", "",
                     f"Connected at: {settled['connected_at']}",
                     f"Counts begin after the settling margin: {settled['from']}",
                     f"Later WLAN disconnects: {settled['wlan_disconnects']}",
                     f"Stream reset entries: {settled['reset_entries']}",
                     f"Connection inactive entries: {settled['connection_inactive_entries']}",
                     f"Maximum reported d in this interval: {settled['max_d_ms']} ms."])
    rows.extend(["", f"Overlap window: recorded action through its last connection observation plus {report['recovery_grace_s']} seconds.",
                 "Legacy records end at the old status check, not the command completion.",
                 "Overlap shows timing, not cause. Events outside recorded recovery can still reflect unrecorded headset restarts, sleep, pairing or settings changes.",
                 "", "## Versions", ""])
    rows.extend(f"- {key}: {value}" for key, value in report["system"].items())
    rows.extend(["", "## Data quality", ""])
    rows.extend(f"- {warning}" for warning in report["warnings"])
    if not report["warnings"]:
        rows.append("- No collector/parser warnings. Headset state and unrecorded actions still limit attribution.")
    rows.extend(["", "## Next controlled trial", "",
                 "On a recurrence, capture the failing state. Record one recovery action while the headset remains awake and unchanged. Compare the same workload afterward. Confirm the warning and stream path inside the headset.",
                 "", "The JSON timeline contains structured events only. Raw logs, network identifiers, passwords and hardware serials are omitted.", ""])
    return "\n".join(rows)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--capture", required=True, type=Path)
    parser.add_argument("--steam-log", required=True, type=Path)
    parser.add_argument("--recovery-dir", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--recovery-grace", type=int, default=5)
    args = parser.parse_args()
    if not 0 <= args.recovery_grace <= 60:
        parser.error("--recovery-grace must be 0..60 seconds")
    report = build_report(load_json(args.capture), args.steam_log, args.recovery_dir, args.recovery_grace)
    args.output.mkdir(parents=True, exist_ok=True)
    (args.output / "report.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    (args.output / "report.md").write_text(markdown(report), encoding="utf-8")
    print(args.output / "report.md")

if __name__ == "__main__":
    main()
