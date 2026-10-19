# 在 Zed Agent Panel 中启动新的独立 Agent Session（并可提交 prompt 开始执行）

> **权威位置**：`~/.agents/skills/launch-local-agent-session/sessions/`  
> 任意场景优先跑本目录脚本（或 `../scripts/launch.sh zed`）。循环任务 ensure 后的仓库副本：`prompt/skill/`。  
> 不要把路径与 `zed://agent` URL 合并进一条 cli 命令、不要把 prompt 发进当前对话。云端 Cloud Agent 不在本 skill。

> 用途：从脚本/自动化里**在 Zed 桌面应用的 Agent Panel 中新建一个独立的 agent 线程**，
> 并可选地**注入 prompt 文本、提交发送、开始执行**。
>
> 目标是其它本地 GUI 后端的对等物：一个**新的 Zed agent session**（内置 Zed agent
> 或外部 ACP agent，如 codex-acp / claude-acp），而不是往当前线程里再塞一条消息。

## 调研结论（为什么是「cli 开窗口 → URL 注入 → 键击提交」三步）

Zed（核实版本 **1.20.2**）的 CLI 没有任何 agent 子命令；可编程入口只有三个，
组合成本脚本路径（源码：`crates/zed/src/zed/open_listener.rs`、`crates/zed/src/main.rs`）：

1. **`cli -n <dir>`** 打开指定目录的 workspace 窗口。
2. **`open "zed://agent?prompt=<form-urlencoded>"`** 路由到「当前活动 multi-workspace」
   的 Agent Panel，新建线程并填充 prompt。URL 天然支持中文/多行（`\n` 有效，
   但会被清洗：控制字符剥除、`\r\n`→`\n`、连续 >2 换行折叠为 2 个）。
3. **`cmd+return`** 提交。源码级硬约束（`agent_ui` thread_view 的
   `FromExternalSource` 分支，带 SECURITY 注释）：**URL 注入的 prompt 永不自动提交**，
   只填进编辑器，必须补一次键击。

### 为什么 URL 和目录不能合并

`cli <dir> "zed://agent?..."` 一条命令**不行**：open_listener 对带 `kind`（AgentPanel）
的请求短路返回，`open_paths` 被跳过。必须先 `cli -n <dir>`，再 `open` URL。
URL 落到「当前活动 workspace」——这就是循环任务必须显式 `-w` 的机制原因。

### 已排除 / 会踩坑的方式

| 方式 | 结果 |
|---|---|
| `cli <dir> "zed://agent?…"` 合并 | 路径被跳过；URL 打进当前活动窗口 |
| 只发 URL 不键击 | prompt 留在编辑器，永不发送（SECURITY 约束） |
| 用 Enter 而非 cmd+return 提交 | 换行进 prompt，不发送 |
| prompt 经剪贴板粘贴 | 不必要：URL 已支持多行/中文；且多一次剪贴板副作用 |
| `cli agent`、`cli --dev-server-token` | 不存在 / 未实现 |
| 空窗口发 URL（empty project） | `external_thread` 直接 return，线程不建、无报错 |

## agent（harness）与模型怎么指定

- **agent**：新线程使用 Zed 记忆的 last-used agent——`~/.config/zed/settings.json`
  的 `agent_servers` 声明可用集合（codex-acp、claude-acp 等 registry agent），
  实际选中 per-workspace 状态优先、全局 kv（`agent_panel__last_used_external_agent`）
  兜底。**切换方式：在目标 workspace 的 Agent Panel 里手动选一次**（随后记住）。
  Zed 退出时也可直接改 `~/Library/Application Support/Zed/db/0-stable/db.sqlite`
  的 `scoped_kv_store`（namespace `agent_panel`）与全局 kv，重启生效。
- **模型**：`settings.json` → `agent_servers["codex-acp"].default_config_options.model`
  热生效，作用于之后新建的线程。无效值会被 Zed 警告并回落到该 agent 自身默认
  （实测 `gpt-5.6-terra` 无效 → 回落 `gpt-5.6-sol`；`GLM-5.3-flash` 生效）。
  模型目录以本机 `~/.codex/model-catalogs/*.json`（codex-acp）等为准。
- 本脚本**不提供** `--harness` / `--model` 参数：这两者在 Zed 里没有逐请求的
  编程入口，只有上述持久配置。任务协议要换 agent/模型时，先改配置再启动。

## 前置条件

