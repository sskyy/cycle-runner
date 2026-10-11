#!/usr/bin/env bash
# 在 Zed 的 Agent Panel 中启动一个新的独立 agent session，并可选地提交 prompt 开始执行。
#
# 用法：
#   new_zed_session.sh                              # 活动窗口：仅新建线程，不发送
#   new_zed_session.sh "你的 prompt"                 # 活动窗口：新建线程并提交 prompt
#   new_zed_session.sh -w /path/to/workspace         # 指定目录：仅新建线程
#   new_zed_session.sh -w /path "你的 prompt"        # 指定目录：新建线程并提交 prompt
#
# 环境变量：
#   ZED_APP          Zed.app 路径（默认 /Applications/Zed.app）
#   ZED_CLI          cli 二进制路径（默认：command -v zed，退回 $ZED_APP/Contents/MacOS/cli）
#   ZED_SUBMIT_DELAY URL 打开后到发送提交键的等待秒数（默认 5；首装 agent 后重试可调大）
#
# 原理（Zed 1.20.2 源码核对 + 2026-09-19 实测）：
#   1) 指定目录 —— `cli -n <dir>` 打开新 workspace 窗口。zed://agent URL 只路由到
#      「当前活动 multi-workspace」，且 URL 与路径不能合并进同一条 cli 命令
#      （open_listener 对带 kind 的请求短路返回，open_paths 被跳过），
#      所以必须「先 cli 开窗口、再 open URL」两步走。
#   2) 新建线程并注入 prompt —— `open "zed://agent?prompt=<form-urlencoded>"`。
#      prompt 经 URL 传递：中文/多行无需剪贴板。Zed 会清洗：剥掉控制字符
#      （保留 \n\t）、\r\n 归一为 \n、连续超过 2 个换行折叠为 2 个。
#      源码（agent_ui thread_view 的 FromExternalSource 分支）带 SECURITY 注释
#      明确【不自动提交】，prompt 只填进编辑器。
#   3) 提交 —— AppleScript 激活 Zed 后发送 cmd+return（需「辅助功能」权限）。
#
# agent（harness）与模型不由本脚本参数指定：
#   - 新线程使用 Zed 记忆的 last-used agent（Agent Panel 里手动切换一次即记住，
#     per-workspace 状态优先、全局 kv 兜底）；
#   - 模型经 ~/.config/zed/settings.json 的
#     agent_servers.<agent-id>.default_config_options.model 指定，热生效，
#     作用于之后新建的线程；写无效值会被 Zed 警告并回落到该 agent 自己的默认。
#
# 前置：macOS；python3；提交 prompt 需要运行 osascript 的宿主在
#   系统设置 → 隐私与安全性 → 辅助功能 中被授权（报 -1719 即未授权）。
# 已知时序：registry 外部 agent（如 codex-acp）首次被拉起会现场 npm install
#   （可达数分钟），期间线程编辑器未就绪、过早的提交键会丢失；重跑本脚本即可。

set -euo pipefail

APP_PATH="${ZED_APP:-/Applications/Zed.app}"
WORKSPACE=""
PROMPT=""
SUBMIT_DELAY="${ZED_SUBMIT_DELAY:-5}"
TAG="[new_zed_session]"

