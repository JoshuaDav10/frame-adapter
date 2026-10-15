"""Conservative findings and equal-duration trial summaries; no machine changes."""
import argparse
import datetime as dt
import json
from pathlib import Path


def stamp(value):
    import re
    parsed = dt.datetime.fromisoformat(re.sub(r'(\.\d{6})\d+', r'\1', value).replace('Z', '+00:00'))
    if parsed.tzinfo is None:
        raise ValueError('Timestamp requires an offset')
    return parsed


def choice(value, allowed):
    return value if isinstance(value, str) and value in allowed else 'unknown'


def configuration(raw):
    raw = raw if isinstance(raw, dict) else {}
    return {
        'profile': choice(raw.get('profile'), ('Public', 'Private', 'DomainAuthenticated', 'no_active_profile')),
        'six_ghz': choice(raw.get('six_ghz'), ('ax', 'other')),
        'usb_mode': choice(raw.get('usb_mode'), ('Auto', 'USB 2.0', 'USB 3.0')),
        'device_power_off': choice(raw.get('device_power_off'), ('Enabled', 'Disabled', 'Unsupported')),
        'selective_suspend': choice(raw.get('selective_suspend'), ('Enabled', 'Disabled', 'Unsupported')),
        'power_query': choice(raw.get('power_query'), ('readable', 'unavailable')),
    }


def findings(report, probe, config):
    result = []

    def add(code, title, evidence, next_check):
        result.append(dict(code=code, title=title, evidence=evidence, next_check=next_check))

    identity = choice(probe, ('verified', 'not_found', 'ambiguous', 'identity_mismatch', 'query_failed'))
    state = report['windows_state']
    if identity in ('not_found', 'ambiguous', 'identity_mismatch'):
        add('identity_unresolved', 'Supported adapter could not be uniquely verified',
            [f'Adapter lookup: {identity}.'], 'Check USB presence and device identity before recovery.')
    elif identity != 'verified':
        add('identity_unknown', 'Adapter identity evidence is unavailable',
            ['This capture does not establish a verified hardware identity.'], 'Run a fresh capture; do not infer a missing device from a failed query.')
    elif state == 'Disabled':
        add('adapter_disabled', 'Windows reports the adapter disabled',
            ['The verified adapter snapshot is Disabled.'], 'Use the existing Enable adapter action if streaming is intended.')
    elif state == 'Disconnected':
        add('adapter_disconnected', 'Windows reports the adapter disconnected',
            ['The verified adapter snapshot is Disconnected.'], 'Keep the headset awake, confirm pairing, and preserve a baseline before one recovery action.')
    elif state == 'Up':
        add('windows_connected', 'Windows reports a connected interface',
            ['The verified adapter snapshot is Up.'], 'Confirm the selected stream path and warning inside the headset; Up alone does not establish streaming health.')
    else:
        add('adapter_state_unknown', 'Current adapter state is unknown',
            ['No supported current state was captured.'], 'Repeat the snapshot and check missing-source warnings.')
    if report.get('headset_warning') == 'inactive':
        add('reported_inactive', 'The user reports an inactive warning',
            ['Headset warning was supplied by the user at capture start, not read from Steam.'],
            'Confirm the path in the headset and correlate a fresh failing capture; this does not identify a firewall or driver cause.')
    if report.get('headset_state') == 'awake_streaming' and (report['counts'].get('reset_outside') or 0) > 0:
        add('stream_resets', 'Stream reset entries occurred outside recorded recovery',
            [f"Reset entries: {report['counts']['reset_outside']}; headset activity is user-reported."],
            'Compare precise symptom times and host rendering/encoding with WLAN events. Unrecorded actions can explain resets.')
    if report.get('headset_state') != 'awake_streaming' or not report.get('stream_metrics_recent') or report.get('warnings'):
        add('evidence_limits', 'Evidence is insufficient to assess active-play stability',
            ['Headset activity, source coverage or stream freshness is incomplete.'],
            'Capture a known awake-streaming workload and review data-quality warnings.')
    if config['profile'] == 'Public':
        add('profile_public', 'The adapter connection profile is Public',
            ['Public is a configuration observation, not proof of blocked Steam traffic.'],
            'Inspect relevant security rules if evidence points to filtering. Changing to Private changes network trust and discovery.')
    if config['six_ghz'] == 'ax':
        add('protocol_already_ax', '6 GHz protocol is already configured for 802.11ax',
            ['The driver reports the expected ax value.'], 'Do not reapply this community tweak as a new repair.')
    if config['power_query'] != 'readable':
        add('power_unknown', 'Power management could not be read',
            ['The query was unavailable; no enabled/disabled value is inferred.'],
            'Inspect in an elevated Windows PowerShell session or Device Manager without changing it first.')
    return result


