#!/usr/bin/env python3
"""Classify a complete, versioned changed-file record for UI rendering tests."""

import argparse
import fnmatch
import json
import sys
from pathlib import PurePosixPath

SCHEMA_VERSION = 1
VALID_STATUSES = {"added", "modified", "deleted", "renamed", "copied"}


class ValidationError(ValueError):
    """Raised for input which a trusted dispatcher must not classify."""


def read_json(path):
    def reject_duplicate_keys(pairs):
        document = {}
        for key, value in pairs:
            if key in document:
                raise ValidationError(f"duplicate JSON key: {key!r}")
            document[key] = value
        return document

    try:
        with (sys.stdin if path == "-" else open(path, encoding="utf-8")) as source:
            return json.load(source, object_pairs_hook=reject_duplicate_keys,
                             parse_constant=lambda value: (_ for _ in ()).throw(ValidationError(f"invalid JSON constant: {value}")))
    except (OSError, ValueError) as error:
        raise ValidationError(f"invalid JSON: {error}") from error


def validate_path(path, field):
    if not isinstance(path, str) or not path or "\x00" in path or "\\" in path:
        raise ValidationError(f"{field} must be a non-empty POSIX repository path")
    candidate = PurePosixPath(path)
    if candidate.is_absolute() or path.startswith("./") or ".." in candidate.parts:
        raise ValidationError(f"{field} must stay inside the repository")
    if any(character in path for character in "\r\n"):
        raise ValidationError(f"{field} must not contain a line break")
    return path


def validate_changes(document):
    if not isinstance(document, dict) or set(document) != {"schema_version", "complete", "changes"}:
        raise ValidationError("input must contain only schema_version, complete, and changes")
    if document["schema_version"] != SCHEMA_VERSION:
        raise ValidationError(f"unsupported input schema_version: {document['schema_version']!r}")
    if document["complete"] is not True:
        raise ValidationError("input must declare complete: true")
    changes = document["changes"]
    if not isinstance(changes, list):
        raise ValidationError("changes must be an array")

    normalized = []
    for index, change in enumerate(changes):
        if not isinstance(change, dict) or not isinstance(change.get("status"), str):
            raise ValidationError(f"changes[{index}] must have a string status")
        status = change["status"]
        if status not in VALID_STATUSES:
            raise ValidationError(f"changes[{index}].status is not supported: {status!r}")
        expected = {"status", "path", "old_path"} if status in {"renamed", "copied"} else {"status", "path"}
        if set(change) != expected:
            raise ValidationError(f"changes[{index}] has fields incompatible with {status}")
        record = {"status": status, "path": validate_path(change["path"], f"changes[{index}].path")}
        if "old_path" in expected:
            record["old_path"] = validate_path(change["old_path"], f"changes[{index}].old_path")
        normalized.append(record)
    return normalized


def validate_policy(policy):
    if not isinstance(policy, dict) or set(policy) != {"schema_version", "description", "categories"}:
        raise ValidationError("policy must contain only schema_version, description, and categories")
    if policy["schema_version"] != SCHEMA_VERSION:
        raise ValidationError(f"unsupported policy schema_version: {policy['schema_version']!r}")
    if not isinstance(policy["description"], str) or not policy["description"].strip():
        raise ValidationError("policy description must be a non-empty string")
    categories = policy["categories"]
    if not isinstance(categories, dict) or not categories:
        raise ValidationError("policy categories must be a non-empty object")
    validated = {}
    for category, patterns in categories.items():
        if not isinstance(category, str) or not category or not isinstance(patterns, list) or not patterns:
            raise ValidationError("each policy category must have one or more patterns")
        if any(not isinstance(pattern, str) or not pattern or pattern.startswith("/") for pattern in patterns):
            raise ValidationError(f"policy category {category!r} contains an invalid pattern")
        validated[category] = patterns
    return validated


def categories_for(path, policy):
    return sorted(category for category, patterns in policy.items()
                  if any(fnmatch.fnmatchcase(path, pattern) for pattern in patterns))


def classify(changes, policy, policy_schema_version=SCHEMA_VERSION):
    matched_changes = []
    unmatched_paths = []
    for index, change in enumerate(changes):
        paths = [("path", change["path"])]
        if "old_path" in change:
            paths.append(("old_path", change["old_path"]))
        matches = {field: categories_for(path, policy) for field, path in paths}
        categories = sorted({category for match in matches.values() for category in match})
        if categories:
            matched_changes.append({"index": index, "status": change["status"],
                                    "paths": {field: path for field, path in paths},
                                    "categories": categories})
        else:
            unmatched_paths.extend(path for _, path in paths)
    eligible = bool(matched_changes)
    return {
        "schema_version": SCHEMA_VERSION,
        "policy_schema_version": policy_schema_version,
        "changed_file_count": len(changes),
        "eligible": eligible,
        "decision": "run" if eligible else "skip",
        "matched_changes": matched_changes,
        "unmatched_paths": sorted(set(unmatched_paths)),
    }


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", default="-", help="versioned diff JSON file, or - for stdin")
    parser.add_argument("--policy", default=str(PurePosixPath(__file__).with_name("ui_rendering_paths.json")),
                        help="trusted policy JSON (pin this to the default branch in automation)")
    args = parser.parse_args(argv)
    try:
        changes = validate_changes(read_json(args.input))
        policy_document = read_json(args.policy)
        policy = validate_policy(policy_document)
        result = classify(changes, policy, policy_document["schema_version"])
    except ValidationError as error:
        print(f"ui rendering classifier: {error}", file=sys.stderr)
        return 2
    print(json.dumps(result, sort_keys=True, separators=(",", ":"), allow_nan=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