1. **macOS**；`python3`。
2. **`/Applications/Zed.app`**（或 `ZED_APP` 指定的安装）已登记 `zed://` scheme。
3. **`zed` cli**：PATH 里的 `zed`，或 `ZED_APP/Contents/MacOS/cli`。
4. **辅助功能权限**：发送提交键的宿主（终端）须在
   `系统设置 → 隐私与安全性 → 辅助功能` 中被勾选；报 `-1719` 即未授权。
5. 目标 agent 可用：registry 外部 agent（如 codex-acp）**首次**被拉起会现场
   `npm install`（实测约 5 分钟 / 300MB），期间线程编辑器未就绪，过早的提交键
   会丢失——等装完重跑脚本即可。

## 用法

```bash
# 活动窗口：仅新建线程
bash prompt/skill/new_zed_session.sh

# 活动窗口：新建线程并提交 prompt
bash prompt/skill/new_zed_session.sh "你的 prompt"

# 指定目录（推荐，循环任务必须显式 -w）
bash prompt/skill/new_zed_session.sh -w /path/to/workspace "你的 prompt"

# 多行 prompt
bash prompt/skill/new_zed_session.sh -w /path/to/workspace $'第一行\n第二行'

# agent 首次安装后重试：放宽 URL→提交键的等待
ZED_SUBMIT_DELAY=15 bash prompt/skill/new_zed_session.sh -w /path "你的 prompt"
```

调度器等价：

```bash
bash "$HOME/.agents/skills/launch-local-agent-session/scripts/launch.sh" \
  zed -w "$(pwd)" "你的 prompt"
```

脚本行为：

- `-w` 时先 `cli -n <dir>` 开 workspace 窗口并等窗口出现（窗口名含目录 basename）；
- 无 `-w` 时仅确保 Zed 在跑，并警告线程会落在当前活动 workspace（可能是 empty
  project，那样 URL 会被静默忽略）；
- form-urlencoded 编码 prompt 进 `zed://agent?prompt=`；
- 无 prompt 时到此结束（线程已建、编辑器留空）；
- 有 prompt 时等 `ZED_SUBMIT_DELAY`（默认 5s）编辑器就绪，激活 Zed 发送
  `cmd+return`；不轮询线程状态。

## 触发方式对比

| 方式 | 结果 |
|---|---|
| **cli `-n` → URL → cmd+return（本脚本）** | 指定目录新建独立线程并开始执行 |
| `zed://agent?…` + Enter | 换行进编辑器，不发送；必须 cmd+return |
| Agent Panel 里 `agent::NewThread` 手动新建 | 无法携带 prompt |
| 剪贴板粘贴 | 会贴进**当前活动线程**的编辑器，不是新线程 |
| `cli -e/--add` 等编辑器 flag | 与 agent 线程无关 |

## 在任务文件循环中的用法

与其它本地后端一致：先提交本轮产物，再以协议原句启动下一轮。

```bash
bash prompt/skill/new_zed_session.sh -w "$(git rev-parse --show-toplevel)" \
  "Please execute docs/<slug>/<slug>-task.md <立项|评审|工作轮|验收轮>."
```

**prompt 保持协议原句一句话，不要塞附加说明。**

## 验证记录（2026-09-19）

环境：Zed 1.20.2（stable），外部 agent `codex-acp`（registry），模型目录
`~/.codex/model-catalogs/omniroute-restricted.json`。

1. **URL 注入不自动提交**（源码核对）：`open_listener.rs` 把
   `zed://agent?prompt=` 解析为 `AgentPanel { external_source_prompt }`；
   `thread_view.rs` `FromExternalSource` 分支 `should_auto_submit = false`
   （SECURITY 注释显式声明）。
2. **完整闭环**：`cli -n /tmp/zed-agent-exp` → `open zed://agent?prompt=…PONG42…`
   → AppleScript `cmd+return`。codex 侧证据
   `~/.codex/sessions/.../rollout-*.jsonl`：USER 消息正是注入的 prompt，
   ASSISTANT 回复 `PONG42`，`cwd=/private/tmp/zed-agent-exp` 正确。
3. **模型指定**：`default_config_options.model` 由 `gpt-5.6-terra`（无效，
   Zed 日志 WARN 后回落 `gpt-5.6-sol`）改为 `GLM-5.3-flash` 后重跑，
   codex `turn_context.model=GLM-5.3-flash`，回复 `FLASH_OK_77`。
4. **失败模式复现**：活动窗口为 empty project 时 URL 被静默忽略；
   last-used agent 为损坏的 `grok-build`（spawn 即崩）时同样无线程。
   切到 codex-acp 后恢复。
