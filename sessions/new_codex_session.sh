#!/usr/bin/env bash
# Start a new Codex Desktop thread that is live in the GUI, with explicit
# project (directory), model, reasoning effort and permission mode.
#
# The Desktop app is driven through the macOS Accessibility tree (no screenshots):
# controls are located and read back by name (codex_gui_ax.swift), clicks are real
# mouse events, and the result is verified from the thread's rollout turn_context.
#
# Usage:
#   new_codex_session.sh [-w DIR] [--model ID] [--effort LEVEL] [--permission MODE]
#                        [--confirm-full-access] [--model-label LABEL] PROMPT
#
#   -w DIR                 project directory (default: cwd). It is trusted in ~/.codex/config.toml
#                          and opened with `codex app DIR` automatically; no manual Trust click.
#   --model ID             e.g. gpt-6-luna (label derived: "GPT-6 Luna"; the pre-2026-10 UI's "GPT 6 Luna" is tried too); omit to keep the composer's model
#   --model-label LABEL    exact picker label if the derived one is wrong
#   --effort LEVEL         low | medium | high | xhigh | max | ultra; omit to keep the composer's effort
#                          (max/ultra must be enabled in Codex Settings > Agent > Model features)
#   --permission MODE      ask | auto | full (alias: bypass); omit to keep the composer's mode
#   --confirm-full-access  required with full/bypass: answers Codex's "Turn on Full Access?" dialog
#   --thinking             alias of --effort
#
# Exit codes: 0 verified launch; 64 usage; 2 environment (Codex/Accessibility/swiftc);
#   3 project; 4 permission; 5 model/effort; 6 prompt/send; 7 rollout missing or differs from request.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
DIR="$(pwd)"; MODEL=""; MODEL_LABEL=""; EFFORT=""; PERM=""; CONFIRM_FULL=0
usage() { sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; }
die() { echo "[codex-gui] FAILED: $2" >&2; exit "$1"; }
step() { echo "[codex-gui] $*"; }

while [ $# -gt 0 ]; do case "$1" in
  -w|--workspace) DIR="$2"; shift 2;;
  --model) MODEL="$2"; shift 2;;
  --model-label) MODEL_LABEL="$2"; shift 2;;
  --effort|--thinking) EFFORT="$2"; shift 2;;
  --permission) PERM="$2"; shift 2;;
  --confirm-full-access) CONFIRM_FULL=1; shift;;
  -h|--help) usage; exit 0;;
  --) shift; break;;
  -*) echo "unknown flag: $1" >&2; usage >&2; exit 64;;
  *) break;;
esac; done
PROMPT="$*"
[ -n "$PROMPT" ] || { echo "a prompt is required" >&2; exit 64; }
[ -d "$DIR" ] || { echo "not a directory: $DIR" >&2; exit 64; }
DIR="$(cd "$DIR" && pwd -P)"; PROJECT="$(basename "$DIR")"

case "$EFFORT" in
  "") EFFORT_LABEL="";; low) EFFORT_LABEL="Light";; medium) EFFORT_LABEL="Standard";; high) EFFORT_LABEL="Extended";;
  xhigh) EFFORT_LABEL="Extra High";; max) EFFORT_LABEL="Max";; ultra) EFFORT_LABEL="Ultra";;
  *) echo "unknown effort: $EFFORT" >&2; exit 64;; esac
case "$PERM" in
  "") PERM_LABEL="";; ask) PERM_LABEL="Ask for approval";; auto) PERM_LABEL="Approve for me";;
  full|bypass) PERM_LABEL="Full access"; PERM=full;;
  *) echo "unknown permission: $PERM" >&2; exit 64;; esac
if [ "$PERM" = full ] && [ $CONFIRM_FULL -ne 1 ]; then
  echo "permission 'full' needs --confirm-full-access (Codex asks for confirmation)" >&2; exit 64; fi
