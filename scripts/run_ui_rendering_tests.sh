#!/usr/bin/env bash
# Credential-free entry point for the advisory macOS UI-rendering suites.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
profile="$root/ci/ui-rendering-profile.json"
reporter="$root/scripts/ui_rendering_report.py"
output="$root/visual-results"

usage() {
  cat >&2 <<'EOF'
usage: scripts/run_ui_rendering_tests.sh [--output DIRECTORY]

Runs only on a verified macOS renderer profile. This script does not use Git,
network credentials, artifact uploads, or pull-request APIs.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      output="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done

mkdir -p "$output/raw"
output="$(cd "$output" && pwd)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/muesli-ui-rendering.XXXXXX")"
active_pid=""

cleanup() {
  local code=$?
  if [[ -n "$active_pid" ]] && kill -0 "$active_pid" 2>/dev/null; then
    # The suites are launched in their own session where setsid is available.
    kill -TERM -- "-$active_pid" 2>/dev/null || kill -TERM "$active_pid" 2>/dev/null || true
    wait "$active_pid" 2>/dev/null || true
  fi
  rm -rf "$scratch"
  exit "$code"
}
trap cleanup EXIT INT TERM

renderer_profile='{}'
write_result() {
  local suite="$1" status="$2" error="${3:-}"
  SUITE="$suite" STATUS="$status" ERROR="$error" PROFILE="$renderer_profile" OUTPUT="$output/raw/$suite.json" python3 - <<'PY'
import json
import os
from pathlib import Path

result = {
    "schema_version": 1,
    "suite": os.environ["SUITE"],
    "status": os.environ["STATUS"],
    "renderer_profile": json.loads(os.environ["PROFILE"]),
    "cases": [],
}
if result["status"] in {"harness_error", "skipped"}:
    result["error"] = os.environ["ERROR"] or "No diagnostic was recorded."
Path(os.environ["OUTPUT"]).write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
PY
}

write_report() {
  if ! python3 "$reporter" --input "$output/raw/snapshot.json" --input "$output/raw/e2e.json" --output "$output"; then
    # A malformed suite result is a harness failure. Replace it with a schema-valid
    # fallback so publishers always have a bounded, structured result to inspect.
    write_result snapshot harness_error "The runner could not validate the snapshot suite result."
    write_result e2e harness_error "The runner could not validate the E2E suite result."
    python3 "$reporter" --input "$output/raw/snapshot.json" --input "$output/raw/e2e.json" --output "$output" || true
    return 1
  fi
}

preflight_error="$(PROFILE="$profile" SCRATCH="$scratch" python3 - <<'PY'
import json
import os
import platform
import shutil
import subprocess
import sys
from pathlib import Path

try:
    profile = json.load(open(os.environ["PROFILE"], encoding="utf-8"))
except (OSError, json.JSONDecodeError) as error:
    print(f"renderer profile is unreadable: {error}")
    raise SystemExit(0)

required = {"schema_version", "enabled", "verification", "reason", "baseline_id", "expected"}
if not isinstance(profile, dict) or set(profile) != required or profile.get("schema_version") != 1:
    print("renderer profile has an unsupported schema")
elif profile.get("enabled") is not True or profile.get("verification") != "verified":
    print(profile.get("reason") or "renderer profile is not verified and enabled")
