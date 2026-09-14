#!/bin/bash
# Replay the same draft-only voice transcript through an installed dev lane.
set -euo pipefail
umask 077
lane="${1:-A}"
case "$lane" in A|B|C) ;; *) echo "usage: $0 [A|B|C]" >&2; exit 2;; esac
root="$(cd "$(dirname "$0")/.." && pwd)"
command_file="$root/scripts/fixtures/cua/twitter-profile-draft.txt"
app="MuesliDev$lane"
support="$HOME/Library/Application Support/$app"
[[ -d "/Applications/$app.app" ]] || { echo "Install $app first" >&2; exit 2; }
previous_id="$(python3 - "$support" <<'PY'
import json,pathlib,sqlite3,sys,plistlib,subprocess
def locked(value):
 if isinstance(value,dict):
  return value.get('IOConsoleLocked') is True or any(locked(v) for v in value.values())
 if isinstance(value,list): return any(locked(v) for v in value)
 return False
if locked(plistlib.loads(subprocess.check_output(['/usr/sbin/ioreg','-a','-n','Root','-d','1']))):
 raise SystemExit('Unlock the Mac before replay; Chrome can stay in the background')
p=pathlib.Path(sys.argv[1])
if not json.loads((p/'config.json').read_text()).get('computer_use_background_mode',False):
 raise SystemExit('Enable Background execution in this dev lane before replay')
c=sqlite3.connect((p/'muesli.db').as_uri()+'?mode=ro',uri=True)
if c.execute("select 1 from computer_use_traces where final_status='running' limit 1").fetchone():
 raise SystemExit('A CUA run is active; stop or finish it before replay')
print(c.execute('select coalesce(max(id),0) from dictations').fetchone()[0])
PY
)"
if pgrep -x "$app" >/dev/null; then
  osascript -e 'with timeout of 8 seconds' -e "tell application id \"com.muesli.dev.$(echo "$lane" | tr 'ABC' 'abc')\" to quit" -e 'end timeout'
  for _ in $(seq 1 80); do
    pgrep -x "$app" >/dev/null || break
    sleep 0.1
  done
  if pgrep -x "$app" >/dev/null; then echo "Dev lane did not quit; replay was not started" >&2; exit 2; fi
fi
output_dir="$(mktemp -d /tmp/muesli-cua-baseline.XXXXXX)"
echo "Baseline artifacts: $output_dir"
open -g -a "/Applications/$app.app" --args --computer-use-command-file "$command_file"
PYTHONUNBUFFERED=1 python3 - "$support/muesli.db" "$previous_id" "$command_file" "$output_dir" <<'PY'
import json,pathlib,sqlite3,sys,time
path,previous,fixture,out=sys.argv[1:]
command=pathlib.Path(fixture).read_text().strip()
c=sqlite3.connect(pathlib.Path(path).as_uri()+'?mode=ro',uri=True)
deadline=time.monotonic()+180
seen=set()
while time.monotonic()<deadline:
 row=c.execute('select t.dictation_id,t.final_status,t.final_message,t.trace_json from computer_use_traces t join dictations d on d.id=t.dictation_id where d.id>? and d.raw_text=? order by d.id desc limit 1',(int(previous),command)).fetchone()
 if row:
  ident,status,message,raw=row
  events=json.loads(raw)
  pathlib.Path(out,'trace.json').write_text(json.dumps(events,indent=2))
  for e in events:
   if e['id'] not in seen:
    seen.add(e['id'])
    if e['kind'] in ('tool_call','tool_result','finish','failed','timed_out'):
     print(f"run={ident} step={e.get('step','-')} {e['kind']}: {e.get('body','')[:700]}",flush=True)
  if status!='running':
   result=dict(dictation_id=ident,status=status,message=message,command=command)
   pathlib.Path(out,'result.json').write_text(json.dumps(result,indent=2))
   print(json.dumps(result),flush=True)
   raise SystemExit(0 if status=='done' else 1)
 time.sleep(1)
raise SystemExit('No completed baseline within 180 seconds; check the app/Stop control before retrying')
PY