MARKERS = {'problem', 'stutter', 'warning_cleared', 'other_change', 'recovery_requested', 'observation_only'}


def summarize_trial(trial, before, after):
    seconds = trial.get('phase_seconds')
    if isinstance(seconds, bool) or not isinstance(seconds, int) or not 15 <= seconds <= 180:
        raise ValueError('Trial phase_seconds must be 15..180')
    markers = []
    for raw in trial.get('markers', []):
        if not isinstance(raw, dict) or raw.get('kind') not in MARKERS:
            continue
        try:
            markers.append({'timestamp': stamp(raw['timestamp']).isoformat(), 'kind': raw['kind']})
        except (ValueError, TypeError, KeyError):
            continue
    periods = []
    blocked = {'steam_log_unavailable', 'steam_log_unrecognized', 'steam_log_tail_only', 'timeline_truncated', 'utc_offset_changed',
               'wlan_events_unavailable', 'wlan_interface_unknown', 'wlan_event_limit', 'wlan_record_invalid', 'recovery_record_invalid'}
    for name, report in (('baseline', before), ('after', after)):
        start = stamp(report['sampling_window']['start'])
        end = start + dt.timedelta(seconds=seconds)
        enough_time = stamp(report['sampling_window']['end']) >= end
        coverage = enough_time and report.get('stream_metrics_recent') is True and not blocked.intersection(report.get('warnings', []))
        events = [e for e in report.get('timeline', []) if start <= stamp(e['timestamp']) < end]
        counts = {kind: sum(e['kind'] == kind for e in events) if coverage else None
                  for kind in ('stream_reset', 'bad_link', 'wlan_disconnected', 'connection_inactive')}
        periods.append(dict(phase=name, start=start.isoformat(), end=end.isoformat(),
                            seconds=seconds, complete=coverage, counts=counts,
                            windows_state=choice(report.get('windows_state'), ('Up', 'Disabled', 'Disconnected'))))
    if stamp(periods[1]['start']) < stamp(before['sampling_window']['end']):
        raise ValueError('Trial phases overlap or are reversed')
    trial_start, trial_end = stamp(periods[0]['start']), stamp(periods[1]['end'])
    marker_warnings = []
    if any(not trial_start <= stamp(m['timestamp']) < trial_end for m in markers):
        marker_warnings.append('marker_outside_observation_period')
    markers = [m for m in markers if trial_start <= stamp(m['timestamp']) < trial_end]
    confounded = any(m['kind'] == 'other_change' for m in markers)
    action_count = sum(m['kind'] == 'recovery_requested' for m in markers)
    actions = {}
    for report in (before, after):
        for action in report.get('actions', []):
            if trial_start <= stamp(action['timestamp']) < trial_end:
                actions[action['timestamp']] = {
                    'timestamp': stamp(action['timestamp']).isoformat(),
                    'completed': stamp(action['completed']).isoformat() if action.get('completed') else None,
                    'operation_succeeded': action.get('operation_succeeded') is True,
                    'kind': choice(action.get('kind'), ('restart', 'enable')),
                    'open_at_capture': action.get('open_at_capture') is True}
    requests = [stamp(m['timestamp']) for m in markers if m['kind'] == 'recovery_requested']
    action_agreement = len(actions) == action_count and action_count <= 1 and all(
        a['operation_succeeded'] and not a['open_at_capture'] and a['completed'] is not None and
        len(requests) == 1 and requests[0] <= stamp(a['timestamp']) and
        stamp(before['sampling_window']['end']) <= stamp(a['timestamp']) <= stamp(a['completed']) <= stamp(periods[1]['start'])
        for a in actions.values())
    changes = []
    for section, keys in (('system', ('os_build', 'steamvr_version', 'steamvr_build', 'adapter_driver', 'gpu_driver')),
                          ('configuration', ('profile', 'six_ghz', 'usb_mode', 'device_power_off', 'selective_suspend'))):
        left, right = before.get(section, {}), after.get(section, {})
        for key in keys:
            a, b = left.get(key), right.get(key)
            if a and b and a not in ('unknown', 'no_active_profile') and b not in ('unknown', 'no_active_profile') and a != b:
                changes.append(section + '.' + key)
    comparable = all(p['complete'] for p in periods) and not confounded and action_agreement and not marker_warnings
    same_workload = trial.get('same_workload') is True
    awake = all(r.get('headset_state') == 'awake_streaming' for r in (before, after))
    paths = [choice(r.get('stream_path_user_reported'), ('adapter', 'home_wifi', 'multilink')) for r in (before, after)]
    path_agreement = paths[0] != 'unknown' and paths[0] == paths[1]
    comparable = comparable and same_workload and awake and not changes and path_agreement
    limits = list(marker_warnings)
    for condition, code in ((not all(p['complete'] for p in periods), 'phase_data_incomplete'),
                            (not same_workload, 'same_workload_not_declared'),
                            (not awake, 'headset_activity_unknown'), (not path_agreement, 'stream_path_unknown_or_changed'),
                            (not action_agreement, 'action_records_mismatch'),
                            (confounded, 'other_change_reported'), (bool(changes), 'configuration_changed')):
        if condition:
            limits.append(code)
    return {'schema_version': 1, 'phases': periods, 'markers': markers,
            'comparable': comparable, 'same_workload_user_declared': same_workload,
            'headset_awake_user_reported': awake, 'other_changes_reported': confounded,
            'recovery_requests': action_count,
            'recorded_operations': sorted(actions.values(), key=lambda a: a['timestamp']),
            'action_records_agree': action_agreement, 'warnings': limits,
            'stream_path_user_reported': paths, 'stream_path_agrees': path_agreement,
            'detected_configuration_changes': changes,
            'interpretation': 'Descriptive comparison only. User markers are observations, not telemetry. '
                'Missing events do not prove stable gameplay. A reduction after recovery does not prove causation.',
            'warning_clearance_reported': any(m['kind'] == 'warning_cleared' for m in markers)}


