#!/usr/bin/env bash
# 在 Codex Desktop 里以 GUI 方式创建一个新 task，并可选地输入并提交 prompt。
#
# 用法：
#   new_codex_session.sh                         # 当前 workspace：只创建空 task
#   new_codex_session.sh "你的 prompt"            # 创建 task，粘贴并提交 prompt
#   new_codex_session.sh -w /path/to/workspace    # 指定 workspace：只创建空 task
#   new_codex_session.sh -w /path "你的 prompt"   # 指定 workspace，创建并提交 prompt
#
# 这是没有 Codex Desktop 原生 task 工具时的 GUI fallback。循环任务由 Codex
# Desktop agent 执行时，应优先遵循同目录 new-codex-session.md 的原生工具流程。

set -euo pipefail

WORKSPACE="$(pwd)"
PROMPT=""

usage() {
  sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -w|--workspace)
      if [[ $# -lt 2 || -z "${2:-}" ]]; then
        echo "[codex_new_session] 缺少 workspace 参数。" >&2
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
      echo "[codex_new_session] 未知参数：$1" >&2
      usage >&2
      exit 2
      ;;
    *)
      PROMPT="$1"
      shift
      if [[ $# -gt 0 ]]; then
        echo "[codex_new_session] prompt 请作为单个参数传入；多行可用 \$'第一行\\n第二行'。" >&2
        exit 2
      fi
      ;;
  esac
done

if [[ ! -d "$WORKSPACE" ]]; then
  echo "[codex_new_session] workspace 不存在或不是目录：$WORKSPACE" >&2
  exit 2
fi
WORKSPACE="$(cd "$WORKSPACE" && pwd)"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "[codex_new_session] 此 GUI fallback 仅支持 macOS。" >&2
  exit 1
fi
if ! command -v codex >/dev/null 2>&1; then
  echo "[codex_new_session] 未找到 codex 命令。" >&2
  exit 1
fi
if ! command -v osascript >/dev/null 2>&1; then
  echo "[codex_new_session] 未找到 osascript。" >&2
  exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "[codex_new_session] 未找到 python3；无法安全传递多行 prompt。" >&2
  exit 1
fi

run_applescript() {
  local script="$1"
  local temporary_script
  temporary_script="$(mktemp -t codex_new_session.XXXXXX).scpt"
  printf '%s\n' "$script" > "$temporary_script"
  osascript "$temporary_script" 2>&1
  local status=$?
  rm -f "$temporary_script"
  return "$status"
}

# `codex app` opens the requested workspace.  ChatGPT.app and Codex.app share
# a bundle id on this machine, so activation must name the Codex app bundle by
# its absolute path.  This prevents Cmd+N from being delivered to Cursor or
# the separate ChatGPT app.
if ! APP_OUTPUT="$(codex app "$WORKSPACE" 2>&1)"; then
  echo "[codex_new_session] 无法打开 Codex workspace：${APP_OUTPUT}" >&2
  exit 1
fi

read -r -d '' NEW_TASK_SCRIPT <<'APPLESCRIPT' || true
tell application "/Applications/Codex.app" to activate
tell application "System Events"
	if not (exists application process "ChatGPT") then error "Codex Desktop process was not found"
	set targetProcess to application process "ChatGPT"
	if bundle identifier of targetProcess is not "com.openai.codex" then error "ChatGPT process is not Codex Desktop"
end tell
set didFront to false
repeat 40 times
	tell application "System Events"
		if frontmost of targetProcess then
			set didFront to true
			exit repeat
		end if
	end tell
	delay 0.2
end repeat
if not didFront then error "Codex Desktop did not come to front"

tell application "System Events"
	if (count of windows of targetProcess) is 0 then error "Codex Desktop has no window"
	-- Cmd+N is the localized New Chat command.  It is sent only after the
	-- foreground process was proven to be com.openai.codex.
	keystroke "n" using command down
end tell
delay 1.2
return "created"
APPLESCRIPT

if ! RESULT="$(run_applescript "$NEW_TASK_SCRIPT")"; then
  echo "[codex_new_session] 未能在 Codex Desktop 中创建新 task：${RESULT}" >&2
  echo "[codex_new_session] 请确认运行脚本的宿主已获辅助功能权限。" >&2
  exit 1
fi

if [[ -z "$PROMPT" ]]; then
  echo "[codex_new_session] 已请求创建独立 Codex GUI task。"
  echo "[codex_new_session] workspace: ${WORKSPACE}"
  exit 0
fi

PROMPT_LITERAL="$(printf '%s' "$PROMPT" | python3 -c 'import sys; text=sys.stdin.read(); print("\"" + text.replace("\\", "\\\\").replace("\"", "\\\"") + "\"")')"
PROMPT_SCRIPT="$(printf '%s\n' \
  'tell application "System Events"' \
  '	if not (exists application process "ChatGPT") then error "Codex Desktop process was not found before prompt dispatch"' \
  '	set targetProcess to application process "ChatGPT"' \
  '	if bundle identifier of targetProcess is not "com.openai.codex" then error "ChatGPT process is not Codex Desktop"' \
  '	if not frontmost of targetProcess then error "Codex Desktop lost foreground before prompt dispatch"' \
  'end tell' \
  '' \
  'set oldClipboard to the clipboard' \
  "set the clipboard to ${PROMPT_LITERAL}" \
  'delay 0.25' \
  'tell application "System Events"' \
  '	keystroke "v" using command down' \
  'end tell' \
  'delay 0.5' \
  'tell application "System Events"' \
  '	keystroke return' \
  'end tell' \
  'set the clipboard to oldClipboard' \
  'return "sent"')"

if ! RESULT="$(run_applescript "$PROMPT_SCRIPT")"; then
  echo "[codex_new_session] 已请求新 task，但 prompt 分发失败：${RESULT}" >&2
  echo "[codex_new_session] 请确认运行脚本的宿主已获辅助功能权限。" >&2
  exit 1
fi

echo "[codex_new_session] 已请求创建独立 Codex GUI task 并分发 prompt。"
echo "[codex_new_session] workspace: ${WORKSPACE}"
echo "[codex_new_session] 请在新 task 中确认 prompt 已提交；GUI fallback 无法读取 Web 输入框来证明焦点。"
