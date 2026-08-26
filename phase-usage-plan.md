# 計劃書：Token 活動分佈報表（Phase Usage）

> 狀態：**v2 — 已實作並驗收**
> 對象：WakaWaka 用量儀表板（`cost-aware-approval/app/WakaWaka` + `cost-aware-approval/parser`）
> 建立 2026-08-08 ｜ v2 修訂 2026-08-08 ｜ 範圍拍板與執行指南 2026-08-10

---

## v2 修訂摘要

v1 送 Codex 獨立對抗式評估，回收 10 條（4 BLOCKER / 5 HIGH / 1 MEDIUM）。
每一條關鍵證據我都自己重跑驗證。

| # | Codex 指出 | 我的驗證 | 處置 |
|---|-----------|---------|------|
| 1 | 「每筆帶同一份 usage 副本」是錯的，streaming 會增長 | **成立**：近 14 天 3,567 個 requestId 有 50 個（1.4%）usage 遞增，如 `[7,7,7,7,529]`。取第一筆會低估 52,126 output（1.62%），單筆最多 7,417 | ✅ 全採納，見 §1 |
| 2 | 四桶不守恆，UI 範例只加到 88.7% | **成立**，我把六桶原型數字直接填進四桶 UI 範例 | ✅ 全採納，已重算，**且重算揭露更大的問題**，見 §2 |
| 3 | prompt 切分會把系統通知當人類 prompt | **成立**：947 筆通過我規則的記錄中，15 筆是 `<task-notification>`、271 筆 `promptSource: sdk` | ✅ 採納，但我補一個它沒講的覆蓋率問題，見 §5 |
| 4 | compact / resume / sidechain 讓 prompt 歸屬未封閉，建議延後 prompt 粒度 | 成立，我另補一項：`origin` 缺失率 82% | ✅ **已採納：v1 只做 session 粒度**，見 §10-1 |
| 5 | sidechain 應是正交維度不是第五桶 | 架構上成立，但**量級被高估**：實測 63 calls、output 1.77%、跨檔重複 `(requestId,msgId)` **0 筆** | ⚠️ 採納模型、下修優先級 |
| 6 | output token 不能叫「費工」 | 成立 | ✅ 全採納，改用「活動分佈」並列三指標 |
| 7 | 分類優先序會把混合 action 全塞單一階段 | 方向成立，**量級被高估**：混合工具只佔 **1.8%**（64/3,580） | ⚠️ 保留診斷欄，駁回 `mixed` 桶 |
| 8 | Bash 前綴分類會大量誤判，`npm run` 不能算 verify | **成立且我有更硬的證據**：64 筆未分類 bash 中 **60 筆以 `cd` 開頭** | ✅ 全採納，shell chain 解析改列必要 |
| 9 | 58% 模型不符成立，但「不符 = 成本必錯」需分開論證 | 成立 | ✅ 採納，逐模型定價，價格需查官方來源 |
| 10 | KPI 警語太弱，UI 本身鼓勵排名式解讀 | 成立 | ✅ 全採納 |

### 我在驗證過程中發現的兩件事（雙方都沒抓到）

**A. 既有 codebase 早就解決了我「發現」的那個坑。**
`usage-calculator.ts:82` 的去重鍵就是 `` `${requestId}|${message.id}` ``，註解明寫
「keeps the LAST occurrence (latest state of a streaming response is the most complete)」，
`daily-usage.test.ts` 還有一條測試叫 `same requestId|msgId deduped, last-write-wins (streaming)`，
用的正是 100 → 150 → 200。我 v1 說「不能直接照抄 usage-calculator」是**錯的**：
去重鍵與 last-write-wins **必須照抄**，只有 content 聯集是新的。

**B. 我 v1 的範例數字往好看的方向錯了。**
v1 表格的 `understand 21.1%` 是用寬鬆 substring 比對灌出來的（`'ls' in command` 會命中
`tools`、`false` 之類的字）。改成嚴格 `startswith` 後只剩 **2.7%**。見 §2。

