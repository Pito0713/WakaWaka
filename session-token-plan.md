# 計劃書：Session Token 用量與上下文警示

> 狀態：草案，等待使用者確認範圍與門檻
> 撰寫：2026-08-25
> 前置：`active-agents-plan.md`（registry 資料層）、`floating-agents-panel-plan.md`（HUD）

---

## 一、這份計劃要解決什麼

ACTIVE AGENTS 面板現在能回答「誰活著、在做什麼」，但回答不了「**這個 session 還剩多少空間**」。
使用者要到上下文塞滿、自動壓縮觸發之後才發現，那時候「要不要收尾」的選擇權已經沒了。

目標：在每一列上顯示該 session 的上下文佔用率，並在逼近上限時提醒。

---

## 二、關鍵區分：累計消耗 ≠ 上下文佔用

這是整份計劃的地基，弄混會做出一個**會誤報的**功能。

| | 是什麼 | 回答哪個問題 |
|---|---|---|
| **累計消耗** | 這個 session 從頭燒掉的 token 總和 | 花了多少錢 |
| **上下文佔用** | 這一輪送進模型的 prompt 有多大 | 還剩多少空間 |

兩者可以差一個數量級。本機實測（2026-08-25，一個進行中的 Claude Code session）：

```
最後一則 assistant 訊息的 usage：
  input_tokens                 2
  cache_creation_input_tokens  492
  cache_read_input_tokens      228,495   ← 上下文的絕大部分
  output_tokens                1,017
```

上下文約 **229K**，但其中 99% 是 cache read——單價約為一般 input 的 1/10。
一個長時間、高快取命中的 session，累計數字很嚇人，實際上既不貴、上下文也未必滿。

**結論：警示只看「上下文佔用」，累計消耗只放進 tooltip 當參考。**

---

## 三、資料盤點（實測本機，非推測）

### 3.1 Codex — 資料已經流經現有 parser

`~/.codex/sessions/**/rollout-*.jsonl` 的 `event_msg` / `token_count` 事件：

```json
"info": {
  "total_token_usage": { "total_tokens": 765162, "cached_input_tokens": 691968, ... },
  "last_token_usage":  { "input_tokens": 60467, ... },
  "model_context_window": 258400
}
```

**分母寫在檔案裡**（`model_context_window`），佔用率 = `last_token_usage.input_tokens / model_context_window` ≈ 23%。

`CodexUsageService.parseEventLine` **現在就在逐行解析這個事件**，但 `Payload` 只宣告了 `rateLimits`，
整個 `info` 區塊被 `Decodable` 丟掉。這一端的成本是「把已經讀進來的欄位撿回來」，沒有新增 I/O。

### 3.2 Claude Code — 可算，但分母要外部補

`~/.claude/projects/<cwd-slug>/<sessionId>.jsonl`，每則 assistant 訊息帶完整 usage。

- 上下文佔用 = 最後一則 assistant 的 `input + cache_creation + cache_read`
- 累計消耗 = 全檔加總（需 dedup，`usage-calculator.ts` 已有這套邏輯）

**掃過 872 行的頂層欄位，transcript 沒有任何欄位說明 context window 多大。**
分母必須外部維護（見 4.4）。

### 3.3 agy — 本輪排除

`~/.gemini/config/hooks.json` 不存在，agy 實際上沒有任何 hook 生效，registry 從未收過 agy 的 entry。
在 hook 真的接上之前，這一端沒有資料可談。

### 3.4 registry → transcript 的對應

| kind | 檔名 | 已驗證 |
|---|---|---|
| claude-code | `~/.claude/projects/<slug>/<sessionId>.jsonl` | ✅ 用本 session 對過 |
| codex | `~/.codex/sessions/<Y>/<M>/<D>/rollout-<ts>-<sessionId>.jsonl` | ✅ 用正在跑的 codex session 對過 |

兩邊都能從 registry 的 `sessionId` 反推，但**不該用猜的**——見 4.2。

---

## 四、核心技術決策

### 4.1 只警示有分母的量

| 基準 | 分母來源 | 採用 |
|---|---|---|
| 上下文佔用率 | Codex 在檔案裡給；Claude 靠對照表 | ✅ 主要警示 |
| rolling window 配額 | app 已有（5h + P90）；Codex 有 weekly `used_percent` | ✅ 已存在，不重做 |
| 絕對 token 數 | 無 | ❌ 不當門檻 |

「用了 76 萬 token」本身不代表任何事。沒有分母的數字可以顯示，但不可以觸發警示——
否則門檻只能靠拍腦袋訂，而拍出來的數字沒有任何人能驗證對錯。

### 4.2 `transcript_path` 存進 registry，不在 app 端猜路徑

hook 本來就拿得到 `transcript_path`（`detectKind` 分辨 Codex/Claude 靠的就是它），
存進 entry 是**一個欄位**，與剛完成的 `tmuxSession` 完全同一條路徑。