# The picker label is derived from the model id: gpt-6-luna -> "GPT-6 Luna", gpt-6.1-sol -> "GPT-6.1 Sol", gpt-5.5 -> "GPT-5.5".
# Before the 2026-10 Codex Desktop redesign it read "GPT 6 Luna" (no hyphen), so that spelling is kept as a fallback.
MODEL_LABEL_ALT=""
if [ -n "$MODEL" ] && [ -z "$MODEL_LABEL" ]; then
  MODEL_LABEL="$(echo "$MODEL" | awk -F- '{for(i=1;i<=NF;i++){w=$i; if(tolower(w)~/^(gpt|glm)$/) w=toupper(w); else w=toupper(substr(w,1,1)) substr(w,2); sep=(i>1?" ":""); if(i==2 && tolower($1)~/^(gpt|glm)$/ && $2~/^[0-9]/) sep="-"; printf "%s%s", sep, w}}')"
  case "$MODEL_LABEL" in "GPT-"*|"GLM-"*) MODEL_LABEL_ALT="${MODEL_LABEL/-/ }";; esac
fi
LABELS=("$MODEL_LABEL"); [ -z "$MODEL_LABEL_ALT" ] || LABELS+=("$MODEL_LABEL_ALT")

# --- helper binary (compiled once per source version) ---
command -v swiftc >/dev/null || die 2 "swiftc not found (install Xcode Command Line Tools)"
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/launch-local-agent-session"; mkdir -p "$CACHE"
SUM="$(shasum "$HERE/codex_gui_ax.swift" | cut -c1-12)"; AX="$CACHE/codex-gui-ax-$SUM"
[ -x "$AX" ] || { step "compiling Accessibility helper"; swiftc -O -o "$AX" "$HERE/codex_gui_ax.swift" 2>/dev/null || die 2 "helper compile failed"; }

key() { osascript -e "tell application \"System Events\" to key code $1" >/dev/null; }
wait_for() { local t=$1; shift; local i=0; while ! "$AX" has "$@" 2>/dev/null; do sleep 0.3; i=$((i+1)); [ $i -gt $((t*3)) ] && return 1; done; return 0; }

# --- one GUI session at a time: the script drives the real mouse and keyboard ---
LOCK="$CACHE/gui.lock"; LOCKED=0
release_lock() { [ $LOCKED -eq 1 ] && { rm -rf "$LOCK"; LOCKED=0; }; return 0; }
trap release_lock EXIT
acquire_lock() {
  local waited=0
  until mkdir "$LOCK" 2>/dev/null; do
    local owner; owner="$(cat "$LOCK/pid" 2>/dev/null || true)"
    if [ -n "$owner" ] && ! kill -0 "$owner" 2>/dev/null; then rm -rf "$LOCK"; continue; fi
    [ $waited -eq 0 ] && step "another GUI launch (pid ${owner:-?}) is running; waiting"
    sleep 2; waited=$((waited+2)); [ $waited -gt 1200 ] && die 2 "GUI lock held for 20 minutes by pid ${owner:-?}"
  done
  echo $$ > "$LOCK/pid"; LOCKED=1
}
acquire_lock

# trust the directory in ~/.codex/config.toml (idempotent, atomic) so `codex app` never shows "Trust this folder?"
python3 - "$DIR" <<'TRUSTPY'
import sys, os, tempfile
d = os.path.realpath(sys.argv[1]); p = os.path.expanduser('~/.codex/config.toml')
t = open(p).read(); hdr = '[projects."%s"]' % d
if hdr in t: sys.exit(0)
t = t.rstrip('\n') + '\n\n' + hdr + '\ntrust_level = "trusted"\n'
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(p)); os.write(fd, t.encode()); os.close(fd); os.chmod(tmp, 0o600); os.replace(tmp, p)
TRUSTPY

pgrep -f "Codex.app/Contents/MacOS" >/dev/null || { open -a /Applications/Codex.app; sleep 5; }
osascript -e 'tell application "/Applications/Codex.app" to activate'; sleep 0.8
"$AX" has "New chat" AXButton 2>/dev/null || die 2 "cannot read Codex UI: grant Accessibility to this process (System Settings > Privacy & Security > Accessibility)"
key 53; sleep 0.3

# 1. `codex app DIR` registers the project and opens its new-chat page (works even when the sidebar hides it)
codex app "$DIR" >/dev/null 2>&1 || true
if ! wait_for 10 "Change project: $PROJECT" AXPopUpButton; then
  "$AX" hover "$PROJECT" AXButton >/dev/null 2>&1 || true; sleep 0.5
  "$AX" click "Start new chat in $PROJECT" AXButton >/dev/null || die 3 "project '$PROJECT' did not open via 'codex app' and is not in the sidebar"
  wait_for 8 "Change project: $PROJECT" AXPopUpButton || die 3 "new chat page for '$PROJECT' did not appear"