---

## 一、歸因單位：`(requestId, message.id)` + last-write-wins + content 聯集

一次 API 回應會被拆成多筆 assistant 記錄（`thinking` / `text` / `tool_use`）。
實測單一 session 的 252 個 requestId：1 筆 → 97 個、2 筆 → 105 個、3 筆 → 50 個。

**多數情況每筆帶相同的 usage 副本，但不是全部。** 近 14 天全量：

```
usage 全同的 requestId：3,517
usage 遞增的 requestId：   50  (1.4%)   ← streaming 部分狀態
實例：output = [7, 7, 7, 7, 529] / [6, 6, 6, 866] / [3, 3, 3, 1588]
取第一筆 vs 取最後一筆：低估 52,126 output（1.62%），單筆最大低估 7,417
```

那 50 筆全部出現在 `agent-*` 的 subagent transcript 中。

**規格（三件事都要做）**：

1. 去重鍵 = `(requestId, message.id)` —— 目前資料每個 requestId 只對應一個 message.id，
   但兩者不可視為永久等價
2. usage 取**依 timestamp / 檔案順序的最後一筆**（不是第一筆、不是 max、不是加總）
   —— 不用 max 是因為各 usage 欄位未必單調
3. content 取**同鍵所有記錄的聯集**後才分類

第 1、2 點直接重用 `usage-calculator.ts` 既有實作；第 3 點是本功能新增。
缺 `requestId`/`message.id` 的記錄沿用既有的 sentinel key 處理，不得被誤併。

---

## 二、四桶必須守恆 —— 而守恆之後暴露了分類法本身的問題

v1 的 UI 範例直接沿用六桶原型數字，前四桶只加到 88.7%。用**嚴格分類 + 正確去重鍵**重算同一個
session（253 個 keyed calls）：

```
phase         calls    output    out%
understand       15     4,333    2.7%
develop          62    70,653   44.5%
verify           51    17,815   11.2%
other           125    66,002   41.6%
合計            253   158,803  100.0%   ← 守恆
```

**`other` 佔 41.6%，`understand` 只剩 2.7%。這份報表在這個狀態下是廢的。**

拆開 `other`：

| 組成 | calls | output | 佔全體 |
|------|------|--------|-------|
| Bash 未分類 | 64 | 32,869 | **20.7%** |
| MCP / 其他工具 | 54 | 18,510 | 11.7% |
| 純文字回覆（無工具呼叫） | 8 | 14,810 | 9.3% |

而那 64 筆未分類 Bash 裡，**60 筆的第一個 token 是 `cd`**（`cd app && npm test` 這種複合指令），
其餘是 `curl` 3 筆、`python3` 1 筆。

**結論：四桶模型要能用，下列三件事都是必要條件、不是加分項**：

1. **shell chain 解析**（§4.2）—— 可回收 20.7%
2. **MCP 工具 mapping**（§4.3）—— 可回收 11.7%
3. **獨立的「回覆」桶**（§4.1）—— 9.3% 的純文字回覆不應與未分類混在一起

這是 v1 沒有認清的範圍。做不到這三件，就只會得到一個 40% 是「其他」的圖表。

---

## 三、指標：三個並列，不選單一「主指標」

v1 主張「主指標用 output token」並從中推導「develop 是 understand 的兩倍費工」。
**後半段不成立** —— output token 同時包含 thinking、tool call JSON 與參數長度、patch 文字量、
回覆冗長度、以及不同模型的輸出習慣。它衡量的是**生成量**，不是時間、認知負荷或工作完成度。

另一方面，v1 說 cache read「跟做了什麼無關」也**過度簡化** —— 它是真實的推論成本。

**改為並列三個觀測，不宣稱哪個是真理**：

| 指標 | 語義 |
|------|------|
| `calls` | 互動次數 —— 這個階段來回了幾次 |
| `output` | 生成量 —— 模型為此產出多少 token |
| `costUSD` | 資源成本 —— 實際帳單意義上的花費 |

