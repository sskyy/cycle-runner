# 新会话启动后端

循环任务通过新的独立会话分离设计、评审、实现和审计角色。任务文件包含完整协议；会话启动文件只负责打开指定工作区并提交提示词。

## 后端

| 用户指定 | 说明文件 | 脚本 |
|---|---|---|
| 默认、Cursor Agents Window | `prompt/skill/new-cursor-agent-session.md` | `prompt/skill/new_cursor_agent_session.sh` |
| Cursor2 | `prompt/skill/new-cursor2-agent-session.md` | `prompt/skill/new_cursor2_agent_session.sh` |
| Cursor3 | `prompt/skill/new-cursor3-agent-session.md` | `prompt/skill/new_cursor3_agent_session.sh` |
| Cursor4 | `prompt/skill/new-cursor4-agent-session.md` | `prompt/skill/new_cursor4_agent_session.sh` |
| Cursor5 | `prompt/skill/new-cursor5-agent-session.md` | `prompt/skill/new_cursor5_agent_session.sh` |
| Cursor Cloud | `prompt/skill/spawn-cloud-agent-session.md` | `prompt/skill/spawn_cloud_agent.sh` |
| ZCode | `prompt/skill/new-zcode-session.md` | `prompt/skill/new_zcode_session.sh` |
| Codex | `prompt/skill/new-codex-session.md` | `prompt/skill/new_codex_session.sh` |

源文件位于本 skill 的 `sessions/`。生成任务时只需准备用户选择的后端；用户未指定时准备 Cursor Agents Window。

## 准备规则

1. 仓库中的目标目录为 `prompt/skill/`。
2. 目标文件不存在时，从 `sessions/` 复制对应的说明文件和脚本。
3. shell 脚本必须具有执行权限。
4. 目标文件已经存在且可正常使用时不覆盖，避免影响仍在执行的旧任务。
5. 任务文件中的 `{{SESSION_SKILL}}` 使用说明文件的仓库相对路径。

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

## 状态传递

- 本地 Agents Window 共享同一个工作目录，不要求每轮创建协议专用提交。
- 云端或新的 clone 只能读取远端可达的提交。使用这类后端时，应按后端说明把任务相关变更提交到可读取的分支，且不得包含无关工作区改动。
- 协议文件负责终止条件；启动脚本不应自行重复启动会话。
