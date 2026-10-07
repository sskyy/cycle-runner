# 在 Claude 桌面应用中启动新的 Claude Code Session（并可提交 prompt 开始执行）

> **权威位置**：`~/.agents/skills/launch-local-agent-session/sessions/`  
> 任意场景优先跑本目录脚本（或 `../scripts/launch.sh claude`）。循环任务 ensure 后的仓库副本：`prompt/skill/`。  
> 不要用 `Cmd+N` / 剪贴板粘贴、不要手写未编码的 `claude://` 查询、不要把 prompt 发进当前对话。云端 Cloud Agent 不在本 skill。

> 用途：从脚本/自动化里**在 Claude 桌面应用（Code 标签页）中新建一个独立的
> Claude Code session**，指定工作目录，并可选地把 prompt 作为首条消息提交。
>
> 目标是其它本地 GUI 后端的对等物：一个**新的 Claude Code session**，而不是往当前
> session 里再塞一条消息。终端里的 `claude` CLI 会话不在本后端范围内。

## 调研结论（为什么是「deep link 预填 → Return 提交」两步）

Claude Desktop（核实版本 **2.9939.2**，bundle id `com.anthropic.claudefordesktop`）
登记了 `claude://` scheme。主进程 `open-url` 处理器对 host `code` 的 `/new` 路径：

```text
claude://code/new?folder=<abs>&q=<prompt>
  → Code 标签页新 session 页（/epitaxy?folder=…&q=…&src=external）
```

- **`folder`**：新 session 的工作目录，可重复；`.claude/worktrees/<name>` 会被折回仓库根。
- **Trust 确认框每次都弹**：链接带 `folder` 时，渲染层直接走 `requestTrust`，不先查已存的
  信任，所以不论 `~/.claude.json` 怎么设，都会弹「Trust this workspace?」（默认焦点在
  Cancel，框开着时 AX 树只暴露这个框，看不到输入框）。框里用 `AXStaticText` 显示完整路径，
  下面有 `Cancel` 与 `Trust workspace` 两个按钮；点 Trust 后日志才出现 `saveTrust: cwd=…`。
  服务端开关 `ccd_deeplink_trusted_folder_skip_main` 只在**没有**预填 prompt 时跳过这个框，
  且只把文件夹列成候选、不直接选中，对本后端没用。
- **同一文件夹重开会落进 scratch（桌面端缺陷）**：草稿 store 里有 `selectedFolder`
  （编辑区文件夹按钮显示的）和 `trustedSelectedFolder`（真正拿来启动的）。链接选文件夹
  会把后者清空，由一个以 `selectedFolder` 为依赖的 effect 补回。草稿原本就是这个文件夹时
  值没变，effect 不再跑，`trustedSelectedFolder` 一直为空：界面照样显示该文件夹和
  「Bypass permissions」，但权限默认值永远算不完（`permissionDefaultPending`），Return
  被挂起，10s 兜底后以 `presettle_failsafe` + `default` 模式开进 `scratch-workspaces/…`。
  队列反复接力同一个仓库根时必然踩中。对策：先开一次指向垫步目录的链接，再开目标链接，
  保证文件夹确实发生变化。
- **`q`**（别名 `prompt`）：预填进新 session 输入框，**截断**到 14336 个 UTF-16 单位。
  脚本超限直接报错，不让它静默截断。
- **永不自动提交**：渲染层对外部链接带来的种子写死 `autoSubmit: false`（与 Zed
  的 SECURITY 约束同类）。所以必须由脚本补一次 **Return**（实测 Return 即发送）。
- **Return 之前必须确认焦点**：盲按 Return 会被用户同时的操作截走（实测一次：
  用户正在别的 session 里打字，Return 落到那边，新 session 没建起来）。Electron 设
  `AXManualAccessibility` 后会暴露网页 AX 树，新 session 的输入框是
  `AXTextArea`、description 为 `Prompt`、`AXValue` 为当前文本。脚本只在它装的正是
  本 prompt 时才按 Return。
- 预填会**覆盖**新 session 页上残留的未发送草稿（实测：先留一条草稿，再跑脚本，
  提交的是新 prompt）。
- 其它同 scheme 入口（不用于本后端）：`claude://code/continue?session=last`、
  `claude://code/needs-input`、`claude://resume?session=<cli-uuid>`（导入 CLI transcript）。

### 已排除 / 会踩坑的方式

