#!/usr/bin/env python3
"""Validate UI-rendering suite results and write an advisory JSON/HTML report."""

import argparse
import datetime as datetime_module
import html
import json
import os
import sys
import math
from pathlib import Path, PurePosixPath
from urllib.parse import quote

SCHEMA_VERSION = 1
SUITES = {"snapshot", "e2e"}
SUITE_STATUSES = {"completed", "harness_error", "skipped"}
IMAGE_STATUSES = {"matched", "changed", "missing_baseline", "incompatible_environment"}
ARTIFACT_NAMES = {"expected", "actual", "diff"}


class ValidationError(ValueError):
    """Raised when a suite result cannot safely become a published report."""


def load_json(path):
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


def artifact_path(value, label):
    if not isinstance(value, str) or not value or len(value) > 1024 or "\\" in value or "\x00" in value:
        raise ValidationError(f"{label} must be a non-empty relative POSIX path")
    candidate = PurePosixPath(value)
    if candidate.is_absolute() or ".." in candidate.parts or any(character in value for character in "\r\n"):
        raise ValidationError(f"{label} must stay under the report directory")
    return value


def validate_result(document, source):
    required = {"schema_version", "suite", "status", "renderer_profile", "cases"}
    allowed = required | {"error"}
    if not isinstance(document, dict) or not required <= set(document) or not set(document) <= allowed:
        raise ValidationError(f"{source} has an unsupported result shape")
    if document["schema_version"] != SCHEMA_VERSION:
        raise ValidationError(f"{source} has unsupported schema_version")
    if document["suite"] not in SUITES or document["status"] not in SUITE_STATUSES:
        raise ValidationError(f"{source} has an unsupported suite or status")
    if not isinstance(document["renderer_profile"], dict) or not json_value(document["renderer_profile"]):
        raise ValidationError(f"{source} renderer_profile must be a JSON object")
    if len(json.dumps(document["renderer_profile"], allow_nan=False)) > 65536:
        raise ValidationError(f"{source} renderer_profile is too large")
    if not isinstance(document["cases"], list):
        raise ValidationError(f"{source} cases must be an array")
    if len(document["cases"]) > 5000:
        raise ValidationError(f"{source} has too many cases")
    is_error = document["status"] in {"harness_error", "skipped"}
    if is_error != ("error" in document):
        raise ValidationError(f"{source} must include error only for skipped or harness_error results")
    if is_error and (not isinstance(document["error"], str) or not document["error"].strip() or len(document["error"]) > 4000):
        raise ValidationError(f"{source} error must be a non-empty string")
    if is_error and document["cases"]:
        raise ValidationError(f"{source} error result must not contain cases")

    cases = []
    identifiers = set()
    for index, case in enumerate(document["cases"]):
        if not isinstance(case, dict) or not {"id", "status"} <= set(case) or not set(case) <= {"id", "status", "artifacts"}:
            raise ValidationError(f"{source} cases[{index}] has an unsupported shape")
        case_id, status = case["id"], case["status"]
        if not isinstance(case_id, str) or not case_id or len(case_id) > 200 or any(character in case_id for character in "\x00\r\n"):
            raise ValidationError(f"{source} cases[{index}].id is invalid")
        if case_id in identifiers or status not in IMAGE_STATUSES:
            raise ValidationError(f"{source} has duplicate case IDs or an invalid image status")
        identifiers.add(case_id)
        normalized = {"id": case_id, "status": status}
        if "artifacts" in case:
            artifacts = case["artifacts"]
            if not isinstance(artifacts, dict) or not artifacts or not set(artifacts) <= ARTIFACT_NAMES:
                raise ValidationError(f"{source} cases[{index}].artifacts is invalid")
            normalized["artifacts"] = {name: artifact_path(value, f"{source} cases[{index}].artifacts.{name}")
                                       for name, value in sorted(artifacts.items())}
        cases.append(normalized)
    return {"schema_version": SCHEMA_VERSION, "suite": document["suite"], "status": document["status"],
            "renderer_profile": document["renderer_profile"], "cases": cases,
            **({"error": document["error"]} if "error" in document else {})}