fi
wait_for 8 "Change permissions" AXPopUpButton || die 3 "composer did not appear"

# 2. permission
if [ -n "$PERM_LABEL" ] && ! "$AX" has "$PERM_LABEL" AXStaticText; then
  step "permission -> $PERM_LABEL"
  "$AX" click "Change permissions" AXPopUpButton >/dev/null; sleep 0.6
  "$AX" click "$PERM_LABEL" AXMenuItem >/dev/null || die 4 "permission '$PERM_LABEL' not offered"
  sleep 0.8
  if "$AX" has "Turn on Full Access"; then
    "$AX" click "Confirm" AXButton >/dev/null || die 4 "could not confirm the Full Access dialog"; sleep 0.8
  fi
fi
[ -z "$PERM_LABEL" ] || "$AX" has "$PERM_LABEL" AXStaticText || die 4 "permission '$PERM_LABEL' not applied"

# 3. model and effort (one popover; skipped when the composer chip already shows the target)
if [ -n "$MODEL_LABEL$EFFORT_LABEL" ]; then
  # the chip is the composer's model button ("GPT-6 Luna Max"); match by provider prefix without a trailing space (old UI "GPT 6", new UI "GPT-6")
  CHIP=""; for pre in "GPT" "Kimi" "GLM"; do CHIP="$("$AX" label "$pre" AXPopUpButton 2>/dev/null || true)"; [ -z "$CHIP" ] || break; done
  chip_ok=0; for L in "${LABELS[@]}"; do [ -n "$CHIP" ] && [ "$CHIP" = "$L${L:+ }$EFFORT_LABEL" ] && chip_ok=1; done
  if [ $chip_ok -eq 1 ]; then
    step "model/effort already $CHIP"
  else
  opened=0
  for pre in "GPT" "Kimi" "GLM"; do "$AX" click "$pre" AXPopUpButton >/dev/null 2>&1 && { opened=1; break; }; done
  [ $opened -eq 1 ] || die 5 "model chip not found"
  sleep 0.7
  model_shown=0; for L in "${LABELS[@]}"; do [ -n "$MODEL_LABEL" ] && "$AX" has "$L " AXStaticText && model_shown=1; done
  if [ -n "$MODEL_LABEL" ] && [ $model_shown -eq 0 ]; then
    step "model -> $MODEL_LABEL"
    "$AX" click "Select model" AXMenuItem >/dev/null; sleep 0.7
    picked=""; for L in "${LABELS[@]}"; do "$AX" click "$L" AXMenuItem >/dev/null 2>&1 && { picked="$L"; break; }; done
    [ -n "$picked" ] || die 5 "model '$MODEL_LABEL' not offered by the picker"
    sleep 0.7
    "$AX" has " of " AXStaticText || { "$AX" click "$picked" AXPopUpButton >/dev/null; sleep 0.7; }
  fi
  if [ -n "$EFFORT_LABEL" ]; then
    step "effort -> $EFFORT_LABEL"
    L="$("$AX" label " of " AXStaticText || true)"; N="$(echo "$L" | sed -n 's/.* of \([0-9]*\)\..*/\1/p')"
    [ -n "$N" ] || die 5 "effort slider not readable"
    case "$L" in *" $EFFORT_LABEL, "*) ok=1;; *) ok=0;; esac
    if [ $ok -eq 0 ]; then
      # levels are always offered in this order, so jump straight to the target's index first
      case "$EFFORT_LABEL" in Light) T=0;; Standard) T=1;; Extended) T=2;; "Extra High") T=3;; Max) T=4;; Ultra) T=5;; esac
      if [ "$T" -lt "$N" ]; then
        f="$(awk -v i="$T" -v n="$N" 'BEGIN{printf "%.3f", 0.06+0.88*i/(n-1)}')"
        "$AX" clickat "Power" "$f" AXMenuItem >/dev/null || die 5 "effort slider not found"; sleep 0.4
        L="$("$AX" label " of " AXStaticText || true)"
        case "$L" in *" $EFFORT_LABEL, "*) ok=1;; esac
      fi
    fi
    if [ $ok -eq 0 ]; then
      for i in $(seq 0 $((N-1))); do
        f="$(awk -v i="$i" -v n="$N" 'BEGIN{printf "%.3f", 0.06+0.88*i/(n-1)}')"
        "$AX" clickat "Power" "$f" AXMenuItem >/dev/null || die 5 "effort slider not found"; sleep 0.5
        L="$("$AX" label " of " AXStaticText || true)"
        case "$L" in *" $EFFORT_LABEL, "*) ok=1; break;; esac
      done
    fi
    [ $ok -eq 1 ] || die 5 "effort '$EFFORT' ($EFFORT_LABEL) not offered here (last: $L). Max/Ultra need enabling in Settings > Agent > Model features."
  fi
  key 53; sleep 0.5
  fi
