#!/usr/bin/env bash
# 在 Claude 桌面应用（Code 标签页）里新建一个独立的 Claude Code session，并可选地提交 prompt。
#
# 用法：
#   new_claude_session.sh                              # 当前目录：只准备新 session，不发送
#   new_claude_session.sh "你的 prompt"                 # 当前目录：新建并提交 prompt
#   new_claude_session.sh -w /path/to/workspace         # 指定目录：只准备
#   new_claude_session.sh -w /path "你的 prompt"        # 指定目录：新建并提交 prompt
#   new_claude_session.sh -w /path -m "Sonnet 5.5" -e Extra "你的 prompt"
#                                                     # 并指定模型（模型菜单里的名字）与 effort（Low|Medium|High|Extra|Max）
#
# 环境变量：
#   CLAUDE_APP                    Claude.app 路径（默认 /Applications/Claude.app）
#   CLAUDE_SUBMIT_TIMEOUT         等草稿就绪的最长秒数（默认 60；Claude 未运行时 90）
#   CLAUDE_EXPECT_PERMISSION_MODE 新 session 应有的权限模式（默认 bypassPermissions；置空则不核对）
#   CLAUDE_LAUNCH_PAD             垫步用的空目录（默认 ~/Library/Caches/claude-launch-pad，不能等于 workspace）
#   CLAUDE_DRY_RUN=1              在目标草稿上选完模型与 effort 后停在按 Return 之前、不提交，只输出三段间隔（测量用）
#
# 退出码：0 已提交；1 未提交（没按 Return，原因见输出）；2 参数错误；3 prompt 超长；
#   4 已提交，但 session 实际权限模式不是 CLAUDE_EXPECT_PERMISSION_MODE；
#   5 已提交，但 session 没有开在该 workspace（例如落进了 Claude 的 scratch 目录）；
#   6 已按 Return，但日志里没找到新 session（状态未知，先核对再决定是否重跑）；
#   7 已提交，但 session 记录的模型 / effort 不是 -m / -e 指定的。
#
# 全自动接力依赖两项全局设置：
#   ~/.claude/settings.json  permissions.defaultMode = "bypassPermissions"
#                            （只有用户级 settings 能把 bypass 设为默认；项目级会被忽略）
#   ~/.claude.json           projects["/"].hasTrustDialogAccepted = true
#                            （新 session 启动时的信任检查沿父目录上溯，根目录受信即通过）
#
# 原理（Claude Desktop 2.9939.2 源码核对 + 2026-09-26 实测；2026-10-31 在 4.4212.0 / Electron 44.9.3 上复核，见 7）：
#   1) `open "claude://code/new?folder=<abs>&q=<prompt>"` —— 桌面端 open-url 处理器把它
#      路由到 Code 标签页的新 session 页，folder 作为工作目录，q 预填进输入框。
#      q 被截断到 14336 个 UTF-16 单位；本脚本超限直接报错，不静默截断。
#   2) 链接带 folder 且预填了 prompt 时，桌面端一律弹「Trust this workspace?」确认框
#      （不看已存的信任，全局设置压不掉），框默认聚焦 Cancel。脚本读框里显示的路径，
#      与本 workspace 完全相同才按「Trust workspace」；不同或读不出就不点、报错退出。
#   3) 桌面端缺陷：草稿里已经是同一个文件夹时，链接再选一次它，界面照样显示该文件夹，
#      但真正用来启动的「已信任文件夹」被清空且不再补回，提交挂起 10s 后开进 scratch 目录、
#      权限为 default（队列反复接力同一个 main 必然踩中）。所以先开一次垫步链接，把草稿
#      切到垫步目录（同样点 Trust），再开目标链接，保证文件夹确实发生变化。
#   4) 外部链接带来的 prompt 永不自动提交（渲染层写死 autoSubmit:false）。脚本等到
#      输入框装着本 prompt、且同一编辑区显示本 workspace 的文件夹与期望权限模式
#      （bypassPermissions 显示为「Bypass permissions」）才聚焦并按 Return。文件夹没落到
#      草稿上时提交会被挂起，10s 兜底后开进 scratch 目录，所以就绪前绝不按。
#   5) 只要按过 Return，就从 ~/Library/Logs/Claude/main.log 找本次新建的 session
#      （`Starting local session <id> in <cwd>` 与 `[permissionMode] spawn <id> … effective=…`），
#      核对实际工作目录与模式，不论输入框有没有清空。
#   6) 链接没有模型参数（Claude Desktop 2.19675.0 源码核对：/new 只读 q|prompt、folder、file）。
#      给了 -m / -e 时，深链已带上 folder 与 prompt，脚本在这份目标草稿上经 AX 打开编辑区的
#      「Model: …」菜单、按下同名菜单项；再经「Effort: …」按钮设置 effort。每步后重新定位草稿并
#      校验，两者都显示期望值才按 Return；选不上则超时、不提交。提交后读桌面端的 session 记录
#      （claude-code-sessions/**/<id>.json 的 model 与 effort）核对。
#      Effort 对话框：按下「Effort: …」后是一个带 `Effort` 滑块（AXSlider，0..5 =
#      Low、Medium、High、Extra、Max、Ultracode）的对话框，脚本用 AXIncrement/AXDecrement
#      走到目标档，再按一次该按钮收起对话框；记录里 Extra 存作 `effort: "xhigh"`。先选模型
#      再设 effort。
#   7) Claude Desktop 4.4212.0（Electron 44.9.3）实测：AX 客户端接入时 Electron 只开基础无障碍模式，
#      对应用元素设 `AXManualAccessibility=true` 后要再防抖 2 秒才进入完整模式（electron_application.mm
#      的 enableScreenReaderCompleteModeAfterDelay）。这 2 秒里树读得到、`AXPress` 返回 0 却不生效，
#      旧版脚本因此在垫步阶段按 Trust 三次都无效后退出。现在读树照旧，所有动作（按 Trust、选模型 /
#      effort、按 Return）都等设置后 2.6 秒再做；按 Trust 后等到框真的关掉（约 0.5 秒）才算按上，
#      3 秒没关才重按，最多三次。完整模式一旦进入就保持到桌面端进程退出，多等只发生在每段开头。
#      同版本另两点：垫步与目标链接都会弹 Trust 框（已存信任压不掉，trust_clicks 两段各 1）；
#      文件夹按钮显示的是 realpath（如 /private/var/…），所以 -w 一律按 pwd -P 解析；另多了一个
#      「Environment: This computer」按钮，不影响判定。
#
# 前置：macOS；python3；运行 osascript 的宿主在
#   系统设置 → 隐私与安全性 → 辅助功能 中被授权。
# 不要用 Cmd+N / 剪贴板粘贴：那会落进当前看的 session 或丢失工作目录。

