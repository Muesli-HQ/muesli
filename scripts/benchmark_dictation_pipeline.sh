#!/usr/bin/env bash
set -euo pipefail
# Compare the actual baseline/current manager and recorder sources, optimized.
# Physical IO, routing, stream consumption, and SDK delivery use synthetic stand-ins.
# This measures app pipeline overhead, not physical mic/model/network/editor timing.
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"
baseline="${1:-origin/main}"
iterations="${2:-1000}"
output="${3:-$(mktemp -d /private/tmp/muesli-pipeline-benchmark.XXXXXX)}"
mkdir -p "$output/baseline"
base_sha="$(git rev-parse "$baseline")"
echo "$base_sha" > "$output/baseline-sha.txt"
app="native/MuesliNative/Sources/MuesliNativeApp"
files=(DictationAudioSessionManager.swift AppScopedDictationRecorder.swift RouteAwareDictationRecorder.swift)
old=(); current=()
for file in "${files[@]}"; do
  git show "$base_sha:$app/$file" > "$output/baseline/$file"
  old+=("$output/baseline/$file")
  current+=("$app/$file")
done
common=(-O -whole-module-optimization -module-cache-path "$output/module-cache" scripts/benchmark_dictation_pipeline_support.swift)
swiftc "${common[@]}" "${old[@]}" -o "$output/baseline-benchmark"
swiftc "${common[@]}" -D WATCHDOG_CANDIDATE -D CAPTURE_HEALTH_CANDIDATE "${current[@]}" "$app/DictationStartupWatchdog.swift" "$app/DictationCaptureHealth.swift" -o "$output/candidate-benchmark"
for round in 1 2 3; do
  if [[ "$round" == 2 ]]; then order=(candidate baseline); else order=(baseline candidate); fi
  for variant in "${order[@]}"; do
    "$output/$variant-benchmark" "$iterations" > "$output/$variant-$round.json" 2> "$output/$variant-$round.trace"
  done
done
python3 - "$output" <<'PY'
import json, pathlib, sys
root=pathlib.Path(sys.argv[1])
print('Baseline:', (root/'baseline-sha.txt').read_text().strip())
for n in range(1,4):
    before=json.loads((root/f'baseline-{n}.json').read_text())
    after=json.loads((root/f'candidate-{n}.json').read_text())
    print(f'Round {n}:')
    for metric in ['request_to_first_audio','per_512_sample_buffer','stop_to_event']:
        a,b=before[metric],after[metric]
        print(f'  {metric}: median {a["median_us"]:.3f} -> {b["median_us"]:.3f} us; p95 {a["p95_us"]:.3f} -> {b["p95_us"]:.3f} us')
print('Artifacts:',root)
PY
