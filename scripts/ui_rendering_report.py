#!/usr/bin/env python3
"""Validate bounded UI-rendering results and write an advisory JSON/HTML report."""

import argparse
import datetime as datetime_module
import html
import json
import math
import os
import re
import sys
from pathlib import Path, PurePosixPath
from urllib.parse import quote

SCHEMA_VERSION = 1
SUITES = {"snapshot", "e2e"}
SUITE_STATUSES = {"completed", "harness_error", "skipped"}
IMAGE_STATUSES = {"matched", "changed", "missing_baseline", "incompatible_environment"}
ARTIFACT_NAMES = {"expected", "actual", "diff"}
RENDERER_PROFILE_KEYS = {
    "architecture", "macos_version", "macos_build", "xcode_version", "xcode_build", "display",
    "scale", "color_space", "locale", "calendar", "time_zone", "appearance",
}
SHA = re.compile(r"[0-9a-f]{40}\Z")


class ValidationError(ValueError):
    """Raised when untrusted suite output cannot become a published report."""


def strict_json(path):
    def reject_duplicate_keys(pairs):
        document = {}
        for key, value in pairs:
            if key in document:
                raise ValidationError(f"duplicate JSON key: {key!r}")
            document[key] = value
        return document

    try:
        return json.loads(Path(path).read_text(encoding="utf-8"), object_pairs_hook=reject_duplicate_keys,
                          parse_constant=lambda value: (_ for _ in ()).throw(ValidationError(f"invalid JSON constant: {value}")))
    except (OSError, ValueError) as error:
        raise ValidationError(f"cannot read {path}: {error}") from error


def json_value(value):
    if value is None or isinstance(value, (bool, int, str)):
        return True
    if isinstance(value, float):
        return math.isfinite(value)
    if isinstance(value, list):
        return all(json_value(item) for item in value)
    if isinstance(value, dict):
        return all(isinstance(key, str) and json_value(item) for key, item in value.items())
    return False


def nonempty(value):
    if isinstance(value, str):
        return bool(value.strip())
    if isinstance(value, (dict, list)):
        return bool(value) and all(nonempty(item) for item in (value.values() if isinstance(value, dict) else value))
    return value is not None


def absolute_directory(path, label):
    if not isinstance(path, str) or not path:
        raise ValidationError(f"{label} must be an absolute directory")
    candidate = Path(path)
    if not candidate.is_absolute() or not candidate.is_dir():
        raise ValidationError(f"{label} must be an existing absolute directory")
    return candidate.resolve()


def artifact_path(value, label):
    if not isinstance(value, str) or not value or len(value) > 1024 or "\\" in value or "\x00" in value:
        raise ValidationError(f"{label} must be a non-empty relative POSIX path")
    candidate = PurePosixPath(value)
    if candidate.is_absolute() or ".." in candidate.parts or any(character in value for character in "\r\n"):
        raise ValidationError(f"{label} must stay under the report directory")
    return value


def existing_artifact(root, relative_path, label):
    candidate = (root / relative_path).resolve()
    if root not in candidate.parents or not candidate.is_file():
        raise ValidationError(f"{label} does not name an existing report artifact")


def validate_profile(profile, source):
    if not isinstance(profile, dict) or set(profile) != RENDERER_PROFILE_KEYS or not json_value(profile):
        raise ValidationError(f"{source} renderer_profile is incomplete")
    if not all(nonempty(value) for value in profile.values()):
        raise ValidationError(f"{source} renderer_profile contains empty values")
    if len(json.dumps(profile, allow_nan=False)) > 65536:
        raise ValidationError(f"{source} renderer_profile is too large")
    return profile


def validate_provenance(provenance, source):
    expected = {"root", "revision", "baseline_id"}
    if not isinstance(provenance, dict) or set(provenance) != expected:
        raise ValidationError(f"{source} baseline_provenance is incomplete")
    root, revision, baseline_id = provenance["root"], provenance["revision"], provenance["baseline_id"]
    if not isinstance(root, str) or not Path(root).is_absolute() or not SHA.fullmatch(revision or ""):
        raise ValidationError(f"{source} baseline_provenance is invalid")
    if not isinstance(baseline_id, str) or not re.fullmatch(r"[A-Za-z0-9._-]+", baseline_id):
        raise ValidationError(f"{source} baseline_provenance has an invalid baseline_id")
    return provenance


def validate_case_ids(case_ids, source):
    if not isinstance(case_ids, list) or not case_ids or len(case_ids) > 5000:
        raise ValidationError(f"{source} expected_cases must be a non-empty bounded array")
    if any(not isinstance(case_id, str) or not case_id or len(case_id) > 200 or any(c in case_id for c in "\x00\r\n")
           for case_id in case_ids) or len(set(case_ids)) != len(case_ids):
        raise ValidationError(f"{source} expected_cases contains invalid or duplicate IDs")
    return case_ids


