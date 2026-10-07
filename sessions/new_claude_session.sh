#!/usr/bin/env bash
# 在 Claude 桌面应用（Code 标签页）里新建一个独立的 Claude Code session，并可选地提交 prompt。
#
# 用法：
#   new_claude_session.sh                              # 当前目录：只准备新 session，不发送
#   new_claude_session.sh "你的 prompt"                 # 当前目录：新建并提交 prompt
#   new_claude_session.sh -w /path/to/workspace         # 指定目录：只准备
#   new_claude_session.sh -w /path "你的 prompt"        # 指定目录：新建并提交 prompt
#
# 环境变量：
#   CLAUDE_APP                    Claude.app 路径（默认 /Applications/Claude.app）
#   CLAUDE_SUBMIT_TIMEOUT         等草稿就绪的最长秒数（默认 15；Claude 未运行时 45）
#   CLAUDE_EXPECT_PERMISSION_MODE 新 session 应有的权限模式（默认 bypassPermissions；置空则不核对）
#   CLAUDE_LAUNCH_PAD             垫步用的空目录（默认 ~/Library/Caches/claude-launch-pad，不能等于 workspace）
#
# 退出码：0 已提交；1 未提交（没按 Return，原因见输出）；2 参数错误；3 prompt 超长；
#   4 已提交，但 session 实际权限模式不是 CLAUDE_EXPECT_PERMISSION_MODE；
#   5 已提交，但 session 没有开在该 workspace（例如落进了 Claude 的 scratch 目录）；
#   6 已按 Return，但日志里没找到新 session（状态未知，先核对再决定是否重跑）。
#
# 全自动接力依赖两项全局设置：
#   ~/.claude/settings.json  permissions.defaultMode = "bypassPermissions"
#                            （只有用户级 settings 能把 bypass 设为默认；项目级会被忽略）
#   ~/.claude.json           projects["/"].hasTrustDialogAccepted = true
#                            （新 session 启动时的信任检查沿父目录上溯，根目录受信即通过）
#
# 原理（Claude Desktop 2.9939.2 源码核对 + 2026-09-26 实测）：
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
TAG="[new_claude_session]"

usage() {
  sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'
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
  SUBMIT_TIMEOUT=15
  if ! ps -axo comm= | grep -Fqx "$APP_PATH/Contents/MacOS/Claude"; then
    SUBMIT_TIMEOUT=45
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
  const phase = env('CLAUDE_PHASE');
  const deadline = Date.now() + Number(env('CLAUDE_SUBMIT_TIMEOUT')) * 1000;
  const se = Application('System Events');

  let cachedPid = null;
  let cachedAx = null;
  const appElement = () => {
    const apps = $.NSRunningApplication.runningApplicationsWithBundleIdentifier(bundleId);
    if (apps.count === 0) return null;
    const pid = apps.objectAtIndex(0).processIdentifier;
    if (pid !== cachedPid) {
      cachedPid = pid;
      cachedAx = $.AXUIElementCreateApplication(pid);
      // Electron 默认不暴露网页内容的 AX 树；这个属性让它按需构建（每个进程设一次）。
      $.AXUIElementSetAttributeValue(cachedAx, $('AXManualAccessibility'), $.NSNumber.numberWithBool(true));
    }
    return cachedAx;
  };
  const windowOf = (ax) => attr(ax, 'AXFocusedWindow') || attr(ax, 'AXMainWindow');

  const frontmost = () => {
    const front = se.applicationProcesses.whose({ frontmost: true })();
    return front.length > 0 && front[0].bundleIdentifier() === bundleId;
  };

  // 「Trust this workspace?」框：返回框里显示的路径与「Trust workspace」按钮。
  const trustDialog = (win) => {
    const dialogs = find(win, (el) => /Dialog/.test(str(el, 'AXSubrole')), 80);
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

  // 草稿就绪：输入框所在编辑区里显示本 workspace 的文件夹按钮与期望的权限模式按钮。
  // 只在包住这一个 Prompt 输入框的祖先里找，爬到别的编辑区（另一个 Prompt 框）就停。
  const ready = (box) => {
    let el = box;
    for (let level = 0; level < 12; level++) {
      el = attr(el, 'AXParent');
      if (el === null) break;
      if (find(el, (x) => is(x, 'AXTextArea', 'AXDescription', 'Prompt'), 30).length > 1) break;
      const popups = find(el, (x) => str(x, 'AXRole') === 'AXPopUpButton', 30).map((x) => str(x, 'AXTitle'));
      if (popups.includes(folderLabel) && (modeLabel === '' || popups.includes(modeLabel))) return null;
    }
    return modeLabel === ''
      ? `draft does not show folder "${folderLabel}" yet`
      : `draft does not show folder "${folderLabel}" and "${modeLabel}" yet`;
  };

  let trustClicks = 0;
  let readySince = 0;
  let last = 'Claude Desktop not running';
  while (Date.now() < deadline) {
    const ax = appElement();
    const win = ax === null ? null : windowOf(ax);
    if (win === null) {
      delay(0.3);
      continue;
    }
    const td = trustDialog(win);
    if (td !== null) {
      if (td.paths.length !== 1 || td.paths[0] !== workspace) {
        throw new Error(`the Trust dialog shows ${td.paths.length === 1 ? 'a different folder' : 'no readable folder'}; not clicking Trust`);
      }
      if (trustClicks >= 3) throw new Error('the Trust dialog keeps coming back; not clicking again');
      $.AXUIElementPerformAction(td.button, $('AXPress'));
      trustClicks++;
      last = 'waiting for the Trust dialog to close';
      delay(0.5);
      continue;
    }
    if (phase === 'pad') {
      // 垫步：草稿显示垫步目录即可，不碰输入框。
      const boxes = find(win, (el) => is(el, 'AXTextArea', 'AXDescription', 'Prompt'), 80);
      const notReady = boxes.length === 1 ? ready(boxes[0]) : `${boxes.length} Prompt boxes`;
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
    const loc = locate(win);
    if (loc.why) {
      last = loc.why;
      delay(0.3);
      continue;
    }
    const notReady = ready(loc.box);
    if (notReady) {
      last = notReady;
      readySince = 0;
      delay(0.3);
      continue;
    }
    // 就绪状态要连续保持 0.5s，避开文件夹刚落上又被草稿重挂载清掉的瞬间。
    if (readySince === 0) readySince = Date.now();
    if (Date.now() - readySince < 500) {
      last = 'draft just became ready';
      delay(0.25);
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
    $.AXUIElementSetAttributeValue(loc.box, $('AXFocused'), $.NSNumber.numberWithBool(true));
    delay(0.2);
    const focused = attr(ax, 'AXFocusedUIElement');
    if (focused === null || !is(focused, 'AXTextArea', 'AXDescription', 'Prompt') || norm(str(focused, 'AXValue')) !== want) {
      last = 'could not put keyboard focus on the Prompt box that holds the prompt';
      delay(0.3);
      continue;
    }
    se.keyCode(36); // Return
    const sentDeadline = Date.now() + 8000;
    while (Date.now() < sentDeadline) {
      delay(0.25);
      const w = windowOf(ax);
      if (w !== null && locate(w).gone) return `sent trust_clicks=${trustClicks}`;
    }
    return `unconfirmed trust_clicks=${trustClicks}`;
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
if [[ "$CONFIRMED" -eq 0 ]]; then
  echo "$TAG 注：Return 后输入框 8s 内没清空，但日志显示 session 已按预期开跑。"
fi
echo "$TAG 已新建 Claude Code session 并提交 prompt。"
