# 在 ChatGPT 中启动新的 Codex GUI Task（并可输入 prompt 开始执行）

> 用途：从脚本/自动化里**在 ChatGPT 桌面应用中新建一个 Codex 图形界面 task**，
> 并可选地**输入 prompt 文本、按回车发送、开始执行**。

## 调研结论（为什么用 `codex app` + ChatGPT AppleScript）

当前 Codex Desktop 集成在 `ChatGPT.app` 中。仍可通过本机 `codex` 命令打开到指定
workspace：

```bash
codex app /path/to/workspace
```

该命令负责启动/聚焦 ChatGPT 桌面端，并把窗口定位到目标 workspace；但它本身不负责在
已有窗口中创建新的 task，也不负责把 prompt 写入输入框。因此新建 task 和提交 prompt
仍需要通过桌面 UI 自动化完成。

当前可稳定触发新 task 的外部入口是应用菜单：

- ChatGPT 应用菜单「File → New Task」

可用下面命令验证菜单项存在：

```bash
osascript -e 'tell application "System Events" to tell process "ChatGPT" to get name of menu items of menu "File" of menu bar item "File" of menu bar 1'
```

成功时应能看到类似输出：

```text
New Window, New Task, New Projectless Task, Open Folder…, Close
```

因此脚本采用两段式流程：

1. `codex app <workspace>`：打开/聚焦 ChatGPT Desktop 到指定 workspace；
2. AppleScript：点击「File → New Task」，并在需要时通过剪贴板粘贴 prompt、回车发送。

## 前置条件

1. **macOS**（AppleScript / System Events 仅 macOS 可用）。
2. **已安装包含 Codex 的 ChatGPT Desktop**，并且 `codex` 命令可用。
   - 本机实测路径：`/Applications/ChatGPT.app/Contents/Resources/codex`。
   - 应用显示名与进程名为 `ChatGPT`；bundle id 仍为 `com.openai.codex`。
3. **辅助功能（Accessibility）权限**：运行 `osascript` 的宿主（通常是「终端」/「iTerm」/「ChatGPT
   内嵌终端」）必须在
   `系统设置 → 隐私与安全性 → 辅助功能` 中被勾选。
   - 首次运行若报 `osascript is not allowed assistive access (-1719)`，即未授权。
   - 授权后无需重启终端，重跑即可。

可用下面命令验证权限是否正常：

```bash
osascript -e 'tell application "System Events" to tell process "ChatGPT" to get name of menu bar items of menu bar 1'
```

成功时应能看到类似输出：

```text
Apple, ChatGPT, File, Edit, View, Window, Help
```

## 用法

```bash
# 在当前目录 workspace 下仅新建一个任务
bash prompt/skill/new_codex_session.sh

# 在当前目录 workspace 下新建任务，输入该 prompt 并按回车发送、开始执行
bash prompt/skill/new_codex_session.sh "你的 prompt"

# 指定 workspace，仅新建一个任务
bash prompt/skill/new_codex_session.sh -w /path/to/workspace

# 指定 workspace，并发送 prompt
bash prompt/skill/new_codex_session.sh -w /path/to/workspace "你的 prompt"

# 多行 prompt（用 $'...' 传入换行）
bash prompt/skill/new_codex_session.sh -w /path/to/workspace $'第一行\n第二行'
```

脚本行为：

- 校验 workspace 目录存在，并转成绝对路径；
- 校验 `codex` 命令存在；
- 执行 `codex app <workspace>` 打开/聚焦 ChatGPT Desktop；
- 激活并等待 ChatGPT 进入前台、窗口存在；
- 点击「File → New Task」打开一个新的 Codex GUI task；
- 若给了 prompt 参数：等待 UI 就绪，通过剪贴板粘贴 prompt 到（已自动聚焦的）输入框，
  按回车发送、开始执行，**结束后恢复原剪贴板内容**（对用户无副作用）；
- 未在前台 / 权限缺失 / 菜单不可访问时以非零退出码并打印诊断信息。

## 触发方式对比（新建任务部分）

| 方式 | 命令 | 语言相关性 | 备注 |
|---|---|---|---|
| **菜单点击 `File → New Task`（推荐）** | `click menu item "New Task" of menu "File" ...` | 依赖英文菜单 | 已实测 ChatGPT Desktop 菜单为英文，语义明确 |
| 快捷键 | 例如 `Cmd+N` | 通常无关 | 可能对应 New Window，不作为默认方案 |
| `codex app <workspace>` | `codex app /path` | 无关 | 只负责打开/聚焦 workspace，不会自动新建 task |
| 直接 AX 写输入框 | `set value of text area ...` | 无关 | ChatGPT 的 Codex Web 内容不稳定暴露 AXTextArea，无法依赖 |

