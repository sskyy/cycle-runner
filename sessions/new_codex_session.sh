#!/usr/bin/env bash
# 在 ChatGPT 桌面应用中启动一个新的 Codex GUI task，并可选地输入 prompt 开始执行。
#
# 用法：
#   new_codex_session.sh                         # 在当前目录 workspace 下仅新建一个任务
#   new_codex_session.sh "你的 prompt"            # 新建任务，输入该 prompt 并按回车发送、开始执行
#   new_codex_session.sh -w /path/to/workspace    # 指定 workspace，仅新建一个任务
#   new_codex_session.sh -w /path "你的 prompt"   # 指定 workspace，并发送 prompt
#
# 原理：
#   1) 用 `codex app <workspace>` 打开/聚焦 ChatGPT Desktop 到指定 workspace。
#   2) 通过 AppleScript 点击菜单「File → New Task」新建 Codex GUI task。
#   3) 若提供 prompt，则通过剪贴板粘贴到自动聚焦的输入框，再按 Enter 发送。
#
# 前置：运行 osascript 的宿主需在
#   系统设置 → 隐私与安全性 → 辅助功能 中被授权。
# 首次运行报 -1719 即未授权。
#
# 实现说明：AppleScript 经临时文件传入 osascript，而非 heredoc。
# 原因：bash 的 $(...) 命令替换内嵌 heredoc 时，若 AppleScript 注释/正文里
# 出现未配对的右括号（如「1)」「步骤 2)」），会被命令替换解析器误判为替换结束，
# 导致 heredoc 内容被当成 shell 命令执行。临时文件可彻底规避该问题。

set -euo pipefail

WORKSPACE="$(pwd)"
PROMPT=""

