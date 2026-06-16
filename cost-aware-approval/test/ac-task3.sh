#!/usr/bin/env bash
# AC Test for Task 3 — manual verification script
# Run this AFTER starting the CostNotch app in a separate terminal:
#   cd cost-aware-approval/app/CostNotch && swift run

set -e
STATE_DIR="$HOME/.costnotch/state"
TRANSCRIPT="$HOME/.claude/projects/-Users-wits-TokenGremlin/b477f4b5-d8fe-493b-82cd-9d34f050b4c3.jsonl"

mkdir -p "$STATE_DIR"
rm -f "$STATE_DIR/pending.json" "$STATE_DIR/decision.json"

echo "=== AC Test 1: pending.json 出現 → menu bar 應在 2 秒內更新 ==="
cat > "$STATE_DIR/pending.json" <<'EOF'
{
  "session_id": "ac-test-001",
  "tool_name": "Bash",
  "tool_input": {"command": "rm -rf /"},
  "transcript_path": "TRANSCRIPT_PATH",
  "timestamp": "2026-06-15T00:00:00.000Z"
}
EOF
# Replace TRANSCRIPT_PATH with actual path
sed -i '' "s|TRANSCRIPT_PATH|$TRANSCRIPT|" "$STATE_DIR/pending.json"

echo "  ✅ pending.json 已寫入。請確認 menu bar 圖示變橙色並出現 popover。"
echo "  等待 3 秒..."
sleep 3

echo ""
echo "=== AC Test 2: 模擬 Allow → decision.json 應出現且 hook exit 0 ==="
# Start hook in background (timeout 10s)
POLL_TIMEOUT_MS=10000 bash -c \
  "echo '{\"session_id\":\"ac-test-001\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"ls\"},\"transcript_path\":\"$TRANSCRIPT\"}' \
  | node ../../hooks/pretooluse.mjs" &
HOOK_PID=$!

echo "  Hook PID: $HOOK_PID — 請點擊 Allow 按鈕..."
echo "  等待最多 8 秒..."
for i in $(seq 1 8); do
  sleep 1
  if ! kill -0 $HOOK_PID 2>/dev/null; then
    wait $HOOK_PID
    EXIT_CODE=$?
    if [ "$EXIT_CODE" -eq 0 ]; then
      echo "  ✅ Hook exited 0 (Allow 成功)"
    else
      echo "  ❌ Hook exited $EXIT_CODE"
    fi
    break
  fi
  echo "  ...waiting ($i/8)"
done

echo ""
echo "=== AC Test 3: 重新觸發 Deny 路徑 ==="
cat > "$STATE_DIR/pending.json" <<EOF
{
  "session_id": "ac-test-002",
  "tool_name": "Write",
  "tool_input": {"file_path": "/etc/hosts", "content": "bad"},
  "transcript_path": "$TRANSCRIPT",
  "timestamp": "2026-06-15T00:00:01.000Z"
}
EOF

POLL_TIMEOUT_MS=10000 bash -c \
  "echo '{\"session_id\":\"ac-test-002\",\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"/etc/hosts\"},\"transcript_path\":\"$TRANSCRIPT\"}' \
  | node ../../hooks/pretooluse.mjs" &
HOOK_PID=$!

echo "  Hook PID: $HOOK_PID — 請點擊 Deny 按鈕..."
for i in $(seq 1 8); do
  sleep 1
  if ! kill -0 $HOOK_PID 2>/dev/null; then
    wait $HOOK_PID
    EXIT_CODE=$?
    if [ "$EXIT_CODE" -eq 2 ]; then
      echo "  ✅ Hook exited 2 (Deny 成功)"
    else
      echo "  ❌ Hook exited $EXIT_CODE"
    fi
    break
  fi
  echo "  ...waiting ($i/8)"
done

echo ""
echo "=== 所有 AC 測試完成 ==="
