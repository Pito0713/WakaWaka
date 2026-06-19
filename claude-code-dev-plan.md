# Claude Code 開發流程計劃書：Cost-Aware Approval MVP

## 摘要
本文件是給 Claude Code 執行開發用的工作指引，對應 v2 計劃的 Phase 1-3（MVP）。三個子系統各自獨立、低耦合，建議**依序**請 Claude Code 開發並驗收，不要一次性丟整個計劃，避免單次任務範圍過大導致品質下降。

---

## 專案結構

```
cost-aware-approval/
├── hooks/
│   └── pretooluse.mjs        # Task 1：hook script
├── parser/
│   ├── usage-calculator.ts   # Task 2：token 用量計算
│   └── pricing.json          # 價格表（手動維護，標注日期）
├── app/
│   └── WakaWaka/             # Task 3：SwiftUI MenuBarExtra app
├── state/
│   └── (執行時產生，不進 git)
│       ├── pending.json       # hook 寫入，等待審核
│       └── decision.json      # app 寫入，hook 讀取
└── README.md
```

## 技術選型（已定案，不要讓 Claude Code 重新討論）
- Hook script：Node.js（`.mjs`），跨平台路徑用 `os.homedir()`、`os.tmpdir()`，避免 shell-specific 指令
- Parser：TypeScript，編譯成 Node 可執行（與 hook 共用 Node runtime）
- UI：Swift + SwiftUI `MenuBarExtra`，macOS 14+
- 通訊機制：檔案輪詢（不做 socket），路徑統一放在 `~/.wakawaka/state/`

---

## Task 1：PreToolUse Hook Script

### 目標
Claude Code 觸發 PreToolUse 時，把當前 session 資訊寫入 `~/.wakawaka/state/pending.json`，然後等待 `decision.json` 出現，依內容 exit 0（允許）或 exit 2（拒絕）。

### 給 Claude Code 的任務描述
```
請在 hooks/pretooluse.mjs 實作一個 Claude Code PreToolUse hook：

1. 從 stdin 讀取 JSON（包含 session_id, transcript_path, tool_name, tool_input 等欄位）
2. 將以下內容寫入 ~/.wakawaka/state/pending.json：
   { "session_id": ..., "tool_name": ..., "tool_input": ..., "transcript_path": ..., "timestamp": <now> }
3. 輪詢（每 200ms，最多等待 30 秒）~/.wakawaka/state/decision.json 是否出現
4. 若 decision.json 內容為 { "decision": "allow" }：刪除該檔案，exit 0
5. 若為 { "decision": "deny", "reason": "..." }：將 reason 寫入 stderr，刪除該檔案，exit 2
6. 若 30 秒內未出現 decision.json（app 未運行的 fallback）：直接 exit 1（中性結果，
   讓 Claude Code 退回原生 permission 流程，不要 exit 0 或 2）
7. 所有檔案操作需 try-catch，錯誤時 fallback 行為同上一點（exit 1）
```

### Acceptance Criteria
- 手動測試：`echo '{"session_id":"test","tool_name":"Bash","tool_input":{"command":"ls"}}' | node hooks/pretooluse.mjs` 在沒有任何 app 運行時，30 秒後 exit code 為 1
- 手動建立 `decision.json` 內容為 `{"decision":"allow"}`，重跑上述指令應立即 exit 0
- 寫一個最小單元測試覆蓋上述三種 exit code 情境

---

## Task 2：Token 用量計算

### 目標
讀取 `transcript_path`（JSONL），計算該 session 累積 tokens 與「上一輪增量」，輸出給 UI 使用。

