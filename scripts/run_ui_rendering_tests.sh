#!/usr/bin/env bash
# Credential-free entry point for the advisory macOS UI-rendering suites.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
profile="$root/ci/ui-rendering-profile.json"
reporter="$root/scripts/ui_rendering_report.py"
output="$root/visual-results"
trusted_baseline_root="${MUESLI_TRUSTED_BASELINE_ROOT:-}"
trusted_baseline_revision="${MUESLI_TRUSTED_BASELINE_REVISION:-}"
trusted_baseline_id="${MUESLI_TRUSTED_BASELINE_ID:-}"
expected_cases="${MUESLI_UI_EXPECTED_CASES:-}"
timeout_seconds="${MUESLI_UI_SUITE_TIMEOUT_SECONDS:-1800}"

usage() {
  cat >&2 <<'EOF'
usage: scripts/run_ui_rendering_tests.sh [--output DIRECTORY] \
  [--trusted-baseline-root DIRECTORY --trusted-baseline-revision SHA --trusted-baseline-id ID] \
  [--expected-cases FILE] [--timeout-seconds SECONDS]

The dispatcher must provide an absolute external read-only baseline root, its
pinned full SHA, and an expected-case contract before a verified profile runs.
This script does not use Git, network credentials, artifact uploads, or PR APIs.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output|--trusted-baseline-root|--trusted-baseline-revision|--trusted-baseline-id|--expected-cases|--timeout-seconds)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      case "$1" in
        --output) output="$2" ;;
        --trusted-baseline-root) trusted_baseline_root="$2" ;;
        --trusted-baseline-revision) trusted_baseline_revision="$2" ;;
        --trusted-baseline-id) trusted_baseline_id="$2" ;;
        --expected-cases) expected_cases="$2" ;;
        --timeout-seconds) timeout_seconds="$2" ;;
      esac
      shift 2
      ;;
    -h|--help) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
done
[[ "$timeout_seconds" =~ ^[0-9]+$ && "$timeout_seconds" -ge 60 && "$timeout_seconds" -le 7200 ]] || {
  echo "--timeout-seconds must be between 60 and 7200" >&2; exit 2;
}

mkdir -p "$output/raw"
output="$(cd "$output" && pwd)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/muesli-ui-rendering.XXXXXX")"
active_pid=""

stop_active_tree() {
  [[ -n "$active_pid" ]] || return 0
  kill -0 "$active_pid" 2>/dev/null || return 0
  # The Python launcher calls setsid before exec, so the suite PID is also its
  # process-group ID. Signal the full group to contain forked descendants.
  kill -TERM -- "-$active_pid" 2>/dev/null || kill -TERM "$active_pid" 2>/dev/null || true
  local deadline=$((SECONDS + 5))
  while kill -0 "$active_pid" 2>/dev/null && [[ "$SECONDS" -lt "$deadline" ]]; do sleep 1; done
  if kill -0 "$active_pid" 2>/dev/null; then
    kill -KILL -- "-$active_pid" 2>/dev/null || kill -KILL "$active_pid" 2>/dev/null || true
  fi
  wait "$active_pid" 2>/dev/null || true
}
cleanup() {
  local code=$?
  stop_active_tree
  rm -rf "$scratch"
  trap - EXIT INT TERM
  exit "$code"
}
trap cleanup EXIT INT TERM

renderer_profile='{}'
baseline_provenance='{}'
write_result() {
  local suite="$1" status="$2" error="${3:-}"
  SUITE="$suite" STATUS="$status" ERROR="$error" PROFILE="$renderer_profile" PROVENANCE="$baseline_provenance" OUTPUT="$output/raw/$suite.json" python3 - <<'PY'
import json
import os
from pathlib import Path

result = {"schema_version": 1, "suite": os.environ["SUITE"], "status": os.environ["STATUS"],
          "renderer_profile": json.loads(os.environ["PROFILE"]), "baseline_provenance": json.loads(os.environ["PROVENANCE"]),
          "expected_cases": [], "cases": []}
if result["status"] in {"harness_error", "skipped"}:
    result["error"] = os.environ["ERROR"] or "No diagnostic was recorded."
Path(os.environ["OUTPUT"]).write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
PY
}