fi

# 4. prompt and send
step "sending prompt"
[ "$("$AX" settext "$PROMPT")" = ok ] || die 6 "could not set the prompt text"
MARK="$(printf '%s' "$PROMPT" | python3 -c 'import sys;print(sys.stdin.read().split("\n")[0][:30],end="")')"
wait_for 8 "$MARK" || die 6 "prompt text not visible in the composer"
BEFORE="$(date +%s)"
PRE_ROLLOUTS="$(mktemp -t codex-rollouts)"
find "${CODEX_SESSIONS_ROOT:-$HOME/.codex/sessions}" -name 'rollout-*.jsonl' -print 2>/dev/null > "$PRE_ROLLOUTS"
"$AX" click "Send" AXButton >/dev/null || die 6 "send button not found"
release_lock

# 5. verify against the rollout Codex wrote
python3 - "$BEFORE" "$PROMPT" "$DIR" "$MODEL" "$EFFORT" "$PERM" "$PRE_ROLLOUTS" <<'PY'
import sys,json,glob,os,time
before=float(sys.argv[1])-5; prompt=sys.argv[2]; mark=prompt[:40]; cwd,model,effort,perm=sys.argv[3:7]
# Rollouts that existed before Send was clicked belong to other threads — including the
# launching session's own thread, whose transcript quotes this very prompt. Only a NEW file
# can be the thread we just started.
pre=set(l.strip() for l in open(sys.argv[7]) if l.strip()) if len(sys.argv)>7 and os.path.exists(sys.argv[7]) else set()
root=os.environ.get('CODEX_SESSIONS_ROOT') or os.path.expanduser('~/.codex/sessions'); deadline=time.time()+60
def is_user_prompt(d):
    # the thread's own user message, not a tool call that merely quotes the prompt
    p=d.get('payload') or {}
    if d.get('type')=='event_msg' and p.get('type')=='user_message': return prompt.strip() in str(p.get('message',''))
    if d.get('type')=='response_item' and p.get('role')=='user':
        return any(prompt.strip() in str(c.get('text','')) for c in (p.get('content') or []) if isinstance(c,dict))
    return False
while time.time()<deadline:
    for f in glob.glob(root+'/**/rollout-*.jsonl',recursive=True):
        if f in pre: continue
        try:
            if os.path.getmtime(f)<before: continue
            txt=open(f).read()
        except OSError: continue
        if mark not in txt: continue
        try:
            if not any(is_user_prompt(json.loads(l)) for l in txt.splitlines() if l.strip()): continue
        except json.JSONDecodeError: continue
        for l in txt.splitlines():
            d=json.loads(l)
            if d.get('type')!='turn_context': continue
            p=d['payload']; sb=(p.get('sandbox_policy') or {}).get('type')
            if os.path.realpath(p.get('cwd') or '')!=cwd: break  # another concurrent launch's rollout: keep looking
            got={'cwd':p.get('cwd'),'model':p.get('model'),'effort':p.get('effort'),'approval':p.get('approval_policy'),'sandbox':sb}
            print(json.dumps(got,ensure_ascii=False)); print('[codex-gui] rollout:',f)
            bad=[]
            if os.path.realpath(got['cwd'] or '')!=cwd: bad.append('cwd')
            if model and got['model']!=model: bad.append('model')
            if effort and got['effort']!=effort: bad.append('effort')
            if perm=='full' and not (got['approval']=='never' and sb=='danger-full-access'): bad.append('permission')
            if bad: print('[codex-gui] FAILED: rollout differs from request:',','.join(bad),file=sys.stderr); sys.exit(7)
            sys.exit(0)
    time.sleep(1)
print('[codex-gui] FAILED: no NEW rollout carries the prompt as its user message (send may not have gone through)',file=sys.stderr); sys.exit(7)
PY
