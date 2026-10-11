# 启动新的 Codex GUI task

> 循环任务的每一轮必须新建独立 task，并把下一轮的完整 prompt 提交到该 task。当前
> Codex Desktop 内的 agent 必须使用下方的**原生 task 工具**；不要用 `codex app-server`
> 加 `codex://threads/<id>` 深链来声称 GUI 已打开同一 task。

## 首选：Codex Desktop 原生 task 工具

当当前会话可调用 `codex_app__create_thread` 时，使用它创建新 task。这是循环任务的唯一
自动化路径：它由 Desktop 创建、带首条 prompt，并可用 `codex_app__navigate_to_codex_page`
显示同一个 task。

执行下一轮时：

1. 使用当前仓库对应的 project，目标环境选 `local`，以便各轮共享当前工作目录和未提交改动。
2. 调用 `codex_app__create_thread`，将下一轮完整 prompt 原样传为 `prompt`。
3. 获得 `threadId` 后调用 `codex_app__navigate_to_codex_page` 打开该 task；若 task 创建尚在
   准备中，先等待取得实际 `threadId`，不得把 `clientThreadId` 当作 thread ID 使用。
4. 启动成功即可结束当前轮，不必等待新 task 完成。

示意参数（使用实际的 project ID 和下一轮 prompt）：

```text
create_thread({
  prompt: "Please execute docs/<slug>/<slug>-task.md Task 1 additional task N.",
  target: { type: "project", projectId: "<current-project-id>", environment: { type: "local" } }
})
navigate_to_codex_page({ threadId: "<returned-thread-id>" })
```

不要传不受当前模型支持的 `thinking` 值。创建后可用 `read_thread` 或 `wait_threads` 核验
新 task 的首轮已经开始；这是 task 内容的证据，Desktop 导航的返回结果是 GUI 目标的证据。

## 禁用的 App Server 组合

`codex app-server` 可以创建并完成持久线程，`codex://threads/<id>` 也有官方的“打开本地
对话”语义，但在本机当前 Desktop 版本中两者组合曾打开一个空白 GUI composer，而非刚由
App Server 创建的线程。它不能满足“prompt 在新 GUI task 中提交”的要求，因此不用于循环
任务启动。不要因为 `thread/read` 显示完成就把它当作 GUI 成功。

## Shell GUI fallback

仅当当前执行环境没有原生 task 工具时，才运行同目录脚本。它会先用 `codex app` 打开目标
workspace，再按绝对路径 `/Applications/Codex.app` 激活 Desktop，最后发送 `Cmd+N`、粘贴 prompt、
回车提交。当前机器的 ChatGPT 与 Codex 共用 bundle id，不能只按 bundle id 选择应用；绝对路径
确保快捷键不会落到 Cursor 或独立的 ChatGPT 应用。

```bash
# 当前 workspace：只创建空 task
bash prompt/skill/new_codex_session.sh

# 当前 workspace：创建并提交 prompt
bash prompt/skill/new_codex_session.sh \
  "Please execute docs/<slug>/<slug>-task.md Task 1."

# 指定 workspace；多行 prompt 使用 $'...'
bash prompt/skill/new_codex_session.sh -w /path/to/workspace \
  $'Please execute docs/<slug>/<slug>-task.md Task 1.\nFollow the task protocol exactly.'
```

该 fallback 需要 macOS、`/Applications/Codex.app`、Codex CLI、Python 3 和运行脚本宿主的辅助功能权限。Codex 的 Web
输入框不稳定地暴露给 macOS Accessibility，所以脚本只能证明：Desktop 已按 bundle id 在前台、
新建对话快捷键已发送、prompt 的粘贴和回车事件已发送。它不能从 shell 读取 composer 来证明
焦点；运行后必须在新 task 中目视确认首条 prompt。

## 已验证的原生烟测（2026-08-07）

使用 `create_thread`（`local` 环境）再 `navigate_to_codex_page` 新建 task
`019fd7e5-6672-7211-b7ce-93da0ad675b2`，首条 prompt 已完成，并返回：

```text
codex_gui_native_binding_final_20260807_ok
```

此前 App Server 测试的“完成”记录只证明服务端线程持久化，未作为 GUI 成功证据保留。

同日的 shell fallback 烟测创建 task `019fd7ed-7dcc-7e20-bc24-e3123c336fe7`，并提交了
唯一的测试 prompt；该 task 的持久首轮已完成并返回：

```text
codex_gui_fallback_bundle_id_20260807_ok
```