set -euo pipefail

APP_PATH="${CLAUDE_APP:-/Applications/Claude.app}"
BUNDLE_ID="com.anthropic.claudefordesktop"
LOG_FILE="$HOME/Library/Logs/Claude/main.log"
WORKSPACE="$(pwd)"
PROMPT=""
SUBMIT_TIMEOUT="${CLAUDE_SUBMIT_TIMEOUT:-}"
EXPECT_MODE="${CLAUDE_EXPECT_PERMISSION_MODE-bypassPermissions}"
MODEL_LABEL=""
EFFORT_LABEL=""
EFFORT_RECORD=""
TAG="[new_claude_session]"
SESSIONS_DIR="$HOME/Library/Application Support/Claude/claude-code-sessions"

usage() {
  sed -n '2,23p' "$0" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -w|--workspace)
      if [[ $# -lt 2 || -z "${2:-}" ]]; then
        echo "$TAG 缺少 workspace 参数。" >&2
        usage >&2
        exit 2
      fi
      WORKSPACE="$2"
      shift 2
      ;;
    -m|--model)
      if [[ $# -lt 2 || -z "${2:-}" ]]; then
        echo "$TAG 缺少模型名（模型菜单里显示的名字，例如 \"Sonnet 5.5\"）。" >&2
        usage >&2
        exit 2
      fi
      MODEL_LABEL="$2"
      shift 2
      ;;
    -e|--effort)
      if [[ $# -lt 2 || -z "${2:-}" ]]; then
        echo "$TAG 缺少 effort 名（Low|Medium|High|Extra|Max）。" >&2
        usage >&2
        exit 2
      fi
      case "$(tr '[:upper:]' '[:lower:]' <<<"$2")" in
        low) EFFORT_LABEL="Low"; EFFORT_RECORD="low" ;;
        medium) EFFORT_LABEL="Medium"; EFFORT_RECORD="medium" ;;
        high) EFFORT_LABEL="High"; EFFORT_RECORD="high" ;;
        extra|xhigh) EFFORT_LABEL="Extra"; EFFORT_RECORD="xhigh" ;;
        max) EFFORT_LABEL="Max"; EFFORT_RECORD="max" ;;
        *)
          echo "$TAG 不认识的 effort：$2（可用 Low|Medium|High|Extra|Max）。" >&2
          exit 2
          ;;
      esac
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      PROMPT="${*:-}"
      break
      ;;
    -*)
      echo "$TAG 未知参数：$1" >&2
      usage >&2
      exit 2
      ;;
    *)
      PROMPT="$1"
      shift
      if [[ $# -gt 0 ]]; then
        echo "$TAG prompt 请作为单个参数传入；多行可用 \$'第一行\\n第二行'。" >&2
        exit 2
      fi
      ;;
  esac
done

if [[ ! -d "$WORKSPACE" ]]; then
  echo "$TAG workspace 不存在或不是目录：$WORKSPACE" >&2
  exit 2
fi
WORKSPACE="$(cd "$WORKSPACE" && pwd -P)"
PAD="${CLAUDE_LAUNCH_PAD:-$HOME/Library/Caches/claude-launch-pad}"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "$TAG 仅支持 macOS（claude:// 由 LaunchServices 投递，提交走辅助功能 API）。" >&2
  exit 1
fi
if [[ ! -d "$APP_PATH" ]]; then
  echo "$TAG 未找到 Claude 桌面应用：$APP_PATH" >&2
  exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "$TAG 未找到 python3；无法编码 launch URL。" >&2
  exit 1
fi

HAS_PROMPT=0
if [[ -n "${PROMPT//[[:space:]]/}" ]]; then
  HAS_PROMPT=1
fi

URL="$(
  CLAUDE_LAUNCH_PROMPT="$PROMPT" python3 - "$WORKSPACE" "$HAS_PROMPT" <<'PY'
import os
import sys
from urllib.parse import quote, urlencode

workspace, has_prompt = sys.argv[1], sys.argv[2] == "1"
prompt = os.environ.get("CLAUDE_LAUNCH_PROMPT", "")
pairs = [("folder", workspace)]
if has_prompt:
    units = len(prompt.encode("utf-16-le")) // 2
    limit = 14336
    if units > limit:
        print(
            f"[new_claude_session] prompt 为 {units} 个 UTF-16 单位，超过 Claude 桌面端上限 {limit}"
            "（超出部分会被静默截断）。请缩短 prompt，或把正文写进文件、prompt 只引用路径。",
            file=sys.stderr,
        )
        sys.exit(3)
    pairs.append(("q", prompt))
print("claude://code/new?" + urlencode(pairs, quote_via=quote, safe=""))
PY
)"

if [[ -z "$SUBMIT_TIMEOUT" ]]; then
  # 垫步与目标阶段各自等草稿就绪；目标阶段要在草稿上选模型与 effort，留足时间。
  SUBMIT_TIMEOUT=60
  if ! ps -axo comm= | grep -Fqx "$APP_PATH/Contents/MacOS/Claude"; then
    SUBMIT_TIMEOUT=90
  fi
fi

# 编辑区权限模式按钮上显示的文字；只认得 bypass，其它模式只在日志里核对。
MODE_LABEL=""
if [[ "$EXPECT_MODE" == "bypassPermissions" ]]; then
  MODE_LABEL="Bypass permissions"
fi

open_link() {
  if ! open "$1"; then
    echo "$TAG 无法打开 claude:// launch link。" >&2
    echo "$TAG 确认 $APP_PATH 已登记 claude://，且未被管理策略禁用 deep link。" >&2
    exit 1
  fi
}

if [[ "$HAS_PROMPT" -eq 0 ]]; then
  if [[ -n "$MODEL_LABEL" || -n "$EFFORT_LABEL" ]]; then
    echo "$TAG -m / -e 只在提交 prompt 时生效（只准备草稿时请在界面里选）。" >&2
    exit 2
  fi
  open_link "$URL"
  echo "$TAG 已打开新 Claude Code session 页（无 prompt，不发送）。"
  echo "$TAG workspace: ${WORKSPACE}"
  echo "$TAG 注：桌面端会弹「Trust this workspace?」，需在界面里确认。"
  exit 0
fi

mkdir -p "$PAD"
PAD="$(cd "$PAD" && pwd -P)"
if [[ "$PAD" == "$WORKSPACE" ]]; then
  echo "$TAG 垫步目录不能等于 workspace：$PAD（改 CLAUDE_LAUNCH_PAD）。" >&2
  exit 2
fi
PAD_URL="$(python3 -c 'import sys; from urllib.parse import quote, urlencode; print("claude://code/new?" + urlencode([("folder", sys.argv[1])], quote_via=quote, safe=""))' "$PAD")"

SUBMIT_SCRIPT="$(mktemp -t claude_new_session.XXXXXX).js"
trap 'rm -f "$SUBMIT_SCRIPT"' EXIT
cat > "$SUBMIT_SCRIPT" <<'JXA'
ObjC.import('AppKit');
ObjC.bindFunction('AXUIElementCreateApplication', ['id', ['int']]);
ObjC.bindFunction('AXUIElementCopyAttributeValue', ['int', ['id', 'id', 'id*']]);
ObjC.bindFunction('AXUIElementSetAttributeValue', ['int', ['id', 'id', 'id']]);
ObjC.bindFunction('AXUIElementPerformAction', ['int', ['id', 'id']]);

function env(name) {
  const v = $.NSProcessInfo.processInfo.environment.objectForKey(name);
  return v.isNil() ? '' : v.js;
}

// Claude 会把全角标点等归一（实测 NFKC 类），输入框的换行表示也可能不同：
// 比较时两边都做 NFKC 并去掉全部空白。
function norm(s) {
  return String(s).normalize('NFKC').replace(/\s+/g, '');
}

function attr(el, name) {
  const r = Ref();
  return $.AXUIElementCopyAttributeValue(el, $(name), r) === 0 ? r[0] : null;
}

function str(el, name) {
  const v = attr(el, name);
  if (v === null) return '';
  try {
    const u = ObjC.unwrap(v);
    return typeof u === 'string' ? u : '';
  } catch (e) {
    return '';
  }
}

function find(root, pred, maxDepth) {
  const out = [];
  const stack = [[root, 0]];
  while (stack.length > 0) {
    const [el, depth] = stack.pop();
    if (pred(el)) out.push(el);
    if (depth >= maxDepth) continue;
    const kids = attr(el, 'AXChildren');
    if (kids === null) continue;
    for (let i = 0; i < kids.count; i++) stack.push([kids.objectAtIndex(i), depth + 1]);
  }
  return out;
}

function is(el, role, attrName, value) {
  return str(el, 'AXRole') === role && str(el, attrName) === value;
}

function run() {
  const bundleId = env('CLAUDE_BUNDLE_ID');
  const appPath = env('CLAUDE_APP_PATH');
  const want = norm(env('CLAUDE_LAUNCH_PROMPT'));
  const workspace = env('CLAUDE_WORKSPACE');
  const folderLabel = workspace.replace(/\/+$/, '').split('/').pop();
  const modeLabel = env('CLAUDE_MODE_LABEL');
  const modelLabel = env('CLAUDE_MODEL_LABEL');
  const effortLabel = env('CLAUDE_EFFORT_LABEL');
  const phase = env('CLAUDE_PHASE');
  const deadline = Date.now() + Number(env('CLAUDE_SUBMIT_TIMEOUT')) * 1000;
  const se = Application('System Events');

  let cachedPid = null;
  let cachedAx = null;
  let axArmedAt = 0;
  const appElement = () => {
    const apps = $.NSRunningApplication.runningApplicationsWithBundleIdentifier(bundleId);
    if (apps.count === 0) return null;
    const pid = apps.objectAtIndex(0).processIdentifier;
    if (pid !== cachedPid) {
      cachedPid = pid;
      cachedAx = $.AXUIElementCreateApplication(pid);
      // Electron 默认不暴露网页内容的 AX 树；这个属性让它按需构建（每个进程设一次）。
      // Electron 44（Claude Desktop 4.4212.0）起设置后还要防抖 2 秒才进入完整无障碍模式：
      // 这 2 秒里树读得到，但 AXPress 等动作不生效（源码 shell/browser/mac/electron_application.mm，
      // enableScreenReaderCompleteModeAfterDelay）。所以读树不等，动作一律等 axReady()。
      $.AXUIElementSetAttributeValue(cachedAx, $('AXManualAccessibility'), $.NSNumber.numberWithBool(true));
      axArmedAt = Date.now();
    }
    return cachedAx;
  };
  // 2 秒防抖 + 0.6 秒让树重建完成。完整模式一旦进入就保持到进程退出，所以多等只发生在本进程开头。
  const AX_SETTLE_MS = 2600;
  const axReady = () => axArmedAt !== 0 && Date.now() - axArmedAt >= AX_SETTLE_MS;
  const axWait = 'waiting for the accessibility tree to become fully active (Electron 2s debounce)';
  const windowOf = (ax) => attr(ax, 'AXFocusedWindow') || attr(ax, 'AXMainWindow');

  const frontmost = () => {
    const front = se.applicationProcesses.whose({ frontmost: true })();
    return front.length > 0 && front[0].bundleIdentifier() === bundleId;
  };

  // 「Trust this workspace?」框：返回框里显示的路径与「Trust workspace」按钮。
  const trustDialog = (win) => {
    // 信任框实测位于第 13 层（Trust this workspace?），留余量到 24 层。
    const dialogs = find(win, (el) => /Dialog/.test(str(el, 'AXSubrole')), 24);
    for (const dlg of dialogs) {
      const btn = find(dlg, (el) => is(el, 'AXButton', 'AXTitle', 'Trust workspace'), 12);
      if (btn.length !== 1) continue;
      const paths = find(dlg, (el) => str(el, 'AXRole') === 'AXStaticText' && str(el, 'AXValue').startsWith('/'), 12)
        .map((el) => str(el, 'AXValue'));
      return { button: btn[0], paths };
    }
    return null;
  };

  // 找到装着本 prompt 的那一个 Prompt 输入框。
  const locate = (win) => {
    const boxes = find(win, (el) => is(el, 'AXTextArea', 'AXDescription', 'Prompt'), 80);
    const mine = boxes.filter((el) => norm(str(el, 'AXValue')) === want);
    if (mine.length === 1) return { box: mine[0] };
    if (mine.length > 1) return { why: 'more than one Prompt box holds the prompt' };
    return { why: `no Prompt box holds the prompt (${boxes.length} Prompt boxes)`, gone: true };
  };

  // 输入框所在编辑区的弹出按钮，由近及远逐层给出；爬到别的编辑区（另一个 Prompt 框）就停。
  const composerPopups = (box) => {
    const levels = [];
    let el = box;
    for (let level = 0; level < 12; level++) {
      el = attr(el, 'AXParent');
      if (el === null) break;
      if (find(el, (x) => is(x, 'AXTextArea', 'AXDescription', 'Prompt'), 30).length > 1) break;
      const popups = find(el, (x) => str(x, 'AXRole') === 'AXPopUpButton', 30);
      levels.push(popups);
      // 编辑区的弹出按钮（文件夹、权限、Model）与「Model: …」同层（Claude Desktop 2.37337.1 实测第 6 层；
      // 更近的祖先里只有「Add」），找到含 Model 按钮的一层就停，再往上爬只浪费时间。
      if (popups.some((x) => str(x, 'AXDescription').startsWith('Model: '))) break;
    }
    return levels;
  };
  const modelText = modelLabel === '' ? '' : `Model: ${modelLabel}`;
  const effortText = effortLabel === '' ? '' : `Effort: ${effortLabel}`;
  // Claude Desktop 2.37337.1 起：文件夹按钮的 AXDescription 为「Folder: <路径>」（家目录写作 ~），
  // 权限按钮为「Permissions: <模式>」，模型与 effort 合并为一个按钮「Model: <模型> <effort>」，
  // 没有单独的 Effort 按钮。早先版本用 AXTitle 显示文件夹名与模式名，另有「Effort: <档>」按钮。
  const home = env('HOME').replace(/\/+$/, '');
  const tildeWorkspace = home !== '' && workspace.startsWith(home + '/') ? '~' + workspace.slice(home.length) : workspace;
  // 已登记为 Code 项目的目录不显示文件夹按钮，而是「Environment: <项目名>」（项目名即目录名）；
  // 同名项目的歧义由提交后按日志核对 session 的 cwd 兜住（退出码 5）。
  const showsFolder = (titles, descs) => titles.includes(folderLabel)
    || descs.includes(`Folder: ${workspace}`) || descs.includes(`Folder: ${tildeWorkspace}`)
    || descs.includes(`Environment: ${folderLabel}`);
  const showsMode = (titles, descs) => modeLabel === '' || titles.includes(modeLabel) || descs.includes(`Permissions: ${modeLabel}`);
  const showsModel = (desc) => desc === modelText || desc.startsWith(`${modelText} `);
  // 合并按钮里 effort 是最后一个词；没有单独 Effort 按钮时由它判定。
  const effortOfModel = (desc) => {
    const word = desc.split(' ').pop();
    return effortSteps.includes(word) ? word : '';
  };
  const showsEffort = (descs) => descs.includes(effortText)
    || descs.some((d) => d.startsWith('Model: ') && effortOfModel(d) === effortLabel);

  // 草稿就绪：输入框所在编辑区里显示本 workspace 的文件夹按钮、期望的权限模式按钮，
  // 以及（wantPicks 且给了 -m / -e 时）期望的模型与 effort。
  const ready = (box, wantPicks) => {
    for (const popups of composerPopupsMemo(box)) {
      const titles = popups.map((x) => str(x, 'AXTitle'));
      const descs = popups.map((x) => str(x, 'AXDescription'));
      if (showsFolder(titles, descs) && showsMode(titles, descs)
        && (!wantPicks || modelText === '' || descs.some(showsModel))
        && (!wantPicks || effortText === '' || showsEffort(descs))) return null;
    }
    const parts = [`folder "${folderLabel}"`];
    if (modeLabel !== '') parts.push(`"${modeLabel}"`);
    if (wantPicks && modelText !== '') parts.push(`"${modelText}"`);
    if (wantPicks && effortText !== '') parts.push(`"${effortText}"`);
    return `draft does not show ${parts.join(' and ')} yet`;
  };

  // 同一个 Prompt 框对象上只爬一次编辑区，ready / 模型 / effort 检查共用。
  let popupMemo = null;
  const composerPopupsMemo = (box) => {
    if (popupMemo !== null && popupMemo.box === box) return popupMemo.levels;
    const levels = composerPopups(box);
    popupMemo = { box, levels };
    return levels;
  };
  // 编辑区里的「Model: …」按钮；没有返回 null。
  const modelButton = (box) => {
    for (const popups of composerPopupsMemo(box)) {
      const hit = popups.filter((x) => str(x, 'AXDescription').startsWith('Model: '));
      if (hit.length === 1) return hit[0];
    }
    return null;
  };

  // 编辑区里的「Effort: …」按钮；没有返回 null。
  const effortButton = (box) => {
    for (const popups of composerPopupsMemo(box)) {
      const hit = popups.filter((x) => str(x, 'AXDescription').startsWith('Effort: '));
      if (hit.length === 1) return hit[0];
    }
    return null;
  };

  // 打开模型菜单、按下名字完全相同的菜单项；菜单里没有就关掉菜单报错（不猜近似名）。
  let modelPicks = 0;
  // effort 滑块的档位顺序（AXSlider 的 AXValueDescription 以档名开头，如 "Medium (Recommended)"）。
  const effortSteps = ['Low', 'Medium', 'High', 'Extra', 'Max', 'Ultracode'];
  let effortPicks = 0;
  const effortSlider = () => {
    const w = windowOf(cachedAx);
    if (w === null) return null;
    let hit = find(w, (x) => is(x, 'AXSlider', 'AXDescription', 'Effort'), 12);
    if (hit.length !== 1) hit = find(w, (x) => is(x, 'AXSlider', 'AXDescription', 'Effort'), 90);
    return hit.length === 1 ? hit[0] : null;
  };
  const stepOf = (slider) => {
    const label = str(slider, 'AXValueDescription');
    return effortSteps.findIndex((name) => label.startsWith(name));
  };
  // 效果滑块与模型菜单都挂在它们按钮的祖先容器里（实测：父层 14 层内约 12–14ms，全窗口约 350ms）。
  // 先在按钮的 1–3 层祖先里找；找不到才由调用方回退到全窗口搜索。
  const nearHit = (btn, pred) => {
    let anc = btn;
    for (let k = 0; k < 3; k++) {
      const p = attr(anc, 'AXParent');
      if (p === null) break;
      anc = p;
      const hit = find(anc, pred, 14);
      if (hit.length === 1) return hit[0];
    }
    return null;
  };
  const isEffortSlider = (x) => is(x, 'AXSlider', 'AXDescription', 'Effort');
  // 按下 Effort 按钮打开对话框，把滑块走到目标档，再按一次按钮收起对话框。
  const pickEffort = (btn) => {
    if (effortPicks >= 3) throw new Error(`the Effort picker does not stay on "${effortLabel}"`);
    effortPicks++;
    const target = effortSteps.indexOf(effortLabel);
    if (target < 0) throw new Error(`unknown effort "${effortLabel}"`);
    let slider = nearHit(btn, isEffortSlider);
    if (slider === null) {
      $.AXUIElementPerformAction(btn, $('AXPress'));
      const until = Date.now() + 3000;
      while (slider === null && Date.now() < until) {
        delay(0.05);
        slider = nearHit(btn, isEffortSlider);
      }
      if (slider === null) slider = effortSlider();
    }
    if (slider === null) throw new Error('the Effort dialog did not open');
    for (let i = 0; i < 8; i++) {
      const at = stepOf(slider);
      if (at < 0) throw new Error(`the Effort slider shows "${str(slider, 'AXValueDescription')}", not a known level`);
      if (at === target) break;
      $.AXUIElementPerformAction(slider, $(at < target ? 'AXIncrement' : 'AXDecrement'));
      delay(0.1);
      slider = nearHit(btn, isEffortSlider) || effortSlider();
      if (slider === null) throw new Error('the Effort slider disappeared while stepping');
    }
    if (stepOf(slider) !== target) throw new Error(`could not move the Effort slider to "${effortLabel}"`);
    $.AXUIElementPerformAction(btn, $('AXPress'));
    const until = Date.now() + 3000;
    while (nearHit(btn, isEffortSlider) !== null && Date.now() < until) delay(0.05);
    if (nearHit(btn, isEffortSlider) !== null) throw new Error('the Effort dialog did not close');
    delay(0.1);
  };

  // 弹出菜单的容器：Claude Desktop 2.37337.1 为 AXMenu；2.42304.0 为 AXGroup，标题仍与触发项的
  // AXDescription（模型按钮）或 AXTitle（「Effort <档>」子菜单项）相同，菜单项仍是 AXMenuItem。
  // 两种角色都接受，标题必须完全相同。
  const isMenuNode = (x, title) => ['AXMenu', 'AXGroup'].includes(str(x, 'AXRole')) && str(x, 'AXTitle') === title;
  // 窗口里是否还开着菜单（模型菜单或其 Effort 子菜单）；开着时按 Return 会选中菜单项而不是提交。
  const menuOpen = (ax) => {
    const w = windowOf(ax);
    return w !== null && find(w, (x) => str(x, 'AXRole') === 'AXMenu'
      || (str(x, 'AXRole') === 'AXGroup' && /^(Model: |Effort )/.test(str(x, 'AXTitle'))), 90).length > 0;
  };

  // 按下 Model 按钮，返回它打开的菜单（菜单容器的标题与按钮的 AXDescription 相同）。
  const openModelMenu = (ax, button) => {
    const menuTitle = str(button, 'AXDescription');
    const isMenu = (x) => isMenuNode(x, menuTitle);
    $.AXUIElementPerformAction(button, $('AXPress'));
    let menu = nearHit(button, isMenu);
    const until = Date.now() + 3000;
    while (menu === null && Date.now() < until) {
      delay(0.05);
      menu = nearHit(button, isMenu);
    }
    if (menu === null) {
      const w = windowOf(ax);
      if (w !== null) {
        const menus = find(w, isMenu, 90);
        if (menus.length === 1) menu = menus[0];
      }
    }
    if (menu === null) throw new Error(`the Model menu did not open (${menuTitle})`);
    return menu;
  };

  // Claude Desktop 2.37337.1：effort 在模型菜单的「Effort <档>」子菜单里（档名 Low、Medium Recommended、High、
  // Extra、Max、Ultracode，当前档 AXValue 为 1）。该菜单项没有 AX 动作：聚焦它后按右方向键展开子菜单，
  // 再按下名字等于目标档、或以「目标档 」开头的项。
  const pickEffortInMenu = (ax, button) => {
    if (effortPicks >= 3) throw new Error(`the Effort picker does not stay on "${effortLabel}"`);
    effortPicks++;
    if (!effortSteps.includes(effortLabel)) throw new Error(`unknown effort "${effortLabel}"`);
    const menu = openModelMenu(ax, button);
    const entry = find(menu, (x) => str(x, 'AXRole') === 'AXMenuItem' && str(x, 'AXTitle').startsWith('Effort '), 12);
    if (entry.length !== 1) {
      se.keyCode(53); // Escape
      throw new Error('the Model menu has no Effort item');
    }
    const subTitle = str(entry[0], 'AXTitle');
    if (!frontmost()) {
      Application(appPath).activate();
      delay(0.3);
      if (!frontmost()) {
        se.keyCode(53);
        throw new Error('Claude Desktop is not frontmost; cannot open the Effort submenu');
      }
    }
    $.AXUIElementSetAttributeValue(entry[0], $('AXFocused'), $.NSNumber.numberWithBool(true));
    delay(0.1);
    se.keyCode(124); // Right arrow
    const isSub = (x) => isMenuNode(x, subTitle);
    let sub = null;
    const until = Date.now() + 3000;
    while (sub === null && Date.now() < until) {
      delay(0.05);
      const w = windowOf(ax);
      const subs = w === null ? [] : find(w, isSub, 90);
      if (subs.length === 1) sub = subs[0];
    }
    if (sub === null) {
      se.keyCode(53);
      throw new Error(`the Effort submenu did not open (${subTitle})`);
    }
    const items = find(sub, (x) => str(x, 'AXRole') === 'AXMenuItem', 6);
    const hit = items.filter((x) => str(x, 'AXTitle') === effortLabel || str(x, 'AXTitle').startsWith(`${effortLabel} `));
    if (hit.length !== 1) {
      se.keyCode(53);
      delay(0.1);
      se.keyCode(53);
      throw new Error(`the Effort submenu has no item "${effortLabel}" (items: ${items.map((x) => str(x, 'AXTitle')).join(', ')})`);
    }
    $.AXUIElementPerformAction(hit[0], $('AXPress'));
    const closed = Date.now() + 2000;
    while (menuOpen(ax) && Date.now() < closed) delay(0.1);
    if (menuOpen(ax)) se.keyCode(53);
    delay(0.1);
  };

  const pickModel = (ax, button) => {
    if (modelPicks >= 3) throw new Error(`the Model picker does not stay on "${modelLabel}"`);
    modelPicks++;
    const menuTitle = str(button, 'AXDescription');
    const isMenu = (x) => isMenuNode(x, menuTitle);
    $.AXUIElementPerformAction(button, $('AXPress'));
    let menu = nearHit(button, isMenu);
    const until = Date.now() + 3000;
    while (menu === null && Date.now() < until) {
      delay(0.05);
      menu = nearHit(button, isMenu);
    }
    if (menu === null) {
      const w = windowOf(ax);
      if (w !== null) {
        const menus = find(w, isMenu, 90);
        if (menus.length === 1) menu = menus[0];
      }
    }
    if (menu === null) throw new Error(`the Model menu did not open (${menuTitle})`);
    const items = find(menu, (x) => str(x, 'AXRole') === 'AXMenuItem', 12);
    const hit = items.filter((x) => str(x, 'AXTitle') === modelLabel);
    if (hit.length !== 1) {
      $.AXUIElementPerformAction(menu, $('AXCancel'));
      throw new Error(`the Model menu has no item "${modelLabel}" (items: ${items.map((x) => str(x, 'AXTitle')).join(', ')})`);
    }
    $.AXUIElementPerformAction(hit[0], $('AXPress'));
    delay(0.1);
  };

  let trustClicks = 0;
  let trustRc = 0;
  let readySince = 0;
  let last = 'Claude Desktop not running';
  const timing = { prompt: 0, model: 0, effort: 0, ret: 0 };
  let promptBox = null;
  const livePromptHolds = (box) => attr(box, 'AXRole') !== null && norm(str(box, 'AXValue')) === want;
  const dryRun = env('CLAUDE_DRY_RUN') === '1';
  while (Date.now() < deadline) {
    const ax = appElement();
    const win = ax === null ? null : windowOf(ax);
    if (win === null) {
      delay(0.3);
      continue;
    }
    popupMemo = null;
    const td = trustDialog(win);
    if (td !== null) {
      if (td.paths.length !== 1 || td.paths[0] !== workspace) {
        throw new Error(`the Trust dialog shows ${td.paths.length === 1 ? 'a different folder' : 'no readable folder'}; not clicking Trust`);
      }
      if (!axReady()) {
        last = axWait;
        delay(0.2);
        continue;
      }
      if (trustClicks >= 3) throw new Error(`the Trust dialog is still there after ${trustClicks} presses of "Trust workspace" (last AXPress rc=${trustRc}); not clicking again`);
      trustRc = $.AXUIElementPerformAction(td.button, $('AXPress'));
      trustClicks++;
      last = 'waiting for the Trust dialog to close';
      // 按下后等它真的关掉（完整模式下实测约 0.5 秒）；3 秒内没关才算这次没按上，回到循环再按。
      const closeBy = Date.now() + 3000;
      while (Date.now() < closeBy) {
        delay(0.1);
        const w = windowOf(ax);
        if (w === null || trustDialog(w) === null) break;
      }
      continue;
    }
    if (phase === 'pad') {
      // 垫步只为改变草稿的文件夹（桌面端同一文件夹重开会丢失已信任文件夹，提交落进 scratch）。
      // 不碰模型与 effort：它们在目标草稿上设置。只动「恰有一个 Prompt 框且显示垫步目录」的草稿。
      const boxes = find(win, (el) => is(el, 'AXTextArea', 'AXDescription', 'Prompt'), 80);
      const notReady = boxes.length === 1 ? ready(boxes[0], false) : `${boxes.length} Prompt boxes`;
      if (notReady) {
        last = notReady;
        readySince = 0;
        delay(0.3);
        continue;
      }
      if (readySince === 0) readySince = Date.now();
      if (Date.now() - readySince < 500) {
        delay(0.25);
        continue;
      }
      return `pad trust_clicks=${trustClicks}`;
    }
    const loc = (promptBox !== null && livePromptHolds(promptBox)) ? { box: promptBox } : locate(win);
    if (loc.why) {
      last = loc.why;
      delay(0.3);
      continue;
    }
    promptBox = loc.box;
    if (timing.prompt === 0) timing.prompt = Date.now();
    if (!axReady()) {
      last = axWait;
      delay(0.2);
      continue;
    }
    // 目标阶段：深链已带上文件夹与 prompt，这里再在同一份草稿上设模型与 effort（与垫步相同的选择步骤，
    // 每步后重新定位草稿并校验）。只有模型与 effort 都校验通过才会提交；选择失败则超时、不提交。
    const folderNotReady = ready(loc.box, false);
    if (folderNotReady) {
      last = folderNotReady;
      readySince = 0;
      delay(0.1);
      continue;
    }
    if (modelText !== '') {
      const button = modelButton(loc.box);
      if (button === null) {
        last = 'draft has no Model picker yet';
        readySince = 0;
        delay(0.1);
        continue;
      }
      if (!showsModel(str(button, 'AXDescription'))) {
        pickModel(ax, button);
        readySince = 0;
        continue;
      }
    }
    if (timing.model === 0) timing.model = Date.now();
    if (effortText !== '') {
      // 早先版本有单独的 Effort 按钮（滑块对话框）；2.37337.1 起 effort 并入 Model 按钮，在其子菜单里选。
      const button = effortButton(loc.box);
      const combined = button === null ? modelButton(loc.box) : null;
      if (button === null && combined === null) {
        last = 'draft has no Effort picker yet';
        readySince = 0;
        delay(0.1);
        continue;
      }
      if (button !== null && str(button, 'AXDescription') !== effortText) {
        pickEffort(button);
        readySince = 0;
        continue;
      }
      if (combined !== null && effortOfModel(str(combined, 'AXDescription')) !== effortLabel) {
        pickEffortInMenu(ax, combined);
        readySince = 0;
        continue;
      }
    }
    if (timing.effort === 0) timing.effort = Date.now();
    const notReady = ready(loc.box, true);
    if (notReady) {
      last = notReady;
      readySince = 0;
      delay(0.1);
      continue;
    }
    // 就绪状态要连续保持 0.5s，避开文件夹刚落上又被草稿重挂载清掉的瞬间。
    if (readySince === 0) readySince = Date.now();
    if (Date.now() - readySince < 500) {
      last = 'draft just became ready';
      delay(0.1);
      continue;
    }
    if (!frontmost()) {
      Application(appPath).activate();
      delay(0.3);
      if (!frontmost()) {
        last = 'Claude Desktop is not frontmost';
        continue;
      }
    }
    if (menuOpen(ax)) {
      se.keyCode(53); // Escape: a menu left open would take the Return
      last = 'a menu is still open';
      readySince = 0;
      delay(0.2);
      continue;
    }
    $.AXUIElementSetAttributeValue(loc.box, $('AXFocused'), $.NSNumber.numberWithBool(true));
    for (let i = 0; i < 12; i++) {
      delay(0.05);
      const f = attr(ax, 'AXFocusedUIElement');
      if (f !== null && is(f, 'AXTextArea', 'AXDescription', 'Prompt')) break;
    }
    const focused = attr(ax, 'AXFocusedUIElement');
    if (focused === null || !is(focused, 'AXTextArea', 'AXDescription', 'Prompt') || norm(str(focused, 'AXValue')) !== want) {
      last = 'could not put keyboard focus on the Prompt box that holds the prompt';
      delay(0.3);
      continue;
    }
    timing.ret = Date.now();
    const timingText = `timing=prompt_to_model_ms:${timing.model - timing.prompt},model_to_effort_ms:${timing.effort - timing.model},effort_to_return_ms:${timing.ret - timing.effort}`;
    if (dryRun) return `dry_run trust_clicks=${trustClicks} model_picks=${modelPicks} effort_picks=${effortPicks} ${timingText}`;
    se.keyCode(36); // Return
    const sentDeadline = Date.now() + 8000;
    let sentPolls = 0;
    while (Date.now() < sentDeadline) {
      delay(0.1);
      sentPolls++;
      if (promptBox !== null && attr(promptBox, 'AXRole') !== null && norm(str(promptBox, 'AXValue')) !== want) return `sent trust_clicks=${trustClicks} model_picks=${modelPicks} effort_picks=${effortPicks} ${timingText}`;
      const w = windowOf(ax);
      if (sentPolls % 5 === 0 && w !== null && locate(w).gone) return `sent trust_clicks=${trustClicks} model_picks=${modelPicks} effort_picks=${effortPicks} ${timingText}`;
    }
    return `unconfirmed trust_clicks=${trustClicks} model_picks=${modelPicks} effort_picks=${effortPicks} ${timingText}`;
  }
  throw new Error(`timed out waiting for the draft: ${last}`);
}
JXA

run_jxa() { # phase workspace mode_label
  CLAUDE_PHASE="$1" \
  CLAUDE_LAUNCH_PROMPT="$PROMPT" \
  CLAUDE_BUNDLE_ID="$BUNDLE_ID" \
  CLAUDE_APP_PATH="$APP_PATH" \
  CLAUDE_WORKSPACE="$2" \
  CLAUDE_MODE_LABEL="$3" \
  CLAUDE_MODEL_LABEL="$MODEL_LABEL" \
  CLAUDE_EFFORT_LABEL="$EFFORT_LABEL" \
  CLAUDE_SUBMIT_TIMEOUT="$SUBMIT_TIMEOUT" \
  osascript -l JavaScript "$SUBMIT_SCRIPT" 2>&1
}

# 垫步：先把草稿切到垫步目录，确保目标链接一定改变草稿的文件夹。
open_link "$PAD_URL"
STATUS=0
RESULT="$(run_jxa pad "$PAD" "")" || STATUS=$?
if [[ "$STATUS" -ne 0 ]]; then
  echo "$TAG 垫步没完成，未打开目标链接、未提交：${RESULT}" >&2
  exit 1
fi
PAD_CLICKS="$(sed -n 's/.*trust_clicks=\([0-9]*\).*/\1/p' <<<"$RESULT")"

LOG_OFFSET=0
if [[ -f "$LOG_FILE" ]]; then
  LOG_OFFSET="$(stat -f %z "$LOG_FILE")"
fi
open_link "$URL"
STATUS=0
RESULT="$(run_jxa submit "$WORKSPACE" "$MODE_LABEL")" || STATUS=$?

if [[ "$STATUS" -ne 0 ]]; then
  echo "$TAG 已打开链接，但未提交（没按 Return）：${RESULT}" >&2
  echo "$TAG 确认宿主有「辅助功能」权限、Claude 窗口停在新 session 页；" >&2
  echo "$TAG 慢机器可调大 CLAUDE_SUBMIT_TIMEOUT 后重跑。" >&2
  exit 1
fi

TRUST_CLICKS="$(sed -n 's/.*trust_clicks=\([0-9]*\).*/\1/p' <<<"$RESULT")"
MODEL_PICKS="$(sed -n 's/.*model_picks=\([0-9]*\).*/\1/p' <<<"$RESULT")"
EFFORT_PICKS="$(sed -n 's/.*effort_picks=\([0-9]*\).*/\1/p' <<<"$RESULT")"
TIMING="$(sed -n 's/.*timing=\(.*\)$/\1/p' <<<"$RESULT")"
echo "$TAG timing (ms): ${TIMING:-none}"
if [[ "$RESULT" == dry_run* ]]; then
  echo "$TAG dry run: stopped before Return; nothing submitted."
  exit 0
fi
CONFIRMED=1
if [[ "$RESULT" == unconfirmed* ]]; then
  CONFIRMED=0
fi

# 从桌面端日志找本次新建的 session：offset 之后出现、此前从未出现过的 session id。
# 挂起的提交最多 10s 后才兜底放行，所以最多等 15s。
FOUND="$(
  python3 - "$LOG_FILE" "$LOG_OFFSET" "$WORKSPACE" <<'PY'
import re
import sys
import time

log_file, offset, workspace = sys.argv[1], int(sys.argv[2]), sys.argv[3]
start_re = re.compile(r"Starting local session (local_[0-9A-Za-z-]+) in (.*)$")
deadline = time.time() + 15
result = None
while time.time() < deadline:
    try:
        raw = open(log_file, "rb").read()
    except OSError:
        break
    if len(raw) < offset:
        offset = 0
    head = raw[:offset].decode("utf-8", "replace")
    tail = raw[offset:].decode("utf-8", "replace")
    candidates = []
    for line in tail.splitlines():
        m = start_re.search(line)
        if not m or m.group(1) in head:
            continue
        sid, cwd = m.group(1), m.group(2).strip()
        ours = cwd == workspace or cwd.startswith(workspace + "/.claude/worktrees/")
        scratch = "/scratch-workspaces/" in cwd
        if ours or scratch:
            mode = re.search(r"\[permissionMode\] spawn " + re.escape(sid) + r" .*effective=(\S+)", tail)
            candidates.append((0 if ours else 1, sid, cwd, mode.group(1) if mode else ""))
    if candidates:
        candidates.sort()
        result = candidates[0]
        if result[0] == 0 and result[3]:
            break
    time.sleep(0.25)
if result:
    print("\t".join(result[1:]))
PY
)"