脚本默认采用菜单点击方式，因为当前 ChatGPT 菜单中 `New Task` 是最明确的新任务入口。

## 输入 prompt 并执行（原理与坑）

新建任务后，下一步是把 prompt 文本送进输入框并触发发送。这里有几个关键约束：

1. **ChatGPT 的 Codex web 内容不稳定暴露给 macOS Accessibility**。实测 `window 1` 下主要是
   `AXGroup` 与窗口按钮，通常没有可稳定定位的 `AXTextArea` / `AXWebArea` / `AXTextField`。
   因此不能依赖 AX 精确定位输入框，也不能用 `set value of ...` 直接写 prompt。

2. **靠「New Task 后输入框自动聚焦」+ 系统级键盘事件**。点击「File → New Task」后，
   新 task 的输入框会自动获得键盘焦点，于是可以用 System Events 向当前焦点控件发送
   `Cmd+V` 和 `Return`。

3. **中文必须走剪贴板粘贴，不能直接 `keystroke`**。`keystroke` 只发键码，会被当前输入法
   影响；中文、引号、反斜杠、多行文本都可能出错。统一做法：

   ```applescript
   set the clipboard to <prompt>          -- 写入剪贴板
   keystroke "v" using command down       -- Cmd+V 粘贴
   keystroke return                       -- 回车发送
   ```

   剪贴板内容在粘贴前后会被保存/恢复，对用户无副作用。

4. **粘贴不触发发送、Enter 才发送**。多行 prompt（含换行）粘贴进去不会提前发送，最后按一次
   `return` 才整体提交，因此多行 prompt 安全。

5. **prompt 经临时 `.scpt` 文件传入**，并用 python 对 `"` / `\` 做转义后拼成 AppleScript
   字符串字面量，避免命令行参数里特殊字符/引号转义问题。

## 实现注意事项

- **AppleScript 经临时文件传入 `osascript`，而非 heredoc**：bash 的 `$(...)` 命令替换
  内嵌 heredoc 时，若 AppleScript 正文/注释里出现未配对的右括号（如 `1)`、`步骤 2)`），
  会被命令替换解析器误判为替换提前结束，导致 heredoc 内容被当成 shell 命令执行。
  临时文件可彻底规避。
- **进程检测用 `System Events` 的 `exists process "ChatGPT"`**，不用
  `application "ChatGPT" is running`
  （该写法在某些 `tell` 上下文会报 -1728），也不用 `pgrep`（沙箱环境下进程可见性不稳定）。
- **不要把“能找到 AX text area”作为成功条件**。ChatGPT 中的 Codex Electron 内容不稳定暴露
  AX 输入框；脚本只校验 ChatGPT 已前台、窗口存在、菜单点击成功，然后依赖自动聚焦提交 prompt。
- **`codex app` 不是“新 task”命令**。它用于打开/聚焦 workspace；新 task 仍需通过 ChatGPT GUI
  菜单触发。
- **菜单点击可能在已成功后返回 `-10000`**。当前 ChatGPT 版本偶尔会在 `New Task` 已经打开后
  返回 `AppleEvent handler failed`；脚本只在该次菜单点击上忽略 `-10000`，其他 AppleScript
  错误仍按失败处理，以便继续执行粘贴 prompt 的阶段。

## 验证记录（2026-07-10）

- `codex` 命令存在，路径为 `/Applications/ChatGPT.app/Contents/Resources/codex`；
- 主应用及 System Events 进程名为 `ChatGPT`，bundle id 仍为 `com.openai.codex`；
- 菜单栏权限验证成功，菜单栏项为 `Apple, ChatGPT, File, Edit, View, Window, Help`；
- `File` 菜单项验证成功，包含 `New Window, New Task, New Projectless Task, Open Folder…, Close`；
- 脚本通过 ChatGPT 的 `File → New Task` 新建 Codex GUI task；
- **带 prompt 端到端验证**：
  - 执行 `prompt/skill/new_codex_session.sh -w /path/to/workspace "请只回复：chatgpt_new_task_test_ok"`；
  - 脚本返回 exit=0；
  - 新 task 正确创建，并且 prompt 已输入并提交。