write_report() {
  local -a arguments=(--input "$output/raw/snapshot.json" --input "$output/raw/e2e.json" --output "$output")
  if [[ $# -gt 0 ]]; then arguments+=("$@"); fi
  if ! python3 "$reporter" "${arguments[@]}"; then
    write_result snapshot harness_error "The runner could not validate the snapshot suite result."
    write_result e2e harness_error "The runner could not validate the E2E suite result."
    python3 "$reporter" --input "$output/raw/snapshot.json" --input "$output/raw/e2e.json" --output "$output" || true
    return 1
  fi
}

preflight="$(PROFILE="$profile" SCRATCH="$scratch" python3 - <<'PY'
import json
import os
import platform
import shutil
import subprocess
from pathlib import Path

try:
    profile = json.load(open(os.environ["PROFILE"], encoding="utf-8"))
except (OSError, json.JSONDecodeError) as error:
    print(f"ERROR:renderer profile is unreadable: {error}")
    raise SystemExit()
required = {"schema_version", "enabled", "verification", "reason", "baseline_id", "expected"}
if not isinstance(profile, dict) or set(profile) != required or profile.get("schema_version") != 1:
    print("ERROR:renderer profile has an unsupported schema")
elif profile.get("enabled") is not True or profile.get("verification") != "verified":
    print("ERROR:" + (profile.get("reason") or "renderer profile is not verified and enabled"))
elif platform.system() != "Darwin" or platform.machine() != "arm64":
    print("ERROR:UI rendering suites require Apple Silicon macOS")
elif not all(shutil.which(tool) for tool in ("xcodebuild", "swift", "xcodegen", "screencapture")):
    print("ERROR:Xcode, Swift, XcodeGen, and screencapture must be available")
elif not isinstance(profile.get("baseline_id"), str) or not profile["baseline_id"] or not all(c.isalnum() or c in ".-_" for c in profile["baseline_id"]):
    print("ERROR:verified renderer profiles must define a safe baseline_id")
elif not isinstance(profile.get("expected"), dict) or any(value is None for value in profile["expected"].values()):
    print("ERROR:verified renderer profiles must define every expected value")
else:
    try:
        def command(*arguments):
            return subprocess.check_output(arguments, text=True, stderr=subprocess.STDOUT).strip()
        xcode = command("xcodebuild", "-version").splitlines()
        source = Path(os.environ["SCRATCH"]) / "renderer-profile.swift"
        source.write_text('''import AppKit
import Foundation
let screen = NSScreen.main
let values: [String: Any] = ["scale": screen?.backingScaleFactor ?? 0, "color_space": screen?.colorSpace?.localizedName ?? "unknown", "locale": Locale.current.identifier, "calendar": Locale.current.calendar.identifier, "time_zone": TimeZone.current.identifier]
let data = try! JSONSerialization.data(withJSONObject: values, options: [.sortedKeys])
print(String(data: data, encoding: .utf8)!)
''', encoding="utf-8")
        appkit = json.loads(subprocess.check_output(["swift", str(source)], text=True, stderr=subprocess.STDOUT))
        observed = {"architecture": platform.machine(), "macos_version": command("sw_vers", "-productVersion"),
                    "macos_build": command("sw_vers", "-buildVersion"), "xcode_version": xcode[0].removeprefix("Xcode "),
                    "xcode_build": xcode[1].removeprefix("Build version "),
                    "display": json.loads(command("system_profiler", "SPDisplaysDataType", "-json")),
                    "scale": appkit["scale"], "color_space": appkit["color_space"], "locale": appkit["locale"],
                    "calendar": appkit["calendar"], "time_zone": appkit["time_zone"],
                    "appearance": command("defaults", "read", "-g", "AppleInterfaceStyle") if subprocess.call(["defaults", "read", "-g", "AppleInterfaceStyle"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL) == 0 else "Light"}
        if set(profile["expected"]) != set(observed):
            print("ERROR:verified renderer profile has incomplete expected keys")
        elif [key for key, value in profile["expected"].items() if observed[key] != value]:
            print("ERROR:renderer profile mismatch: " + ", ".join(key for key, value in profile["expected"].items() if observed[key] != value))
        else:
            print("OK:" + json.dumps(observed, sort_keys=True, separators=(",", ":")))
    except (OSError, subprocess.CalledProcessError, IndexError, json.JSONDecodeError) as error:
        print(f"ERROR:could not observe renderer profile: {error}")
PY
)"

if [[ "$preflight" != OK:* ]]; then
  renderer_profile="$(PROFILE="$profile" python3 -c 'import json, os; print(json.dumps({"verification": json.load(open(os.environ["PROFILE"], encoding="utf-8")).get("verification", "unknown")}))')"
  write_result snapshot harness_error "${preflight#ERROR:}"
  write_result e2e harness_error "${preflight#ERROR:}"
  write_report || true
  echo "UI rendering preflight failed: ${preflight#ERROR:}" >&2
  exit 78
fi
renderer_profile="${preflight#OK:}"
printf '%s\n' "$renderer_profile" > "$scratch/renderer-profile.json"

contract_error="$(ROOT="$root" BASELINE_ROOT="$trusted_baseline_root" BASELINE_REVISION="$trusted_baseline_revision" BASELINE_ID="$trusted_baseline_id" CASES="$expected_cases" PROFILE="$profile" SCRATCH="$scratch" python3 - <<'PY'
import json
import os
import re
from pathlib import Path

root, baseline, cases = Path(os.environ["ROOT"]).resolve(), Path(os.environ["BASELINE_ROOT"]), Path(os.environ["CASES"])
revision = os.environ["BASELINE_REVISION"]
baseline_id = os.environ["BASELINE_ID"]
if not str(baseline) or not baseline.is_absolute() or not baseline.is_dir() or os.access(baseline, os.W_OK):
    print("trusted baseline root must be an absolute existing read-only directory")
elif root == baseline.resolve() or root in baseline.resolve().parents:
    print("trusted baseline root must be external to the PR checkout")
elif not re.fullmatch(r"[0-9a-f]{40}", revision):
    print("trusted baseline revision must be a full lowercase SHA")
elif not re.fullmatch(r"[A-Za-z0-9._-]+", baseline_id):
    print("trusted baseline ID must use only letters, numbers, dots, underscores, or hyphens")
elif not str(cases) or not cases.is_absolute() or not cases.is_file():
    print("expected case contract must be an absolute file supplied by the dispatcher")
elif root == cases.resolve() or root in cases.resolve().parents:
    print("expected case contract must be external to the PR checkout")
else:
    try:
        document = json.loads(cases.read_text(encoding="utf-8"))
        suites = document["suites"]
        if set(document) != {"schema_version", "suites"} or document["schema_version"] != 1 or set(suites) != {"snapshot", "e2e"}:
            raise ValueError("expected case contract must define snapshot and e2e")
        if any(not isinstance(ids, list) or not ids or len(ids) != len(set(ids)) or any(not isinstance(case, str) or not case for case in ids) for ids in suites.values()):
            raise ValueError("expected case contract has invalid case IDs")
        profile = json.loads(Path(os.environ["PROFILE"]).read_text(encoding="utf-8"))
        if profile["baseline_id"] != baseline_id:
            raise ValueError("trusted baseline ID does not match the verified renderer profile")
        provenance = {"root": str(baseline.resolve()), "revision": revision, "baseline_id": baseline_id}
        Path(os.environ["SCRATCH"], "baseline-provenance.json").write_text(json.dumps(provenance, sort_keys=True), encoding="utf-8")
        print("")
    except (OSError, ValueError, KeyError, json.JSONDecodeError) as error:
        print(f"invalid expected case contract: {error}")
PY
)"
if [[ -n "$contract_error" ]]; then
  write_result snapshot harness_error "$contract_error"
  write_result e2e harness_error "$contract_error"
  write_report || true
  echo "UI rendering preflight failed: $contract_error" >&2
  exit 78
fi
baseline_provenance="$(cat "$scratch/baseline-provenance.json")"

if ! screencapture -x "$scratch/preflight.png" || [[ ! -s "$scratch/preflight.png" ]]; then
  write_result snapshot harness_error "Screenshot authorization preflight failed."
  write_result e2e harness_error "Screenshot authorization preflight failed."
  write_report || true
  echo "UI rendering preflight failed: screenshot authorization is unavailable." >&2
  exit 78
fi

run_suite() {
  local suite="$1" default_command="$2" command_variable="MUESLI_UI_${3}_COMMAND"
  local command="${!command_variable:-$default_command}" result="$output/raw/$suite.json" log="$output/$suite.log" code=0 timed_out=false
  export MUESLI_VISUAL_TESTS=1 MUESLI_VISUAL_FIXTURE_DIR="$root/native/VisualTesting/Fixtures"
  export MUESLI_VISUAL_BASELINE_ROOT="$trusted_baseline_root" MUESLI_VISUAL_BASELINE_DIR="$trusted_baseline_root/$trusted_baseline_id/$suite"
  export MUESLI_VISUAL_BASELINE_REVISION="$trusted_baseline_revision" MUESLI_VISUAL_BASELINE_PROVENANCE_JSON="$baseline_provenance"
  export MUESLI_VISUAL_RENDERER_PROFILE_JSON="$renderer_profile" MUESLI_VISUAL_RENDERER_PROFILE="$renderer_profile" MUESLI_VISUAL_EXPECTED_CASES_FILE="$expected_cases"
  export MUESLI_VISUAL_EXPECTED_CASES_JSON="$(SUITE="$suite" CASES="$expected_cases" python3 -c 'import json, os; print(json.dumps(json.load(open(os.environ["CASES"]))["suites"][os.environ["SUITE"]], separators=(",", ":")))')"
  export MUESLI_VISUAL_DATA_DIR="$scratch/data-$suite" MUESLI_VISUAL_ARTIFACT_DIR="$output/cases/$suite" MUESLI_UI_RENDERING_RESULT="$result"
  export MUESLI_SWIFTPM_SCRATCH_PATH="$scratch/swiftpm-$suite" MUESLI_XCODEBUILD_DERIVED_DATA="$scratch/derived-data-$suite"
  export MUESLI_VISUAL_SCENARIO_ID="${MUESLI_VISUAL_SCENARIO_ID:-recording-indicator-picker-dark}" MUESLI_VISUAL_WINDOW_ID="${MUESLI_VISUAL_WINDOW_ID:-window.visual-test}"
  mkdir -p "$MUESLI_VISUAL_DATA_DIR" "$MUESLI_VISUAL_ARTIFACT_DIR"
  echo "Running $suite UI rendering suite from $root (timeout ${timeout_seconds}s)"
  python3 -c 'import os, sys; os.setsid(); os.chdir(sys.argv[1]); os.execvp("bash", ["bash", "-c", sys.argv[2]])' \
    "$root" "$command" >"$log" 2>&1 &
  active_pid="$!"
  local deadline=$((SECONDS + timeout_seconds))
  while kill -0 "$active_pid" 2>/dev/null; do
    if [[ "$SECONDS" -ge "$deadline" ]]; then timed_out=true; stop_active_tree; break; fi
    sleep 1
  done
  if wait "$active_pid"; then :; else code=$?; fi
  active_pid=""
  if [[ "$timed_out" == true ]]; then
    write_result "$suite" harness_error "$suite suite exceeded ${timeout_seconds} seconds; see $suite.log."
  elif [[ "$code" -ne 0 ]]; then
    write_result "$suite" harness_error "$suite suite exited with status $code; see $suite.log."
  elif [[ ! -s "$result" ]]; then
    write_result "$suite" harness_error "$suite suite did not write MUESLI_UI_RENDERING_RESULT."
  fi
}

run_suite snapshot 'swift test --package-path native/MuesliNative --scratch-path "$MUESLI_SWIFTPM_SCRATCH_PATH" --filter MuesliSnapshotTests' SNAPSHOT
run_suite e2e 'cd native/MuesliXcode && xcodegen generate && xcodebuild test -project MuesliXcode.xcodeproj -scheme MuesliVisualTests -destination "platform=macOS" -derivedDataPath "$MUESLI_XCODEBUILD_DERIVED_DATA"' E2E

report_contract=(--expected-renderer-profile "$scratch/renderer-profile.json" --expected-cases "$expected_cases" --trusted-baseline-root "$trusted_baseline_root" --trusted-baseline-revision "$trusted_baseline_revision" --trusted-baseline-id "$trusted_baseline_id")
if ! write_report "${report_contract[@]}"; then exit 1; fi
outcome="$(SUMMARY="$output/summary.json" python3 -c 'import json, os; print(json.load(open(os.environ["SUMMARY"], encoding="utf-8"))["outcome"])')"
[[ "$outcome" == advisory ]] || { echo "UI rendering harness did not complete successfully: $outcome" >&2; exit 1; }
echo "UI rendering report completed: $output/summary.json"
