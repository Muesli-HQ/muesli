#!/usr/bin/env bash
# Purpose: Monitor Muesli process memory health during meeting recording
# Created: 2026-05-26
#
# Usage: ./scripts/monitor-memory.sh [duration_sec] [interval_sec]
#   duration_sec  Total monitoring window in seconds (default: 180)
#   interval_sec  Seconds between samples (default: 15)
#
# Output: live table + /tmp/muesli-memory-YYYYMMDD-HHMMSS.tsv
#
# What it tracks:
#   Footprint      Physical RAM used by the process
#   Float Total    Combined size of all Swift [Float] arrays (audio history buffers)
#   Largest Float  Item count of the biggest [Float] array (should stay ≤ ~150K)
#   AG Nodes       SwiftUI AttributeGraph node count (should stay flat)
#   Tracking Dicts SwiftUI @Observable subscription dictionaries

DURATION=${1:-180}
INTERVAL=${2:-15}

# ── Find process ─────────────────────────────────────────────────────────────
PID=""
for NAME in MuesliDev Muesli; do
    PID=$(pgrep -x "$NAME" 2>/dev/null | head -1)
    [[ -n "$PID" ]] && break
done

if [[ -z "$PID" ]]; then
    echo "Error: no Muesli process found. Launch the app first." >&2
    exit 1
fi

APP_NAME=$(ps -p "$PID" -o comm= 2>/dev/null || echo "Muesli")
LOG_FILE="/tmp/muesli-memory-$(date +%Y%m%d-%H%M%S).tsv"

echo "Monitoring $APP_NAME  PID=$PID  duration=${DURATION}s  interval=${INTERVAL}s"
echo "Log → $LOG_FILE"
echo ""

# ── Header ───────────────────────────────────────────────────────────────────
printf "%-10s  %-10s  %-10s  %-12s  %-20s  %-10s  %-14s\n" \
    "Time" "Footprint" "Peak" "Float Total" "Largest Float(n)" "AG Nodes" "Tracking Dicts"
printf "%-10s  %-10s  %-10s  %-12s  %-20s  %-10s  %-14s\n" \
    "----------" "----------" "----------" "------------" "--------------------" "----------" "--------------"

printf "timestamp\tfootprint_mb\tpeak_mb\tfloat_total_mb\tlargest_float_items\tag_nodes\ttracking_dicts\n" \
    > "$LOG_FILE"

# ── Helpers ───────────────────────────────────────────────────────────────────
footprint_color() {
    # Green if rate < 2 MB/min, yellow < 10, red otherwise
    local rate=$1
    local abs
    abs=$(awk "BEGIN{v=$rate; print (v<0?-v:v)}")
    if   awk "BEGIN{exit !($abs < 2)}";  then printf "\033[32m"   # green
    elif awk "BEGIN{exit !($abs < 10)}"; then printf "\033[33m"   # yellow
    else                                      printf "\033[31m"   # red
    fi
}
reset_color() { printf "\033[0m"; }

verdict() {
    local rate=$1
    local abs
    abs=$(awk "BEGIN{v=$rate; print (v<0?-v:v)}")
    if   awk "BEGIN{exit !($abs < 2)}";  then echo "✓ STABLE (< 2 MB/min)"
    elif awk "BEGIN{exit !($abs < 10)}"; then echo "⚠ SLOW GROWTH ($rate MB/min)"
    else                                      echo "✗ LEAKING ($rate MB/min)"
    fi
}

float_verdict() {
    local largest=$1
    if ! [[ "$largest" =~ ^[0-9]+$ ]]; then echo "?"; return; fi
    if   awk "BEGIN{exit !($largest < 160000)}"; then echo "✓ bounded (~${largest})"
    elif awk "BEGIN{exit !($largest < 400000)}"; then echo "⚠ elevated (~${largest})"
    else                                               echo "✗ unbounded (~${largest})"
    fi
}

# ── Sample loop ───────────────────────────────────────────────────────────────
SAMPLES=0
START_EPOCH=$SECONDS
FIRST_FP=""
LAST_FP=""
FIRST_LARGEST=""
LAST_LARGEST=""

