#!/usr/bin/env python3
"""Retain three main release snapshots, only after verifying their replacement."""

import argparse
from datetime import datetime
import json
import os
import re
import subprocess

NAMESPACE = "ci-release-v1-"
KEY_PATTERN = re.compile(r"ci-release-v1-[0-9a-f]{64}-[0-9a-f]{40}")
MAIN_REF = "refs/heads/main"
KEEP = 3


def timestamp(value):
    result = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if result.tzinfo is None:
        raise ValueError("Cache timestamp must include a timezone")
    return result


def cleanup_plan(entries, replacement_key):
    """Fail closed; ignore every namespace/ref other than our main snapshots."""
    if not KEY_PATTERN.fullmatch(replacement_key):
        raise ValueError("Invalid replacement cache key")
    scoped = []
    seen = set()
    for entry in entries:
        if entry.get("ref") != MAIN_REF or not KEY_PATTERN.fullmatch(entry.get("key", "")):
            continue
        cache_id = entry["id"]
        if type(cache_id) is not int or cache_id <= 0 or cache_id in seen:
            raise ValueError("Invalid or duplicate cache ID")
        seen.add(cache_id)
        if type(entry["size_in_bytes"]) is not int or entry["size_in_bytes"] <= 0:
            raise ValueError("Cache must be fully populated")
        scoped.append((timestamp(entry["created_at"]), cache_id, entry))
    replacements = [row for row in scoped if row[2]["key"] == replacement_key]
    if not replacements:
        raise ValueError("Replacement cache not visible; refusing all deletion")
    replacement_time = max(row[0] for row in replacements)
    scoped.sort(key=lambda row: (row[0], row[1]), reverse=True)
    keep_ids = {row[1] for row in scoped[:KEEP]} | {row[1] for row in replacements}
    # A late/older job may not delete snapshots newer than its own replacement.
    return [row[2] for row in scoped if row[1] not in keep_ids and row[0] < replacement_time]


def trusted_context(env):
    if (env.get("GITHUB_ACTIONS") != "true" or env.get("GITHUB_EVENT_NAME") != "push"
            or env.get("GITHUB_REF") != MAIN_REF or env.get("CACHE_SAVE_OUTCOME") != "success"
            or env.get("CACHE_DISABLED") == "true"):
        raise ValueError("Cleanup requires an enabled successful main-push cache save")
    repo = env.get("GITHUB_REPOSITORY", "")
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repo):
        raise ValueError("Invalid repository")
    key = env.get("CACHE_KEY", "")
    sha = env.get("GITHUB_SHA", "")
    if (not re.fullmatch(r"[0-9a-f]{40}", sha) or not KEY_PATTERN.fullmatch(key)
            or not key.endswith("-" + sha)):
        raise ValueError("Replacement must belong to this main commit")
    return repo, key


def list_caches(repo):
    # Read every page BEFORE deleting: deleting while paginating can skip entries.
    pages = json.loads(subprocess.check_output([
        "gh", "api", "--method", "GET", f"repos/{repo}/actions/caches",
        "--paginate", "--slurp", "-f", f"ref={MAIN_REF}", "-f", f"key={NAMESPACE}",
        "-f", "per_page=100", "-f", "sort=created_at", "-f", "direction=desc",
    ], text=True, timeout=60))
    return [entry for page in pages for entry in page["actions_caches"]]


def delete_cache(repo, cache_id):
    subprocess.run(["gh", "api", "--method", "DELETE",
                    f"repos/{repo}/actions/caches/{cache_id}"], check=True, timeout=30)


def cleanup(env, delete=False):
    repo, key = trusted_context(env)
    victims = cleanup_plan(list_caches(repo), key)
    deleted = []
    for entry in victims:
        print(f"{'Candidate' if delete else 'Would delete'} main release cache {entry['id']}: {entry['key']}")
        if delete:
            # Revalidate the replacement and target before EACH exact-ID deletion.
            # API failures, eviction of the replacement, or malformed metadata stop cleanup.
            current = cleanup_plan(list_caches(repo), key)
            if not any(item["id"] == entry["id"] and item["key"] == entry["key"] for item in current):
                continue
            delete_cache(repo, entry["id"])
            deleted.append(entry["id"])
            print(f"Deleted rebuildable main release cache {entry['id']}")
    print(f"Release cache cleanup: {len(deleted)} deleted; retention target {KEEP} snapshots.")
    return deleted


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--delete", action="store_true", help="Apply deletions; otherwise only print the plan")
    args = parser.parse_args()
    cleanup(os.environ, delete=args.delete)


if __name__ == "__main__":
    main()
