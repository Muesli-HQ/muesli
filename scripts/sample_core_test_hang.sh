#!/usr/bin/env bash
# Emit a stack sample before the CI job timeout if core tests remain running.
set -u

delay="${MUESLI_CORE_SAMPLE_DELAY_SECONDS:-300}"
interval="${MUESLI_CORE_SAMPLE_POLL_SECONDS:-10}"

while :; do
  pid="$(pgrep -f '[/]swiftpm-testing-helper' | head -n 1 || true)"
  if [[ -n "$pid" ]]; then
    break
  fi
  sleep "$interval"
done

sleep "$delay"
if kill -0 "$pid" 2>/dev/null; then
  echo "::group::Core test process sample after ${delay}s (pid ${pid})"
  sample "$pid" 5 2>&1 || echo "Unable to sample core test process ${pid}"
  echo "::endgroup::"
fi