elif not isinstance(profile.get("baseline_id"), str) or not profile["baseline_id"] or any(character not in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-" for character in profile["baseline_id"]):
    print("verified renderer profiles must define a safe baseline_id")
elif platform.system() != "Darwin":
    print("UI rendering suites require macOS")
elif platform.machine() != "arm64":
    print(f"UI rendering suites require arm64, observed {platform.machine()!r}")
elif not shutil.which("xcodebuild") or not shutil.which("swift") or not shutil.which("screencapture") or not shutil.which("xcodegen"):
    print("Xcode, Swift, XcodeGen, and screencapture must be available")
elif not isinstance(profile.get("expected"), dict) or any(value is None for value in profile["expected"].values()):
    print("verified renderer profiles must define every expected value")
else:
    # Keep the observed data in results. The profile deliberately compares only
    # fields a verified host has recorded; this repository does not invent them.
    def command(*arguments):
        return subprocess.check_output(arguments, text=True, stderr=subprocess.STDOUT).strip()
    try:
        xcode = command("xcodebuild", "-version").splitlines()
        appkit_probe = '''
import AppKit
import Foundation
let screen = NSScreen.main
let values: [String: Any] = [
  "scale": screen?.backingScaleFactor ?? 0,
  "color_space": screen?.colorSpace?.localizedName ?? "unknown",
  "locale": Locale.current.identifier,
  "calendar": Locale.current.calendar.identifier,
  "time_zone": TimeZone.current.identifier
]
let data = try! JSONSerialization.data(withJSONObject: values, options: [.sortedKeys])
print(String(data: data, encoding: .utf8)!)
'''
        appkit_source = Path(os.environ["SCRATCH"]) / "renderer-profile.swift"
        appkit_source.write_text(appkit_probe, encoding="utf-8")
        appkit = json.loads(subprocess.check_output(["swift", str(appkit_source)], text=True,
                                                    stderr=subprocess.STDOUT))
        observed = {
            "baseline_id": profile["baseline_id"],
            "architecture": platform.machine(),
            "macos_version": command("sw_vers", "-productVersion"),
            "macos_build": command("sw_vers", "-buildVersion"),
            "xcode_version": xcode[0].removeprefix("Xcode "),
            "xcode_build": xcode[1].removeprefix("Build version "),
            "display": json.loads(command("system_profiler", "SPDisplaysDataType", "-json")),
            "scale": appkit["scale"],
            "color_space": appkit["color_space"],
            "locale": appkit["locale"],
            "calendar": appkit["calendar"],
            "time_zone": appkit["time_zone"],
            "appearance": command("defaults", "read", "-g", "AppleInterfaceStyle") if subprocess.call(["defaults", "read", "-g", "AppleInterfaceStyle"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL) == 0 else "Light",
        }
    except (OSError, subprocess.CalledProcessError, IndexError, json.JSONDecodeError) as error:
        print(f"could not observe renderer profile: {error}")
    else:
        mismatches = [key for key, expected in profile["expected"].items() if observed.get(key) != expected]
        if mismatches:
            print("renderer profile mismatch: " + ", ".join(mismatches))
        else:
            print(json.dumps(observed, sort_keys=True))
PY
)"

if [[ "$preflight_error" != \{* ]]; then
  renderer_profile="$(PROFILE="$profile" python3 -c 'import json, os; print(json.dumps({"verification": json.load(open(os.environ["PROFILE"], encoding="utf-8")).get("verification", "unknown")}))')"
  write_result snapshot harness_error "$preflight_error"
  write_result e2e harness_error "$preflight_error"
  write_report || true
  echo "UI rendering preflight failed: $preflight_error" >&2
  exit 78
fi
renderer_profile="$preflight_error"
baseline_id="$(PROFILE="$profile" python3 -c 'import json, os; print(json.load(open(os.environ["PROFILE"], encoding="utf-8"))["baseline_id"])')"
if ! screencapture -x "$scratch/preflight.png" || [[ ! -s "$scratch/preflight.png" ]]; then
  write_result snapshot harness_error "Screenshot authorization preflight failed."
  write_result e2e harness_error "Screenshot authorization preflight failed."
  write_report || true
  echo "UI rendering preflight failed: screenshot authorization is unavailable." >&2
  exit 78
fi

run_suite() {
  local suite="$1" default_command="$2" command_variable="MUESLI_UI_${3}_COMMAND"
  local command="${!command_variable:-$default_command}"
  local result="$output/raw/$suite.json"
  local log="$output/$suite.log"
  local code=0

  export MUESLI_VISUAL_TESTS=1
  export MUESLI_VISUAL_FIXTURE_DIR="$root/native/VisualTesting/Fixtures"
  export MUESLI_VISUAL_BASELINE_DIR="$root/native/VisualTesting/Baselines/$baseline_id/$suite"
  export MUESLI_VISUAL_DATA_DIR="$scratch/data-$suite"
  export MUESLI_VISUAL_ARTIFACT_DIR="$output/cases/$suite"
  export MUESLI_UI_RENDERING_RESULT="$result"
  export MUESLI_SWIFTPM_SCRATCH_PATH="$scratch/swiftpm-$suite"
  export MUESLI_XCODEBUILD_DERIVED_DATA="$scratch/derived-data-$suite"
  export MUESLI_VISUAL_SCENARIO_ID="${MUESLI_VISUAL_SCENARIO_ID:-recording-indicator-picker-dark}"
  export MUESLI_VISUAL_WINDOW_ID="${MUESLI_VISUAL_WINDOW_ID:-window.visual-test}"
  mkdir -p "$MUESLI_VISUAL_DATA_DIR" "$MUESLI_VISUAL_ARTIFACT_DIR"

  echo "Running $suite UI rendering suite"
  if command -v setsid >/dev/null 2>&1; then
    setsid bash -lc "$command" >"$log" 2>&1 &
  else
    bash -lc "$command" >"$log" 2>&1 &
  fi
  active_pid="$!"
  if wait "$active_pid"; then
    :
  else
    code=$?
  fi
  active_pid=""
  if [[ "$code" -ne 0 ]]; then
    write_result "$suite" harness_error "$suite suite exited with status $code; see $suite.log."
  elif [[ ! -s "$result" ]]; then
    write_result "$suite" harness_error "$suite suite did not write MUESLI_UI_RENDERING_RESULT."
  fi
}

run_suite snapshot 'swift test --package-path native/MuesliNative --scratch-path "$MUESLI_SWIFTPM_SCRATCH_PATH" --filter MuesliSnapshotTests' SNAPSHOT
run_suite e2e 'cd native/MuesliXcode && xcodegen generate && xcodebuild test -project MuesliXcode.xcodeproj -scheme MuesliVisualTests -destination "platform=macOS" -derivedDataPath "$MUESLI_XCODEBUILD_DERIVED_DATA"' E2E

if ! write_report; then
  exit 1
fi

outcome="$(SUMMARY="$output/summary.json" python3 -c 'import json, os; print(json.load(open(os.environ["SUMMARY"], encoding="utf-8"))["outcome"])')"
if [[ "$outcome" != "advisory" ]]; then
  echo "UI rendering harness did not complete successfully: $outcome" >&2
  exit 1
fi

echo "UI rendering report completed: $output/summary.json"