實測的偏差證據仍保留在 UI 註記：cache read 使後期階段系統性偏貴
（verify 每次呼叫平均讀 259K，understand 157K），
差距主因是驗證通常發生在 session 後段、context 已大。

`activeTokens = uncachedInput + output` 列為實驗欄位，但明標「非 effort 指標」。

---

## 四、分類法（v2 修訂）

### 4.1 五桶（v1 的四桶 + 回覆）

| 桶 | 判定 |
|----|------|
| **理解** understand | `Read`/`Grep`/`Glob`/`LS`/`WebFetch`/`WebSearch`/`NotebookRead`/`Task`/`Agent`；或 Bash 經 §4.2 判定為唯讀 |
| **開發** develop | `Edit`/`Write`/`MultiEdit`/`NotebookEdit`/`apply_patch` |
| **驗證** verify | Bash 經 §4.2 判定為測試／建置／檢查 |
| **回覆** reply | **無任何 tool_use 的回應**（純思考／文字回覆），實測 9.3% |
| **其他** other | 其餘：未 mapping 的 MCP、無法判定的 Bash、未知工具 |

優先序 `develop > verify > understand > other`，`reply` 僅在完全無工具時適用。

**混合工具的處置**：實測混合只佔 **1.8%**（64/3,580，最大宗是 `bash+understand` 52 筆）。
Codex 建議新增 `mixed` 桶或改用「最後一個工具決定」——**駁回**：1.8% 的量不值得讓所有使用者
面對一個看不懂的第六桶，且優先序比「最後一個工具」更可預測。
改為輸出 `mixedCalls` 診斷欄位（含工具組合與次數），讓比例若日後上升時可被發現。

### 4.2 Bash 需要 shell chain 解析（v1 的前綴比對不可行）

證據見 §2：64 筆未分類中 60 筆以 `cd` 開頭。v1 的「取指令首字」對複合指令完全失效。

規格：

- 依 `&&` / `||` / `;` / `|` 切成 segment，逐段判定，取**最高優先序**的結果
- 剝除前綴雜訊：`cd <path> &&`、`env X=Y`、`sudo`、`time`、`npx`、`pnpm exec`、`npm exec`
- **`npm run` / `make` / `cargo` / `gradlew` 不得單獨作為 verify 前綴** ——
  必須匹配到 script/target 名（`npm run test*` 是驗證，`npm run dev` 不是）
- 判不出來 → `other`，**寧可誠實不分類，不要假精確**
- 每筆輸出 `classificationReason`（命中哪條規則），供抽樣稽核
- 未分類 Bash 比照 `unclassifiedTools` 列成 `unknownBash`（首 token + 次數 + output）

### 4.3 MCP 工具 mapping

實測 MCP 佔 11.7%，全是 `mcp__claude-in-chrome__*`。在那個 session 裡它其實是驗證
（開瀏覽器測 UI），但工具名無從得知。

- 內建一份 **versioned** 預設 mapping（`parser/tool-phases.json`），本版先只填
  `mcp__claude-in-chrome__*` → other，不臆測
- 輸出 `unclassifiedTools`（名稱 + calls + output）與 `unknownRate`
- 使用者自訂 mapping 檔延後，但格式先定，避免日後破壞相容

---

## 五、prompt 邊界（**v1 不實作，本節為 v2 預備研究**）

> **範圍決策（已拍板）**：v1 只做 **session 粒度**。本節的調查結果保留，
> 因為 v2 要做 prompt 粒度時會需要，且它同時解釋了「為什麼 v1 不做」。
> 相關測試（§11-13～16）一併留到 v2。

Codex 指出 `type == "user"` 不等於人類 prompt。實測近 14 天，通過 v1 §5 規則的 947 筆記錄：

```
promptSource:  typed 148 | sdk 271 | system 13 | queued 2 | suggestion_accepted 4 | (缺) 509
origin.kind:   human 153 | task-notification 15 | (缺) 779
其中含 <task-notification> 內文：15 筆
```

