#!/usr/bin/env bash
# Integration test: Cost-Aware Approval MVP
# Tests the full hook ↔ state file ↔ decision loop end-to-end.

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$REPO_ROOT/hooks/pretooluse.mjs"
BINARY="$REPO_ROOT/app/CostNotch/.build/debug/CostNotch"
STATE_DIR="$HOME/.costnotch/state"
PENDING="$STATE_DIR/pending.json"
DECISION="$STATE_DIR/decision.json"
TRANSCRIPT="$HOME/.claude/projects/-Users-wits-TokenGremlin/b477f4b5-d8fe-493b-82cd-9d34f050b4c3.jsonl"
APP_PID=""

GREEN='\033[0;32m'; RED='\033[0;31m'; RESET='\033[0m'
PASS=0; FAIL=0

pass() { echo -e "${GREEN}  ✅ PASS${RESET}: $1"; PASS=$((PASS + 1)); }
fail() { echo -e "${RED}  ❌ FAIL${RESET}: $1"; FAIL=$((FAIL + 1)); }

cleanup_state() { rm -f "$PENDING" "$DECISION"; }

kill_app() {
  [[ -n "$APP_PID" ]] && kill "$APP_PID" 2>/dev/null || true
  [[ -n "$APP_PID" ]] && wait "$APP_PID" 2>/dev/null || true
  APP_PID=""
}

trap 'cleanup_state; kill_app' EXIT

# Wait for file to appear (poll every 200ms, up to max_secs)
wait_for_file() {
  local file="$1" max_secs="${2:-3}"
  local attempts=$(( max_secs * 5 ))
  for (( i=0; i<attempts; i++ )); do
    [[ -f "$file" ]] && return 0
    sleep 0.2
  done
  return 1
}

NODE="/Users/wits/.nvm/versions/node/v20.14.0/bin/node"

# Start hook in background; sets global HOOK_PID to the node PID directly.
# Using <<< avoids a bash wrapper so kill/wait operate on node itself.
start_hook() {
  local timeout_ms="${1:-5000}" stderr_file="${2:-/dev/null}"
  local input="{\"session_id\":\"integ\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"ls\"},\"transcript_path\":\"$TRANSCRIPT\"}"
  POLL_TIMEOUT_MS="$timeout_ms" "$NODE" "$HOOK" <<< "$input" 2>"$stderr_file" &
  HOOK_PID=$!
}

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════════"
echo "  Cost-Aware Approval — Integration Test Suite"
echo "═══════════════════════════════════════════════════════"
echo ""

# ── Pre-flight ───────────────────────────────────────────────────────────────
echo "── Pre-flight ──────────────────────────────────────────"
[[ -f "$HOOK" ]]   && pass "hook script exists"     || { fail "hook missing: $HOOK"; exit 1; }
[[ -f "$BINARY" ]] && pass "CostNotch binary exists" || { fail "binary missing — run: swift build"; exit 1; }
[[ -f "$TRANSCRIPT" ]] && pass "transcript JSONL found" || fail "no transcript — usage display unavailable"
mkdir -p "$STATE_DIR"
cleanup_state
echo ""

# ═══════════════════════════════════════════════════════════
# TEST 1 — hook writes pending.json (no app needed)
# ═══════════════════════════════════════════════════════════
echo "── Test 1: hook writes pending.json ───────────────────"
cleanup_state

start_hook 5000
# Give Node.js time to start and write pending.json (cold start can take 1-2s)
if wait_for_file "$PENDING" 3; then
  TOOL=$(python3 -c "import json; d=json.load(open('$PENDING')); print(d.get('tool_name','?'))" 2>/dev/null || echo "?")
  SESS=$(python3 -c "import json; d=json.load(open('$PENDING')); print(d.get('session_id','?'))" 2>/dev/null || echo "?")
  TS=$(python3   -c "import json; d=json.load(open('$PENDING')); print(d.get('timestamp',''))"  2>/dev/null || echo "")
  [[ "$TOOL" == "Bash" ]]  && pass "tool_name correct ($TOOL)"    || fail "tool_name wrong: got $TOOL"
  [[ "$SESS" == "integ" ]] && pass "session_id correct ($SESS)"   || fail "session_id wrong: got $SESS"
  [[ -n "$TS" ]]           && pass "timestamp present"            || fail "timestamp missing"
else
  fail "pending.json not written within 3s"
fi
# Let hook time out on its own (5s), or kill it
sleep 0.2
kill "$HOOK_PID" 2>/dev/null || true
wait "$HOOK_PID" 2>/dev/null || true
cleanup_state
echo ""

# ═══════════════════════════════════════════════════════════
# TEST 2 — Allow: hook exits 0
# ═══════════════════════════════════════════════════════════
echo "── Test 2: Allow → hook exits 0 ───────────────────────"
cleanup_state

