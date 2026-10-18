# 新会话启动后端

循环任务通过新的独立会话分离立项、评审、工作和验收角色。任务文件包含完整协议；会话启动文件只负责打开指定工作区并提交提示词。

## 后端

下表的说明文件与脚本 ensure 后位于目标仓库的 `prompt/skill/`。

| 用户指定 | 说明文件 | 脚本 |
|---|---|---|
| 默认、Cursor Agents Window | `new-cursor-agent-session.md` | `new_cursor_agent_session.sh` |
| Cursor2 | `new-cursor2-agent-session.md` | `new_cursor2_agent_session.sh` |
| Cursor3 | `new-cursor3-agent-session.md` | `new_cursor3_agent_session.sh` |
| Cursor4 | `new-cursor4-agent-session.md` | `new_cursor4_agent_session.sh` |
| Cursor5 | `new-cursor5-agent-session.md` | `new_cursor5_agent_session.sh` |
| Cursor Cloud | `spawn-cloud-agent-session.md` | `spawn_cloud_agent.sh` |
| ZCode | `new-zcode-session.md` | `new_zcode_session.sh` |
| Codex | `new-codex-session.md` | `new_codex_session.sh` |
| Waku | `new-waku-session.md` | `new_waku_session.sh` |
| Zed | `new-zed-session.md` | `new_zed_session.sh` |
| Claude（桌面 Code session） | `new-claude-session.md` | `new_claude_session.sh` |

源文件：

- 本地后端（Cursor / Cursor2–5 / Codex / ZCode / Waku / Zed / Claude）的权威位置是 `~/.agents/skills/launch-local-agent-session/`。生成任务时用 `~/.agents/skills/launch-local-agent-session/scripts/ensure-into-repo.sh` 把所选后端拷进 `prompt/skill/`。
- 云端后端的权威位置仍是本 skill 的 `sessions/`。
- 本 skill `sessions/` 里仍留有本地后端的副本，仅在 `launch-local-agent-session` 尚未安装时回退使用。

循环任务的每个角色可以使用不同后端与启动参数。生成任务时对本次运行用到的每个后端各准备一次——任务文件的各启动出口（含 Task 1 的再设计启动）、队列终止句，以及 Task 1 的首启后端；未单独指定的任务使用默认后端，默认后端未指定时为 Cursor Agents Window。

## 准备规则

1. 仓库中的目标目录为 `prompt/skill/`。
2. 本地后端调用（任务用到的每个本地后端各执行一次）：

   ```bash
   bash "$HOME/.agents/skills/launch-local-agent-session/scripts/ensure-into-repo.sh" \
     -C "$(pwd)" <backend>
   ```

   该 skill 不存在时，再从本 skill `sessions/` 复制对应的说明文件和脚本。
3. 云端后端从本 skill `sessions/` 复制 `spawn-cloud-agent-session.md` 与 `spawn_cloud_agent.sh`。
4. shell 脚本必须具有执行权限。
5. 目标文件已经存在且可正常使用时不覆盖，避免影响仍在执行的旧任务。
6. 任务文件中的 `{{SESSION_SKILL_DESIGN}}` / `{{SESSION_SKILL_REVIEW}}` / `{{SESSION_SKILL_WORK}}` / `{{SESSION_SKILL_ACCEPT}}` 分别使用 Task 1（立项与再设计）、评审、工作轮、验收轮所选说明文件的仓库相对路径；`{{SESSION_ARGS_*}}` 按 SKILL.md 定义写启动参数后缀，本地后端无额外参数时为 `，启动参数：`-w "$(pwd)"``。
7. 启动下一轮时按 `launch-local-agent-session` 的硬性规则执行脚本；不要手写 `cursor -r`/`-n`，也不要把 prompt 发进当前对话。

## 启动参数

各后端支持的启动选项以其说明文件「用法」段（及脚本 usage 头）为准，生成时不得写入不支持的选项：

- 全部本地后端：`-w <workspace>`。**默认必须写 `-w "$(pwd)"`**——本地后端的新建会话命令不接受路径、新会话落在当前前台 workspace，不写 `-w` 时目录正确性只靠「前台恰好是本仓库」成立（2026-09-05 实测踩过）。用户显式指定其它目录时写该目录，且必须保证新会话仍能读到任务文件。Zed 的 URL 只路由到当前活动 workspace，`-w` 同样必需。
- Waku：另支持 `--harness <id>` / `--model <id>` / `--effort <id>`，省略时使用 Waku 的记忆默认。
- Cursor Cloud（`spawn_cloud_agent.sh`）：`-n <name>` / `-r <repo>` / `-m <model>`，无 `-w`。
- Claude：只支持 `-w`（编码为 `claude://code/new?folder=`）。模型 / effort 没有逐次启动参数；权限模式靠全局 `~/.claude/settings.json` 的 `permissions.defaultMode: "bypassPermissions"`；链接每次弹的 Trust 确认框由脚本核对路径后自动点，并先开一次垫步目录规避桌面端「同一文件夹重开落进 scratch」的缺陷（见其说明文件）。协议原句用 ASCII 标点（全角标点会被归一）。
- Zed：只支持 `-w`。agent（harness）与模型没有逐次启动参数，须先在 Zed 里配置（Agent Panel 手动选一次 agent；模型经 `~/.config/zed/settings.json` 的 `agent_servers.<id>.default_config_options.model`），见其说明文件。

启动参数放在脚本参数中、prompt 之前，与任务文件启动句中的后缀一致。

## 启动示例

默认 Cursor Agents Window：

```bash
bash prompt/skill/new_cursor_agent_session.sh -w "$(pwd)" \
  "Please execute docs/<slug>/<slug>-task.md Task 1."
```

Cursor2：

```bash
bash prompt/skill/new_cursor2_agent_session.sh -w "$(pwd)" \
  "Please execute docs/<slug>/<slug>-task.md Task 1."
```

Cursor Cloud：

```bash
bash prompt/skill/spawn_cloud_agent.sh \
  "Please execute docs/<slug>/<slug>-task.md Task 1."
```

Waku 指定 harness 与 model（对应任务文件中的「启动参数：`--harness claude --model claude-sonnet-4-6`」）：

```bash
bash prompt/skill/new_waku_session.sh --harness claude --model claude-sonnet-4-6 \
  -w "$(pwd)" "Please execute docs/<slug>/<slug>-task.md Task 1."
```

Zed（Agent Panel 线程）：

```bash
bash prompt/skill/new_zed_session.sh -w "$(pwd)" \
  "Please execute docs/<slug>/<slug>-task.md Task 1."
```

Claude（桌面 Code session）：

```bash
bash prompt/skill/new_claude_session.sh -w "$(pwd)" \
  "Please execute docs/<slug>/<slug>-task.md Task 1."
```

## 状态传递

- 本地 Agents Window 共享同一个工作目录，不要求每轮创建协议专用提交。
- 云端或新的 clone 只能读取远端可达的提交。使用这类后端时，应按后端说明把任务相关变更提交到可读取的分支，且不得包含无关工作区改动。
- 不同任务混用后端时，该约束按被启动的那一轮适用：某个启动出口指向云端（或其它只能读远端提交的）后端时，执行该启动句的上一轮会话必须先把任务相关变更提交并推送到该后端可读取的分支。
- 协议文件负责终止条件；启动脚本不应自行重复启动会话。