def build_summary(results):
    results = sorted(results, key=lambda result: result["suite"])
    suite_names = [result["suite"] for result in results]
    if len(suite_names) != len(set(suite_names)):
        raise ValidationError("only one result per suite may be reported")
    counts = {status: 0 for status in sorted(IMAGE_STATUSES)}
    errors = []
    environment_errors = []
    for result in results:
        if result["status"] == "harness_error":
            errors.append({"suite": result["suite"], "error": result["error"]})
        for case in result["cases"]:
            counts[case["status"]] += 1
            if case["status"] == "incompatible_environment":
                environment_errors.append({"suite": result["suite"], "case": case["id"]})
    if errors:
        outcome = "harness_error"
    elif environment_errors:
        outcome = "environment_error"
    elif results and all(result["status"] == "skipped" for result in results):
        outcome = "skipped"
    else:
        outcome = "advisory"
    return {
        "schema_version": SCHEMA_VERSION,
        "generated_at": datetime_module.datetime.now(datetime_module.timezone.utc).isoformat().replace("+00:00", "Z"),
        "outcome": outcome,
        "advisory": outcome == "advisory",
        "counts": {**counts, "errors": len(errors) + len(environment_errors)},
        "harness_errors": errors,
        "environment_errors": environment_errors,
        "suites": results,
    }


def render_html(summary):
    def text(value):
        return html.escape(str(value), quote=True)

    rows = []
    for suite in summary["suites"]:
        if suite["status"] != "completed":
            rows.append(f"<tr><td>{text(suite['suite'])}</td><td colspan=\"3\">{text(suite['status'])}: {text(suite['error'])}</td></tr>")
        for case in suite["cases"]:
            links = " ".join(
                f'<a href="{quote(path, safe="/-._~")}">{text(name)}</a>'
                for name, path in case.get("artifacts", {}).items()) or "—"
            rows.append(f"<tr><td>{text(suite['suite'])}</td><td>{text(case['id'])}</td>"
                        f"<td>{text(case['status'])}</td><td>{links}</td></tr>")
    count_items = " ".join(f"<li>{text(name)}: {text(count)}</li>"
                            for name, count in summary["counts"].items())
    page = """<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Muesli UI rendering report</title><style>
body{font-family:-apple-system,BlinkMacSystemFont,sans-serif;margin:2rem;color:#1d1d1f}table{border-collapse:collapse;width:100%}th,td{border:1px solid #d2d2d7;padding:.5rem;text-align:left}th{background:#f5f5f7}code{background:#f5f5f7;padding:.1rem .25rem}
</style></head><body>
<h1>Muesli UI rendering report</h1>
<p>Outcome: <strong>__OUTCOME__</strong>. Image differences and missing baselines are advisory; harness errors are operational failures.</p>
<ul>__COUNTS__</ul>
<table><thead><tr><th>Suite</th><th>Case</th><th>Status</th><th>Artifacts</th></tr></thead><tbody>__ROWS__</tbody></table>
</body></html>
"""
    return page.replace("__OUTCOME__", text(summary["outcome"])).replace("__COUNTS__", count_items).replace("__ROWS__", "\n".join(rows))


def atomic_write(path, contents):
    temporary = path.with_name(f".{path.name}.tmp")
    temporary.write_text(contents, encoding="utf-8")
    os.replace(temporary, path)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", action="append", required=True, help="one suite result JSON; repeat for each suite")
    parser.add_argument("--output", required=True, help="directory for summary.json and index.html")
    args = parser.parse_args(argv)
    try:
        results = [validate_result(load_json(path), path) for path in args.input]
        summary = build_summary(results)
        output = Path(args.output)
        output.mkdir(parents=True, exist_ok=True)
        atomic_write(output / "summary.json", json.dumps(summary, indent=2, sort_keys=True, allow_nan=False) + "\n")
        atomic_write(output / "index.html", render_html(summary))
    except (OSError, ValidationError, ValueError) as error:
        print(f"ui rendering report: {error}", file=sys.stderr)
        return 2
    print(output / "summary.json")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