def validate_result(document, source, artifact_root, expected_profile=None, expected_cases=None, expected_provenance=None):
    required = {"schema_version", "suite", "status", "renderer_profile", "cases", "expected_cases", "baseline_provenance"}
    allowed = required | {"error"}
    if not isinstance(document, dict) or not required <= set(document) or not set(document) <= allowed:
        raise ValidationError(f"{source} has an unsupported result shape")
    if document["schema_version"] != SCHEMA_VERSION or document["suite"] not in SUITES or document["status"] not in SUITE_STATUSES:
        raise ValidationError(f"{source} has an unsupported schema, suite, or status")
    if not isinstance(document["cases"], list) or len(document["cases"]) > 5000:
        raise ValidationError(f"{source} cases must be a bounded array")

    completed = document["status"] == "completed"
    error_status = not completed
    if error_status != ("error" in document):
        raise ValidationError(f"{source} must include error only for skipped or harness_error results")
    if error_status:
        if document["cases"] or document["expected_cases"]:
            raise ValidationError(f"{source} error result must not contain cases")
        if not isinstance(document["error"], str) or not document["error"].strip() or len(document["error"]) > 4000:
            raise ValidationError(f"{source} error must be a non-empty string")
        return document

    profile = validate_profile(document["renderer_profile"], source)
    provenance = validate_provenance(document["baseline_provenance"], source)
    declared_cases = validate_case_ids(document["expected_cases"], source)
    if expected_profile is not None and profile != expected_profile:
        raise ValidationError(f"{source} renderer_profile does not match the runner observation")
    if expected_cases is not None and declared_cases != expected_cases:
        raise ValidationError(f"{source} expected_cases does not match the runner contract")
    if expected_provenance is not None and provenance != expected_provenance:
        raise ValidationError(f"{source} baseline_provenance does not match the dispatcher contract")

    cases = []
    identifiers = set()
    for index, case in enumerate(document["cases"]):
        if not isinstance(case, dict) or not {"id", "status", "artifacts"} <= set(case) or set(case) != {"id", "status", "artifacts"}:
            raise ValidationError(f"{source} cases[{index}] has an unsupported shape")
        case_id, status, artifacts = case["id"], case["status"], case["artifacts"]
        if not isinstance(case_id, str) or not case_id or len(case_id) > 200 or any(character in case_id for character in "\x00\r\n"):
            raise ValidationError(f"{source} cases[{index}].id is invalid")
        if case_id in identifiers or status not in IMAGE_STATUSES:
            raise ValidationError(f"{source} has duplicate case IDs or an invalid image status")
        if not isinstance(artifacts, dict) or not artifacts or not set(artifacts) <= ARTIFACT_NAMES:
            raise ValidationError(f"{source} cases[{index}].artifacts is invalid")
        normalized_artifacts = {name: artifact_path(value, f"{source} cases[{index}].artifacts.{name}")
                                for name, value in sorted(artifacts.items())}
        for name, relative_path in normalized_artifacts.items():
            existing_artifact(artifact_root, relative_path, f"{source} cases[{index}].artifacts.{name}")
        if status in {"matched", "changed"} and "expected" not in normalized_artifacts:
            raise ValidationError(f"{source} cases[{index}] needs an expected artifact for {status}")
        identifiers.add(case_id)
        cases.append({"id": case_id, "status": status, "artifacts": normalized_artifacts})
    if not cases or identifiers != set(declared_cases):
        raise ValidationError(f"{source} completed result cases do not match expected_cases")
    return {"schema_version": SCHEMA_VERSION, "suite": document["suite"], "status": document["status"],
            "renderer_profile": profile, "baseline_provenance": provenance, "expected_cases": declared_cases,
            "cases": cases}


def load_case_contract(path):
    document = strict_json(path)
    if not isinstance(document, dict) or set(document) != {"schema_version", "suites"} or document["schema_version"] != SCHEMA_VERSION:
        raise ValidationError("expected case contract has an unsupported shape")
    suites = document["suites"]
    if not isinstance(suites, dict) or set(suites) != SUITES:
        raise ValidationError("expected case contract must define snapshot and e2e")
    return {suite: validate_case_ids(case_ids, f"expected case contract {suite}") for suite, case_ids in suites.items()}