echo "$TAG workspace: ${WORKSPACE}"
echo "$TAG prompt_chars: ${#PROMPT}"
echo "$TAG trust_clicks: pad=${PAD_CLICKS:-0} workspace=${TRUST_CLICKS:-0}"
if [[ -n "$MODEL_LABEL" ]]; then
  echo "$TAG model_picks: ${MODEL_PICKS:-0}"
fi
if [[ -n "$EFFORT_LABEL" ]]; then
  echo "$TAG effort_picks: ${EFFORT_PICKS:-0}"
fi
if [[ -z "$FOUND" ]]; then
  if [[ "$CONFIRMED" -eq 1 ]]; then
    echo "$TAG 已提交，但 ${LOG_FILE} 里没找到本次新建的 session，无法核对权限模式与工作目录。" >&2
  else
    echo "$TAG 已按 Return，但输入框没清空，日志里也没有新 session。先在 Claude 里核对，不要直接重跑。" >&2
  fi
  exit 6
fi
IFS=$'\t' read -r SESSION_ID SESSION_CWD EFFECTIVE <<<"$FOUND"
echo "$TAG session: ${SESSION_ID}"
echo "$TAG session_cwd: ${SESSION_CWD}"
echo "$TAG permission_mode: ${EFFECTIVE:-?}"
if [[ "$SESSION_CWD" != "$WORKSPACE" && "$SESSION_CWD" != "$WORKSPACE/.claude/worktrees/"* ]]; then
  echo "$TAG 错误：session 没有开在 ${WORKSPACE}，而是 ${SESSION_CWD}。" >&2
  exit 5
