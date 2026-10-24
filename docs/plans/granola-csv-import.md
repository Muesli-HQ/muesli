# Granola CSV import

The importer uses Granola's supported historical-data export. In Granola, open
workspace menu → Settings → Profile → Export historical data → Generate CSV.
Choose workspaces, generate, then download the emailed ZIP.
In Muesli, choose Meetings → Import → Granola, select the ZIP or CSV files,
review the preview, then import. New meetings go into the top-level
“Granola” folder, created automatically or reused by name. Folder
creation is part of the import transaction and is skipped when there are no new meetings.

## Observed format

Verified against the October 2026 export. UTF-8 CSV with quoted multiline fields;
no private meeting content is included in this repository or its test fixtures.

| CSV column | Muesli representation |
| --- | --- |
| `document_id` | Normalized UUID; stable sync identity `meeting-granola-<UUID>` and local import provenance |
| `document_title` | Meeting title |
| `document_created` | Creation date, displayed as “Created”; not asserted to be the actual meeting start |
| `summary` | Formatted notes, preserving exported Markdown |
| `notes` | Manual notes, kept separately from the generated summary |
| `transcript` | Raw transcript, preserving text and line breaks |
| `workspace_name` | Local provenance metadata and preview |
| `user_email` | Local provenance metadata; not treated as a participant |

The export has no duration, audio, structured participants, or speaker timestamps.
No such metadata is inferred. Duration is stored as zero for compatibility with
the existing numeric schema, but omitted from the imported meeting's UI. Imported
records are completed and carry the `granola_import` source. Summary-only,
transcript-only, and manual-note-only records are accepted. Missing content stays
empty. A malformed row rejects the file before persistence; database failures
roll back the entire import batch.

Imports skip existing document IDs, including tombstones, without overwriting
local edits. The stable sync identity also prevents a repeat import from creating
another local row when that document has already arrived via iCloud. Existing
sync behavior still resolves simultaneous edits on different devices. Import
provenance's workspace and owner email are device-local; source, content, and
stable identity use the existing sync transport. Account unlink/reset behavior
continues to be governed by the existing sync lifecycle.

Import does not regenerate summaries, re-transcribe, or dispatch meeting-completed
webhooks. Imported content follows the user's existing iCloud sync settings.
The browser currently shows the latest 200 meetings in its folder scope; older
records remain available via global meeting search.

## Validation

`GranolaImportTests` covers quoting/Unicode/BOM, incomplete records, malformed
input, content preservation, folder placement, deduplication, sync round-trip,
automatic folder creation/reuse, and whole-batch rollback. Fixtures are synthetic.
Real exports are inspected only in temporary databases and are not bundled.

The export guide includes a sanitized, annotated illustration based on the three
captured Granola screens, with example account details. It is bundled locally as
`granola-export-guide.png` and displayed inline. Clicking it opens an image-only
expanded view, with a close control and Escape support. Original screenshots
remain private research assets outside the repository. Verify the navigation
against Granola when updating this image; it was checked in October 2026.

ZIP imports read regular CSV entries directly into memory with ZIPFoundation 0.9.20,
without extracting files to disk. All CSV parts share the 50 MB uncompressed and
10,000-meeting limits. Inputs are capped at 50 MB and ZIPs at 1,000 entries.
CSV headers are capped at 128 columns, and data rows cannot exceed the header's
column count. Checksums, entry sizes, and entry counts are verified; damaged, encrypted,
symlink CSV, and multi-disk/ZIP64 archives are rejected. CSV import remains
available for unsupported archive variants. macOS metadata files are ignored.

The preview and default meeting browser sort newest first by document creation
date. The store orders by date before applying the browser's 200-record limit,
so a large historical import does not displace newer meetings based on insertion order.
Completion shows a brief success message without zero-count diagnostics.
Existing automatically created “Imported from Granola” folders are renamed in
place to “Granola” once on upgrade. Within the Granola folder, rows omit the
redundant import badge and current-folder breadcrumb; All Meetings retains them.
