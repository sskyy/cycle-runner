#!/usr/bin/env bash
# 在 Cursor2（薄启动器 / 独立 user-data-dir）Agents Window 中新建独立 GUI Agent session，
# 并可选地输入 prompt 开始执行。与默认 Cursor 隔离，避免串实例。
#
# 用法：
#   new_cursor2_agent_session.sh                         # 当前目录 workspace，仅新建
#   new_cursor2_agent_session.sh "你的 prompt"            # 新建并发送 prompt
#   new_cursor2_agent_session.sh -w /path/to/workspace    # 指定 workspace
#   new_cursor2_agent_session.sh -w /path "你的 prompt"   # 指定 workspace 并发送 prompt
#
# 原理（不依赖严格前台激活 / 辅助功能门禁）：
#   1) 确认 Cursor2 profile 进程在跑（必要时 open -a Cursor2）。
#   2) 执行 cursor --user-data-dir <cursor2> <workspace>（不加 -r/-n）触发 glass.newAgent。
#   3) 若提供 prompt：尽力把 Cursor2 置前，再剪贴板粘贴 + Return
#      （置前失败不阻断；依赖新 session 输入框自动聚焦）。

set -euo pipefail

WORKSPACE="$(pwd)"
PROMPT=""
USER_DATA="${CURSOR2_USER_DATA:-$HOME/.cursor-profiles/cursor2}"
EXT_DIR="${CURSOR2_EXTENSIONS_DIR:-$USER_DATA/extensions}"
CURSOR2_APP="${CURSOR2_APP:-$HOME/Applications/Cursor2.app}"
CURSOR_CLI="${CURSOR_CLI:-/usr/local/bin/cursor}"