那 15 筆 task-notification 會建立假的 prompt 區段。**成立。**

**但 Codex 沒講到的問題：`origin` 缺失率 779/947 = 82%，`promptSource` 缺失率 54%。**
若照它建議「優先使用 `origin.kind == human`」當硬性條件，會把 82% 的歷史資料判成非人類，
報表直接空掉。

**規格（分層判定 + 標記可信度）**：

1. 有 `origin.kind` → 只接受 `human`，明確排除 `task-notification` / `coordinator`
2. 無 `origin` 但有 `promptSource` → 白名單 `typed` / `queued` / `suggestion_accepted`；
   排除 `system`；**`sdk` 單獨決策**（271 筆，多為 subagent 委派）
3. 兩者皆無（舊格式）→ 退回 v1 的 heuristic（排除 `tool_result` / `isMeta` /
   `isCompactSummary` / `isVisibleInTranscriptOnly`），並標
   `promptBoundaryConfidence: "inferred"`
4. UI 對 inferred 區段加註記

---

## 六、sidechain：正交維度，但量級不大

Codex 主張 sidechain 應是 `direct` / `sidechain` 的正交維度而非第五桶 —— **架構上正確**，
subagent 內部同樣有理解／開發／驗證，做成一個桶會丟失內部結構。

但實測量級被高估：

```
sidechain: 63 calls, output 56,933 / 總 3,221,811 = 1.77%
跨檔重複的 (requestId, message.id)：0 筆   ← 目前沒有 double count 風險
```

**處置**：每個桶加 `direct` / `sidechain` 子計數（一個布林欄位，成本近零），
session 總計含 sidechain，UI 顯示「其中 subagent X%」。
但**不做可切換的 execution dimension UI**（1.77% 不值得），也不因此延後任何東西。

全域仍以 `(requestId, message.id)` 去重，防未來格式出現跨檔副本。

---

## 七、定價：改為逐模型（並修好既有儀表板）

近 14 天各模型的 keyed call 分布：

```
claude-opus-5      1,512    claude-sonnet-4-6  1,476
claude-opus-4-8      530    claude-sonnet-5       36
<synthetic>            5    → 排除
排除 synthetic 後，非 sonnet-4-6 佔比 = (1512+530+36)/3554 = 58.5%
```

`pricing.json` 只有一組 Claude 價格（寫死 `claude-sonnet-4-6`），
`daily-usage.ts:298` 對所有 Claude usage 一次計價 —— **既有每日儀表板的成本欄位已經失真**，
不是本功能引入的。

Codex 查證官方文件後估算低估 39.3%（$158.96 → $261.90）。
**我未獨立驗證這組價格數字**，實作時必須重新查官方來源。

規格：

- `pricing.json` 改為 model → 價格的 map，來源限官方文件（現有 `_note` 的第三方來源不合格）
- 未知模型 → `costUSD: null`，**不得 fallback 到預設價格**
- 輸出 `pricedCalls / totalCalls` 與 `pricingAsOf`
- 標明「標準 API list price 估算」，不含 fast mode / 長 context / cache duration 修正
- **一併修 `daily-usage.ts`** —— 同一份 pricing 載入邏輯，不修的話兩張表會互相矛盾

---

## 八、資料模型與檔案異動

### 8.1 parser 輸出

