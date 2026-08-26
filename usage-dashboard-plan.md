# 計劃書：每日 Token 用量儀表板（Usage Dashboard）

> 狀態：**已實作並驗收**（決策見 §10）
> 對象：WakaWaka menu bar app（`cost-aware-approval/app/WakaWaka`）
> 建立：2026-07-24

---

## 摘要

需求：一個彈出視窗，看**每日 token 使用量**與**各 agent 的佔比**。

結論：可行。**本版範圍 = Claude Code + Codex 兩家**，agy 不納入 —— 它沒有任何 token 數據，
只有「剩餘額度 %」且無歷史（詳見 §1）。其餘部分（每日趨勢、agent 佔比、成本估算）資料都齊全，效能實測沒有問題。

---

## 一、資料源盤點（已實測，非推測）

| Agent | 來源 | 有 token 數？ | 粒度 | 歷史深度 |
|-------|------|--------------|------|---------|
| **Claude Code** | `~/.claude/projects/**/*.jsonl` → `message.usage` + `timestamp` | ✅ `input` / `output` / `cache_read` / `cache_creation` | 每則 assistant message | 1,349 檔 / 145 MB，可回溯數月 |
| **Codex** | `~/.codex/sessions/**/*.jsonl` → `payload.info.last_token_usage` | ✅ `input` / `cached_input` / `output` / `reasoning_output` | 每個 `token_count` event | 24 檔 / 830 events，**目前只有 2026-07-23 一天** |
| **agy** | 本地 language server `GetUserStatus`（`AgyQuotaService.swift`） | ❌ **只有 `remainingFraction`** | 即時快照 | **無歷史，無 token** |

實測輸出（Claude Code，近 7 日）：

```
2026-07-21 out=255,902  cacheRead=78,152,110
2026-07-22 out=289,247  cacheRead=37,659,461
2026-07-23 out=180,098  cacheRead=30,702,122
```

實測輸出（Codex，全部歷史）：

```
2026-07-23 input=63,526,839（其中 cached=60,276,480）output=257,876
```

### 三個必須處理的資料陷阱

1. **Claude 需以 `requestId` 去重** —— 同一 request 會在 JSONL 出現多行（含 sidechain），不去重會灌水。
2. **Codex 不能加總 `total_token_usage`** —— 那是 session 累計值，逐筆加總會重複計數。要用 `last_token_usage` 逐 event 加總（實測兩種算法差 ~3%，差異來自 fork/resume session）。
3. **`input_tokens` 語意兩家相反** ——
   - Claude：`input_tokens` **不含** `cache_read_input_tokens`（要相加才是總輸入）
   - Codex：`input_tokens` **已含** `cached_input_tokens`（60.2M / 63.5M 都是 cache）
   直接把兩邊 `input_tokens` 放進同一張圓餅圖 = 錯的。必須先正規化成 `uncachedInput` / `cachedInput` 兩欄。

---

## 二、「佔比」要用什麼分母 —— 已定案：成本 USD 為主

跨 agent 比 raw token **不公平**：cache read 單價約是一般 input 的 1/10，兩家模型單價也不同。
Codex 有 96% 的 input 是 cache，用 raw token 比，Codex 會被嚴重誇大。

| 方案 | 分母 | 優點 | 缺點 |
|------|------|------|------|
| **A（建議）** | 估算成本 USD | 唯一跨 agent 可比的單位；`parser/pricing.json` 已有 Claude 價格 | 需補 Codex 價格表；訂閱制下成本是「等值估算」非實際帳單 |
| B | Raw total tokens | 不需價格表 | 誇大 cache 重的 agent，結論會誤導 |
| C | 各自的額度消耗 % | 最貼近「我還能用多少」 | agy/Codex/Claude 三種窗口長度不同（5h / 7d / 未知），不可直接相加成 100% |

**定案：A —— 主視圖成本 USD，次視圖 token 明細**，用一個 segmented control 切換。C 已經在現有 popover 有了，不重做。

隨之而來的必辦事項：`parser/pricing.json` 需補 Codex 價格區塊（標注抓取日期），否則 Codex 成本恆為 0。

---

## 三、彈出視窗的形式 —— 已定案：獨立 NSWindow

