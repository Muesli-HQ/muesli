#!/usr/bin/env bash
set -euo pipefail
# Launch a *quit* Debug Dev C with a one-shot fault. Never reset data, change
# microphone permissions, alter CoreAudio, or create persistent preferences.
mode="${1:---help}"
case "$mode" in
  mic-startup|streaming|clear) ;;
  --help|-h)
    cat <<'EOF'
Quit Dev C normally, then run:
  ./scripts/dev-dictation-fault.sh mic-startup
    Next dictation waits on the capture queue; the 3s advisory warning appears.
    Expect Connecting, Keep Waiting / Cancel Dictation, and no recovery audio.
    Cancel the attempt; after cleanup the next take is normal.
  ./scripts/dev-dictation-fault.sh streaming
    Enable local buffered live dictation and use hands-free toggle mode
    in an editor without an app-specific formatting rule.
    Speak a disposable test sentence, wait for live words, then stop.
    Expect one failed recording with partial text in Dictations; retry locally.
  ./scripts/dev-dictation-fault.sh clear
    Launch normally with simulations disabled.

Debug com.muesli.dev.c only. Each fault fires once per launch. No dictation is
started automatically. Error telemetry goes to the existing dev channel.
EOF
    exit 0 ;;
  *) echo 'Choose mic-startup, streaming, or clear; use --help for instructions.' >&2; exit 2 ;;
esac
app=/Applications/MuesliDevC.app
python3 - "$app" <<'PY'
import mmap, pathlib, plistlib, sys
app=pathlib.Path(sys.argv[1])
with (app/'Contents/Info.plist').open('rb') as f: info=plistlib.load(f)
if info.get('CFBundleIdentifier')!='com.muesli.dev.c' or info.get('MuesliTelemetryChannel')!='dev':
    sys.exit('This helper requires the isolated Dev C app and dev telemetry channel.')
with (app/'Contents/MacOS/MuesliDevC').open('rb') as f:
    with mmap.mmap(f.fileno(),0,access=mmap.ACCESS_READ) as binary:
        if binary.find(b'MUESLI_DEV_DICTATION_FAULT')<0 or binary.find(b'dictation.microphone.startup.warning')<0:
            sys.exit('Rebuild Debug Dev C with the warning-only fault hooks before using this helper.')
PY
if pgrep -f '^/Applications/MuesliDevC\.app/Contents/MacOS/MuesliDevC' >/dev/null; then
  echo 'Quit Dev C normally first, then rerun this command. Existing data is kept.' >&2
  exit 1
fi
value="$mode"
[[ "$mode" != clear ]] || value=""
open --env "MUESLI_DEV_DICTATION_FAULT=$value" -a "$app"
if [[ "$mode" == clear ]]; then
  echo 'Dev C launched with simulations disabled.'
else
  echo "Dev C launched: $mode (one-shot; next matching dictation only)."
fi
