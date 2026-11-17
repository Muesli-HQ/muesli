# Native typography

Muesli uses **Nunito Sans** for app-owned text, matching the sans-serif family on
[muesli.works](https://muesli.works). The website's Newsreader editorial headings
are a marketing treatment, not the native application's heading family.

## Audit baseline

The October 2026 audit compared v0.8.5 with origin/main at `1617cf29` and inspected
the running DevB settings surface. The worktree already matched that main commit.
The release diff introduced or expanded models, meeting chat, recording overlays,
onboarding and settings surfaces. Typography had three independent paths:

- `MuesliTheme` used SF Pro, with hundreds of additional explicit SwiftUI system
  fonts and semantic defaults bypassing those tokens.
- `AppFonts` loaded Inter, used by the Insights share image.
- AppKit editors/indicators and AIElementsSwift supplied their own system fonts.

## Shared roles

| Role | Native points | Weight |
| --- | ---: | --- |
| Page title | 26 | Bold |
| Section title | 20 | Semibold |
| Subsection title | 18 | Semibold |
| Headline | 15 | Semibold |
| Reading text | 15 | Regular |
| Body | 14 | Regular |
| Control/callout | 13 | Regular |
| Caption | 12 | Regular / Medium |
| Compact metadata | 11 | Medium |

Use `MuesliTheme` roles for new SwiftUI text. `MuesliTheme.font(size:weight:)`
serves existing compact layouts and display statistics that need an explicit
size. Rounded text uses the same brand family. Do not add custom font names at
call sites. Keep paragraph leading and truncation intentional; changing the
family does not justify changing the available content width.

`AppFonts.font(size:weight:)` is the AppKit counterpart. Labels, attributed text,
text editors and measurement must use the same font. In particular, the Ask
Meetings composer and recording previews must measure the face they draw.

`AIElementsTheme.textFont` injects host typography into chat labels, source cards,
tables, tool status, reasoning summaries and Markdown headings. The reusable
package keeps system-font defaults and contains no Muesli font resources.

## Settings hierarchy and copy

Settings and Models use `SettingsSectionHeading` (12 pt semibold, secondary)
for compact group headings. Settings labels are 14 pt regular, control values
13 pt, helpers 12 pt regular, and statuses/errors 12 pt medium. Reserve
`MuesliTheme.metadata()` (11 pt medium) for badges and keyboard hints, not
instructions or errors. Page titles remain 26 pt bold.

`SettingsRow` aligns controls with the label's first line. Compact switches use
intrinsic width; menus and fields use a bounded 275 pt column and stack below
their labels when the Settings content is narrower than 540 pt. A single
page-level breakpoint supplies the layout environment. Row helpers and section
notes share the label edge, without extra horizontal insets or negative spacing.

A setting does not require a subtitle. Keep a short explanation only when it
clarifies a choice, consequence or prerequisite. Keep privacy, executable
behavior and recovery guidance visible; optional setup instructions can use a
disclosure. Let meaningful text wrap instead of truncating it to meet a line
count. Use previews to explain formatting rather than repeating the controls.

The Settings section selector uses segmented tabs when they fit and a labeled
menu in narrow windows, so navigation cannot force the whole page wider.

## Brand spelling

Use lowercase **muesli** in user-facing copy, accessibility labels, exports and
app display names (including lane suffixes such as `muesliDevC`). Keep bundle
filenames, executable names, bundle IDs, support directories, model repository
IDs and diagnostic domains stable; those are compatibility identifiers. The
packager sets the display name separately from the existing support directory.

## Intentional exceptions

- SF Symbols retain system font sizing and weight; custom font metrics must not
  change symbol rendering.
- Code, paths, key chords and existing monospaced time/counter fields retain a
  monospaced font. Tabular statistics retain `monospacedDigit()`.
- macOS-owned menu chrome, alerts, file panels and permission dialogs use native
  system typography. The app's own accessory labels use the brand font.
- Portable HTML/PDF exports and browser authentication callbacks retain their
  existing document fonts; this change targets the application surfaces.
- Unsupported scripts and emoji use CoreText's system fallback cascade. Do not
  replace missing characters or force a Latin-only fallback.

## Loading and performance

Seven static faces (under 1 MB total), including genuine italic and bold italic,
ship in the app target's `Resources/Fonts` SwiftPM bundle. Retired Inter assets
are no longer copied into the application. Registration is lazy,
thread-safe through static initialization, and occurs once per process. AppKit
font instances use a bounded cache. No runtime downloads or font conversion are
required. Missing individual font faces are logged and fall back to system fonts. The
SwiftPM resource bundle itself is required, as it is for the app’s other assets.

See the bundled font README and OFL license for source checksums and generation.
The generator is a maintenance tool, not a build dependency. Verify packaged
resources, not just locally installed fonts.

## Validation

`MuesliTypographyTests` checks real bundled weights, AppKit bold/italic conversion,
and multilingual glyph fallback. It is registered in the native CI shard list.
AIElementsSwift's standalone tests validate the reusable presentation package.

For changes, inspect DevC at normal and narrow window widths, in Light, Dark and
Ultra Dark appearances. Check settings, models, onboarding, sidebar, meeting notes, chat,
and floating/notch labels for truncation or clipped descenders. Exercise pointer
focus, multiline paste, selection, undo and navigation in native editors; font
unit tests do not establish these interactions. Preserve the lane's existing data.