| 方案 | 說明 | 評估 |
|------|------|------|
| **A（建議）獨立 `NSWindow`** | 點按鈕開一個約 720×520 可調整大小的視窗 | 圖表需要空間；不會因失焦自動關閉，可以邊看邊做事；與現有審批 popover 職責分離 |
| B | 現有 popover 內加分頁 | 免新視窗管理成本，但 popover 目前寬約 360pt，且點外面就消失，看趨勢圖很痛苦 |
| C | 兩者都做 | popover 放迷你 sparkline，點擊展開完整視窗。工作量 +30% |

**定案：A**。進入點：popover 底部加一個「📊 用量」按鈕，另外 menu bar icon 右鍵選單也放一個。

---

## 四、技術選型

| 項目 | 選擇 | 理由 |
|------|------|------|
| 聚合邏輯 | 新增 `cost-aware-approval/parser/daily-usage.ts` | `pricing.json` 與 JSONL 解析邏輯已在 TS 端，不重寫第二份 Swift 版本；沿用既有 `ParserRunner` 呼叫模式 |
| 圖表 | SwiftUI `Charts`（`import Charts`） | `Package.swift` 已是 `.macOS(.v14)`，Swift Charts 原生可用，零依賴 |
| 視窗 | `NSWindow` + `NSHostingController` | 與現有 `AppDelegate` 的 popover 管理模式一致 |
| 快取 | `DailyUsageService` 記憶體快取 + 60s TTL | 見下方效能實測 |

### 效能實測（Python 等價實作）

```
全部檔案：1,349 檔 / 145.3 MB
近 14 天過濾後：448 檔 → 聚合耗時 0.69 s
```

→ **不需要落地快取檔**。但 `npx tsx` 冷啟動約 1–2 s（現有 `ParserRunner` 已知成本），
所以視窗開啟時要有 loading 狀態，且結果快取 60 s，不隨 popover 每次刷新重算。

---

## 五、UI 草圖

```
┌──────────────────────────────────────────────────────────┐
│  用量儀表板                    [7天 ▾]  [成本|Token]  ↻  │  ← 期間切換 + 分母切換
├──────────────────────────────────────────────────────────┤
│  今日 $2.41        7 日 $16.80       日均 $2.40          │  ← KPI 列
├──────────────────────────────────────────────────────────┤
│  每日用量（堆疊長條，顏色 = agent）                       │
│   $ ┤        ▄▄                                          │
│     ┤   ▄▄  ████  ▄▄                                     │
│     ┤  ████ ████ ████ ▄▄                                 │
│     └───┴────┴────┴────┴───────                          │
│       7/18 7/19 7/20 7/21                                │
├────────────────────────┬─────────────────────────────────┤
│  Agent 佔比（成本）    │  Token 明細（選定日）            │
│    ● Claude   87%      │   uncached input   1,204,880    │
│    ● Codex    13%      │   cache read      30,702,122    │
│                        │   cache write      1,356,682    │
│                        │   output             180,098    │
├────────────────────────┴─────────────────────────────────┤
│ 成本為估算值，非實際帳單                                  │
└──────────────────────────────────────────────────────────┘
```

狀態：`loading`（parser 執行中）／`empty`（該期間無資料）／`partial`（某 agent 該期間無資料）／`error`（parser 失敗）。

期間預設 **7 天**（可切 7/14/30）—— Codex 目前只有一天資料，30 天預設會是一整排空白長條。

---

## 六、Task 分解

### Task A — `parser/daily-usage.ts`

輸出（stdout JSON）：

```json
{
  "generatedAt": "2026-07-24T09:00:00Z",
  "days": [
    {
      "date": "2026-07-23",
      "agents": {
        "claude-code": {
          "uncachedInput": 9546, "cacheRead": 30702122, "cacheWrite": 1356682,
          "output": 180098, "costUSD": 2.41
        },
        "codex": {
          "uncachedInput": 3250359, "cachedInput": 60276480,
          "output": 257876, "reasoningOutput": 57379, "costUSD": 0.37
        }
      }
    }
  ]
}
```

輸入：`--days <N>`（預設 7）

