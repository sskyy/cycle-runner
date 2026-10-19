# 启动新的 Codex GUI task

> **权威位置**：`~/.agents/skills/launch-local-agent-session/sessions/`；仓库副本在
> `prompt/skill/`（`ensure-into-repo.sh codex` 复制）。脚本 `new_codex_session.sh` 与
> `codex_gui_ax.swift` 必须放在同一目录。

## 做什么

在 Codex Desktop 里新建一个**由桌面版自己创建并执行**的 task，可在 GUI 中实时观察，并逐次指定：

| 参数 | 选项 | GUI 中的位置 |
|---|---|---|
| 目录 | `-w DIR`（取其目录名作项目名） | 脚本自动信任并用 `codex app DIR` 打开该项目的新聊天页 |
| 模型 | `--model gpt-6-luna`（标签推导为 “GPT-6 Luna”，`gpt-6.1-sol` → “GPT-6.1 Sol”，`gpt-5.5` → “GPT-5.5”；2026-10 改版前界面写作 “GPT 6 Luna”，脚本会两种拼写都试；可用 `--model-label` 覆盖） | 输入框右下模型按钮 → Select model |
| 强度 | `--effort low｜medium｜high｜xhigh｜max｜ultra`（别名 `--thinking`） | 同一面板的滑块 |
| 权限 | `--permission ask｜auto｜full`（`bypass` = `full`） | 输入框左下 “Change permissions” |

未给出的参数沿用输入框当前值。`full` 会触发 Codex 的 “Turn on Full Access?” 确认框，必须显式
加 `--confirm-full-access`，脚本才会点 Confirm。

```bash
bash "$HOME/.agents/skills/launch-local-agent-session/sessions/new_codex_session.sh" \
  -w "$(pwd)" --model gpt-6-luna --effort max --permission bypass --confirm-full-access "完整 prompt"
# 仓库副本：bash prompt/skill/new_codex_session.sh -w "$(pwd)" --model gpt-6-luna --effort max "完整 prompt"
```

## 原理

不看屏幕。`codex_gui_ax.swift`（首次运行时用 `swiftc` 编译并缓存到
`~/.cache/launch-local-agent-session/`）读取桌面版的 Accessibility 树，按名字找到控件并读回状态，
用真实鼠标事件点击（Accessibility 自带的点击在该网页界面里无效）：

- 强度：先读输入框右下芯片（如 “GPT-6 Luna Max”；按 “GPT” / “Kimi” / “GLM” 前缀找，不带空格），已等于目标就整段跳过弹层；否则按固定档位顺序直接点目标档位的位置并回读校验，失败才退回沿滑块逐档点击。建议在 `~/.codex/config.toml` 顶层设置 `model` 与 `model_reasoning_effort`，新会话默认就是目标值，通常走快路径。
  标签与 CLI 值对应：Light=`low`、Standard=`medium`、Extended=`high`、Extra High=`xhigh`、Max=`max`。
- 项目行需先悬停，“Start new chat in …” 按钮才有可点击区域。
- prompt 用 Accessibility 直接写进输入框（不占剪贴板），再点 Send。
- 提交后读 `~/.codex/sessions/**/rollout-*.jsonl` 的 `turn_context`，只认 cwd 与 `-w` 一致的 rollout（并发启动时不会串到别人的），与请求逐项比对（model、
  effort；`full` 还要求 approval=`never` 且 sandbox=`danger-full-access`），打印实际值。

退出码：0 已核对；64 用法；2 环境；3 项目；4 权限；5 模型/强度；6 输入/发送；7 rollout 缺失或与请求不符。

## 前置条件

- macOS；运行脚本的进程有「辅助功能」权限；已安装 Xcode Command Line Tools（`swiftc`）。
- 新目录无需手工登记或信任：脚本在 `~/.codex/config.toml` 追加 `[projects."<目录>"] trust_level = "trusted"`（幂等、原子替换），再执行 `codex app <目录>`，窗口会直接切到该项目的新聊天页（不依赖侧栏，侧栏会折叠项目）。
- 脚本全程真实操作鼠标键盘，所以持有全局锁 `~/.cache/launch-local-agent-session/gui.lock`（mkdir + pid，持有进程已死则回收）：多个脚本并发调用会自动排队，一个一个发送，不会互相抢焦点；发送后立即释放，rollout 核对在锁外进行。
- `max` / `ultra` 默认不在滑块中：在 Codex 设置 → Agent → Model features → Available reasoning
  efforts 里打开。模型目录里声明了 `max` 也不够，不是自定义 endpoint 的问题。