while [[ $((SECONDS - START_EPOCH)) -lt $DURATION ]]; do
    TS=$(date +%H:%M:%S)

    # Physical footprint (vmmap — fast, ~0.5s)
    VMMAP=$(vmmap --summary "$PID" 2>/dev/null)
    FP=$(printf "%s" "$VMMAP"   | awk '/Physical footprint:/ && !/peak/ {gsub(/M/,"",$3); print $3}')
    PEAK=$(printf "%s" "$VMMAP" | awk '/Physical footprint \(peak\):/ {gsub(/M/,"",$4); print $4}')

    # Heap snapshot (heap — slow, 2-4s, but single invocation for most metrics)
    HEAP=$(heap "$PID" -sortBySize 2>/dev/null)

    FLOAT_BYTES=$(printf "%s" "$HEAP" | awk '/_ContiguousArrayStorage<Swift\.Float>/{b+=$2} END{print b+0}')
    FLOAT_MB=$(awk "BEGIN{printf \"%.1f\", $FLOAT_BYTES/1048576}")

    AG_NODES=$(printf "%s" "$HEAP" | awk '/non-object in zone AttributeGraph/{c+=$1} END{print c+0}')

    TRACKING=$(printf "%s" "$HEAP" | awk '/DictionaryStorage.*AnyTrackedValue/{c+=$1} END{print c+0}')

    # Largest float array by item count (heap -addresses — slower, ~3-5s)
    LARGEST=$(heap "$PID" -addresses "Swift._ContiguousArrayStorage<Swift.Float>" 2>/dev/null \
        | grep "^0x" \
        | sort -t'(' -k2 -rn \
        | head -1 \
        | grep -oE 'item count: [0-9]+' \
        | grep -oE '[0-9]+')
    LARGEST=${LARGEST:-"?"}

    # Track bounds
    [[ -z "$FIRST_FP" ]]      && FIRST_FP="$FP"
    [[ -z "$FIRST_LARGEST" ]] && FIRST_LARGEST="$LARGEST"
    LAST_FP="$FP"
    LAST_LARGEST="$LARGEST"

    # Print row
    printf "%-10s  %-10s  %-10s  %-12s  %-20s  %-10s  %-14s\n" \
        "$TS" "${FP}M" "${PEAK}M" "${FLOAT_MB}M" "$LARGEST" "$AG_NODES" "$TRACKING"

    # TSV row
    printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
        "$TS" "$FP" "$PEAK" "$FLOAT_MB" "$LARGEST" "$AG_NODES" "$TRACKING" \
        >> "$LOG_FILE"

    SAMPLES=$((SAMPLES + 1))

    # Check process still alive
    kill -0 "$PID" 2>/dev/null || { echo ""; echo "Process $PID exited."; break; }

    sleep "$INTERVAL"
done

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════════════"
printf " Summary — %s samples over %ds\n" "$SAMPLES" "$DURATION"
echo "════════════════════════════════════════════════════"

if [[ -n "$FIRST_FP" && -n "$LAST_FP" && "$FIRST_FP" != "$LAST_FP" ]]; then
    GROWTH=$(awk "BEGIN{printf \"%.1f\", $LAST_FP - $FIRST_FP}")
    RATE=$(awk "BEGIN{printf \"%.2f\", ($LAST_FP - $FIRST_FP) * 60 / $DURATION}")
    printf " Footprint:  %sM → %sM  (%sMB growth,  %s MB/min)\n" \
        "$FIRST_FP" "$LAST_FP" "$GROWTH" "$RATE"
    printf " Verdict:    %s\n" "$(verdict "$RATE")"
else
    echo " Footprint:  ${FIRST_FP}M → ${LAST_FP}M"
fi

echo ""

if [[ "$FIRST_LARGEST" =~ ^[0-9]+$ && "$LAST_LARGEST" =~ ^[0-9]+$ ]]; then
    LARGEST_GROWTH=$((LAST_LARGEST - FIRST_LARGEST))
    printf " Float buf:  %s → %s items  (%s items growth)\n" \
        "$FIRST_LARGEST" "$LAST_LARGEST" "$LARGEST_GROWTH"
    printf " Float buf:  %s\n" "$(float_verdict "$LAST_LARGEST")"
fi

echo ""
echo " TSV log:    $LOG_FILE"
echo "════════════════════════════════════════════════════"
