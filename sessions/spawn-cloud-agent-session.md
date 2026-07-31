---
name: spawn-cloud-agent-session
description: 用环境变量 CURSOR_API_KEY 调用 Cloud Agents API（POST https://api.cursor.com/v1/agents）程序化开启新的独立 Cloud Agent session。当用户要求自动开启/派生新的 Cloud Agent 会话（包括在一个 Cloud Agent session 内再开子 session）、批量派发云端任务、追加 follow-up run、或询问如何用 API/脚本启动 cloud agent 时使用。
---

# 通过 Cloud Agents API 开启新的 Cloud Agent session

目标：不经过任何 GUI，用 REST API 开出一个**独立的** `bc-*` Cloud Agent session。适用于本地脚本、CI，以及在一个 Cloud Agent session 内部再开子 session。

与 `prompt/skill/new-cursor-agent-session.md` 的分工：那个 skill 在 macOS 桌面 Agents Window 里开本地 GUI session；本 skill 开的是云端 session，无桌面依赖，Cloud Agent / CI 内也可用。

## 前置条件

1. 环境变量 `CURSOR_API_KEY`：**agent 专用 API key**（Cursor Dashboard → Integrations → API Keys 生成；普通 dashboard key 可能只够 GET，`POST /v1/agents` 会 500）。
   - 本地：自行 export。
   - Cloud Agent 内：在 Dashboard → Cloud Agents → Secrets 配置后自动注入新 VM。
2. `curl` 与 `python3`（脚本依赖）。
3. 目标仓库须在 Cursor GitHub App 的授权范围内。

**安全红线：key 只能以 `-u "$CURSOR_API_KEY:"` 的形式从环境变量引用；绝不打印完整值，绝不写入文件、日志、代码或提交。**

## 快捷方式：脚本

```bash
# 默认 repo = 当前 git 仓库的 origin；默认模型 = Fable 5 Max
bash prompt/skill/spawn_cloud_agent.sh "你的任务 prompt"

# 指定显示名 / 仓库 / 模型（-m default 回到系统 Auto）
bash prompt/skill/spawn_cloud_agent.sh \
  -n my-task -r https://github.com/owner/repo -m composer "你的任务 prompt"
```

成功时输出 `agent_id`（`bc-*`）、`run_id`、URL，退出码 0；任何失败退出码非 0。

## 手工步骤（脚本背后做的事）

### 1. 确认 key 存在（不打印值）

```bash
[[ -n "${CURSOR_API_KEY:-}" ]] && echo "set, len=${#CURSOR_API_KEY}"
```

### 2. 验证 key 可用

```bash
curl -sS -u "${CURSOR_API_KEY}:" https://api.cursor.com/v1/me
# 200 + {"apiKeyName":...,"userId":...} 即可用
```

### 3. 创建 agent（即开出新 session）

```bash
curl -sS -X POST https://api.cursor.com/v1/agents \
  -u "${CURSOR_API_KEY}:" \
  -H "Content-Type: application/json" \
  --data '{
    "name": "my-task",
    "prompt": { "text": "任务内容" },
    "repos": [ { "url": "https://github.com/owner/repo" } ],
    "autoCreatePR": false
  }'
```

成功：HTTP 201，响应含 `agent.id`（`bc-*`，即新 session id）、`agent.url`（`https://cursor.com/agents/<bc-id>`）、`run.id`（`run-*`，初始 `CREATING`）。

请求体关键字段：

| 字段 | 说明 |
|---|---|
| `prompt.text`（必填） | 任务 prompt；实验/短任务务必写明「不要改文件、不要开 PR」 |
| `repos[].url` | GitHub 仓库 URL；可加 `startingRef` 指定起始分支或 commit（不传时新 session 克隆仓库**默认分支 main**） |
| `name`（可选） | 显示名 ≤100 字符；缺省由 prompt 自动生成 |
| `model`（可选） | API 缺省用系统 Auto（2026-07 实测解析到 claude-4.5-sonnet-thinking）；**本 skill 脚本缺省注入 Fable 5 Max**：`{"id":"claude-fable-5","params":[{"id":"thinking","value":"true"},{"id":"context","value":"1m"},{"id":"effort","value":"max"}]}`。只传 `model.id` 时走该模型默认档位；模型与档位可用 `GET /v1/models` 查询（`items[].parameters` / `variants`） |
| `autoCreatePR`（可选） | `false` 时只推分支不开 PR |
| `envVars`（可选） | 注入子 session 的环境变量；名称不能以 `CURSOR_` 开头 |

### 4. 跟踪结果与追问

```bash
# 查单次 run 状态；status=FINISHED 后 result 即最终回复文本
curl -sS -u "${CURSOR_API_KEY}:" https://api.cursor.com/v1/agents/<bc-id>/runs/<run-id>

# 向既有 session 追加后续任务（新开一个 run，沿用会话与工作区状态）
curl -sS -X POST -u "${CURSOR_API_KEY}:" -H "Content-Type: application/json" \
  --data '{"prompt":{"text":"后续任务"}}' \
  https://api.cursor.com/v1/agents/<bc-id>/runs

# 列出 agents（newest first）
curl -sS -u "${CURSOR_API_KEY}:" "https://api.cursor.com/v1/agents?limit=20"
```

## 必知注意事项

1. **UI 默认隐藏 API 来源的 session**：`source=api` 的 agent 不出现在 cursor.com/agents 与 Agents Window 的默认列表，需在列表的 **Filter → Source 勾选 API** 才可见；直链 `https://cursor.com/agents/<bc-id>` 始终可打开。
2. **额度**：每个子 session 独立消耗额度，prompt 尽量短小明确，用 `autoCreatePR: false` 避免多余动作。
3. **递归风险**：子 session 若与父 session 同仓库同环境，会注入同样的 secrets（含 `CURSOR_API_KEY`），可以继续派生孙 session。编排多级任务时必须显式设置终止条件，防止失控递归。
4. **多仓库 agent 目前不显示在列表 UI**（2026-06 官方论坛确认），单仓库不受影响。
5. **新会话只能看到它克隆的分支——接力任务先保证产出可达**：不带 `startingRef` 时新 session 从默认分支（main）克隆，看不到父 session 工作分支上未合并的提交。凡新 session 依赖本轮产出的接力任务（评审→裁决→实现等收敛循环），启动前必须先把产出合并/推送到 main（本仓库惯例即在 main 上工作），或在 `repos[]` 显式传 `startingRef` 指向工作分支（脚本未封装该参数，需按「手工步骤」手工 curl）。已踩坑（doc0 仓库，2026-07-15）：评审产出只推了工作分支就 spawn 裁决轮，新会话对着 main 上的过期 review 做重复裁决；补救为删除该会话（`DELETE /v1/agents/<bc-id>` → 200，RUNNING 中亦可终止）、fast-forward 合并 main 后重开。

## 备注

脚本本身（`scripts/spawn_cloud_agent.sh`）靠 `git remote get-url origin` 自动推断仓库，与具体仓库无关，已在 doc0 仓库端到端验证可用。本仓库首次使用前建议先用 `GET /v1/me` 验证 key 可用。
