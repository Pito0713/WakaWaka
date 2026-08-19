#!/usr/bin/env bash
# WakaWaka 一鍵啟動腳本
# Usage: ./start.sh [--build]
#   --build / -b   跳過 mtime 比對，無條件重新 swift build

set -euo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$REPO/cost-aware-approval/app/WakaWaka"
HOOK="$REPO/cost-aware-approval/hooks/pretooluse.mjs"
CLAUDE_SETTINGS="$HOME/.claude/settings.json"
BINARY="$APP_DIR/.build/debug/WakaWaka"

G='\033[0;32m'; Y='\033[1;33m'; R='\033[0;31m'; N='\033[0m'
ok()   { echo -e "${G}✅${N} $*"; }
warn() { echo -e "${Y}⚠️ ${N} $*"; }
fail() { echo -e "${R}❌${N} $*"; exit 1; }

echo ""
echo "╔══════════════════════════════════════╗"
echo "║        WakaWaka — 啟動腳本           ║"
echo "╚══════════════════════════════════════╝"
echo ""

FORCE_BUILD=false
for arg in "$@"; do [[ "$arg" == "--build" || "$arg" == "-b" ]] && FORCE_BUILD=true; done

# ── Step 1: Build ─────────────────────────────────────────────
# 只看 app target 的輸入：Sources 下的 Swift 檔與 Package.swift。Tests 不進
# binary，改測試不該觸發重 build。
#
# 用 awk 求最大值而不是 `sort -rn | head -1`：head 讀到第一行就結束，會讓 sort
# 收到 SIGPIPE，在 pipefail 下整條 pipeline 算失敗，set -e 會直接中斷腳本。
latest_source_mtime() {
  { find "$APP_DIR/Sources" "$APP_DIR/Package.swift" -type f -name '*.swift' \
      -exec stat -f '%m' {} + 2>/dev/null || true; } \
    | awk 'BEGIN { newest = 0 } $1 + 0 > newest { newest = $1 + 0 } END { if (newest > 0) print newest }'
}

BUILD_REASON=""
if [[ "$FORCE_BUILD" == true ]]; then
  BUILD_REASON="--build 指定強制重建"
elif [[ ! -f "$BINARY" ]]; then
  BUILD_REASON="binary 不存在"
else
  # -L：$BINARY 走的是 .build/debug 這個 symlink，要拿目標檔的時間而不是連結的。
  BINARY_MTIME=$(stat -L -f '%m' "$BINARY" 2>/dev/null || echo 0)
  SOURCE_MTIME=$(latest_source_mtime)
  if [[ -z "$SOURCE_MTIME" ]]; then
    # 掃不到原始碼時寧可多 build 一次。判斷不出來就沿用舊 binary，正是這個
    # 檢查要防的事——舊執行檔被靜悄悄跑起來，行為對不上已經 commit 的程式碼。
    BUILD_REASON="無法判定原始碼時間"
  elif (( SOURCE_MTIME > BINARY_MTIME )); then
    BUILD_REASON="原始碼比 binary 新"
  fi
fi

if [[ -n "$BUILD_REASON" ]]; then
  # ${} 不可省略：全形括號緊接變數時 bash 會把它的首個 byte 併進變數名，
  # set -u 下直接變成 unbound variable（與下方 SKIN_SRC 同一個坑）。
  echo "🔨 Building WakaWaka...（${BUILD_REASON}）"
  (cd "$APP_DIR" && swift build) || fail "swift build 失敗，請確認已安裝 Xcode Command Line Tools"
  ok "Build 完成"
else
  ok "Binary 已是最新（原始碼自上次 build 後未變更）"
fi

# ── Step 2: 還原 menubar skin ────────────────────────────────
# SkinManager 只在啟動時掃描 ~/.wakawaka/skins，所以這步必須排在重啟之前，
# 首次安裝才能在同一次執行就載入到圖。以 idle_0.png 當基準幀判斷是否已安裝
# ——SkinManager 也是用它決定一個 skin 算不算存在。
#
# 用 cp -Rn（no-clobber）而非 cp -R：基準幀缺失但其他檔還在時（使用者改圖改壞、
# 或誤刪），-R 會連同使用者自己畫的圖一起蓋回原版。-n 只補真正缺的檔，
# 兩條路徑的語義因此一致——這個腳本只會補檔，永遠不覆寫既有的圖。
SKIN_SRC="$APP_DIR/skins/arcade"
SKIN_DEST="$HOME/.wakawaka/skins"

if [[ -f "$SKIN_DEST/arcade/idle_0.png" ]]; then
  ok "menubar skin 已安裝（略過）"
elif [[ -d "$SKIN_SRC" ]]; then
  mkdir -p "$SKIN_DEST"
  cp -Rn "$SKIN_SRC" "$SKIN_DEST/" || true   # -n 跳過既有檔時可能回傳非 0，不算失敗
  ok "menubar skin 已還原至 $SKIN_DEST/arcade"
else
  # ${} 不可省略：全形逗號緊接變數時，bash 會把它的首個 byte 併進變數名，
  # set -u 下會變成 unbound variable 直接中斷。
  warn "找不到 ${SKIN_SRC}，menubar 將使用內建繪製圖示"
