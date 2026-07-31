# 在 Cursor4 Agents Window 中启动新的独立 Agent Session（并可输入 prompt 开始执行）

> 用途：从脚本/自动化里**在 Cursor4（薄启动器实例）的 Agents Window 中新建一个独立的 GUI Agent session**，
> 并可选地**输入 prompt 文本、按回车发送、开始执行**。
>
> 与默认 `prompt/skill/new-cursor-agent-session.md` 对等，但打到独立 `--user-data-dir`
> （`~/.cursor-profiles/cursor4`），避免和正常 Cursor 串实例。

## 与默认 Cursor skill 的区别

| | 默认 `new-cursor-agent-session` | 本 skill（Cursor4） |
|---|---|---|
| 目标实例 | `/Applications/Cursor.app` 默认 profile | `~/Applications/Cursor4.app` → `~/.cursor-profiles/cursor4` |
| CLI | `cursor <workspace>` | `cursor --user-data-dir <cursor4> <workspace>` |
| 激活方式 | `tell application "Cursor"` | CLI 直打 cursor4 socket；置前仅为 best-effort（不硬依赖辅助功能） |

## 调研结论（路由仍是 glass.newAgent）

Cursor 3 的 Agents Window（glass）里，真正新建独立 Agent 的内部路径是：

```text
CLI 打开目录
  → 主进程 vscode:createNewComposer { folderUri }
  → glass.newAgent({ folderUri, source: "cli" })
```

与默认 skill 相同，但必须：

1. 确保 Cursor4 profile 进程在跑（必要时 `open -a Cursor4`；**不**把「严格 frontmost」当作成功条件）；
2. 执行 `cursor --user-data-dir ~/.cursor-profiles/cursor4 --extensions-dir … <workspace>`
   （**不加** `-r` / `-n`），使 IPC 打到 cursor4 的 socket——这是新建 session 的主路径；
3. 若给了 prompt：尽力按 PID 置前（失败忽略），再剪贴板粘贴 + 回车发送（依赖新 session 输入框自动聚焦）。

### 已排除 / 会踩坑的方式

| 方式 | 结果 |
|---|---|
| 直接用默认 `new_cursor_agent_session.sh` | 打进默认 Cursor，与 Cursor4 无关 |
| PATH 里裸 `cursor <workspace>`（无 user-data-dir） | IPC 走默认 `Application Support/Cursor` |
| `tell application "Cursor"` | 多实例时可能激活错误进程 |
| `cursor -r` / `cursor -n` | 破坏 glass 的 createNewComposer 路由 |
| `cursor agent ...` | 终端 Agent，不是 GUI Agents Window session |

## 前置条件

1. **macOS**（AppleScript / System Events 仅 macOS 可用）。
2. 薄启动器已安装：`~/Applications/Cursor4.app`（独立 Bundle ID `com.local.cursor4`）。
3. **Cursor4 已打开 Agents Window**（窗口标题一般为 `Cursor Agents`）。
   首次启动需在 Cursor4 内登录，并 `Cmd+Shift+P` → Open Agents Window。
4. **`cursor` CLI 可用**（`/usr/local/bin/cursor` → 原版 Cursor.app；脚本会附加 `--user-data-dir`）。
5. **辅助功能（可选）**：仅影响「置前 + 粘贴 prompt」。新建 session 本身不依赖辅助功能；
   若粘贴失败，再给运行 `osascript` 的宿主开辅助功能，或手动聚焦新 session 后重试。

可用下面命令确认 Cursor4 进程在跑：

```bash
ps -ax -o pid= -o command= | grep -F -- "--user-data-dir=$HOME/.cursor-profiles/cursor4" | grep MacOS/Cursor | grep -v Helper
```

## 用法

```bash
# 在当前目录 workspace 下仅新建一个独立 Agent
bash prompt/skill/new_cursor4_agent_session.sh

# 新建独立 Agent，输入该 prompt 并按回车发送、开始执行
bash prompt/skill/new_cursor4_agent_session.sh "你的 prompt"

# 指定 workspace，仅新建一个独立 Agent
bash prompt/skill/new_cursor4_agent_session.sh -w /path/to/workspace

# 指定 workspace，并发送 prompt
bash prompt/skill/new_cursor4_agent_session.sh -w /path/to/workspace "你的 prompt"

# 多行 prompt（用 $'...' 传入换行）
bash prompt/skill/new_cursor4_agent_session.sh -w /path/to/workspace $'第一行\n第二行'
```

脚本行为：

- 校验 workspace 目录存在，并转成绝对路径；
- 若 Cursor4 未运行则 `open -a Cursor4.app`；
- **先**执行带 `--user-data-dir` 的 `cursor <workspace>`，在 Cursor4 的 Agents Window 中触发 `glass.newAgent`
  （不因 frontmost 失败而中止）；
- 置前为 best-effort：AppleScript 失败只忽略，不 exit 1；
- 若给了 prompt：尽力置前后剪贴板粘贴 + 回车发送，
  **结束后恢复原剪贴板内容**；
- **不会**点击窗口底部输入区（那会把焦点打回旧 session）。

## 隔离边界

- **已隔离**：Electron user-data、extensions、IPC socket
  （`~/.cursor-profiles/cursor4/3.12-main.sock`）、glass 选中 agent / tabs（cursor4 的 `state.vscdb`）。
- **仍共享**：同一 workspace 路径下的 `~/.cursor/projects/.../agent-transcripts`
  （按项目目录聚合，不按 user-data 拆分）。不影响「session 开在哪个 GUI 实例」。

## 实现注意事项

- **必须带 cursor4 的 `--user-data-dir` / `--extensions-dir`**，不要改回裸 `cursor`。
- **禁止 `-r` / `-n` / `--classic`**。
- **禁止把「PID 未到前台」当作致命错误**（会在无辅助功能时误杀整条流水线）。
- **用 PID + user-data-dir 定位进程**，不要依赖应用名 `"Cursor"`。
- **Cursor4 最近活动窗口必须是 glass**（粘贴 prompt 时尤其如此）。

## 验证记录

### 2026-07-22（严格 frontmost 路径，历史）

```bash
bash prompt/skill/new_cursor4_agent_session.sh -w /Users/camus/Work/medeo/mesh \
  "请只回复：cursor4_new_session_test_ok_20260722b"
```

结果：脚本 exit=0；新 session 仅出现在 cursor4 `state.vscdb`。

### 2026-07-22（CLI-first / 无严格 frontmost，现行）

在宿主无辅助功能、旧脚本因 `did not come to front (-2700)` 失败后，改用：

1. `cursor --user-data-dir ~/.cursor-profiles/cursor4 … <workspace>` 新建 Agent（成功）；
2. best-effort 置前 + 剪贴板粘贴 prompt（成功）。

现行脚本已固定为该路径：frontmost 失败不再 exit 1。