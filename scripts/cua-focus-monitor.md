# Background CUA focus observation

Use `monitor_cua_focus.swift` instead of the retired temporary monitor that killed
the reference daemon on any foreground window change. This observer never stops
CUA, activates an application, or sends input. Users may switch apps/windows.

```sh
swiftc scripts/monitor_cua_focus.swift -o /tmp/muesli-cua-focus-monitor
mkdir -p /tmp/cua-focus-run
/tmp/muesli-cua-focus-monitor /tmp/cua-focus-run
```

Run the benchmark separately. End observation with
`touch /tmp/cua-focus-run/stop-monitor`. Use a new output directory for each run.
Then correlate against the replay's trace:

```sh
python3 scripts/report_cua_focus.py /tmp/cua-focus-run/focus.jsonl /tmp/muesli-cua-baseline.EXAMPLE/trace.json
python3 scripts/test_cua_focus_monitor.py
```

The report identifies actual tool targets and correlates foreground transitions
with mutation intervals plus a two-second observation tail. Recent mouse-down or
modifier events are evidence of possible user switching, never proof that a
transition was harmless. Ordinary typing alone does not excuse target activation.
Unrelated window changes are recorded and do not stop automation. Target changes
without sufficient evidence remain unattributed. No classification proves
causality; delayed effects can occur beyond the correlation window.

The collector records activation notifications and samples every50ms. It also
retains visible window ordering for investigation. It does not observe typed text
or establish that keyboard focus/typing continuity was preserved. A stable
foreground app/window is not a universal background-CUA guarantee.
