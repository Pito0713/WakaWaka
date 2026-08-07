#!/usr/bin/env bash
# WakaWaka 一鍵啟動腳本
# Usage: ./start.sh [--build]
#   --build / -b   強制重新 swift build

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
if [[ ! -f "$BINARY" || "$FORCE_BUILD" == true ]]; then
  echo "🔨 Building WakaWaka..."
  (cd "$APP_DIR" && swift build) || fail "swift build 失敗，請確認已安裝 Xcode Command Line Tools"
  ok "Build 完成"
else
  ok "Binary 已存在（加 --build 可強制重新 build）"
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

# ── Step 4: 寫入 Claude Code hook（並清理舊路徑）────────────
mkdir -p "$HOME/.claude"
[[ -f "$CLAUDE_SETTINGS" ]] || echo '{}' > "$CLAUDE_SETTINGS"

NODE_BIN=$(command -v node 2>/dev/null || echo "node")
HOOK_CMD="$NODE_BIN $HOOK"

RESULT=$(python3 - "$CLAUDE_SETTINGS" "$HOOK_CMD" <<'PYEOF'
import json, sys

path, hook_cmd = sys.argv[1], sys.argv[2]
try:
    with open(path) as f:
        cfg = json.load(f)
except Exception:
    cfg = {}

pre = cfg.setdefault("hooks", {}).setdefault("PreToolUse", [])

# Drop any prior WakaWaka registration (matched by the hook SCRIPT path, not the
# full command) so a changed node binary path can't leave a stale duplicate
# entry. Two blocking hooks would race on the same decision file and starve one
# another into a timeout-deny.
def is_wakawaka(entry):
    return any("pretooluse.mjs" in h.get("command", "") for h in entry.get("hooks", []))

already = any(
    h.get("command") == hook_cmd
    for entry in pre for h in entry.get("hooks", [])
)
pre[:] = [entry for entry in pre if not is_wakawaka(entry)]
pre.append({"matcher": "*", "hooks": [{"type": "command", "command": hook_cmd}]})

with open(path, "w") as f:
    json.dump(cfg, f, indent=2, ensure_ascii=False)
    f.write("\n")

print("skip" if already else "done")
PYEOF
)

if [[ "$RESULT" == "skip" ]]; then
  ok "Claude Code hook 已設定（略過）"
else
  ok "Hook 已寫入 $CLAUDE_SETTINGS"
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