| 方式 | 结果 |
|---|---|
| 只 `open` 链接不补 Return | prompt 停在输入框，session 不会创建 |
| 固定延时后盲按 Return | 用户同时在操作时 Return 落进别处，可能发出用户自己的草稿 |
| `Cmd+N` / 菜单新建再粘贴 | 丢失工作目录；焦点不对时贴进当前 session |
| 手写未编码的 `q=` | 换行、`&`、`+` 截断或变空格 |
| `claude -p` / `claude://resume` 导入 | headless 跑完才导入，不是 GUI 里开工的新 session |
| 不点 Trust，指望全局信任设置压掉确认框 | 链接路径不看已存信任，框一直挂着，脚本等到超时（此前每次都是机主手动点的） |
| 连续两次开同一 `folder` 的链接（不垫步） | 界面显示正确，实际以 `default` 模式开进 scratch 目录（2026-09-26 复现 2 次） |
| 只看编辑区文件夹按钮与模式按钮判定就绪 | 同一文件夹缺陷下两者都显示正确，判不出来；必须靠垫步规避，并在提交后核对日志 |

## 全局设置（全自动接力的前提）

链接没有权限模式参数。机主决定用下表的全局设置解决权限模式，**不要**用界面自动化去点
模式选择器：

| 文件 | 设置 | 作用 |
|---|---|---|
| `~/.claude/settings.json` | `permissions.defaultMode: "bypassPermissions"` | 新 session 以 bypass 启动（日志 `source=settings_default_mode`）。**只有用户级**能把 bypass 设为默认，项目级 `.claude/settings*.json` 里的 bypass/auto 会被丢弃 |
| `~/.claude/settings.json` | `skipDangerousModePermissionPrompt: true` | 终端 CLI 首次进入 bypass 时不再弹确认 |
| `~/.claude.json` | `projects["/"].hasTrustDialogAccepted: true` | 信任检查沿父目录上溯，根目录受信则提交时的信任检查、CLI 与手动选文件夹都不再问；**压不掉**链接带来的 Trust 确认框 |

这两项对本机**所有**新 Claude Code session（桌面与 CLI）生效：之后开的 session 不再询问任何权限，
项目里的 hooks / MCP 配置也会直接生效。2026-09-26 已按机主要求设置，备份为
`~/.claude/settings.json.bak-before-global-bypass-20260926104822` 与
`~/.claude.json.bak-before-global-trust-20260926104822`。

链接带来的 Trust 确认框由脚本处理（2026-09-26 机主决定）：脚本读框里显示的路径，与
`-w` 解析后的真实路径**完全相同**时才经 AX 按「Trust workspace」；路径不同、读不出或
被截断（带 `…`）一律不点、exit 1。同一次启动最多点 3 次，框反复出现即报错退出。

曾试过、已放弃的逐 session 做法（留作记录）：用 AX 点开输入框下方的模式选择器选
「Bypass permissions」。可行但两处麻烦：每个 workspace 第一次会弹「Bypass all permissions?」
确认（记在 account 级 `epitaxy-perm-mode-acks`）；而且在外部链接打开的草稿上切模式后，
草稿会丢掉文件夹绑定，提交时铸出 scratch 目录。

## 原生工具

若执行方是 Claude 桌面里的 session，且当前会话暴露了创建 session 的原生工具
（`ccd_session_mgmt` 的 `start_session`），可优先用它。2026-09-26 本机会话
**未暴露**该工具（只有 list/get/send_message 等），所以默认走本脚本。
这一路径未验证，出现时按工具自身说明使用。

## 前置条件

1. **macOS**；`python3`（编码 URL）。
2. **`/Applications/Claude.app`**（或 `CLAUDE_APP`）已登录；管理策略未开
   「Disable claude:// deep-link handling」。
3. **辅助功能权限**：运行 osascript 的宿主须在
   `系统设置 → 隐私与安全性 → 辅助功能` 中被勾选，报 `-1719` / `-1728` 即未授权。
   从 Claude 桌面自己的 session 里跑时，宿主就是 Claude.app。
4. 执行方若本身就是 Claude 桌面 session：链接会把窗口切到新 session，
   当前 session 在后台继续跑，不受影响。用户正在输入的草稿留在原 session。

## 用法

```bash
# 当前目录：只准备新 session（预填目录，不发送）
bash prompt/skill/new_claude_session.sh

# 当前目录：新建并提交 prompt
bash prompt/skill/new_claude_session.sh "你的 prompt"

# 指定目录（循环任务必须显式 -w）
bash prompt/skill/new_claude_session.sh -w /path/to/workspace "你的 prompt"

# 多行 prompt
bash prompt/skill/new_claude_session.sh -w /path/to/workspace $'第一行\n第二行'

# 机器很慢：放宽等待草稿就绪的上限
CLAUDE_SUBMIT_TIMEOUT=40 bash prompt/skill/new_claude_session.sh -w /path "你的 prompt"
```