usage() {
  sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -w|--workspace)
      if [[ $# -lt 2 || -z "${2:-}" ]]; then
        echo "$TAG 缺少 workspace 参数。" >&2
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
      echo "$TAG 未知参数：$1" >&2
      usage >&2
      exit 2
      ;;
    *)
      PROMPT="$1"
      shift
      if [[ $# -gt 0 ]]; then
        echo "$TAG prompt 请作为单个参数传入；多行可用 \$'第一行\\n第二行'。" >&2
        exit 2
      fi
      ;;
  esac
done

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "$TAG 仅支持 macOS（zed:// launch link 与 System Events 键击）。" >&2
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "$TAG 未找到 python3；无法编码 URL 与 AppleScript 字面量。" >&2
  exit 1
fi

if [[ -n "$WORKSPACE" ]]; then
  if [[ ! -d "$WORKSPACE" ]]; then
    echo "$TAG workspace 不存在或不是目录：$WORKSPACE" >&2
    exit 2
  fi
  WORKSPACE="$(cd "$WORKSPACE" && pwd)"
fi

# --- 定位 cli ---
CLI_PATH="${ZED_CLI:-}"
if [[ -z "$CLI_PATH" ]]; then
  if command -v zed >/dev/null 2>&1; then
    CLI_PATH="$(command -v zed)"
  elif [[ -x "$APP_PATH/Contents/MacOS/cli" ]]; then
    CLI_PATH="$APP_PATH/Contents/MacOS/cli"
  else
    echo "$TAG 未找到 Zed cli（zed 不在 PATH，且 $APP_PATH 不存在）。" >&2
    exit 1
  fi
fi

run_applescript() {
  # run_applescript <script_text> -> prints result, returns osascript exit code
  local scpt="$1"
  local tmp
  tmp="$(mktemp -t zed_new_session.XXXXXX).scpt"
  printf '%s\n' "$scpt" > "$tmp"
  osascript "$tmp" 2>&1
  local rc=$?
  rm -f "$tmp"
  return $rc
}

# --- 步骤 1：确保目标 workspace 窗口存在 ---
if [[ -n "$WORKSPACE" ]]; then
  "$CLI_PATH" -n "$WORKSPACE" >/dev/null 2>&1 || true
  BASENAME="$(basename "$WORKSPACE")"
  ESC_BASE="$(python3 -c 'import sys; s=sys.argv[1]; print("\"" + s.replace("\\","\\\\").replace("\"","\\\"") + "\"")' "$BASENAME")"
  read -r -d '' POLL_SCPT <<'APPLESCRIPT_EOF' || true
on hasWin()
	tell application "System Events"
		tell process "Zed"
			repeat with w in windows
				try
					if name of w contains BASENAME_PLACEHOLDER then return true
				end try
			end repeat
		end tell
	end tell
	return false
end hasWin

repeat 150 times
	if hasWin() then return "ok"
	delay 0.3
end repeat
error "workspace window not found"
APPLESCRIPT_EOF
  POLL_SCPT="${POLL_SCPT/BASENAME_PLACEHOLDER/$ESC_BASE}"
  if ! RESULT=$(run_applescript "$POLL_SCPT"); then
    echo "$TAG workspace 窗口未就绪：${RESULT}" >&2
    echo "$TAG workspace: ${WORKSPACE}" >&2
    exit 1
  fi
  sleep 1
else
  read -r -d '' RUNNING_SCPT <<'APPLESCRIPT_EOF' || true
tell application "System Events"
	return exists process "Zed"
end tell
APPLESCRIPT_EOF
  if ! RESULT=$(run_applescript "$RUNNING_SCPT"); then
    echo "$TAG 检测 Zed 进程失败：${RESULT}" >&2
    exit 1
  fi
  if [[ "$RESULT" != "true" ]]; then
    "$CLI_PATH" >/dev/null 2>&1 || true
    sleep 3
  fi
  echo "$TAG 未指定 -w：线程将落在 Zed 当前活动 workspace（活动窗口是 empty project 时会静默不建线程）。" >&2
fi

# --- 步骤 2：zed://agent URL 新建线程并注入 prompt ---
URL="$(python3 - "$PROMPT" <<'PY'
import sys
from urllib.parse import quote

prompt = sys.argv[1] if len(sys.argv) > 1 else ""
url = "zed://agent"
if prompt.strip():
    url += "?prompt=" + quote(prompt, safe="")
print(url)
PY
)"

if [[ ${#PROMPT} -gt 4096 ]]; then
  echo "$TAG prompt 为 ${#PROMPT} 字符，超出常规单句任务协议；zed:// URL 超长行为未验证，建议缩短。" >&2
fi

if ! open "$URL"; then
  echo "$TAG 无法打开 zed:// launch link：${URL}" >&2
  echo "$TAG 确认 $APP_PATH 已登记 zed:// scheme。" >&2
  exit 1
fi

# 无 prompt：到此结束（线程已新建，编辑器留空）
if [[ -z "$PROMPT" || -z "${PROMPT//[[:space:]]/}" ]]; then
  echo "$TAG 已新建 agent 线程（无 prompt，不发送）。"
  if [[ -n "$WORKSPACE" ]]; then
    echo "$TAG workspace: ${WORKSPACE}"
  fi
  exit 0
fi

# --- 步骤 3：等待编辑器就绪并发送提交键（cmd+return） ---
sleep "$SUBMIT_DELAY"

read -r -d '' SUBMIT_SCPT <<'APPLESCRIPT_EOF' || true
on isFront()
	tell application "System Events"
		return (name of first application process whose frontmost is true) is "Zed"
	end tell
end isFront

if not isFront() then
	tell application "Zed" to activate
	repeat 25 times
		if isFront() then exit repeat
		delay 0.2
	end repeat
end if
if not isFront() then error "Zed did not come to front"

-- URL 注入永不自动提交（源码 SECURITY 约束），由这里补上 cmd+return
tell application "System Events"
	keystroke return using command down
end tell
return "sent"
APPLESCRIPT_EOF

if ! RESULT=$(run_applescript "$SUBMIT_SCPT"); then
  echo "$TAG 已注入 prompt，但发送提交键失败：${RESULT}" >&2
  echo "$TAG 提示：确认已授予运行 osascript 的终端「辅助功能」权限（报 -1719 即未授权）。" >&2
  exit 1
fi

echo "$TAG 已新建 agent 线程并提交 prompt 开始执行。"
if [[ -n "$WORKSPACE" ]]; then
  echo "$TAG workspace: ${WORKSPACE}"
fi
echo "$TAG prompt_bytes: ${#PROMPT}"
echo "$TAG 注：提交键发出即完成；不轮询新线程。若目标 agent 首次安装中（npm install），提交键会丢失，重跑本脚本即可。"