usage() {
  sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -w|--workspace)
      if [[ $# -lt 2 || -z "${2:-}" ]]; then
        echo "[cursor2_agent_session] 缺少 workspace 参数。" >&2
        usage >&2
        exit 2
      fi
      WORKSPACE="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      PROMPT="${*:-}"
      break
      ;;
    -*)
      echo "[cursor2_agent_session] 未知参数：$1" >&2
      usage >&2
      exit 2
      ;;
    *)
      PROMPT="$1"
      shift
      if [[ $# -gt 0 ]]; then
        echo "[cursor2_agent_session] prompt 请作为单个参数传入；多行可用 \$'第一行\\n第二行'。" >&2
        exit 2
      fi
      ;;
  esac
done

if [[ ! -d "$WORKSPACE" ]]; then
  echo "[cursor2_agent_session] workspace 不存在或不是目录：$WORKSPACE" >&2
  exit 2
fi
WORKSPACE="$(cd "$WORKSPACE" && pwd)"

if [[ ! -x "$CURSOR_CLI" ]]; then
  echo "[cursor2_agent_session] 未找到 cursor CLI：$CURSOR_CLI" >&2
  exit 1
fi

mkdir -p "$USER_DATA" "$EXT_DIR"

find_cursor2_pid() {
  # Match Electron main process for this user-data-dir (exclude Helper).
  # NOTE: do not pipe into python while also using a stdin heredoc — the heredoc
  # replaces stdin and the ps output is lost.
  /usr/bin/python3 - "$USER_DATA" <<'PY'
import subprocess, sys
target = sys.argv[1]
out = subprocess.check_output(["/bin/ps", "-ax", "-o", "pid=", "-o", "command="], text=True)
for line in out.splitlines():
    line = line.strip()
    if not line:
        continue
    sp = line.split(None, 1)
    if len(sp) != 2:
        continue
    pid, cmd = sp
    if "Cursor Helper" in cmd or "CursorUIViewService" in cmd:
        continue
    if "MacOS/Cursor" not in cmd and "--user-data-dir=" not in cmd:
        continue
    if f"--user-data-dir={target}" in cmd or f"--user-data-dir {target}" in cmd:
        print(pid)
        sys.exit(0)
sys.exit(1)
PY
}

# Best-effort: bring Cursor2 forward. Never fail the script if Accessibility
# blocks System Events — CLI newAgent does not require frontmost success.
try_activate_cursor2() {
  local pid="$1"
  osascript - "$pid" <<'APPLESCRIPT_EOF' >/dev/null 2>&1 || true
on run argv
	set targetPid to (item 1 of argv) as integer
	tell application "System Events"
		set procs to every process whose unix id is targetPid
		if (count of procs) is 0 then return
		set frontmost of item 1 of procs to true
	end tell
end run
APPLESCRIPT_EOF
}

# --- 确保 Cursor2 在跑 ---
PID="$(find_cursor2_pid || true)"
if [[ -z "${PID:-}" ]]; then
  if [[ ! -d "$CURSOR2_APP" ]]; then
    echo "[cursor2_agent_session] 未找到 Cursor2.app：$CURSOR2_APP" >&2
    exit 1
  fi
  echo "[cursor2_agent_session] Cursor2 未运行，正在启动…"
  open -a "$CURSOR2_APP"
  for _ in $(seq 1 60); do
    PID="$(find_cursor2_pid || true)"
    if [[ -n "${PID:-}" ]]; then
      break
    fi
    sleep 0.5
  done
fi

if [[ -z "${PID:-}" ]]; then
  echo "[cursor2_agent_session] 无法启动或找到 Cursor2 进程（user-data-dir=$USER_DATA）。" >&2
  exit 1
fi

# Optional focus before CLI; ignore failure (no Accessibility hard-depend).
try_activate_cursor2 "$PID"

# --- CLI：强制打到 cursor2 user-data（禁止 -r/-n）---
if ! CURSOR_OPEN_OUTPUT=$("$CURSOR_CLI" \
  --user-data-dir="$USER_DATA" \
  --extensions-dir="$EXT_DIR" \
  "$WORKSPACE" 2>&1); then
  echo "[cursor2_agent_session] 通过 cursor CLI 新建 Agent 失败：${CURSOR_OPEN_OUTPUT}" >&2
  exit 1
fi

sleep 1.8

# Refresh PID after CLI; best-effort focus again for paste targeting.
PID="$(find_cursor2_pid || echo "$PID")"
try_activate_cursor2 "$PID"
sleep 0.3

if [[ -z "$PROMPT" ]]; then
  echo "[cursor2_agent_session] 已在 Cursor2 Agents Window 中新建独立 Agent session。"
  echo "[cursor2_agent_session] workspace: ${WORKSPACE}"
  echo "[cursor2_agent_session] user-data: ${USER_DATA}"
  exit 0
fi

PROMPT_SCPT_FILE="$(mktemp -t cursor2_agent_prompt.XXXXXX).scpt"
trap 'rm -f "$PROMPT_SCPT_FILE"' EXIT

ESCAPED_PROMPT="$(python3 -c 'import sys; s=sys.stdin.read(); print("\"" + s.replace("\\","\\\\").replace("\"","\\\"") + "\"")' <<<"$PROMPT")"

cat > "$PROMPT_SCPT_FILE" <<APPLESCRIPT_EOF
set targetPid to ${PID}
-- Best-effort frontmost; do not abort if Accessibility denies it.
try
	tell application "System Events"
		set frontmost of (first process whose unix id is targetPid) to true
	end tell
end try
delay 0.4
set oldClip to the clipboard
set the clipboard to ${ESCAPED_PROMPT}
delay 0.3
tell application "System Events"
	keystroke "v" using command down
end tell
delay 0.6
tell application "System Events"
	keystroke return
end tell
set the clipboard to oldClip
return "sent"
APPLESCRIPT_EOF

if ! RESULT=$(osascript "$PROMPT_SCPT_FILE" 2>&1); then
  echo "[cursor2_agent_session] 已新建独立 Agent，但发送 prompt 失败：${RESULT}" >&2
  echo "[cursor2_agent_session] 若粘贴未进输入框：手动聚焦 Cursor2 新 session 后重试，或给运行 osascript 的宿主开辅助功能。" >&2
  exit 1
fi

echo "[cursor2_agent_session] 已在 Cursor2 中新建独立 Agent session 并发送 prompt。"
echo "[cursor2_agent_session] workspace: ${WORKSPACE}"
echo "[cursor2_agent_session] user-data: ${USER_DATA}"
echo "[cursor2_agent_session] prompt: ${PROMPT}"
