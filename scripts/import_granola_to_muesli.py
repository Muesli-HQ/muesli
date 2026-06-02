#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import sqlite3
import sys
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import Request, urlopen


API_BASE = "https://public-api.granola.ai/v1"


@dataclass
class ImportStats:
    fetched: int = 0
    with_transcript: int = 0
    created: int = 0
    skipped_existing: int = 0
    skipped_missing_transcript: int = 0
    failed: int = 0


def parse_args() -> argparse.Namespace:
    default_db = Path.home() / "Library/Application Support/Muesli/muesli.db"
    parser = argparse.ArgumentParser(description="Import Granola note transcripts into the local Muesli database.")
    parser.add_argument("--db-path", default=str(default_db), help="Path to the Muesli SQLite database.")
    parser.add_argument("--api-key-env", default="GRANOLA_API_KEY", help="Environment variable containing the Granola API key.")
    parser.add_argument("--page-size", type=int, default=30, help="Granola list page size. API maximum is 30.")
    parser.add_argument("--created-after", help="Optional ISO date or datetime lower bound passed to Granola.")
    parser.add_argument("--created-before", help="Optional ISO date or datetime upper bound passed to Granola.")
    parser.add_argument("--limit", type=int, help="Optional maximum number of notes to fetch for testing.")
    parser.add_argument("--export-json", help="Optional path to write fetched Granola note JSON.")
    parser.add_argument("--input-json", help="Import from a previously exported JSON file instead of calling Granola.")
    parser.add_argument("--dry-run", action="store_true", help="Fetch and parse data without writing to Muesli.")
    parser.add_argument("--no-backup", action="store_true", help="Do not create a timestamped database backup before writing.")
    return parser.parse_args()


def request_json(path: str, api_key: str, params: dict[str, Any] | None = None, retries: int = 4) -> dict[str, Any]:
    query = f"?{urlencode(params)}" if params else ""
    request = Request(
        f"{API_BASE}{path}{query}",
        headers={
            "Authorization": f"Bearer {api_key}",
            "Accept": "application/json",
            "User-Agent": "muesli-granola-import/1.0",
        },
    )

    for attempt in range(retries + 1):
        try:
            with urlopen(request, timeout=45) as response:
                return json.loads(response.read().decode("utf-8"))
        except HTTPError as error:
            if error.code == 429 and attempt < retries:
                retry_after = error.headers.get("Retry-After")
                delay = float(retry_after) if retry_after else min(8, 1.5 * (attempt + 1))
                time.sleep(delay)
                continue
            body = error.read().decode("utf-8", errors="replace")
            raise RuntimeError(f"Granola API returned HTTP {error.code} for {path}: {body}") from error
        except URLError as error:
            if attempt < retries:
                time.sleep(min(8, 1.5 * (attempt + 1)))
                continue
            raise RuntimeError(f"Granola API request failed for {path}: {error}") from error

    raise RuntimeError(f"Granola API request failed for {path}")


def fetch_notes(api_key: str, page_size: int, created_after: str | None, created_before: str | None, limit: int | None) -> list[dict[str, Any]]:
    notes: list[dict[str, Any]] = []
    cursor: str | None = None

    while True:
        params: dict[str, Any] = {"page_size": min(max(page_size, 1), 30)}
        if cursor:
            params["cursor"] = cursor
        if created_after:
            params["created_after"] = created_after
        if created_before:
            params["created_before"] = created_before

        page = request_json("/notes", api_key, params)
        for note in page.get("notes") or []:
            note_id = note.get("id")
            if not isinstance(note_id, str) or not note_id:
                continue
            detail = request_json(f"/notes/{note_id}", api_key, {"include": "transcript"})
            notes.append(detail)
            if limit and len(notes) >= limit:
                return notes

        if not page.get("hasMore"):
            return notes
        cursor = page.get("cursor")
        if not cursor:
            return notes


def load_notes(path: str) -> list[dict[str, Any]]:
    payload = json.loads(Path(path).read_text(encoding="utf-8"))
    if isinstance(payload, list):
        return payload
    if isinstance(payload, dict) and isinstance(payload.get("notes"), list):
        return payload["notes"]
    raise SystemExit("Expected input JSON to be an array of Granola notes or an object with { notes: [...] }.")


def parse_date(value: Any) -> datetime | None:
    if not isinstance(value, str) or not value.strip():
        return None
    text = value.strip()
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    try:
        parsed = datetime.fromisoformat(text)
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc)