usage() {
  sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'
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
    -* )
      echo "[codex_new_session] 未知参数：$1" >&2
      usage >&2
      exit 2
      ;;
    *)
      PROMPT="$1"
      shift
      if [[ $# -gt 0 ]]; then
        echo "[codex_new_session] prompt 请作为单个参数传入；多行可用 $'第一行\\n第二行'。" >&2
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

if ! command -v codex >/dev/null 2>&1; then
  echo "[codex_new_session] 未找到 codex 命令。" >&2
  echo "[codex_new_session] 提示：确认 /Applications/ChatGPT.app 已安装，且 codex 在 PATH 中。" >&2
  exit 1
fi

run_applescript() {
  # run_applescript <script_text>  -> prints result, returns osascript exit code
  local scpt="$1"
  local tmp
  tmp="$(mktemp -t codex_new_session.XXXXXX).scpt"
  printf '%s\n' "$scpt" > "$tmp"
  osascript "$tmp" 2>&1
  local rc=$?
  rm -f "$tmp"
  return $rc
}

# 1) 打开/聚焦 ChatGPT Desktop 到指定 workspace。
# codex app 通常会快速返回；如果应用已运行，也会复用现有窗口。
if ! CODEX_APP_OUTPUT=$(codex app "$WORKSPACE" 2>&1); then
  echo "[codex_new_session] 启动 ChatGPT Desktop 失败：${CODEX_APP_OUTPUT}" >&2
  exit 1
fi

# --- 第 1 段 AppleScript：激活 ChatGPT + 新建 Task + 校验窗口存在 ---
read -r -d '' NEW_TASK_SCPT <<'APPLESCRIPT_EOF' || true
on isFront()
	tell application "System Events"
		return (name of first application process whose frontmost is true) is "ChatGPT"
	end tell
end isFront

on isRunning()
	tell application "System Events"
		return exists process "ChatGPT"
	end tell
end isRunning

on windowCount()
	tell application "System Events"
		tell process "ChatGPT"
			return count of windows
		end tell
	end tell
end windowCount

if not isRunning() then error "ChatGPT is not running after `codex app`"

tell application "ChatGPT" to activate
set frontOK to false
repeat 40 times
	if isFront() then
		set frontOK to true
		exit repeat
	end if
	delay 0.2
end repeat
if not frontOK then error "ChatGPT did not come to front"

set windowOK to false
repeat 50 times
	if windowCount() > 0 then
		set windowOK to true
		exit repeat
	end if
	delay 0.2
end repeat
if not windowOK then error "ChatGPT did not open a window"

-- 触发「File → New Task」。优先点击菜单项而非快捷键，避免快捷键语义随版本变化。
-- 当前 ChatGPT 版本有时会在任务已经打开后，让 click 返回 -10000
-- (AppleEvent handler failed)。该错误只在此菜单点击动作上忽略；其他错误仍然失败。
try
	tell application "System Events"
		tell process "ChatGPT"
			click menu item "New Task" of menu "File" of menu bar item "File" of menu bar 1
		end tell
	end tell
on error errorMessage number errorNumber
	if errorNumber is not -10000 then error errorMessage number errorNumber
end try

-- ChatGPT 的 Codex Web 内容不稳定暴露 AXTextArea/AXWebArea。
-- New Task 触发后输入框会自动聚焦，因此等待一小段时间作为 UI 就绪缓冲。
delay 1.0
if windowCount() = 0 then error "New Task was requested, but ChatGPT has no window"

return "ok"
APPLESCRIPT_EOF

if ! RESULT=$(run_applescript "$NEW_TASK_SCPT"); then
  echo "[codex_new_session] 在 ChatGPT 中新建 Codex task 失败：${RESULT}" >&2
  echo "[codex_new_session] 提示：确认已授予运行 osascript 的终端「辅助功能」权限。" >&2
  exit 1
fi

# 2) 若无 prompt 参数，到此结束。
if [[ -z "$PROMPT" ]]; then
  echo "[codex_new_session] 已在 ChatGPT 中新建 Codex GUI task。"
  echo "[codex_new_session] workspace: ${WORKSPACE}"
  exit 0
fi

# 3) 有 prompt：通过剪贴板粘贴 + 回车发送。
#    剪贴板内容会被恢复，对用户无副作用。
PROMPT_SCPT_FILE="$(mktemp -t codex_prompt.XXXXXX).scpt"
trap 'rm -f "$PROMPT_SCPT_FILE"' EXIT

# 用 python 把 prompt 安全写进 AppleScript 字符串字面量（处理引号、反斜杠、换行）。
# AppleScript 字符串用双引号，转义 " 为 \" 、\ 为 \\。
ESCAPED_PROMPT="$(python3 -c 'import sys; s=sys.stdin.read(); print("\"" + s.replace("\\","\\\\").replace("\"","\\\"") + "\"")' <<<"$PROMPT")"

cat > "$PROMPT_SCPT_FILE" <<APPLESCRIPT_EOF
on isFront()
	tell application "System Events"
		return (name of first application process whose frontmost is true) is "ChatGPT"
	end tell
end isFront

-- 确保仍在 ChatGPT 前台
if not isFront() then
	tell application "ChatGPT" to activate
	delay 0.4
end if

-- ChatGPT 的 Codex Web 内容通常不暴露可定位的 AX text area；依赖 New Task 后输入框自动聚焦。
delay 0.5
-- 保存原剪贴板
set oldClip to the clipboard

-- 设置 prompt 到剪贴板并粘贴到（已聚焦的）输入框
set the clipboard to ${ESCAPED_PROMPT}
delay 0.3
tell application "System Events"
	keystroke "v" using command down
end tell
delay 0.6

-- 回车发送：Enter 在 Codex 输入框默认为发送
tell application "System Events"
	keystroke return
end tell

-- 恢复原剪贴板
set the clipboard to oldClip
return "sent"
APPLESCRIPT_EOF

if ! RESULT=$(osascript "$PROMPT_SCPT_FILE" 2>&1); then
  echo "[codex_new_session] 已新建 task，但发送 prompt 失败：${RESULT}" >&2
  echo "[codex_new_session] 提示：若剪贴板被占用，可重试；确认 ChatGPT 仍在前台。" >&2
  exit 1
fi

echo "[codex_new_session] 已在 ChatGPT 中新建 Codex GUI task 并发送 prompt 开始执行。"
echo "[codex_new_session] workspace: ${WORKSPACE}"
echo "[codex_new_session] prompt: ${PROMPT}"