fi
if [[ -n "$EXPECT_MODE" && "$EFFECTIVE" != "$EXPECT_MODE" ]]; then
  echo "$TAG 错误：session 以 ${EFFECTIVE:-未知模式} 启动，不是 ${EXPECT_MODE}。" >&2
  echo "$TAG 检查 ~/.claude/settings.json 的 permissions.defaultMode（须在用户级设置）。" >&2
  exit 4
fi
if [[ -n "$MODEL_LABEL" || -n "$EFFORT_LABEL" ]]; then
  # 桌面端把每个 session 的设置记在 claude-code-sessions/<account>/<org>/<id>.json；
  # 菜单名 "Sonnet 5.5" 对应模型 id claude-sonnet-5-5（可能带日期后缀），Extra 记作 xhigh。
  RECORD="$(
    python3 - "$SESSIONS_DIR" "$SESSION_ID" <<'PY'
import glob
import json
import os
import sys
import time

root, sid = sys.argv[1], sys.argv[2]
deadline = time.time() + 10
while time.time() < deadline:
    for path in glob.glob(os.path.join(glob.escape(root), "*", "*", sid + ".json")):
        try:
            data = json.load(open(path, encoding="utf-8"))
        except (OSError, ValueError):
            continue
        if data.get("model"):
            print((data.get("model") or "") + "\t" + (data.get("effort") or ""))
            sys.exit(0)
    time.sleep(0.25)