不這麼做的代價：app 端要複製一份 cwd → slug 的轉換規則，而那是 Claude Code 的內部約定，
它改一次我們就靜默失效——而且失效方式是「找不到檔案 = 不顯示」，沒有人會發現。

**安全**：這個值進 registry 前必須驗證是絕對路徑、在預期的根目錄底下、且無控制字元；
它會被用來開檔，是目前所有 registry 欄位裡權限最高的一個。

### 4.3 讀檔尾 + `(size, mtime)` 快取，不進每秒輪詢

transcript 會長到數 MB，而 registry 輪詢是 1 秒一次。規則：

- 只讀檔案**尾端** N KB（預設 64KB，與 `AgentRegistryService` 既有上限一致）
- 快取鍵 `(path, size, mtime)`，沒變就不重讀
- 仍走既有的背景執行緒，主執行緒永遠不碰檔案
- regular-file 檢查照舊：一個 fifo 會卡死讀取端

### 4.4 context window 表放 `pricing.json`

`parser/pricing.json` 已經是「人工維護的外部事實」的家：有 `pricingAsOf` 日期、有來源註記、
按 `claude.models.<model>` 分層。context window 是同性質的資料，放進同一個模型節點：

```json
"claude-opus-5": { "inputPerMTok": 5.0, ..., "contextWindow": 200000 }
```

**表裡沒有的模型不顯示佔用率**，而不是假設一個預設值。錯的分母比沒有分母更糟：
它會給出一個看起來精確、實際上錯誤的百分比，而使用者沒有辦法分辨。

### 4.5 警示走既有管道，不新開通知

面板已經有三套現成語彙：狀態燈顏色、degraded 佔一列、HUD 的 focus 失敗列。
警示用「meter 變色 + 一行說明」就夠，**不新增系統通知、不搶焦點**——
這個 app 的既有原則是不打斷使用者，一個會跳出來的 token 提醒與那個原則直接衝突。

狀態燈**不參與**警示配色：它表示 agent 在做什麼（working / idle），與上下文滿不滿是兩件事，
共用一個顏色會讓兩者都讀不準。

---

## 五、UI 規格

### 5.1 Popover 列（480pt 寬）

正常（< 70%）：

```
┌────────────────────────────────────────────────────────────┐
│ ● WakaWaka (tmux · WakaWaka)   main                        │
│    ⚡ code-review          ▇▇▇▇░░░░░ 41%          12s ago │
└────────────────────────────────────────────────────────────┘
```

提醒（70–84%，meter 轉黃）：

```
│ ● lake-ui-kit                  feat/checkout               │
│    Bash                    ▇▇▇▇▇▇▇░░ 78%           3s ago │
```

強提醒（≥ 85%，meter 轉紅 + 一行說明）：

```
│ ● WakaWaka (tmux · WakaWaka)   main                        │
│    Edit                    ▇▇▇▇▇▇▇▇▉ 91%           1s ago │
│    ⚠ 上下文快滿了，建議收尾或 /compact                      │
```

- meter 寬度固定 54pt，`▇` 為填滿、`░` 為空；實作用 `Capsule` 疊圖，不用字元
- 百分比 `caption2.monospacedDigit()`，避免數字跳動造成寬度抖動
- 說明列只在 ≥85% 出現，與現有 degraded 列同一種呈現

### 5.2 HUD 列（300pt 寬）

300pt 放不下說明文字，只放 meter；警示靠顏色，細節進 tooltip：

```
┌──────────────────────────────┐
│ ● WakaWaka        main       │
│    Edit    ▇▇▇▇▇▇▇▇▉ 91%  1s │
└──────────────────────────────┘
```

### 5.3 Tooltip（兩處相同）

沒有分母的數字放這裡，不佔版面：

```
上下文 187,432 / 200,000（91%）
本 session 累計 765,162 tokens ≈ US$1.24
最後活動 1 秒前
```

### 5.4 沒有資料時

**不顯示 meter**，不顯示 0%。與面板「永不靜默失敗」的原則一致：
0% 與「讀不到」在畫面上必須可分辨，而一條空的 meter 兩者都像。

---

## 六、門檻與依據

| 帶 | 範圍 | 呈現 | 依據 |
|---|---|---|---|
| 正常 | < 70% | 灰 | — |
| 提醒 | 70–84% | 黃 | 還有約三成空間可以決定要不要收尾 |
| 強提醒 | ≥ 85% | 紅 + 說明列 | 逼近自動壓縮，選擇權即將消失 |

**70 / 85 是提案值，不是實測值。** Phase 0 必須先量一次 Claude Code 的自動壓縮實際觸發點，
再回頭決定紅帶要不要往上或往下移——門檻的價值全在「它比自動壓縮早多少」，
不先量就訂，等於用一個沒有根據的數字去警示另一個沒有根據的數字。

