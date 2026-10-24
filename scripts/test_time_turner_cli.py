#!/usr/bin/env python3
"""Exercise a built muesli-cli against an isolated visual catalog.
Usage: python3 scripts/test_time_turner_cli.py /path/to/muesli-cli [archive.mp4]
"""
import hashlib
import json
from pathlib import Path
import shutil
import sqlite3
import struct
import subprocess
import sys
import tempfile
import zlib

cli = str(Path(sys.argv[1]).resolve())
with tempfile.TemporaryDirectory(prefix="muesli-cli-visual-") as directory:
    support = Path(directory)
    root = support / "visual-memory"
    root.mkdir()
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 128, 128, 8, 2, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress((b"\0" + b"\xff\xff\xff" * 128) * 128)) + chunk(b"IEND", b"")
    (root / "still.png").write_bytes(png)
    database = root / "catalog.sqlite"
    db = sqlite3.connect(database)
    db.executescript("CREATE TABLE evidence(id TEXT PRIMARY KEY,kind TEXT,meeting_id INTEGER,captured REAL,body TEXT); CREATE VIRTUAL TABLE evidence_search USING fts5(id UNINDEXED,text);")
    def insert(identifier, captured, app, bundle, path="still.png", frame=None):
        body = dict(id=identifier, kind="moment", capturedAt=captured-978307200, source=app+" · Plan", bundleID=bundle, text="roadmap evidence", path=path, duration=0, meetingOffset=0, bytes=0)
        body.update(captureCompletedAt=captured-978307200+0.25, pixelWidth=128, pixelHeight=128,
                    appName=app, windowTitle="Plan")
        if frame is not None:
            body["frameIndex"] = frame
        db.execute("INSERT INTO evidence VALUES(?,?,?,?,?)", (identifier, "moment", None, captured, json.dumps(body)))
        db.execute("INSERT INTO evidence_search VALUES(?,?)", (identifier, body["source"]+" "+body["text"]))
    insert("wanted", 1000.125, "ChatGPT", "com.openai.chat")
    insert("wanted-tie", 1000.125, "ChatGPT", "com.openai.chat")
    insert("newer", 1001, "Editor", "editor")
    insert("missing-media", 999, "Missing", "missing", "absent.heic")
    insert("unsafe", 998, "Unsafe", "unsafe", "../outside.png")
    if len(sys.argv) > 2:
        shutil.copyfile(sys.argv[2], root / "archive.mp4")
        insert("archived", 997, "Archive", "archive", "archive.mp4", 12)
    db.commit()
    db.close()
    before = hashlib.sha256(database.read_bytes()).digest()
    def run(*args, code=0):
        result = subprocess.run([cli, "time-turner", *args, "--support-dir", str(support)], capture_output=True, text=True)
        assert result.returncode == code, (args, result.returncode, result.stdout, result.stderr)
        payload = json.loads(result.stdout)
        assert payload["ok"] == (code == 0), payload
        return payload
    data = run("search", "--query", "roadmap", "--app", "chatgpt", "--limit", "1", "--from", "1970-01-01T00:16:40Z", "--until", "1970-01-01T00:16:41Z")["data"]
    assert [item["id"] for item in data] == ["wanted"]
    assert data[0]["capturedAtUnix"] == 1000.125
    first = run("search", "--app", "ChatGPT", "--limit", "1")
    assert first["meta"]["hasMore"]
    second = run("search", "--app", "ChatGPT", "--limit", "1", "--cursor", first["meta"]["nextCursor"])
    assert [row["id"] for row in second["data"]] == ["wanted-tie"]
    assert not second["meta"]["hasMore"]
    assert "nextCursor" not in second["meta"]
    run("search", "--cursor", "invalid", code=4)
    run("search", "--from", "2026-10-25T09:00:00", code=4)
    assert len(run("search", "--app", "COM.OPENAI.CHAT")["data"]) == 2
    assert run("search", "--app", "Chat")["data"] == []
    assert run("search", "--query", '" OR *')["data"] == []
    run("search", "--from", "yesterday", code=4)
    run("search", "--limit", "1001", code=4)
    run("search", "--from", "1970-01-02T00:00:00Z", "--until", "1970-01-01T00:00:00Z", code=4)
    output = support / "capture.png"
    result = run("get", "wanted", "--output", str(output))["data"]
    assert result["screenshotPath"] == str(output)
    assert result["appName"] == "ChatGPT" and result["windowTitle"] == "Plan"
    assert result["captureCompletedAtUnix"] == 1000.375
    assert result["pixelWidth"] == 128 and result["pixelHeight"] == 128
    assert struct.unpack(">II", output.read_bytes()[16:24]) == (128, 128)
    run("get", "wanted", "--output", str(output), code=4)
    run("get", "unknown", code=3)
    assert not run("get", "missing-media")["data"]["mediaExists"]
    run("get", "missing-media", "--output", str(support / "missing.png"), code=3)
    run("get", "unsafe", code=6)
    if len(sys.argv) > 2:
        archive_output = support / "frame.png"
        assert run("get", "archived", "--output", str(archive_output))["data"]["archiveFrameIndex"] == 12
        assert archive_output.read_bytes().startswith(b"\x89PNG")
    assert hashlib.sha256(database.read_bytes()).digest() == before, "CLI mutated catalog"
    print("PASS: Time Turner CLI search/filter/validation/read-only/get/PNG export" + ("/archive frame" if len(sys.argv)>2 else ""))