```jsonc
{
  "generatedAt": "…", "granularity": "session", "pricingAsOf": "2026-08-08",
  "segments": [{
    "id": "…", "label": "lake-ui-kit", "startedAt": "…",
    "promptBoundaryConfidence": "human | inferred",   // prompt 粒度時
    "total": { "calls": 253, "output": 158803, "costUSD": null },
    "phases": {
      "understand": { "calls": 15, "output": 4333, "cacheRead": …, "costUSD": …,
                      "direct": {…}, "sidechain": {…} },
      "develop": {…}, "verify": {…}, "reply": {…}, "other": {…}
    }
  }],
  "diagnostics": {
    "unclassifiedTools": [{ "name": "mcp__…__browser_batch", "calls": 33, "output": 12040 }],
    "unknownBash":       [{ "head": "cd", "calls": 60, "output": 31200 }],
    "mixedCalls":        [{ "combo": "bash+understand", "calls": 52 }],
    "excluded":          { "synthetic": 5, "noUsage": 12 },
    "unknownRate": 0.416, "pricedCalls": 3554, "totalCalls": 3559
  },
  "warnings": ["…"]
}
```

**invariant（必須有測試）**：五桶的 `calls` / `output` / 各 token 欄位總和
== segment `total`；`excluded` 的記錄不得計入任何桶。

### 8.2 檔案

| 檔案 | 動作 | 預估 |
|------|------|------|
| `parser/phase-usage.ts` | 新增 | ~320 行 |
| `parser/bash-classify.ts` | 新增（shell chain 解析，可獨立測試） | ~120 行 |
| `parser/tool-phases.json` | 新增（versioned mapping） | — |
| `parser/phase-usage.test.ts` | 新增 | ~260 行 |
| `parser/pricing.json` | **改**：單一價格 → model map | — |
| `parser/daily-usage.ts` | **改**：逐模型計價（修既有失真） | — |
| `app/…/PhaseUsage.swift` | 新增 Codable 模型 | ~90 行 |
| `app/…/PhaseUsageService.swift` | 新增，照 `DailyUsageService` pattern | ~60 行 |
| `ParserRunner.swift` | 加 `runPhaseUsage` | — |
| `UsageDashboardWindow.swift` | 加分頁切換 + 新區塊 | — |

儀表板目前是單一捲動視圖（`liveQuotaSection` → `kpiRow` → `chart` → `breakdown`），
無分頁機制，需先加 segmented control。

去重與掃描邏輯抽成 `parser/transcript-scan.ts` 共用，避免第三份複製。

---

## 九、UI

```
┌ 每日用量 │ 活動分佈 ┐                            [7天 ▾] [↻]
└──────────┴──────────┘
（v1 只有 session 粒度，故無粒度切換；v2 加 prompt 粒度時才需要）

  ⚠ 未分類比例 41.6% — 分類品質不足，數字僅供參考

  開發  ██████████████████░░  44.5%   70.7K out    62 calls
  其他  █████████████████░░░  41.6%   66.0K out   125 calls
  驗證  ████░░░░░░░░░░░░░░░░  11.2%   17.8K out    51 calls
  回覆  ███░░░░░░░░░░░░░░░░░   9.3%   14.8K out     8 calls
  理解  █░░░░░░░░░░░░░░░░░░░   2.7%    4.3K out    15 calls
                                        其中 subagent 1.8%

  ⓘ 這是「工具活動的 token 分佈」，不是時間分配、工作量或生產力指標。
    不可用於人員、模型或專案之間的績效比較。

  未分類明細
    Bash（無法解析）        cd …           60 calls   31.2K out
    mcp__claude-in-chrome__browser_batch   33 calls   12.0K out
```

- 名稱用「**活動分佈**」，不用「階段效率」「生產力」
- `unknownRate` 超過門檻（建議 25%）時頂端顯示紅字警告，數字仍顯示但明標不可信
- 三指標（calls / output / cost）可切換，預設 output
- **不做** leaderboard、score、紅綠門檻、跨人比較
- 空資料 / parser 失敗沿用 `DailyUsageService` 既有三態

---

## 十、範圍決策（已拍板）

### 10-1 prompt 粒度 → **不進 v1，v1 只做 session 粒度**

原始需求是「一個 prompt **或** session」，經評估後決定砍掉 prompt 粒度。理由：

- compact 之後第一批 calls 歸屬未定義（原 prompt 可能落在掃描時間窗外 → orphan）
- resume / branch 後 `sessionId` 與可見 prompt 不成單純線性序列
- subagent transcript 位於 `<parent-session>/subagents/agent-*.jsonl`，`sessionId` 是母 session，
  但第一則 user message 是委派 prompt 不是人類 prompt