---

## 七、檔案計劃

### 新增

| 檔案 | 職責 |
|---|---|
| `Sources/WakaWaka/SessionTokens.swift` | 資料模型：佔用率、累計、帶（band）判定 |
| `Sources/WakaWaka/TranscriptTailReader.swift` | 檔尾讀取 + `(size, mtime)` 快取 |
| `Sources/WakaWaka/ContextWindows.swift` | 讀 `pricing.json` 的 contextWindow，查無則回 nil |
| `Sources/WakaWaka/ContextMeter.swift` | meter 視圖，popover 與 HUD 共用 |
| `Tests/.../SessionTokensTests.swift` | 帶邊界、缺分母、髒資料 |
| `Tests/.../TranscriptTailReaderTests.swift` | 快取命中、截斷行、fifo 防護 |

### 修改

| 檔案 | 異動 |
|---|---|
| `hooks/agent-registry.mjs` | 存 `transcriptPath`（含路徑驗證） |
| `AgentRegistry.swift` / `AgentRegistryService.swift` | 新欄位 + sanitize |
| `CodexUsageService.swift` | `Payload` 補 `info`，撿回 `total/last/model_context_window` |
| `ActiveAgentsView.swift` / `FloatingAgentRow.swift` | 掛上 meter |
| `FloatingPanelSizing.swift` | 說明列進入高度量測 |
| `parser/pricing.json` | 每個模型補 `contextWindow` |

---

## 八、分期與驗收條件

### Phase 0 — 風險閘（先做，不寫功能碼）

1. 量 Claude Code 自動壓縮的實際觸發點（開一個長 session 逼近上限，記錄觸發時的 usage）
2. 確認 Claude 各模型的 context window 來源，寫進 `pricing.json` 並註明查證日期
3. 量一次 5MB transcript 的檔尾讀取成本，確認低於一次輪詢預算

**驗收**：三個數字都有實測記錄。任一項拿不到 → 停下來重新評估範圍，不要硬做。

### Phase 1 — Codex 端（最便宜，先驗 UI）

`CodexUsageService` 撿回 `info`，popover 顯示 meter。

**驗收**：真實 codex session 的佔用率與 `rollout-*.jsonl` 手算值一致；無 `info` 的舊檔不顯示 meter 且不崩。

### Phase 2 — Claude Code 端

`transcriptPath` 入 registry → tail reader → contextWindow 表 → 同一個 meter。

**驗收**：本機兩個並行 claude session 各自顯示正確佔用率；殺掉 transcript 讀取權限後 meter 消失而非歸零。

### Phase 3 — 警示帶與 HUD

黃/紅帶、說明列、tooltip、HUD 呈現與高度重新量測。

**驗收**：說明列出現時 popover 與 HUD 高度都正確增長（**這裡踩過坑**，見第十節）。

---

## 九、測試計畫

- **帶邊界**：69 / 70 / 84 / 85 / 100 / 101%，以及負值與 NaN
- **缺分母**：模型不在 `pricing.json` → 回 nil，不得回 0
- **髒資料**：截斷的最後一行、非 JSON 行、`usage` 缺欄位 → 略過該行而非整檔失敗
- **sidechain 汙染**：transcript 帶 `isSidechain: true` 的訊息屬於 sub-agent，
  **必須排除**，否則 sub-agent 的 usage 會被算成主 session 的上下文
- **快取**：size/mtime 不變不得重讀；變了必須重讀
- **變異測試**：每條守衛都要能被拆掉並轉紅，否則視為未驗證

---

## 十、風險與已知限制

1. **context window 表會過期**。緩解：查無則不顯示。錯的分母比沒有分母更糟。
2. **HUD 高度量測**。本專案已經踩過一次：量測用的形態與渲染的形態不一致，三個 agent 差 48pt，
   要露出的列反而被裁掉。新增說明列必須進入 `FloatingPanelSizing` 的量測副本。
3. **sidechain / sub-agent**。見第九節，會系統性高估上下文。
4. **Codex 的 `last_token_usage` 是「上一輪」**，session 閒置時它不會更新——
   與心跳一樣，顯示的是最後一次已知值，不是即時值。tooltip 應標明時間。
5. **多 harness 並行**。registry 由多個 session 同時寫，`transcriptPath` 與其他欄位一樣
   受「偵測失敗不覆寫既有值」的規則保護。

---

## 十一、明確排除的範圍

- **不做系統通知 / 不搶焦點**（見 4.5）
- **不做自動壓縮或自動收尾**：這是使用者的決定，這個 app 只提供資訊
- **不做 agy**：hook 未生效，沒有資料
- **不重做 rolling window 配額**：app 已經有，本計劃不碰
- **不做歷史趨勢圖**：儀表板的職責，不是面板的