调度器等价：

```bash
bash "$HOME/.agents/skills/launch-local-agent-session/scripts/launch.sh" \
  claude -w "$(pwd)" "你的 prompt"
```

脚本行为：

- 未传 `-w` 时使用当前工作目录（必须存在），编码为 `folder=`。
- 空白 prompt 视为省略：只打开新 session 页，不发送。
- 有 prompt，分两段，都用 JXA（`osascript -l JavaScript` 绑定 AX 函数）轮询，每段最长
  `CLAUDE_SUBMIT_TIMEOUT` 秒（默认 15；Claude 原本未运行时 45）：
  1. **垫步**：`open` 指向垫步目录的链接（`CLAUDE_LAUNCH_PAD`，默认
     `~/Library/Caches/claude-launch-pad`，不能等于 workspace），按上面的规则点 Trust，
     等编辑区显示垫步目录的文件夹按钮并稳定 0.5s。垫步不碰输入框、不按 Return。
  2. **目标**：`open` 目标链接，同样点 Trust；等到输入框（`AXTextArea`、description
     `Prompt`）两边做 NFKC 并去掉空白后内容与本 prompt 相同，且同一编辑区里有标题为
     workspace 目录名的 `AXPopUpButton` 与标题为「Bypass permissions」的 `AXPopUpButton`
     （期望模式不是 bypass 时只看文件夹），稳定 0.5s；再确认前台是 Claude、焦点在这个
     输入框，才按 Return（key code 36），随后 8s 内看输入框是否清空。
- 没按 Return 的一切失败（超时、Trust 框路径不符、内容不符）都 exit 1 并说明原因
  （只报长度，不打印用户草稿）。
- 只要按过 Return，不论输入框有没有清空，都读 `~/Library/Logs/Claude/main.log`：找
  offset 之后新出现、此前从没出现过的 `Starting local session <id> in <cwd>`（cwd 是本
  workspace 或 `scratch-workspaces/…` 的才算），配上 `[permissionMode] spawn <id> …
  effective=<mode>`，最多等 15s（挂起的提交 10s 后才兜底放行）。输出 session id、cwd、
  权限模式与两段的 Trust 点击次数。cwd 不是该 workspace（或其 `.claude/worktrees/*`）
  → exit 5；模式不是 `CLAUDE_EXPECT_PERMISSION_MODE`（默认 `bypassPermissions`，置空不
  核对）→ exit 4；两者都表示 session 已经开跑，不要直接重跑。日志里找不到新 session →
  exit 6，状态未知，先在 Claude 里核对。
- 确认提交后即退出，不轮询新 session 的执行。
- 不逐次指定模型 / effort / permission mode：新 session 沿用全局设置与桌面端默认值。

## 已知限制

- **全角标点会被归一**：实测 prompt 里的 `，：` 进 transcript 时变成 `,:`（NFKC 类
  归一化）；中文字符与换行保持不变。协议原句用 ASCII 标点即可规避。
- 冷启动（Claude 未运行）路径按源码有「先加载、再补发导航」的处理，但未实测；
  轮询兜底，超时则不提交，加大 `CLAUDE_SUBMIT_TIMEOUT` 重跑。
- 依赖这些 AX 文字：输入框 description `Prompt`、确认框按钮 `Trust workspace`、模式按钮
  `Bypass permissions`、文件夹按钮显示目录名。Claude 改版后若对不上，脚本会超时退出而
  不是误按，届时用本文件的 AX 探测思路重新核对。
- 垫步依赖「文件夹发生变化才补回已信任文件夹」这一行为；桌面端修掉同一文件夹缺陷后
  垫步只是多一次 Trust 点击（约 1s），无害。
- 每次启动会给垫步目录与 workspace 各记一次信任（`saveTrust`），垫步目录会出现在
  桌面端的最近文件夹里。

## 在任务文件循环中的用法

与其它本地后端一致，以协议原句启动下一轮：

```bash
bash prompt/skill/new_claude_session.sh -w "$(git rev-parse --show-toplevel)" \
  "Please execute docs/<slug>/<slug>-task.md Task 1 additional task <N>."
```

**prompt 保持协议原句一句话，不要塞附加说明。**

## 验证记录（2026-09-26）

环境：Claude Desktop 2.9939.2，Claude Code 2.1.283，从 Claude 桌面自身 session 内执行。

1. **只开链接不提交**：`open claude://code/new?folder=<exp>&q=…PREFILL_1` 后窗口切到
   新 session 页，日志记录 `saveTrust: cwd=<exp>`；`list_sessions` 无新增 session，
   说明 `q` 只预填。