def iso_z(value: datetime) -> str:
    return value.astimezone(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def note_start(note: dict[str, Any]) -> datetime:
    calendar_event = note.get("calendar_event") if isinstance(note.get("calendar_event"), dict) else {}
    transcript = note.get("transcript") if isinstance(note.get("transcript"), list) else []
    candidates = [
        calendar_event.get("scheduled_start_time"),
        first_transcript_time(transcript, "start_time"),
        note.get("created_at"),
        note.get("updated_at"),
    ]
    for candidate in candidates:
        parsed = parse_date(candidate)
        if parsed:
            return parsed
    return datetime.now(timezone.utc)


def note_end(note: dict[str, Any], start: datetime) -> datetime:
    calendar_event = note.get("calendar_event") if isinstance(note.get("calendar_event"), dict) else {}
    transcript = note.get("transcript") if isinstance(note.get("transcript"), list) else []
    candidates = [
        calendar_event.get("scheduled_end_time"),
        last_transcript_time(transcript, "end_time"),
        last_transcript_time(transcript, "start_time"),
    ]
    parsed_candidates: list[datetime] = []
    for candidate in candidates:
        parsed = parse_date(candidate)
        if parsed and parsed >= start:
            parsed_candidates.append(parsed)
    return max(parsed_candidates) if parsed_candidates else start


def first_transcript_time(transcript: list[Any], key: str) -> Any:
    for item in transcript:
        if isinstance(item, dict) and item.get(key):
            return item.get(key)
    return None


def last_transcript_time(transcript: list[Any], key: str) -> Any:
    for item in reversed(transcript):
        if isinstance(item, dict) and item.get(key):
            return item.get(key)
    return None


def speaker_label(item: dict[str, Any]) -> str:
    speaker = item.get("speaker") if isinstance(item.get("speaker"), dict) else {}
    diarization = speaker.get("diarization_label")
    if isinstance(diarization, str) and diarization.strip():
        return diarization.strip()

    source = speaker.get("source")
    if source == "microphone":
        return "Microphone"
    if source == "speaker":
        return "Speaker"
    if isinstance(source, str) and source.strip():
        return source.strip().replace("_", " ").title()
    return "Speaker"


def format_offset(timestamp: datetime | None, start: datetime) -> str:
    if not timestamp:
        return "00:00:00"
    seconds = max(int((timestamp - start).total_seconds()), 0)
    hours = seconds // 3600
    minutes = (seconds % 3600) // 60
    secs = seconds % 60
    return f"{hours:02d}:{minutes:02d}:{secs:02d}"


def transcript_text(note: dict[str, Any], start: datetime) -> str:
    transcript = note.get("transcript")
    if not isinstance(transcript, list):
        return ""

    lines: list[str] = []
    for item in transcript:
        if not isinstance(item, dict):
            continue
        text = item.get("text")
        if not isinstance(text, str) or not text.strip():
            continue
        started_at = parse_date(item.get("start_time"))
        offset = format_offset(started_at, start)
        lines.append(f"[{offset}] {speaker_label(item)}: {text.strip()}")
    return "\n".join(lines)


def plain_word_count(value: str) -> int:
    return len(re.findall(r"\b[\w']+\b", value))


def attendee_lines(note: dict[str, Any]) -> list[str]:
    attendees = note.get("attendees")
    if not isinstance(attendees, list):
        return []
    lines: list[str] = []
    for attendee in attendees:
        if not isinstance(attendee, dict):
            continue
        name = attendee.get("name")
        email = attendee.get("email")
        if isinstance(name, str) and name.strip() and isinstance(email, str) and email.strip():
            lines.append(f"- {name.strip()} <{email.strip()}>")
        elif isinstance(name, str) and name.strip():
            lines.append(f"- {name.strip()}")
        elif isinstance(email, str) and email.strip():
            lines.append(f"- {email.strip()}")
    return lines


def formatted_notes(note: dict[str, Any]) -> str:
    note_id = str(note.get("id") or "")
    parts: list[str] = []
    summary = note.get("summary_markdown") or note.get("summary_text")
    if isinstance(summary, str) and summary.strip():
        parts.append(summary.strip())
    else:
        parts.append("## Imported From Granola\n\nNo generated summary was returned by the Granola API.")

    attendees = attendee_lines(note)
    if attendees:
        parts.append("## Attendees\n\n" + "\n".join(attendees))

    calendar_event = note.get("calendar_event") if isinstance(note.get("calendar_event"), dict) else {}
    source_lines = [f"- Granola note ID: `{note_id}`"]
    web_url = note.get("web_url")
    if isinstance(web_url, str) and web_url.strip():
        source_lines.append(f"- Granola URL: {web_url.strip()}")
    calendar_id = calendar_event.get("calendar_event_id")
    if isinstance(calendar_id, str) and calendar_id.strip():
        source_lines.append(f"- Calendar event ID: `{calendar_id.strip()}`")
    parts.append("## Source\n\n" + "\n".join(source_lines))
    return "\n\n".join(parts).strip() + "\n"


def calendar_event_id(note: dict[str, Any]) -> str | None:
    calendar_event = note.get("calendar_event") if isinstance(note.get("calendar_event"), dict) else {}
    value = calendar_event.get("calendar_event_id")
    if isinstance(value, str) and value.strip():
        return value.strip()
    return None


def connect(db_path: Path) -> sqlite3.Connection:
    connection = sqlite3.connect(str(db_path))
    connection.row_factory = sqlite3.Row
    connection.execute("PRAGMA foreign_keys = ON")
    return connection


def ensure_meetings_schema(connection: sqlite3.Connection) -> None:
    row = connection.execute(
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'meetings'"
    ).fetchone()
    if not row:
        raise RuntimeError("Muesli meetings table does not exist. Launch Muesli once before importing.")


def backup_database(db_path: Path) -> Path:
    timestamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    backup_path = db_path.with_name(f"{db_path.name}.backup-before-granola-{timestamp}")
    shutil.copy2(db_path, backup_path)
    for suffix in ("-wal", "-shm"):
        sidecar = Path(f"{db_path}{suffix}")
        if sidecar.exists():
            shutil.copy2(sidecar, Path(f"{backup_path}{suffix}"))
    return backup_path


def import_notes(connection: sqlite3.Connection, notes: list[dict[str, Any]], dry_run: bool) -> ImportStats:
    stats = ImportStats(fetched=len(notes))
    for note in notes:
        note_id = note.get("id")
        if not isinstance(note_id, str) or not note_id.strip():
            stats.failed += 1
            continue

        start = note_start(note)
        raw_transcript = transcript_text(note, start)
        if not raw_transcript.strip():
            stats.skipped_missing_transcript += 1
            continue
        stats.with_transcript += 1

        external_id = f"granola:{note_id.strip()}"
        calendar_id = calendar_event_id(note)
        duplicate_ids = [external_id]
        if calendar_id:
            duplicate_ids.append(calendar_id)
        existing = connection.execute(
            f"SELECT id FROM meetings WHERE calendar_event_id IN ({','.join('?' for _ in duplicate_ids)}) LIMIT 1",
            duplicate_ids,
        ).fetchone()
        if existing:
            stats.skipped_existing += 1
            continue

        end = note_end(note, start)
        duration_seconds = max((end - start).total_seconds(), 0)
        title = note.get("title") if isinstance(note.get("title"), str) and note.get("title").strip() else "Granola meeting"
        notes_markdown = formatted_notes(note)
        word_count = plain_word_count(raw_transcript)

        if not dry_run:
            connection.execute(
                """
                INSERT INTO meetings
                (title, calendar_event_id, start_time, end_time, duration_seconds, raw_transcript, formatted_notes,
                 mic_audio_path, system_audio_path, saved_recording_path, meeting_status, manual_notes, word_count,
                 selected_template_id, selected_template_name, selected_template_kind, selected_template_prompt, source)
                VALUES (?, ?, ?, ?, ?, ?, ?, NULL, NULL, NULL, 'completed', '', ?, 'granola-import', 'Granola Import', 'builtin', NULL, 'granola')
                """,
                (
                    title.strip(),
                calendar_id or external_id,
                    iso_z(start),
                    iso_z(end),
                    duration_seconds,
                    raw_transcript,
                    notes_markdown,
                    word_count,
                ),
            )
        stats.created += 1

    if not dry_run:
        connection.commit()
    return stats


def main() -> int:
    args = parse_args()
    db_path = Path(args.db_path).expanduser()
    if not db_path.exists():
        print(f"Muesli database not found: {db_path}", file=sys.stderr)
        return 2

    if args.input_json:
        notes = load_notes(args.input_json)
    else:
        api_key = os.environ.get(args.api_key_env)
        if not api_key:
            print(f"Set {args.api_key_env} to a Granola API key.", file=sys.stderr)
            return 2
        notes = fetch_notes(api_key, args.page_size, args.created_after, args.created_before, args.limit)

    if args.export_json:
        Path(args.export_json).expanduser().write_text(
            json.dumps({"notes": notes}, indent=2, ensure_ascii=False) + "\n",
            encoding="utf-8",
        )

    backup_path: Path | None = None
    if not args.dry_run and not args.no_backup:
        backup_path = backup_database(db_path)

    with connect(db_path) as connection:
        ensure_meetings_schema(connection)
        stats = import_notes(connection, notes, args.dry_run)

    output = {
        "ok": True,
        "dryRun": args.dry_run,
        "dbPath": str(db_path),
        "backupPath": str(backup_path) if backup_path else None,
        "stats": stats.__dict__,
    }
    print(json.dumps(output, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
