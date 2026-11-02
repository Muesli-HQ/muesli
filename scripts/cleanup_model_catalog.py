#!/usr/bin/env python3
"""Maintain docs/models/cleanup-models.json, the signed cleanup model catalog.

The app reads this file (and its detached .sig) from GitHub Pages to offer
cleanup model updates without an app release. See docs/cleanup-model-updates.md.

  add    Pin a Hugging Face revision as the newest release of a slot. File sizes
         and SHA-256 digests are taken from the Hub (LFS) or hashed after download.
  check  Validate the catalog the way the app does, and optionally confirm every
         pinned file against the Hub (--remote).
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CATALOG = ROOT / "docs" / "models" / "cleanup-models.json"

# Must mirror CleanupModelSlot.all in CleanupModelRelease.swift.
SLOTS = {
    "qwen35-postproc-v4": ("mlx-qwen3.5", "model.safetensors"),
    "qwen35-2b-cleanup-v12": ("mlx-qwen3.5", "model.safetensors"),
    "lfm25-cleanup-v12": ("gguf-lfm2.5", "lfm25-muesli-v12-Q4_K_M.gguf"),
}
SKIPPED_FILES = {".gitattributes", "README.md"}
SAFE_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")


def hub_tree(repo: str, revision: str) -> list[dict]:
    with urllib.request.urlopen(f"https://huggingface.co/api/models/{repo}/tree/{revision}", timeout=60) as response:
        return json.load(response)


def hub_sha256(repo: str, revision: str, path: str) -> str:
    digest = hashlib.sha256()
    url = f"https://huggingface.co/{repo}/resolve/{revision}/{path}?download=1"
    with urllib.request.urlopen(url, timeout=300) as response:
        while chunk := response.read(1 << 20):
            digest.update(chunk)
    return digest.hexdigest()


def hub_files(repo: str, revision: str, model_file: str) -> list[dict]:
    files = []
    for entry in hub_tree(repo, revision):
        if entry.get("type") != "file" or entry["path"] in SKIPPED_FILES or "/" in entry["path"]:
            continue
        lfs = entry.get("lfs") or {}
        sha = lfs.get("oid") or hub_sha256(repo, revision, entry["path"])
        files.append({"path": entry["path"], "size": entry["size"], "sha256": sha})
    files.sort(key=lambda f: (f["path"] != model_file, f["path"]))
    if not files or files[0]["path"] != model_file:
        sys.exit(f"{repo}@{revision} has no {model_file}")
    return files


def validate(release: dict) -> list[str]:
    problems = []
    slot = SLOTS.get(release.get("slot"))
    if not slot:
        return [f"unknown slot {release.get('slot')!r}"]
    runtime, model_file = slot
    name = f"{release['slot']} {release.get('version')}"
    if release.get("runtime") != runtime:
        problems.append(f"{name}: runtime must be {runtime}")
    if not isinstance(release.get("sequence"), int) or release["sequence"] <= 0 or not release.get("version"):
        problems.append(f"{name}: needs a version and a positive integer sequence")
    repo = release.get("repo", "")
    if not repo.startswith("Muesli-HQ/") or repo.count("/") != 1:
        problems.append(f"{name}: repo must be under Muesli-HQ/")
    if not re.fullmatch(r"[0-9a-f]{40}", release.get("revision", "")):
        problems.append(f"{name}: revision must be a full commit hash")
    minimum = release.get("minimum_app_version")
    if minimum is not None and not re.fullmatch(r"\d+(\.\d+)*", minimum):
        problems.append(f"{name}: minimum_app_version must be numeric, e.g. 0.9.2 (the app ignores other suffixes)")
    files = release.get("files") or []
    if not files or files[0].get("path") != model_file:
        problems.append(f"{name}: first file must be {model_file}")
    seen = set()
    for f in files:
        path = f.get("path", "")
        if not SAFE_NAME.match(path) or path in seen:
            problems.append(f"{name}: bad or duplicate file path {path!r}")
        seen.add(path)
        if not isinstance(f.get("size"), int) or f["size"] <= 0 or not re.fullmatch(r"[0-9a-f]{64}", f.get("sha256", "")):
            problems.append(f"{name}: bad size or sha256 for {path}")
    return problems


def load() -> dict:
    return json.loads(CATALOG.read_text()) if CATALOG.exists() else {"schema": 1, "releases": []}


def save(catalog: dict) -> None:
    CATALOG.parent.mkdir(parents=True, exist_ok=True)
    CATALOG.write_text(json.dumps(catalog, indent=2) + "\n")
    signature = CATALOG.with_name(CATALOG.name + ".sig")
    if signature.exists():
        signature.unlink()
        print(f"Removed stale {signature.relative_to(ROOT)}; re-sign with scripts/sign_cleanup_model_catalog.sh")


def command_add(args: argparse.Namespace) -> None:
    runtime, model_file = SLOTS[args.slot]
    catalog = load()
    existing = [r for r in catalog["releases"] if r["slot"] == args.slot]
    if any(r["sequence"] >= args.sequence for r in existing):
        sys.exit(f"sequence {args.sequence} must exceed every published {args.slot} release")
    release = {
        "slot": args.slot,
        "version": args.version,
        "sequence": args.sequence,
        "runtime": runtime,
        "repo": args.repo,
        "revision": args.revision,
        "files": hub_files(args.repo, args.revision, model_file),
    }
    if args.notes:
        release["notes"] = args.notes
    if args.minimum_app_version:
        release["minimum_app_version"] = args.minimum_app_version
    if problems := validate(release):
        sys.exit("\n".join(problems))
    # The app only uses the newest valid release per slot; older entries are history.
    catalog["releases"] = [r for r in catalog["releases"] if r["slot"] != args.slot] + [release]
    save(catalog)
    print(f"Added {args.slot} {args.version} ({args.repo}@{args.revision[:12]})")


def command_check(args: argparse.Namespace) -> None:
    catalog = load()
    problems = [] if catalog.get("schema") == 1 else ["schema must be 1"]
    for release in catalog.get("releases", []):
        problems += validate(release)
        if args.remote and not problems:
            remote = {f["path"]: f for f in hub_files(release["repo"], release["revision"], release["files"][0]["path"])}
            for f in release["files"]:
                if remote.get(f["path"]) != f:
                    problems.append(f"{release['slot']} {release['version']}: {f['path']} differs from the Hub")
    if problems:
        sys.exit("\n".join(problems))
    print(f"{CATALOG.relative_to(ROOT)}: {len(catalog.get('releases', []))} release(s) OK")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    add = sub.add_parser("add")
    add.add_argument("slot", choices=sorted(SLOTS))
    add.add_argument("version", help="display version, e.g. v15")
    add.add_argument("sequence", type=int, help="monotonic ordering key, e.g. 15")
    add.add_argument("repo", help="Muesli-HQ/<repo>")
    add.add_argument("revision", help="full 40-character commit hash")
    add.add_argument("--notes", help="one sentence shown in the Models page")
    add.add_argument("--minimum-app-version", help="oldest app version that can run this build")
    add.set_defaults(func=command_add)
    check = sub.add_parser("check")
    check.add_argument("--remote", action="store_true", help="also verify every file against the Hub")
    check.set_defaults(func=command_check)
    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