fi

# ── Step 3: 重啟 WakaWaka ────────────────────────────────────
if pgrep -x WakaWaka &>/dev/null; then
  pkill -x WakaWaka 2>/dev/null || true
  sleep 0.5
  warn "已關閉舊 WakaWaka 進程"
fi

"$BINARY" &>/dev/null &
sleep 0.8

if pgrep -x WakaWaka &>/dev/null; then
  ok "WakaWaka 已啟動 (PID: $(pgrep -x WakaWaka))"
else
  fail "WakaWaka 啟動失敗，請執行 swift build 確認無錯誤"
fi

# ── Step 4: 寫入 Claude Code hooks（並清理舊路徑）───────────
mkdir -p "$HOME/.claude"
[[ -f "$CLAUDE_SETTINGS" ]] || echo '{}' > "$CLAUDE_SETTINGS"

NODE_BIN=$(command -v node 2>/dev/null || echo "node")
HOOKS_DIR="$REPO/cost-aware-approval/hooks"

RESULT=$(python3 - "$CLAUDE_SETTINGS" "$NODE_BIN" "$HOOKS_DIR" <<'PYEOF'
import json, os, sys

path, node_bin, hooks_dir = sys.argv[1], sys.argv[2], sys.argv[3]

# PreToolUse gates every tool call; the other four keep the active-agents panel
# current. Only PreToolUse blocks — the lifecycle hooks write a small file and
# exit, so they cost one short-lived process per session or per turn.
REGISTRATIONS = [
    ("PreToolUse",       "pretooluse.mjs"),
    ("SessionStart",     "sessionstart.mjs"),
    ("UserPromptSubmit", "userpromptsubmit.mjs"),
    ("Stop",             "stop.mjs"),
    ("SessionEnd",       "sessionend.mjs"),
]

# This rewrites the user's whole settings file, so a file we cannot parse is a
# reason to stop, not a reason to start over: `cfg = {}` here would silently
# replace every unrelated Claude setting with WakaWaka's five hooks.
try:
    with open(path) as f:
        cfg = json.load(f)
except FileNotFoundError:
    cfg = {}
except Exception as err:
    print(f"error:{err}")
    sys.exit(0)

if not isinstance(cfg, dict):
    print("error:settings.json is not a JSON object")
    sys.exit(0)

hooks = cfg.setdefault("hooks", {})
if not isinstance(hooks, dict):
    print("error:settings.json 'hooks' is not a JSON object")
    sys.exit(0)

unchanged = True

# Identifies OUR registration by its repo-relative path rather than by the
# script's basename. Names like `stop.mjs` are generic enough that a substring
# match on the basename alone would delete an unrelated third-party hook.
def is_wakawaka(command, script):
    return f"cost-aware-approval/hooks/{script}" in command

for event, script in REGISTRATIONS:
    command = f"{node_bin} {hooks_dir}/{script}"
    entries = hooks.setdefault(event, [])
    if not isinstance(entries, list):
        print(f"error:settings.json hooks.{event} is not a list")
        sys.exit(0)

    if not any(h.get("command") == command
               for entry in entries if isinstance(entry, dict)
               for h in entry.get("hooks", []) if isinstance(h, dict)):
        unchanged = False

    # Strip prior WakaWaka registrations command-by-command so a mixed entry
    # keeps its other hooks, and drop an entry only once it is empty. Matching
    # by path rather than by the full command means a changed node binary
    # cannot leave a stale duplicate behind — for PreToolUse that matters most:
    # two blocking hooks would race on the same decision file and starve one
    # another into a timeout-deny.
    pruned = []
    for entry in entries:
        if not isinstance(entry, dict):
            pruned.append(entry)
            continue
        kept = [h for h in entry.get("hooks", [])
                if not (isinstance(h, dict) and is_wakawaka(h.get("command", ""), script))]
        if len(kept) == len(entry.get("hooks", [])):
            pruned.append(entry)
        elif kept:
            pruned.append({**entry, "hooks": kept})
    entries[:] = pruned
    entries.append({"matcher": "*", "hooks": [{"type": "command", "command": command}]})

# Write to a sibling temp file and rename, so an interrupted write cannot leave
# the user with a truncated settings.json.
tmp = f"{path}.wakawaka.tmp"
with open(tmp, "w") as f:
    json.dump(cfg, f, indent=2, ensure_ascii=False)
    f.write("\n")
os.replace(tmp, path)

print("skip" if unchanged else "done")
PYEOF
)

if [[ "$RESULT" == error:* ]]; then
  warn "Claude Code hooks 未寫入：${RESULT#error:}"
  warn "  → 修好 $CLAUDE_SETTINGS 後重跑，settings.json 未被更動"
elif [[ "$RESULT" == "skip" ]]; then
  ok "Claude Code hooks 已設定（略過）"
else
  ok "Hooks 已寫入 $CLAUDE_SETTINGS（PreToolUse + 4 個 lifecycle）"
  echo "   → node: $NODE_BIN"
fi

# ── 完成 ─────────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " 🎉 WakaWaka 已就緒！"
echo "    開啟 Claude Code，執行任何 Bash 指令"
echo "    即可觸發 menubar 審批視窗。"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
