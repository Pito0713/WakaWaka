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

# ── Step 2: 重啟 WakaWaka ────────────────────────────────────
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

# ── Step 3: 寫入 Claude Code hook（並清理舊路徑）────────────
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

for entry in pre:
    for h in entry.get("hooks", []):
        if h.get("command") == hook_cmd:
            print("skip")
            sys.exit(0)

pre.append({"matcher": "*", "hooks": [{"type": "command", "command": hook_cmd}]})

with open(path, "w") as f:
    json.dump(cfg, f, indent=2, ensure_ascii=False)
    f.write("\n")

print("done")
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
