#!/usr/bin/env bash
# 通过 Cloud Agents API（POST https://api.cursor.com/v1/agents）开启一个新的独立 Cloud Agent session。
#
# 用法：
#   spawn_cloud_agent.sh "任务 prompt"                          # repo 默认取当前 git 仓库 origin
#   spawn_cloud_agent.sh -n my-task "任务 prompt"                # 指定显示名
#   spawn_cloud_agent.sh -r https://github.com/owner/repo "任务 prompt"   # 指定仓库
#   spawn_cloud_agent.sh -m composer "任务 prompt"               # 指定模型 id（走该模型默认档位）
#
# 模型缺省为 Fable 5 Max（claude-fable-5：thinking=true, context=1m, effort=max）。
# 用 -m 覆盖为其他模型 id（可用 GET /v1/models 查询）；-m default 回到系统 Auto。
#
# 依赖：curl、python3、环境变量 CURSOR_API_KEY（agent 专用 key）。
# 安全：key 仅经 -u "$CURSOR_API_KEY:" 引用，本脚本不打印、不落盘。
#
# 成功：exit 0，输出 agent_id（bc-*）、run_id、url。
# 失败：exit 非 0，stderr 给出原因（HTTP 状态码与响应体，响应体不含敏感信息）。

set -euo pipefail

NAME=""
REPO_URL=""
MODEL_ID=""
PROMPT=""

usage() {
  sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--name)
      if [[ $# -lt 2 || -z "${2:-}" ]]; then
        echo "[spawn_cloud_agent] 缺少 -n 参数值。" >&2; usage >&2; exit 2
      fi
      NAME="$2"; shift 2 ;;
    -r|--repo)
      if [[ $# -lt 2 || -z "${2:-}" ]]; then
        echo "[spawn_cloud_agent] 缺少 -r 参数值。" >&2; usage >&2; exit 2
      fi
      REPO_URL="$2"; shift 2 ;;
    -m|--model)
      if [[ $# -lt 2 || -z "${2:-}" ]]; then
        echo "[spawn_cloud_agent] 缺少 -m 参数值。" >&2; usage >&2; exit 2
      fi
      MODEL_ID="$2"; shift 2 ;;
    -h|--help)
      usage; exit 0 ;;
    --)
      shift; PROMPT="${*:-}"; break ;;
    -*)
      echo "[spawn_cloud_agent] 未知参数：$1" >&2; usage >&2; exit 2 ;;
    *)
      PROMPT="$1"; shift
      if [[ $# -gt 0 ]]; then
        echo "[spawn_cloud_agent] prompt 请作为单个参数传入；多行可用 \$'第一行\\n第二行'。" >&2
        exit 2
      fi ;;
  esac
done

if [[ -z "$PROMPT" ]]; then
  echo "[spawn_cloud_agent] 缺少任务 prompt。" >&2
  usage >&2
  exit 2
fi

if [[ -z "${CURSOR_API_KEY:-}" ]]; then
  echo "[spawn_cloud_agent] 未设置环境变量 CURSOR_API_KEY。" >&2
  echo "[spawn_cloud_agent] 本地：export CURSOR_API_KEY=...；Cloud Agent：在 Dashboard → Cloud Agents → Secrets 配置。" >&2
  exit 1
fi

# repo 缺省：当前 git 仓库 origin（ssh 形式转 https，去掉 .git 后缀）
if [[ -z "$REPO_URL" ]]; then
  origin="$(git remote get-url origin 2>/dev/null || true)"
  if [[ "$origin" == git@github.com:* ]]; then
    REPO_URL="https://github.com/${origin#git@github.com:}"
  else
    REPO_URL="$origin"
  fi
  REPO_URL="${REPO_URL%.git}"
  # 剥离 URL 内嵌凭据（如 Cloud Agent VM 中 origin 常为 https://x-access-token:<token>@github.com/...），
  # 防止把 token 发给 API 或带进输出
  REPO_URL="$(printf '%s' "$REPO_URL" | sed -E 's#^(https?://)[^/@]*@#\1#')"
  if [[ -z "$REPO_URL" ]]; then
    echo "[spawn_cloud_agent] 无法从当前目录的 git origin 推断仓库，请用 -r 指定。" >&2
    exit 2
  fi
fi

# 先验证 key 可用，失败早退，避免误判为创建接口的问题
ME_CODE="$(curl -sS -o /dev/null -w "%{http_code}" -u "${CURSOR_API_KEY}:" https://api.cursor.com/v1/me || true)"
if [[ "$ME_CODE" != "200" ]]; then
  echo "[spawn_cloud_agent] CURSOR_API_KEY 校验失败（GET /v1/me → HTTP ${ME_CODE}）。" >&2
  echo "[spawn_cloud_agent] 请确认是 Dashboard → Integrations 生成的 agent 专用 key。" >&2
  exit 1
fi

# 用 python3 组装 JSON，避免 prompt 中引号/换行破坏请求体
PAYLOAD="$(SPAWN_NAME="$NAME" SPAWN_PROMPT="$PROMPT" SPAWN_REPO="$REPO_URL" SPAWN_MODEL="$MODEL_ID" python3 - <<'PY'
import json, os
body = {
    "prompt": {"text": os.environ["SPAWN_PROMPT"]},
    "repos": [{"url": os.environ["SPAWN_REPO"]}],
    "autoCreatePR": False,
}
if os.environ.get("SPAWN_NAME"):
    body["name"] = os.environ["SPAWN_NAME"]
model = os.environ.get("SPAWN_MODEL")
if not model:
    # 缺省：Fable 5 Max（2026-07-14 经 POST /v1/agents 实测，见 SKILL.md 验证记录）
    body["model"] = {"id": "claude-fable-5", "params": [
        {"id": "thinking", "value": "true"},
        {"id": "context", "value": "1m"},
        {"id": "effort", "value": "max"},
    ]}
elif model != "default":
    body["model"] = {"id": model}
print(json.dumps(body, ensure_ascii=False))
PY
)"

TMP_BODY="$(mktemp)"
trap 'rm -f "$TMP_BODY"' EXIT

HTTP_CODE="$(curl -sS -o "$TMP_BODY" -w "%{http_code}" -X POST \
  -u "${CURSOR_API_KEY}:" \
  -H "Content-Type: application/json" \
  --data "$PAYLOAD" \
  https://api.cursor.com/v1/agents)"

if [[ "$HTTP_CODE" != "201" ]]; then
  echo "[spawn_cloud_agent] 创建失败（HTTP ${HTTP_CODE}）：$(cat "$TMP_BODY")" >&2
  exit 1
fi

python3 - "$TMP_BODY" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
agent = data.get("agent", {})
run = data.get("run", {})
print(f"[spawn_cloud_agent] agent_id {agent.get('id')}")
print(f"[spawn_cloud_agent] name     {agent.get('name')}")
print(f"[spawn_cloud_agent] run_id   {run.get('id')} ({run.get('status')})")
print(f"[spawn_cloud_agent] url      {agent.get('url')}")
PY