def build_summary(results):
    results = sorted(results, key=lambda result: result["suite"])
    suite_names = {result["suite"] for result in results}
    if suite_names != SUITES or len(results) != len(SUITES):
        raise ValidationError("exactly one snapshot and one e2e result are required")
    counts = {status: 0 for status in sorted(IMAGE_STATUSES)}
    errors, environment_errors = [], []
    provenance = []
    for result in results:
        if result["status"] == "harness_error":
            errors.append({"suite": result["suite"], "error": result["error"]})
        if result["status"] == "completed":
            provenance.append(result["baseline_provenance"])
        for case in result["cases"]:
            counts[case["status"]] += 1
            if case["status"] == "incompatible_environment":
                environment_errors.append({"suite": result["suite"], "case": case["id"]})
    if errors:
        outcome = "harness_error"
    elif environment_errors:
        outcome = "environment_error"
    elif any(result["status"] == "skipped" for result in results):
        outcome = "skipped"
    else:
        outcome = "advisory"
    return {"schema_version": SCHEMA_VERSION,
            "generated_at": datetime_module.datetime.now(datetime_module.timezone.utc).isoformat().replace("+00:00", "Z"),
            "outcome": outcome, "advisory": outcome == "advisory",
            "counts": {**counts, "errors": len(errors) + len(environment_errors)},
            "harness_errors": errors, "environment_errors": environment_errors,
            "baseline_provenance": provenance, "suites": results}


def render_html(summary):
    def text(value):
        return html.escape(str(value), quote=True)
    rows = []
    for suite in summary["suites"]:
        if suite["status"] != "completed":
            rows.append(f"<tr><td>{text(suite['suite'])}</td><td colspan=\"3\">{text(suite['status'])}: {text(suite['error'])}</td></tr>")
        for case in suite["cases"]:
            links = " ".join(f'<a href="{quote(path, safe="/-._~")}">{text(name)}</a>'
                              for name, path in case["artifacts"].items())
            rows.append(f"<tr><td>{text(suite['suite'])}</td><td>{text(case['id'])}</td><td>{text(case['status'])}</td><td>{links}</td></tr>")
    counts = " ".join(f"<li>{text(name)}: {text(count)}</li>" for name, count in summary["counts"].items())
    return """<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>Muesli UI rendering report</title></head><body><h1>Muesli UI rendering report</h1><p>Outcome: <strong>__OUTCOME__</strong>. Image differences and missing baselines are advisory; harness errors are operational failures.</p><ul>__COUNTS__</ul><table><thead><tr><th>Suite</th><th>Case</th><th>Status</th><th>Artifacts</th></tr></thead><tbody>__ROWS__</tbody></table></body></html>""".replace("__OUTCOME__", text(summary["outcome"])).replace("__COUNTS__", counts).replace("__ROWS__", "\n".join(rows))


def atomic_write(path, contents):
    temporary = path.with_name(f".{path.name}.tmp")
    temporary.write_text(contents, encoding="utf-8")
    os.replace(temporary, path)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", action="append", required=True, help="one suite result JSON; repeat for each suite")
    parser.add_argument("--output", required=True, help="directory for summary.json and index.html")
    parser.add_argument("--expected-renderer-profile", help="runner-observed renderer profile JSON")
    parser.add_argument("--expected-cases", help="trusted expected-case contract JSON")
    parser.add_argument("--trusted-baseline-root", help="external read-only trusted baseline root")
    parser.add_argument("--trusted-baseline-revision", help="pinned trusted baseline revision")
    args = parser.parse_args(argv)
    try:
        output = Path(args.output).resolve()
        output.mkdir(parents=True, exist_ok=True)
        if bool(args.trusted_baseline_root) != bool(args.trusted_baseline_revision):
            raise ValidationError("trusted baseline root and revision must be provided together")
        expected_provenance = None
        if args.trusted_baseline_root:
            root = absolute_directory(args.trusted_baseline_root, "trusted baseline root")
            if not SHA.fullmatch(args.trusted_baseline_revision):
                raise ValidationError("trusted baseline revision must be a full lowercase SHA")
            expected_provenance = {"root": str(root), "revision": args.trusted_baseline_revision, "baseline_id": None}
        expected_profile = strict_json(args.expected_renderer_profile) if args.expected_renderer_profile else None
        if expected_profile is not None:
            expected_profile = validate_profile(expected_profile, "expected renderer profile")
        expected_cases = load_case_contract(args.expected_cases) if args.expected_cases else None
        results = []
        for path in args.input:
            raw = strict_json(path)
            suite = raw.get("suite") if isinstance(raw, dict) else None
            provenance = expected_provenance
            if provenance is not None and isinstance(raw, dict) and isinstance(raw.get("baseline_provenance"), dict):
                provenance = {**provenance, "baseline_id": raw["baseline_provenance"].get("baseline_id")}
            results.append(validate_result(raw, path, output, expected_profile,
                                           expected_cases.get(suite) if expected_cases and suite in SUITES else None,
                                           provenance))
        summary = build_summary(results)
        atomic_write(output / "summary.json", json.dumps(summary, indent=2, sort_keys=True, allow_nan=False) + "\n")
        atomic_write(output / "index.html", render_html(summary))
    except (OSError, ValidationError, ValueError) as error:
        print(f"ui rendering report: {error}", file=sys.stderr)
        return 2
    print(output / "summary.json")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