### 給 Claude Code 的任務描述
```
請在 parser/usage-calculator.ts 實作：

1. 函式 calculateUsage(transcriptPath: string): UsageSnapshot
   - 逐行讀取 JSONL，找出所有帶 usage 欄位的 message
   - 累加 input_tokens、output_tokens、cache_creation_input_tokens、
     cache_read_input_tokens（先用 console.log 印出一筆真實 message 的
     usage 結構讓我確認欄位名稱是否正確，因為這是非公開格式）
   - 回傳結構：
     {
       cumulativeInput: number,
       cumulativeOutput: number,
       cumulativeCacheRead: number,
       cumulativeCacheCreation: number,
       lastTurnDelta: { input: number, output: number } | null
     }

2. lastTurnDelta 計算方式：比較最後兩個有 usage 的 message 的累積值差異

3. 函式 estimateCost(usage: UsageSnapshot, pricing: PricingTable): number
   - 讀取 parser/pricing.json
   - 回傳估算費用（USD）

4. parser/pricing.json 格式：
   {
     "_date": "2026-06-13",
     "_note": "手動維護，需定期更新",
     "model": "claude-sonnet-4-6",
     "inputPerMTok": 3.0,
     "outputPerMTok": 15.0,
     "cacheReadPerMTok": 0.3,
     "cacheCreationPerMTok": 3.75
   }
   （請先用搜尋確認 Sonnet 4.6 當前實際價格，不要直接用我給的範例數字）

5. 主程式：接受 transcriptPath 作為 command line 參數，輸出上述結構為 JSON 到 stdout，
   供 Task 3 的 app 呼叫
```

### Acceptance Criteria
- 用一個真實的 Claude Code session JSONL 檔案測試，輸出的 cumulativeInput/Output 數字與你自己用 `jq` 手動加總的結果一致（誤差為 0）
- pricing.json 的價格數字需附上來源連結與查證日期（寫在 `_note` 欄位）
- 單元測試：用一個 fixture JSONL（手動構造 3-4 筆 message）驗證 lastTurnDelta 計算正確

---

## Task 3：MenuBarExtra UI

### 目標
輪詢 `pending.json`，有內容時顯示 popover 含用量資訊與 Allow/Deny 按鈕；點擊後寫入 `decision.json`。

### 給 Claude Code 的任務描述
```
請建立一個 SwiftUI macOS app（MenuBarExtra），位於 app/WakaWaka/：

1. 每 1 秒輪詢 ~/.wakawaka/state/pending.json
2. 若檔案存在：
   - 呼叫 Task 2 的 parser（用 Process 執行 node parser/usage-calculator.ts
     <transcript_path>，解析 stdout 的 JSON）
   - MenuBarExtra 圖示顯示提示狀態（例如變色或加 badge）
   - popover 顯示：
     - tool_name 與 tool_input 摘要
     - "目前累積用量：input X / output Y / cache Z tokens"
     - "上一輪增量：約 N tokens（僅供參考，非本次預估）"
     - "估算費用：$X.XX（依 2026-06-13 價格表）"
     - Allow / Deny 兩個按鈕
3. 點擊 Allow：寫入 decision.json = {"decision":"allow"}
   點擊 Deny：寫入 decision.json = {"decision":"deny","reason":"User denied"}
4. 若 pending.json 不存在：MenuBarExtra 顯示正常狀態（無 pending）

不需要做動畫、不需要做精緻排版，純功能驗證即可。
```

### Acceptance Criteria
- pending.json 出現後 2 秒內，menu bar 圖示與 popover 內容更新
- 點擊按鈕後 decision.json 正確寫入，且 pending.json 對應的 hook process（Task 1）能正確 exit

---

## 整合測試（三個 Task 都完成後）

```
請寫一個整合測試腳本 test/integration.sh：

1. 啟動 WakaWaka app（背景執行）
2. 模擬呼叫 hooks/pretooluse.mjs（用真實或 fixture 的 session 資料）
3. 確認 pending.json 正確產生
4. 手動或腳本模擬點擊 Allow，確認 hook process 在 2 秒內 exit 0
5. 重複測試 Deny 路徑
6. 測試「app 未啟動」情境：不啟動 app，確認 hook 在 30 秒後 exit 1
```

---

## 給 Claude Code 的整體提醒（建議寫在專案根目錄 CLAUDE.md）
- JSONL 的 usage 欄位結構是**非公開格式**，實作前先印出真實資料確認欄位名稱，不要憑記憶假設
- pricing.json 的價格資訊**容易過時**，需主動搜尋查證並標注日期來源
- hook 的 fallback（exit 1）行為是安全機制核心，任何例外路徑都必須 fallback 到 exit 1，不可預設 exit 0 或 2
- 每個 Task 完成後先跑 Acceptance Criteria，確認通過才進下一個 Task

---

## Next Steps
1. 把本文件交給 Claude Code，逐個 Task 執行（建議用 `/clear` 或新 session 切分，避免 context 過長影響品質）
2. Task 1 完成並通過 AC 後才開始 Task 2
3. 三個 Task 都完成後執行整合測試
