# Muesli design reference

Open `muesli-design-system.html` in a browser. It is a self-contained visual reference with dark/light previews and no external font dependency. The **Dashboard & Notch Patterns** section records the UI work in PR #584, updated October 8, 2026.

For a local preview:

```sh
python3 -m http.server 8767 --bind 127.0.0.1 --directory design-system
```

Then open http://127.0.0.1:8767/muesli-design-system.html#ui-polish.

## Source of truth

The native implementation owns behavior and token values. Browser specimens illustrate the design and cannot substitute for AppKit/SwiftUI rendering checks. One CSS pixel represents one layout point in the examples, not one physical Retina pixel.

| Pattern | Native source under `native/MuesliNative/Sources/MuesliNativeApp/` |
| --- | --- |
| Adaptive colors, typography, spacing, reading width | `MuesliTheme.swift` |
| Sidebar width, compact layout, global tint | `DashboardRootView.swift`, `SidebarView.swift` |
| Outlined statistics with centered icon/value/caption stacks | `StatsHeaderView.swift` |
| Prominent, labeled Insights Share action and adaptive range controls | `InsightsView.swift` |
| History rows and expandable previews | `DictationRowView.swift`, `TimelineView.swift`, `MeetingListItemView.swift` |
| Notes and transcript reading columns | `MeetingNotesView.swift`, `MeetingDetailView.swift` |
| Accent swatches, account and maintenance actions | `MuesliSettingsOptions.swift`, `SettingsView.swift` |
| Centered indicator choice captions | `RecordingIndicatorStylePicker.swift` |
| Single-line notch, aligned expansion, and compact computer-use tool responses | `NotchIndicatorController.swift` |
| Image-only notification close button | `NotificationDismissButton.swift` |
| Provider marks, sharing, and sync invitation | `ModelsView.swift`, `AboutView.swift`, `IPhoneBridgeCard.swift` |

When changing these patterns, update the corresponding specimen and token descriptions in the same PR. Reuse existing provider assets rather than exporting replacement logos. The default accent's legacy `1e1e2e` value means adaptive blue, not a literal dark color. Preserve that stored value for compatibility.

## Current constraints

- The native stats header still uses four columns at narrow widths. Its compact-window behavior is an open review finding, not resolved by the reference's scrollable desktop specimen.
- The notch's 78pt right wing leaves 32pt more space than the previous usual 110pt wing. It does not discover the macOS microphone indicator's bounds. Validate other display scales and crowded menu bars before claiming universal clearance.
- The close mark is an image-only system xmark centered in a 22pt circular button. Its native rendering has already been verified at 1×/2×; browser text glyphs are not an equivalent implementation.
- Real UI verification must include narrow windows, both appearances, keyboard focus, and selected/hover states. The HTML theme toggle changes only this reference, never app preferences.

## What Insights means by a session

The app/model rankings in `DictationStore.insightsUsage` count one saved, non-deleted dictation record as one session within the selected calendar-day range. A short utterance and a long dictation both count once; streaming partials are not separate saved sessions. Meetings, Quill (`quil`), and computer-use (`cua`) records are excluded from these rankings. Synced records can count, with unavailable model attribution remaining explicitly unrecorded.

App rankings group by destination bundle ID, falling back to the app name. Model rankings group by backend, model, and recorded endpoint. Rankings sort by session count, then word count. Counts describe saved records, not time spent in an application or model invocations/retries.

The overview's `dictationSessions` currently uses the broader daily cache and includes saved Quill/computer-use records. That inconsistency is documented here, not corrected as part of this visual reference update. The aggregation source is `native/MuesliNative/Sources/MuesliCore/DictationStore.swift`.

## Computer-use expanded notch

Center the expanded instruction and question panels beneath the visible bar (its midpoint), while keeping the top bar’s camera gap aligned with the hardware. The unequal 110pt/78pt wings place this midpoint 16pt left of the camera center. Clamp panels to the active display.

Show the latest three executed-tool responses under the working status, using 10pt text, two lines per response, and a 180-character excerpt. Exclude raw observations, planning text, and tool arguments; full detail remains in the run trace. Use 13pt instruction text in a scrollable area. The normal panel starts at 100pt high and adds 30pt per result, capped at 190pt; review and question surfaces retain their dedicated layouts. Clear excerpts when a new command starts or the session ends.
