# muesli design reference

Open `muesli-design-system.html` in a browser. It is a visual reference with Light, Dark and Ultra Dark previews. It loads the repository’s bundled Nunito Sans fonts locally; no remote font service is used. The **Dashboard & Notch Patterns** section records the UI work in PR #584, updated October 8, 2026.

For a local preview:

```sh
python3 -m http.server 8767 --bind 127.0.0.1
```

Then open http://127.0.0.1:8767/design-system/muesli-design-system.html#typography.

## Current visual language

Nunito Sans is the app-wide text family, matching the website’s Nunito family.
Use `MuesliTheme.font` and semantic typography helpers in SwiftUI; use
`AppFonts` in AppKit. This includes onboarding, chat, settings and auxiliary
surfaces. SF Symbols retain the system symbol font; code retains a system
monospaced font. The bundled regular, medium, semibold, bold, extra-bold, italic
and bold-italic faces use shared registration and caching, never per-render I/O.

| Role | Size / weight |
| --- | --- |
| Page title | 26 bold |
| Section title / smaller title | 20 / 18 semibold |
| Headline | 15 semibold |
| Reading | 15 regular; maximum column 720pt |
| Body / settings label | 14 regular |
| Callout | 13 regular |
| Helper / warning | 12 regular / medium |
| Settings group heading | 12 semibold |
| Metadata / keyboard hint | 11 medium |

Keep the feel quiet and tactile: layered surfaces, restrained borders, rounded
controls, readable hierarchy and clear pressed/selected states. Depth must
serve interaction, without expensive decorative blur, animation or shadows.
Keep native keyboard navigation, focus, IME, selection and undo intact. Honor
Reduce Motion. Font and palette changes must not rebuild view identity or
introduce background work.

### Settings and copy

Use `SettingsSectionHeading`, `SettingsRow` and `SettingsNote`. Standard
controls occupy a 275pt trailing column with 20pt separation; compact switches
keep intrinsic width. Below 540pt of content width, standard controls stack
below labels. The section selector falls back to a menu when needed.
Avoid repeating headings in subtitles; retain short explanations of consequences,
privacy and prerequisites. Put optional setup instructions in disclosures.
Never reduce body/helper sizes to conceal overflow.

Order tabs General, Dictations, Meetings, Appearance, Experimental. iCloud Sync
lives in General; Computer Use, Quill and Cotypist live in Experimental. The
meeting-chat destination is labeled Chat.

### Ultra Dark and color roles

Ultra Dark is an explicit local preference available only in Settings →
Appearance, not in the sidebar quick choices or voice settings actions.
Deep/base backgrounds are #000000; raised #0A0A0A; hover #181818; primary
surface #121212; selected surface #222222. Text uses white at 100%, 80%, 65%;
borders use white at 28%. Primary accent is white and `onAccent` is black.
Use `MuesliTheme.toggleAccent` on switches: their on state keeps the user’s
saved accent (adaptive blue by default), including in Ultra Dark. Accent
selection remains available there. Preserve semantic recording, warning,
error and success colors.

Use adaptive foreground attributes for native text inputs, including preset
insertion and restored drafts. A replacement into empty NSTextStorage must
carry font and foreground color explicitly; keep undo/redo behavior.

### Brand and identity

Write the visible brand as **muesli**. Display-name changes do not change bundle
IDs, executables, support folders, database paths, keychain identifiers or sync
identity. Older configurations continue to use their existing local data.

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
- Real UI verification must include narrow windows, Light, Dark and Ultra Dark, keyboard focus, and selected/hover states. The HTML theme toggle changes only this reference, never app preferences.

## What Insights means by a session

The app/model rankings in `DictationStore.insightsUsage` count one saved, non-deleted dictation record as one session within the selected calendar-day range. A short utterance and a long dictation both count once; streaming partials are not separate saved sessions. Meetings, Quill (`quil`), and computer-use (`cua`) records are excluded from these rankings. Synced records can count, with unavailable model attribution remaining explicitly unrecorded.

App rankings group by destination bundle ID, falling back to the app name. Model rankings group by backend, model, and recorded endpoint. Rankings sort by session count, then word count. Counts describe saved records, not time spent in an application or model invocations/retries.

The overview's `dictationSessions` currently uses the broader daily cache and includes saved Quill/computer-use records. That inconsistency is documented here, not corrected as part of this visual reference update. The aggregation source is `native/MuesliNative/Sources/MuesliCore/DictationStore.swift`.

## Computer-use expanded notch

Center the expanded instruction and question panels beneath the visible bar (its midpoint), while keeping the top bar’s camera gap aligned with the hardware. The unequal 110pt/78pt wings place this midpoint 16pt left of the camera center. Clamp panels to the active display.

Show the latest three tool summaries under the working status, using 10pt text and at most two lines per summary. Generate display copy from the operation and outcome (for example, “Read page text” or “Open app — failed”), never from raw response bodies. Full responses, observations, errors, and tool arguments remain in Timeline. Older trace events without a summary remain readable there and do not fall back to raw text in the notch. Use 13pt instruction text in a scrollable area. The normal panel starts at 100pt high and adds 30pt per result, capped at 190pt; review and question surfaces retain their dedicated layouts. Clear summaries when a new command starts or the session ends.

Active dictation, processing, and computer-use sessions own the indicator until they finish. Background loading callbacks and cursor feedback must not hide or replace their presentation or cancellation controls. Loading may use the shared floating surface while idle; starting an activity retires that loading presentation so its later completion cannot reset the session.