def trial_markdown(report):
    rows = ['# Frame trial comparison', '', f"Comparable observation windows: {report['comparable']}", '',
            '| Phase | Seconds | Complete | Reset entries | Bad-link entries | WLAN disconnects |',
            '| --- | ---: | --- | ---: | ---: | ---: |']
    for phase in report['phases']:
        c = phase['counts']
        values = [str(c[k]) if c[k] is not None else 'unavailable'
                  for k in ('stream_reset', 'bad_link', 'wlan_disconnected')]
        rows.append(f"| {phase['phase']} | {phase['seconds']} | {phase['complete']} | {' | '.join(values)} |")
    rows.extend(['', report['interpretation'], '',
                 f"Warning clearance reported: {report['warning_clearance_reported']}",
                 f"Other changes reported: {report['other_changes_reported']}",
                 f"Recovery requests / recorded operations: {report['recovery_requests']} / {len(report['recorded_operations'])}",
                 f"Action records agree: {report['action_records_agree']}",
                 f"Version/configuration fields changed: {', '.join(report['detected_configuration_changes']) or 'none detected'}",
                 'No automatic repair or root-cause conclusion is made.', '', '## Observation windows', ''])
    rows.extend(f"- {p['phase']}: {p['start']} to {p['end']} (end exclusive)." for p in report['phases'])
    rows.extend(['', '## User markers', ''])
    rows.extend(f"- {m['timestamp']}: {m['kind']}" for m in report['markers'])
    rows.extend(['', '## Limits', '', *[f'- {w}' for w in report['warnings']]])
    return '\n'.join(rows) + '\n'


def main():
    parser = argparse.ArgumentParser(description='Compare two saved, fixed-duration trial phases.')
    for name in ('trial', 'baseline', 'after', 'output'):
        parser.add_argument('--' + name, required=True, type=Path)
    args = parser.parse_args()
    from frame_diagnostics import load_json
    report = summarize_trial(load_json(args.trial), load_json(args.baseline), load_json(args.after))
    args.output.mkdir(parents=True, exist_ok=True)
    (args.output / 'comparison.json').write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    (args.output / 'comparison.md').write_text(trial_markdown(report), encoding='utf-8')


if __name__ == '__main__':
    main()
