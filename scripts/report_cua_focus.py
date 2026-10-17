#!/usr/bin/env python3
"""Correlate foreground transitions with CUA targets/actions. Never controls CUA.

Labels are evidence classes, not causal proof. Hardware activity can overlap a
real focus steal; absence of hardware events does not establish driver causality.
"""
import datetime
import json
import pathlib
import sys

READ_ONLY = {'list_apps', 'list_windows', 'get_window_state', 'verify_state',
             'get_accessibility_tree', 'get_browser_state', 'check_permissions',
             'get_cursor_position', 'get_screen_size', 'get_agent_cursor_state', 'finish', 'fail'}


def timestamp(value):
    return datetime.datetime.fromisoformat(value.replace('Z', '+00:00')).timestamp()


def classify(previous, current, target_pids, target_windows, action_nearby):
    if (previous['pid'], previous['window']) == (current['pid'], current['window']):
        return None
    if current['pid'] not in target_pids:
        return 'unrelated_foreground_change'
    exact = (current['pid'], current['window']) in target_windows
    # Ordinary typing alone is not evidence of a deliberate app/window switch.
    ages = current.get('hardware_event_ages', {})
    switch_input = any(ages.get(key, float('inf')) < 1.0
                       for key in ('left_mouse_down', 'right_mouse_down', 'flags_changed'))
    if switch_input:
        return 'target_change_with_recent_user_input'
    if action_nearby and previous['pid'] == current['pid']:
        return 'suspected_target_window_raise'
    if action_nearby:
        return 'suspected_driver_target_activation' if exact else 'suspected_driver_target_app_activation'
    return 'unattributed_target_change'


def report(rows, events):
    targets, pids, actions = set(), set(), []
    calls = {}
    for event in events:
        body = event.get('body', '')
        if event['kind'] == 'tool_call' and body.startswith('[trycua] '):
            header, _, encoded = body.partition('\n')
            try:
                args = json.loads(encoded)
            except ValueError:
                continue
            name = header.removeprefix('[trycua] ')
            for scope in (args, args.get('target', {})):
                if isinstance(scope, dict) and isinstance(scope.get('pid'), int):
                    pids.add(scope['pid'])
                    if isinstance(scope.get('window_id'), int):
                        targets.add((scope['pid'], scope['window_id']))
            if name not in READ_ONLY:
                action = {'tool': name, 'start': timestamp(event['timestamp']), 'end': timestamp(event['timestamp'])}
                actions.append(action)
                calls[event.get('step')] = action
        elif event['kind'] == 'tool_result' and event.get('step') in calls:
            calls[event.get('step')]['end'] = timestamp(event['timestamp'])
    # Restrict to the command interval; don't blame idle activity after it ends.
    start, end = min(timestamp(e['timestamp']) for e in events), max(timestamp(e['timestamp']) for e in events)
    changes = []
    previous = rows[0]
    samples = 0
    for row in rows[1:]:
        t = timestamp(row['time'])
        if start <= t <= end:
            samples += 1
            nearby = [a['tool'] for a in actions if a['start'] <= t <= a['end'] + 2.0]
            label = classify(previous, row, pids, targets, bool(nearby))
            if label:
                changes.append({'time': row['time'], 'classification': label,
                                'from': [previous['pid'], previous['window']],
                                'to': [row['pid'], row['window']], 'nearby_actions': nearby,
                                'hardware_event_ages': row.get('hardware_event_ages', {})})
        previous = row
    return {'samples_during_command': samples, 'targets': sorted(targets), 'changes': changes,
            'monitor_stops_driver': False,
            'limits': 'Temporal correlation only; does not prove causality or detect all key-focus theft. Window IDs are ordering proxies, not AX key-window proof. Window order is retained in the raw log for inspection.'}


if __name__ == '__main__':
    rows = [json.loads(line) for line in pathlib.Path(sys.argv[1]).read_text().splitlines()]
    events = json.loads(pathlib.Path(sys.argv[2]).read_text())
    print(json.dumps(report(rows, events), indent=2))
