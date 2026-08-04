---
name: cyclic-task-prompt
description: 将复杂软件任务转换为由独立会话交替执行的设计、评审、实现和审计任务文档。适用于生成循环任务、收敛任务、任务协议或 docs/<slug>/<slug>-task.md，并负责准备新会话启动脚本。
---

# 循环任务文档生成

本 skill 将一个复杂需求整理为自包含的 `docs/<slug>/<slug>-task.md`。任务文件包含生成时的完整项目画像、共享规范，以及依次列出的 Task 1 / additional task 1–4；后续会话不需要读取本 skill。

任务文件把循环写成可直接执行的任务序列，而不是需要推理的抽象协议：

- **Task 1**：设计初稿，完成后启动 additional task 1。
- **additional task 1**：设计评审，完成后启动 additional task 2。
- **additional task 2**：设计裁决；按任务内写明的分支启动 additional task 1、additional task 3，或终止。
- **additional task 3**：实现，完成后一律启动 additional task 4。
- **additional task 4**：实现审计；按任务内写明的分支启动 additional task 3，或终止。

设计循环最多 15 轮；实现循环总预算为初始里程碑数乘以 5。目的是通过新的上下文和独立立场提高工作质量，同时保持持续推进。不要求设计阶段证明所有实现细节，也不为每个任务建立额外的流程管理系统。

## 路径

| 内容 | 路径 |
|---|---|
| 项目画像 | `docs/agent-project-profile.md` |
| 任务模板 | 本 skill 的 `assets/protocol-template.md` |
| 画像规范 | 本 skill 的 `references/project-profile-schema.md` |
| 会话后端说明 | 本 skill 的 `references/session-backends.md` |
| 会话启动文件源 | 本 skill 的 `sessions/` |
| 仓库内会话启动文件 | `prompt/skill/` |
| 任务文件 | `docs/<slug>/<slug>-task.md` |
| 设计文档 | `docs/<slug>/<slug>.md` |
| 设计评审 | `docs/<slug>/<slug>-review.md` |
| 实现审计 | `docs/<slug>/<slug>-audit.md` |
| 运行记录 | `docs/<slug>/retro.md` |

## 生成流程

### 1. 确定参数

确定以下内容：

- `slug`：使用 kebab-case。
- 任务标题：简短、准确，不包含实现细节。
- 会话后端：用户未指定时使用 Cursor Agents Window。
- 是否立即启动：默认只生成任务文件；只有用户明确要求时才启动首个会话。

若同名任务目录已经存在：

- 用户要求保留旧运行时，先将完整运行移出仓库归档，再使用原 slug。
- 不需要归档时，使用 `-v2` 等新 slug。
- 不得覆盖仍在执行的任务。

### 2. 读取或建立项目画像

固定路径为：

```text
docs/agent-project-profile.md
```

文件存在时：

1. 读取全文。
2. 对照 `references/project-profile-schema.md` 检查内容。
3. 若画像仍包含已废弃的流程专用内容，例如里程碑状态机、人工白名单、固定风险实验数量或评审流程，应在用户明确要求重新生成任务时，将画像整理为项目事实、工程原则、调研入口和测试命令。

文件不存在时：

1. 阅读 `references/project-profile-schema.md`。
2. 调研仓库的权威规则、源码布局、测试命令和运行环境。
3. 起草 `docs/agent-project-profile.md`。
4. 默认停止，等待用户确认；用户已明确授权连续执行时可以继续。

生成任务文件时，必须把项目画像全文逐字复制到 `{{PROJECT_PROFILE}}`。不得只写画像路径或摘要。这样任务目录归档后仍能完整保留生成时的项目背景。

### 3. 调研并整理任务

使用项目画像中的调研入口：

1. 阅读权威规则和与需求直接相关的源码、测试及设计文档。
2. 核实用户描述中的关键现状；不确定的事实应写成待验证事项。
3. 将需求整理为背景和编号要求。要求只描述目标、边界和验收约束，不预先指定未经验证的实现方案。
4. 若需求明确要求修改既有原则，应在要求中直接说明。
5. 只有相互独立、可以分别验收的需求才拆成多个任务。
6. 任务若依赖前置成果，应列出权威文件和接口，但不得复制旧运行的设计结论作为新设计。