2. **完整闭环**：未授权辅助功能时 osascript 报 `-1728`；授权后跑
   `new_claude_session.sh -w <exp2> $'…\nCLAUDE_LAUNCH_SUBMIT_OK_2 中文多行'`，
   新 session `local_6c21a75b…` 的 cwd 为 `<exp2>`，首条 USER 消息为该 prompt，
   换行与中文保留、全角标点被归一，ASSISTANT 回复 `CLAUDE_LAUNCH_SUBMIT_OK_2 中文多行`。
3. **残留草稿**：对第 1 步留下未发送草稿的 `<exp>` 再跑脚本，提交的是新 prompt
   `…SUBMIT_OK_3`，回复一致；旧草稿没有被发送。
4. **盲按 Return 的失败**：先跑无 prompt 模式（exp4），再用调度器
   `launch.sh claude -w <exp3> …` 发 prompt。旧版脚本固定延时后盲按 Return，exit 0，
   但 exp3 没有 session。日志显示 Return 时焦点被切到用户正在打字的另一个 session。
   据此加入 AX 焦点/内容校验。
5. **校验的负向路径**：在不打开链接的情况下单跑校验，焦点是用户自己的草稿，脚本报
   `Prompt box holds other text (190 chars)` 并超时，没有按 Return。
6. **校验后的正向路径**：重复第 4 步的顺序（无 prompt → 调度器发 prompt），2s 内确认
   并提交，新 session `local_10eb7fa7…` 的 cwd 为 `<exp3>`，首条 USER 消息为
   `Reply with exactly: CLAUDE_LAUNCH_GUARDED_OK_5`，ASSISTANT 回复一致。
7. **逐 session 切模式（已放弃）**：AX 选中 Bypass 后提交，日志 `effective=bypassPermissions`，
   但 cwd 是 Claude 的 `scratch-workspaces/…`，不是目标目录。事后的 cwd 核对把它报成错误。
8. **全局设置后的闭环**：写入上表的全局设置后，对一个从未信任过的新目录 `<exp5>` 跑
   调度器：无 Trust 弹窗、无任何界面点击，4s 完成。日志
   `source=settings_default_mode effective=bypassPermissions`，cwd 为 `<exp5>`，
   transcript 中 USER 的 permissionMode 为 `bypassPermissions`，回复 `CLAUDE_LAUNCH_GLOBAL_OK_10`。

### 补充验证（2026-09-26 下午，Claude Desktop 2.9939.2）

9. **队列接力失败的复现**：旧脚本对 `client-wt/main` 连续第二次启动时，日志 15:56:34
   `saveTrust`（机主手动点的 Trust），10s 后 `createScratchWorkspace`、
   `source=presettle_failsafe effective=default`，session 开进 scratch 目录。旧脚本还把
   「按了 Return 但输入框没清空」报成「未按 Return」并跳过了 cwd 核对。
10. **Trust 框每次都弹**：只 `open` 带 `q` 的链接、不做任何操作，AX 看到
    `AXApplicationAlertDialog`「Trust this workspace?」，焦点在 Cancel；机主确认此前每次
    都是手动点的 Trust，否则界面没有反应。第 8 条「无 Trust 弹窗」是误判。
11. **路径不符不点**：框里显示目录 A，脚本期望目录 B → 报 `the Trust dialog shows a
    different folder; not clicking Trust`，exit 1；日志无 `saveTrust`、无新 session。
12. **新目录一次成功**：新脚本（尚无垫步）对新目录 `claude-launch-t1`：自动点 Trust 1 次，
    3.8s 完成，cwd 正确，`bypassPermissions`。
13. **同一文件夹缺陷复现**：紧接着对同一 `claude-launch-t1` 再启动：编辑区显示该文件夹
    与「Bypass permissions」，就绪检查通过，按 Return 后 10s 兜底开进 scratch、`default`，
    新增的日志核对报 exit 5。对比探测：同一文件夹时 `saveTrust` 后没有
    `checkGhAvailable`，新目录时有。
14. **垫步后的同一文件夹**：加垫步后对 `claude-launch-t5` 连跑 3 次（后两次草稿原本就是
    t5，正是第 13 条的条件），3 次都 exit 0，约 4s/次，cwd 为 t5，
    `source=settings_default_mode effective=bypassPermissions`，垫步与目标各点 Trust 1 次；
    新 session 首条 USER 为 `Reply with exactly: LAUNCH_T5_B_OK`，ASSISTANT 回复一致。