- 我補充的第四點：`origin` 缺失率 82%，舊資料只能 inferred

**決定**：session 粒度的數字現在就能用；prompt 粒度在 linkage 沒解決前會產出看似精確、
實則不可比的區段。prompt 粒度連同 compact / resume / sidechain linkage 規格留 v2。

連帶影響：`--granularity` 參數仍保留在 CLI 介面（只接受 `session`），
`promptBoundaryConfidence` 欄位先不輸出，§5 的調查結果留作 v2 依據。

### 10-2 其餘兩項

- **逐模型定價**：做，且一併修 `daily-usage.ts`（§7）
- **Codex 納入**：本版不做。Claude 側的 grouping、prompt 邊界、sidechain 都還沒穩定，
  此時加入另一套 event schema 只會放大問題。資料模型預留 `provider` 欄位

---

## 十一、測試計畫

`parser/phase-usage.test.ts` + `parser/bash-classify.test.ts`：

**歸因**
1. 同 `(requestId,msgId)` 三筆、usage `100→150→200` → 只計 200，工具集合完整保留
2. 亂序 timestamp → 依 timestamp 取最後一筆，非檔案順序
3. 缺 requestId/msgId 的記錄不得被誤併（沿用 sentinel key）

**守恆**
4. 五桶 calls/output/token 總和 == segment total
5. `<synthetic>` 與缺 usage 的記錄進 `excluded`，不計入任何桶

**分類**
6. 五桶各自分類正確
7. 混合工具依 `develop > verify > understand > other`，且出現在 `mixedCalls`
8. `cd app && npm test` → verify（v1 規則會判成 other，這是回歸守門）
9. `npm run dev` → **不是** verify
10. `env NODE_ENV=test pytest` / `git -C repo diff` / `xcodebuild test` / `./gradlew test`
11. 判不出的 Bash → other 且出現在 `unknownBash`
12. MCP 工具落 other 且出現在 `unclassifiedTools`

**prompt 邊界 —— v2 才需要**（v1 只做 session 粒度，以下留作 v2 清單）
13. `origin.kind == task-notification` 不建立區段
14. `promptSource == system` 不建立區段
15. 無 `origin` 的舊記錄 → 走 heuristic 且標 `inferred`
16. `<command-name>` slash command 是合法切點

**健壯性**
17. 空 session / 空目錄 → 合法空結果
18. 損毀 JSON 行跳過而不中止掃描
19. 未知模型 → `costUSD: null`，不 fallback

既有 20 個 Swift 測試與既有 parser 測試不得退步（特別是 `daily-usage.test.ts` —— §7 會動它）。

---

## 十二、已知限制

| # | 限制 | 狀態 |
|---|------|------|
| 1 | 分類法本質主觀，「理解佔 X%」只適合看趨勢 | UI 明文標示，禁止績效解讀 |
| 2 | `unknownRate` 目前 41.6%，需 §4.2 + §4.3 才降得下來 | 這是 v1 沒認清的必要範圍 |
| 3 | cache read 使後期階段偏貴 | 三指標並列 + UI 註記 |
| 4 | output token 衡量生成量，不是工作量 | 命名與文案已全面改寫 |
| 5 | 定價為官方 list price 估算，不含 fast mode / 長 context 修正 | 輸出 `pricingAsOf` |
| 6 | Bash 分類仍有灰色地帶（`npm run dev` 算開發還是操作？） | 判不出就落 other，附 `classificationReason` |
| 7 | 需 `npx tsx` 冷啟動 | 沿用既有 60s 快取 |

---

## 十三、非目標