PY
  )"
  IFS=$'\t' read -r SESSION_MODEL SESSION_EFFORT <<<"$RECORD"
  if [[ -n "$MODEL_LABEL" ]]; then
    WANT_MODEL="claude-$(tr '[:upper:]' '[:lower:]' <<<"$MODEL_LABEL" | sed -E 's/[[:space:].]+/-/g')"
    echo "$TAG model: ${SESSION_MODEL:-?}"
    if [[ "$SESSION_MODEL" != "$WANT_MODEL" && "$SESSION_MODEL" != "$WANT_MODEL"-* ]]; then
      echo "$TAG 错误：session 记录的模型是 ${SESSION_MODEL:-未知}，不是 -m \"${MODEL_LABEL}\"（${WANT_MODEL}）。" >&2
      echo "$TAG session 已经开跑，不要直接重跑；可在 Claude 里切换它的模型。" >&2
      exit 7
    fi
  fi
  if [[ -n "$EFFORT_LABEL" ]]; then
    echo "$TAG effort: ${SESSION_EFFORT:-?}"
    if [[ "$SESSION_EFFORT" != "$EFFORT_RECORD" ]]; then
      echo "$TAG 错误：session 记录的 effort 是 ${SESSION_EFFORT:-未知}，不是 -e ${EFFORT_LABEL}（${EFFORT_RECORD}）。" >&2
      echo "$TAG session 已经开跑，不要直接重跑；可在 Claude 里切换它的 effort。" >&2
      exit 7
    fi
  fi
fi
if [[ "$CONFIRMED" -eq 0 ]]; then
  echo "$TAG 注：Return 后输入框 8s 内没清空，但日志显示 session 已按预期开跑。"
fi
echo "$TAG 已新建 Claude Code session 并提交 prompt。"