要求：
- Claude 以 `requestId` 去重；Codex 用 `last_token_usage` 逐 event 加總
- 依 `timestamp` 分日，用**本地時區**（不是 UTC，否則跨半夜的用量會歸錯日）
- 只掃 `mtime` 在期間內的檔案（沿用 `usage-calculator.ts` 的 `scanForJSONL`）
- 任一 agent 目錄不存在 → 該 agent 缺席，**不報錯**
- 補 `pricing.json` 的 Codex 價格區塊（標注抓取日期，沿用現有格式）；缺價格時 `costUSD` 回 `null` 而非 `0`，讓 UI 能區分「沒用」與「不知道多少錢」
- 不掃 agy（本版不納入）

### Task B — `DailyUsageService.swift`

- 呼叫 `ParserRunner` 執行 `daily-usage.ts`（timeout 30s，背景 queue）
- 60 s 記憶體快取；`refresh()` 強制重取
- decode 成 `DailyUsage` model（`Models.swift` 新增，或獨立檔避免 Models 破 300 行 —— 目前已 564 行，**新增請放獨立檔**）

### Task C — `UsageDashboardWindow.swift`

- `NSWindow` 720×520，`.titled/.closable/.resizable`，記憶上次位置
- SwiftUI Charts：`BarMark`（堆疊每日）+ 佔比列表
- 期間切換 7/14/30 天（預設 7）；分母切換 成本/Token（預設成本）
- 四種狀態齊備（loading / empty / partial / error）

### Task D — 進入點

- `ContentView` 底部列加「📊 用量」按鈕 → `AppDelegate.showUsageDashboard()`
- menu bar icon 右鍵選單同一入口
- 開啟時 `NSApp.activate(ignoringOtherApps:)`，確保視窗到前景

### Task E — 測試

- `Tests/WakaWakaTests/DailyUsageTests.swift`：JSON decode、缺 agent、空期間
- `parser/daily-usage.test.ts`：requestId 去重、Codex 不重複計數、跨日邊界、時區分日

---

## 七、驗收條件

1. 點「📊 用量」開啟獨立視窗，2 s 內顯示（或顯示 loading）
2. 每日長條圖與 `python3` 手算結果一致（誤差 0，去重後）
3. Codex 只有一天資料時，其他日期顯示 0 而非空白或崩潰
4. Codex 價格表未補齊時顯示「—」而非 $0（$0 會誤導成「沒花錢」）
5. 關閉視窗後 app 不退出（`NSApplication` 是 accessory 模式）
6. `swift build` 通過、既有測試不退步

---

## 八、風險與已知限制

| 風險 | 影響 | 處置 |
|------|------|------|
| agy 無 token 數據 | 「多 agent 佔比」實際只有 2 家 | 本版不納入 agy。日後若要補，需新增每日快照記錄器，**只能從啟用日開始累積**，且單位（額度 %）與 token/成本不可比 |
| 成本是估算非帳單 | 訂閱制下數字不等於實付 | 標題標注「估算」，與現有 `estimatedCostUSD` 口徑一致 |
| Codex 價格表要手動維護 | 價格變動後數字失真 | `pricing.json` 標注抓取日期（沿用現有慣例） |
| `npx tsx` 冷啟動 1–2 s | 首開有延遲 | loading 狀態 + 60 s 快取；若不可接受，改為 app 啟動時預熱一次 |
| Claude JSONL 格式變動 | 解析失效 | parser 對缺欄位採 `?? 0`，不 throw；已有測試守著 |
| 掃描檔案數持續成長 | 未來變慢 | 目前 448 檔 / 0.69 s，離痛點還遠；超過 3 s 再引入落地快取 |

---

## 九、明確不做

- 不做跨機器同步／上傳
- **不納入 agy**（本版決策；歷史 token 也不存在，回補做不到）
- 不改動現有 5h 窗口配額邏輯（`usage-calculator.ts` 不動）
- 不做匯出 CSV / 報表（有需要再開新任務）

---

## 十、已定案決策（2026-07-24）

| # | 決策 | 選擇 |
|---|------|------|
| 1 | 佔比分母 | **成本 USD 為主**，token 明細為次視圖（segmented control 切換） |
| 2 | 視窗形式 | **獨立 `NSWindow`** 720×520，可調整大小 |
| 3 | agy | **本版不納入**（無 token 數據、無歷史） |
| 4 | 預設期間 | **7 天**（可切 7/14/30）—— Codex 目前僅一天資料，30 天預設會大片空白 |

實作順序：Task A → B → C → D → E。A 完成後可先用 `npx tsx` 手動驗證數字，再進 Swift 端。