start_hook 8000
if wait_for_file "$PENDING" 3; then
  echo '{"decision":"allow"}' > "$DECISION"
  wait "$HOOK_PID" 2>/dev/null; CODE=$?
  [[ $CODE -eq 0 ]] && pass "hook exited 0 (allow)"              || fail "hook exited $CODE (expected 0)"
  [[ ! -f "$DECISION" ]] && pass "decision.json removed by hook" || fail "decision.json still present"
else
  fail "pending.json not written within 3s"
  kill "$HOOK_PID" 2>/dev/null || true; wait "$HOOK_PID" 2>/dev/null || true
fi
cleanup_state
echo ""

# ═══════════════════════════════════════════════════════════
# TEST 3 — Deny: hook exits 2 + reason on stderr
# ═══════════════════════════════════════════════════════════
echo "── Test 3: Deny → hook exits 2 + reason on stderr ─────"
cleanup_state

STDERR_TMP=$(mktemp)
start_hook 8000 "$STDERR_TMP"
if wait_for_file "$PENDING" 3; then
  echo '{"decision":"deny","reason":"User denied via integration test"}' > "$DECISION"
  wait "$HOOK_PID" 2>/dev/null; CODE=$?
  REASON=$(cat "$STDERR_TMP")
  [[ $CODE -eq 2 ]]   && pass "hook exited 2 (deny)"            || fail "hook exited $CODE (expected 2)"
  [[ "$REASON" == "User denied via integration test" ]] \
                       && pass "deny reason on stderr correct"   || fail "stderr wrong: \"$REASON\""
  [[ ! -f "$DECISION" ]] && pass "decision.json removed by hook" || fail "decision.json still present"
else
  fail "pending.json not written within 3s"
  kill "$HOOK_PID" 2>/dev/null || true; wait "$HOOK_PID" 2>/dev/null || true
fi
rm -f "$STDERR_TMP"
cleanup_state
echo ""

# ═══════════════════════════════════════════════════════════
# TEST 4 — App NOT running: hook exits 1 after timeout
# ═══════════════════════════════════════════════════════════
echo "── Test 4: no app → hook exits 1 after 2s timeout ─────"
cleanup_state
kill_app  # ensure no app running

START=$SECONDS
start_hook 2000
wait "$HOOK_PID" 2>/dev/null; CODE=$?
ELAPSED=$(( SECONDS - START ))

[[ $CODE -eq 1 ]] && pass "hook exited 1 (fallback)"    || fail "hook exited $CODE (expected 1)"
[[ $ELAPSED -ge 1 ]] && pass "hook waited ≥1s (${ELAPSED}s)" || fail "hook returned too fast (${ELAPSED}s)"
cleanup_state
echo ""

# ═══════════════════════════════════════════════════════════
# TEST 5 — End-to-end with CostNotch app running
# ═══════════════════════════════════════════════════════════
echo "── Test 5: end-to-end with CostNotch app ───────────────"
cleanup_state

"$BINARY" &>/tmp/costnotch-integ.log &
APP_PID=$!
echo "  CostNotch PID: $APP_PID — waiting 2s for startup…"
sleep 2

if ! kill -0 "$APP_PID" 2>/dev/null; then
  fail "CostNotch failed to start (see /tmp/costnotch-integ.log)"
else
  pass "CostNotch app started"

  # Write pending.json — app polls every 1s, should pick up within 2s
  python3 - <<PYEOF
import json, os, datetime
state = os.path.expanduser("~/.costnotch/state")
os.makedirs(state, exist_ok=True)
with open(os.path.join(state, "pending.json"), "w") as f:
    json.dump({
        "session_id": "integ-t5",
        "tool_name": "Bash",
        "tool_input": {"command": "echo hello"},
        "transcript_path": "$TRANSCRIPT",
        "timestamp": datetime.datetime.utcnow().isoformat() + "Z"
    }, f)
PYEOF

  sleep 2  # give app time to detect pending.json and show popover

  # Now run hook — app should write decision.json when user clicks Allow
  # In test, we simulate the click immediately
  start_hook 8000
  if wait_for_file "$PENDING" 3; then
    # Simulate app clicking Allow
    echo '{"decision":"allow"}' > "$DECISION"
    wait "$HOOK_PID" 2>/dev/null; CODE=$?
    [[ $CODE -eq 0 ]] && pass "end-to-end allow: hook exited 0" || fail "hook exited $CODE"
  else
    fail "pending.json not detected within 3s"
    kill "$HOOK_PID" 2>/dev/null || true; wait "$HOOK_PID" 2>/dev/null || true
  fi
fi

kill_app
cleanup_state
echo ""

# ─────────────────────────────────────────────────────────────────────────────
TOTAL=$((PASS + FAIL))
echo "═══════════════════════════════════════════════════════"
echo "  Results: ${PASS}/${TOTAL} passed"
if [[ $FAIL -eq 0 ]]; then
  echo -e "  ${GREEN}All tests PASSED ✅${RESET}"
  exit 0
else
  echo -e "  ${RED}${FAIL} test(s) FAILED ❌${RESET}"
  exit 1
fi
