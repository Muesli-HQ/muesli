# Private meetings

A meeting or a folder can be marked private. A private meeting stays on your Mac unless you
have said that a specific service may receive it.

## What "private" covers

| Where content could leave | What happens to a private meeting |
|---|---|
| Meeting summary and title generation | Skipped unless the selected backend is allowed for private meetings. The transcript is kept and the meeting shows why no summary was made. An audio file imported into a private folder is treated the same way. |
| Ask Meetings (chat) | Excluded from retrieval, search, browse and read tools, even when attached explicitly. A chat whose earlier answers cite a private meeting refuses to continue on a backend that is not allowed. |
| Auto-export | Never written. |
| `muesli-cli` | `meetings list` and `meetings get` return the title and timing with `isPrivate: true` and no transcript, notes, audio paths or context. `meetings update-notes` refuses. |
| iCloud sync | Content is not uploaded. A copy that reached iCloud before the meeting became private is replaced with a deletion marker, so it also leaves your other devices. The meeting stays on this Mac. Un-marking it uploads it again. |

Copying text and exporting by hand are explicit actions and are not blocked.

## How to mark

- A meeting: the lock button in the meeting header.
- A folder: right-click the folder, "Mark Folder Private". Every meeting in that folder and in its
  subfolders is private. Moving a meeting out of the folder makes it normal again; a meeting marked
  private on its own stays private wherever it is.

## Allowing a service

Settings, "Private Meetings": one switch per summary backend. All are off by default, including
local ones, because Ollama, LM Studio and Custom LLM can all point at another machine. Turn on only
services you trust with private content, for example your own server. These switches are manual-only
and cannot be changed by voice command.

If a private meeting is waiting and no allowed backend is selected, nothing is sent and the meeting
says so. It never falls through to another backend.

## Failure behaviour

A failed privacy lookup counts as private, so an error can only withhold content, never send it.

## Limits

- Marking a meeting private does not recall a file that auto-export wrote before it was marked.
- Meeting titles are visible in CLI output so a meeting can still be found.
