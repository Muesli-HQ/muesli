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
selection remains available there; its swatches preview the switch color, not
the white action fill. Preserve semantic recording, warning, error and success
colors.

Fills keep the raw saved accent and semantic hues; foregrounds use a role
matched to the surface beneath them (4.5:1 for labels, 3:1 for state glyphs):

| Role | Use |
| --- | --- |
| `onAccent` | Text and glyphs on `accent` fills. Black or white, whichever contrasts more with the resolved fill, so Dark Default and light presets get dark ink. |
| `accentText` | Accent-hued labels, links, chips, badges and selected icons on neutral surfaces and accent tints. A same-hue shade, deepened in Light and lightened in Dark only as needed. Never a fill. White in Ultra Dark. |
| `accentStateShade` | Hover/pressed overlay on accent fills (8%/16%), always moving away from `onAccent`. |
| `onSuccess` | Dark ink on `success` fills (Donate, onboarding confirmations). Never `onAccent`. |
| `recordingFill` | #DC2626 with white labels for labelled Stop/Record. `recording` (#EF4444) remains for dots, waveforms and badges. |
| `destructiveText` | Destructive labels, trash glyphs and error text, on cards and red tints up to 16%. |
| `successText`, `warningText` | Status labels; deeper shades in Light. |
| `joinAction` | Join split buttons (dashboard and notification) with dark ink. |

`MuesliAccentPalette` derives these once when the accent changes and caches
them per swatch; views never parse hex or compute contrast while rendering.
`MuesliColorRolesTests` checks every preset and a spread of arbitrary saved
hex values in Light, Dark and Ultra Dark. Native controls keep system rendering.

### Control feedback

Custom buttons use `MuesliButtonStyle` (`.muesli(.primary | .secondary |
.raised | .tinted | .destructive | .destructiveTinted | .success | .recording |
.quiet)`). The label keeps its existing padding, height, width and typography;
the style owns fill, border, foreground and a full-shape hit area, so visible
padding is clickable. Hover and keyboard focus raise one flat color step and
press a second. Quiet controls show hover and press as neutral fills, never
outlines; only keyboard focus draws a ring. `.raised` is the field-like
launcher surface (`backgroundRaised` with a border), used by the collapsed chat
composer. Disabled controls render once, flat, as `surfacePrimary` with
`textTertiary`; do not add opacity on top.

Resting depth is restrained and physical, built from solid 1pt shape edges
(`MuesliControlDepth`), never gradients, blur, shadow filters or offscreen
compositing:

| Depth | Kinds | Treatment |
| --- | --- | --- |
| Lifted | `.primary`, `.success`, `.recording` | Black lower lip (Light 14%, Dark 26%; Increase Contrast 24%/40%) plus a 1pt inset rim (10%, 20% with Increase Contrast) in the same shade the hover overlay uses, so it moves away from the label. |
| Edge | `.secondary`, `.raised` | Neutral lip beneath the bottom border (Light 6%, Dark 20%; 12%/32%). None in Ultra Dark, whose 28% white border already carries the edge. |
| Rim | `.tinted` | Quieter accent rim (14%, 26% with Increase Contrast); no lip. |
| Flat | `.quiet`, `.destructive`, `.destructiveTinted`, `compresses: false`, pressed, disabled | Existing fills/borders; quiet controls reserve their ring for keyboard focus. |

The lip is the face's lower 1pt edge, exposed by drawing a second copy of the
opaque face 1pt shorter; the face under the label keeps its exact color, so
label/fill contrast is unchanged. Edges sit at the shape border inside the
label's own padding, never behind text, and do not hit-test. The layer
structure is fixed per button; only edge opacities change with state, color
scheme and Increase Contrast, with no per-render contrast math.

Press feedback is tactile but small. Mouse-down removes the lip and rim and
shows the pressed color on the same frame; release restores them with the
same 0.12s color fade. The drawn control
compresses to `MuesliMotion.pressedScale` (0.98) in 0.06s and releases in
0.14s, via `MuesliPressCompression`. The scale is visual only: it is applied
before `contentShape`, so layout and the full unscaled hit region do not move,
and the action never waits for the animation. Reduce Motion removes the scale
and the fades but keeps the instant color and depth change. No blur shadows,
springs or offsets.
Full-width list rows (`compresses: false`) and sidebar navigation stay flat and
acknowledge a press with an immediate fill. The 0.12s color fade, navigation
and row-hover animations go through `MuesliMotion`; repeating motion (sync
spinner, onboarding preparation bar, title marquee) becomes static under
Reduce Motion. Native focus rings, keyboard shortcuts and button semantics are
unchanged.