### 4. 准备会话后端

阅读 `references/session-backends.md`，只将本次选择的后端文件从 `sessions/` 复制到仓库 `prompt/skill/`。文件已存在且可用时不覆盖；缺失时复制，并为 shell 脚本增加执行权限。

`{{SESSION_SKILL}}` 使用仓库相对路径。

### 5. 生成任务文件

读取 `assets/protocol-template.md`，替换以下占位符：

| 占位符 | 内容 |
|---|---|
| `{{PROJECT_PROFILE}}` | 项目画像全文，逐字复制 |
| `{{SLUG}}` | 任务 slug |
| `{{DOC_DIR}}` | `docs/<slug>` |
| `{{TASK_TITLE}}` | 任务标题 |
| `{{TASK_BODY}}` | 背景和编号要求 |
| `{{TASK_NOTES}}` | 任务特定的调查、验证和范围说明 |
| `{{SESSION_SKILL}}` | 会话后端说明文件的仓库相对路径 |
| `{{GENERATION_STAMP}}` | `generated-by: cyclic-task-prompt | template-sha256: <前12位> | generated-at: <YYYY-MM-DD>` |

生成时只创建任务目录和任务文件。设计、评审、审计、运行记录及测试资产由后续会话创建。

任务模板除占位符外必须逐字保留。单次任务不得修改以下规则：

- 六类设计复审条件。
- 设计预算 15。
- 实现预算为初始里程碑数乘以 5，且预算在各里程碑之间共享。
- 设计通过后自动进入实现循环。
- 只有实现轮增加实现轮次计数。
- 实现轮不能将里程碑标记为已完成。
- 审计发现验证缺口时，先加强验证并立即复验；产品实现仍通过时不退回里程碑。
- 审计退回实现时必须给出下一轮的具体工作。
- 真实实现缺陷导致`待审`→`开放`时累计 milestone reopen；纯验证缺口和原本`开放`不计。
- 同一领域第二次 reopen 触发 `domain-review`，同一里程碑第三次 reopen 触发 `milestone-review`。
- 收敛审计只在现有 audit 文件顶部维护四段式 `Convergence Note`，不得增加新的流程文件。
- 收敛模式下实现轮必须按 Note 的实施批次推进，并通过全部 Closure gates 后才能再次标记`待审`。
- 目标不可实现和协议预算耗尽的终止语义。

### 6. 自检

生成后检查：

```bash
rg -n "\{\{" docs/<slug>/<slug>-task.md
test -f docs/agent-project-profile.md
test -f <SESSION_SKILL>
```

并人工确认：

- 项目画像已完整嵌入。
- 任务要求编号连续、边界明确。
- 任务路径和会话启动路径存在。
- 任务结构为：共享规范 → Task 1 → additional task 1 → 2 → 3 → 4；每个任务末尾写明下一步启动谁。
- 启动链路为：初稿 → 设计评审 → 设计裁决 → 实现 → 审计。
- 设计通过后自动启动实现，不等待人工确认。
- 设计头和每个里程碑包含 reopen 计数；审计任务包含双触发收敛规则。
- `Convergence Note` 固定在 audit 文件中且只有 Remaining closure map、Root cause and scope、Next implementation batch、Closure gates 四部分。
- 没有旧任务名称、旧归档路径或其它项目的残留内容。

### 7. 交付

报告以下内容：

- 任务文件路径。
- 使用的项目画像路径。
- 会话后端。
- 模板哈希。
- 是否已启动首个会话。

用户未要求启动时，不得自行启动。

首个启动提示词为：

```text
Please execute docs/<slug>/<slug>-task.md Task 1.
```

## 维护原则

- 每个任务文件固定使用生成时的模板快照。运行期间不得同步新版模板。
- 旧任务保持原样；模板变更只影响新生成的任务。
- 模板改进以多个运行的复盘证据为依据，不因单个任务的局部问题增加全局规则。
- 任务之间如何接力必须直白写在 Task / additional task 内；不要改回需要模型推理的抽象循环协议。
- 项目特定的状态表、清单、参考函数或验证程序应留在任务设计中，不应加入全局模板。