- 窗口需要在某个显示器上可见（不要最小化）。

## 已验证与限制

- 2026-09-29 实测（rollout 回读）：`gpt-6-luna` + `max` + `full` → `never` / `danger-full-access`；
  `low` / `medium` / `high` + `auto` → `on-request` / `workspace-write`；`gpt-6-sol` + `xhigh`；
  项目在 `issue-892-giant-seam-split` 与 `mesh-wt` 间切换。
- 依赖界面元素的名称；桌面版改版或界面语言变化时需更新 `codex_gui_ax.swift` 与脚本里的标签。
- 会真实操纵鼠标和键盘焦点，运行期间不要操作该窗口。
- `ask` / `auto` 只核对到 rollout 已生成，不逐项比对 approval 值。

## 为什么不用其他方式（2026-09-29 实测）

- `codex exec`：命令行首轮占着线程的唯一 writer，运行中打开 `codex://threads/<id>` 报
  “already has an active writer”，GUI 看不到实时过程，只能在首轮结束后接管。
- 深链：只有 `codex://threads/<id>`、设置、插件等路由，不能新建线程，也不接受 prompt / 模型。
- 原生 `codex_app__create_thread`：只有 Codex 会话内的 MCP 能调用（走会话专属管道并要求调用方 thread id），
  外部 agent 用不了。Codex 会话内可以优先用它，参数见其工具说明。
- 桌面版本机 IPC（`~/.codex/ipc/ipc.sock`）的 `thread-follower-start-turn`：请求版本号取对后仍返回
  `no-client-found`，未走通。

## 变更记录

- 2026-10-07：桌面版改版为统一的 “ChatGPT” 应用（窗口标题 ChatGPT，`Switch mode, current mode: Codex`），模型按钮改叫 “GPT-6 Luna Max”（带连字符，模型列表为 GPT-6.1 Sol / GPT-6 Astra / GPT-6 Sol / GPT-6 Luna / GPT-5.6 Sol / Terra / Luna / GPT-5.5）。旧脚本按 `"GPT "`（带空格）找芯片，在发送前以退出码 5 `model chip not found` 失败（会让所有交接给 Codex 的循环在下一次交接处中断）。修复：芯片按 `GPT`/`Kimi`/`GLM` 前缀查找；标签推导 `gpt-N-xxx` → “GPT-N Xxx”、`gpt-5.5` → “GPT-5.5”，旧拼写 “GPT N Xxx” 作为备选。实测（rollout 回读，exit 0）：`gpt-6-sol` + `low` + `auto` → `on-request` / `workspace-write`（走模型切换与强度滑块）；`gpt-6-luna` + `max` + `full` → `never` / `danger-full-access`（切回，含 Full Access 确认）；同参数再跑一次走 “already GPT-6 Luna Max” 快路径。强度滑块与 “Select model” 菜单名称没变。
- 2026-10-01：自动信任与 `codex app` 打开项目；全局 GUI 锁；强度快路径；prompt 可见性校验改为只取首行前 30 字符（原 `cut -c1-30` 逐行截取，多行 prompt 会误判）；rollout 核对按 cwd 过滤。五个并发启动实测通过。
- 2026-10-19：回读修正。此前第 5 步在全部 rollout 里找「含提示词前 40 字且 cwd 相同」的文件，启动者自己是 Codex 会话时，它的 rollout 里引用了同一提示词（启动命令就在工具调用里），于是误选到当前会话，再按模型不符退出 7；三个循环每次交接都要人工核验（issue-1670/1542/1496 v3 的 retro）。现在在点 Send 前记下已存在的 rollout 文件集合，只在新文件里找，并要求提示词出现在该线程自己的用户消息（`event_msg/user_message` 或 `response_item` 的 user 角色）里，不接受只在工具调用参数里引用的文件。可用 `CODEX_SESSIONS_ROOT` 指向假目录做单元测试。