- **prompt 粒度**（§10-1 已決，留 v2；需先解決 compact / resume / sidechain linkage）
- 使用者自訂 tool→phase mapping（格式先定，實作延後）
- 階段耗時（wall clock）
- 跨 session 趨勢圖 —— **分類穩定性驗證前不做**
- popover 即時顯示當前 turn
- Codex、agy
- leaderboard / score / 績效比較（永久非目標）

---

## 十四、接手執行指南

### 動工前

```bash
git status
cd cost-aware-approval/app/WakaWaka && swift build && swift test   # 基準：20 tests 綠
npx tsx cost-aware-approval/parser/daily-usage.ts --days 7 | head  # 確認 parser 跑得動
node --test cost-aware-approval/parser/*.test.ts 2>/dev/null || npx tsx --test cost-aware-approval/parser/daily-usage.test.ts
```

必讀既有檔（本計劃大量重用，**不要重寫**）：

- `parser/usage-calculator.ts:78-95` —— `(requestId|message.id)` 去重鍵 + last-write-wins，**直接重用**
- `parser/daily-usage.test.ts` 的 `same requestId|msgId deduped, last-write-wins (streaming)` —— 現成的參考測試
- `parser/daily-usage.ts:126-175`（`scanForJSONL` / `recentFiles`）、`:298`（`claudeCost`，§7 要改）
- `app/…/DailyUsageService.swift` —— `PhaseUsageService` 照抄這個 pattern
- `app/…/DailyUsage.swift` —— `PhaseUsage.swift` 照抄這個 Codable 風格

### 建議實作順序

| 階段 | 內容 | 驗證 | 備註 |
|------|------|------|------|
| 0 | **逐模型定價**：`pricing.json` 改 model map + `daily-usage.ts` 逐模型計價 | 既有 `daily-usage.test.ts` 全綠 + 新增未知模型回 null 的測試 | **可獨立出貨**，修的是現在就在騙人的既有數字 |
| 1 | `parser/bash-classify.ts`（shell chain 解析） | §11-8、9、10、11 | 獨立可測，先做掉風險最高的部分 |
| 2 | `parser/transcript-scan.ts`（抽出共用掃描/去重） | 既有 parser 測試不得退步 | 避免第三份複製 |
| 3 | `parser/phase-usage.ts` 主體 + `tool-phases.json` | §11-1～7、12、17～19 | **守恆 invariant（§11-4）是最重要的一條** |
| 4 | Swift：`PhaseUsage.swift` + `PhaseUsageService.swift` + `ParserRunner.runPhaseUsage` | swift test | |
| 5 | `UsageDashboardWindow.swift` 加 segmented control + 活動分佈區塊 | 實機目測 | 儀表板目前是單一捲動視圖，需先加分頁 |

階段 0 與 1 可以先出貨，不必等整個功能完成。

### 完成判準

- [ ] `swift test` ≥ 20 tests 全綠（不得退步）
- [ ] 既有 `daily-usage.test.ts` 全綠（階段 0 會動到它）
- [ ] 守恆測試通過：五桶總和 == segment total，`excluded` 不計入任何桶
- [ ] 用真實資料跑一次，`unknownRate` **降到 25% 以下**
      —— v1 現況是 41.6%，若做完 shell chain 解析 + MCP mapping 後仍高於 25%，
      表示分類法有問題，**停下來重新檢視 §4，不要硬上**
- [ ] `cd app && npm test` 分類為 verify（v1 規則會判成 other，這是回歸守門）
- [ ] `npm run dev` **不**分類為 verify
- [ ] UI 文案不含「生產力 / 效率 / 費工 / 時間分配」等字眼（§9 的紅線）
- [ ] 依 `version-log` skill 更新 README 版本紀錄

### 最容易犯的三個錯（都已有測試守門）

1. **usage 取第一筆而非最後一筆** —— 1.4% 的 requestId 是 streaming 遞增，會低估 1.62%
2. **去重時只保留第一筆記錄的 content** —— 會讓 80% 的量落進「回覆」桶（原型踩過）
3. **Bash 只取指令首字** —— 實測 64 筆未分類中 60 筆開頭是 `cd`