Targets: icon and text actions use at least a 28pt hit region, 32pt where a row
or footer allows (chat footer, Insights refresh, Meetings header actions). Put
the padding inside the Button label, so the label's actual bounds are the
drawn control and its hit region. Align a padded text action by those actual
bounds, adjusting the column's spacing or alignment; do not pull it outward
with negative outer padding, which makes targets overlap their neighbors.
`MuesliTextButton` is the shared text-only action. Adjacent targets' actual
bounds must not overlap: a row's primary target and its trailing actions are separate
buttons, and margins inside a row belong to one of them rather than being dead.
Native switches, pickers and menus keep system rendering; enlarge a `Menu`
label's frame and content shape instead of replacing it with gestures.

Rows that host drag and drop or context menus remain gestures and show hover
and selected fills, but no mouse-down fill: that would require a zero-distance
gesture that competes with drag sources and scrolling. Rows with neither (for
example All Meetings) are buttons. A primary button that shares a row with
other actions reports its press so the row draws one shared fill.

Asynchronous actions show their state at click time and refuse repeats:
copy actions show a short visible confirmation; renames, deletes, model
updates, imports/exports and Insights refresh show local progress and disable
the conflicting controls; refreshing the same range keeps the previous content
visible. Failures stay next to the control that caused them.

Hover-revealed row actions also appear while one of them has keyboard focus,
and carry labels. Rows that host drag and drop, context menus or nested buttons
stay gestures and use `muesliRowActivation` for button/selected traits and
Space/Return activation under full keyboard navigation. Send and Stop share
one 32pt slot in the chat composer; sign-in progress occupies the button's frame.

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
| Accent-derived foreground roles and contrast math | `MuesliAccentPalette.swift` |
| Shared button feedback, resting depth, motion policy, gesture-row activation | `MuesliControlStyles.swift` |
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

Custom button focus uses a non-hit-testing 2pt readable-accent outline; sidebar navigation uses subtle selected/hover fills without outlines; appearance choices retain their neutral selection outline. Sidebar rings are reserved for keyboard focus. Composer focus has its own host-supplied color through AIElementsTheme. Native text-editing and recording behavior remain unchanged.

## Official brand assets

The cover and brand specimens use approved artwork from [muesli.works/brand](https://muesli.works/brand), copied from `Muesli-HQ/muesli-landing` commit `7b6b434e5fc54e51d05a002440355fd5b90a416f` (brand library PR #5). Files live in `assets/brand/`; `assets/brand/assets.json` maps local files to their published URLs and descriptions. Keep this directory beside the HTML when sharing the offline reference.

Use the supplied icon, waveform lockups, and outlined wordmarks directly. Do not recreate the brand with CSS bars, a guessed bar count, or separately typeset letters. Outlined wordmarks preserve Nunito Sans lettering and spacing without a font download. The animated recording-indicator specimens remain UI behavior examples.

The light-blue-on-site-ink lockup uses `#6AA0F4` over `#080E16`. The primary transparent lockup uses `#12365B`. These brand values do not replace the native app's adaptive UI accent. Copy updated official files and their metadata together when refreshing this reference.

## Iconography and indicator audit (October 31, 2026)

Audited against `origin/main` at `e1b52117ffb1ab6980f7266b72d9cb9e706a5afb`. Sources: `SidebarView.swift`, `MWaveformIcon.swift`, `FloatingIndicatorController.swift`, `IndicatorWaveformDynamics.swift`, `NotchIndicatorController.swift`, and `RecordingIndicatorStylePicker.swift` under `native/MuesliNative/Sources/MuesliNativeApp/`.

Corrected the missing Chat destination, Meetings symbols (`person.wave.2` expanded, `person.2` collapsed), preparing size/timing, waveform count/geometry/smoothing, waiting animation, and explicit meeting controls. Section 05 now distinguishes Classic, Minimal and Notch behavior. Browser emoji remain illustrative placeholders, not actual SF Symbols. This source audit does not certify pixel fidelity or all other component specifications; native visual and interaction checks still apply.
