**Created:** 2026-11-10 · **Status:** current

# Calendar menu

The menu-bar label selects an ongoing timed calendar event, or the next event today. Among overlapping events it prefers the occurrence linked to the active recording; otherwise it chooses the earliest start, with occurrence identity breaking ties. The countdown uses the scheduled end, not elapsed recording time. Only the title is shortened.

Appearance settings provide title + time, time only, icon only, and invite-document visibility. The existing meeting-label and hotkey switches remain compatible. The separate Marauder’s Map countdown retains precedence. Calendar selection, hidden occurrences, and the meeting-link visibility filter apply to the label and menu. The agenda retains its configured window; the label and featured meeting can reach the rest of today.

The featured meeting has direct Join, Join & Record, Record Only, and document items. Other agenda meetings keep actions and documents in submenus. Recording actions reuse the existing recording entry points and guards. Invite links open through the default handler. Only HTTP(S) links without embedded credentials are accepted; Google and Outlook Safe Links wrappers are resolved locally. Meet dial-in and help links are omitted. On opening the menu, generic document labels can be replaced with public page titles from supported document providers. These bounded HTTPS metadata requests use no cookies, credentials, subresources, or Drive permissions, stop at the page title/head, and reject redirects to login pages or unsupported hosts. Private documents retain invite-provided titles or readable type/domain fallbacks.

## Native calendar document availability

The app continues to use macOS Calendar through EventKit, as established in upstream PR #510. It does not restore direct Google sign-in, background Google API requests, or OAuth configuration.

Documents are read from EventKit notes and the event URL. Google and other accounts configured in macOS Internet Accounts remain supported. EventKit does not expose Google attachment metadata through a public API, so an attachment must also appear as a link in the synced notes or event URL to be shown.

The dormant Google Calendar utility retains tested attachment parsing and document merging, but is not part of the live app pipeline. No new account permissions are requested.
