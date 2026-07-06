# WakaWaka — Cost-Aware Approval for Claude Code

> macOS menubar 守門員：攔截 Claude Code 與 agy（Antigravity CLI）的工具呼叫，顯示 token 用量、評估操作風險，並讓你決定放行或拒絕。

---

## 專案介紹

Claude Code 預設會自動執行所有工具（Bash、Edit、Write、WebFetch…），但這帶來兩個問題：

1. **成本失控**：你不知道目前 5 小時用量窗口還剩多少 token，也不知道這次操作會燒掉多少
2. **操作失控**：高風險指令（`sudo`、`git push --force`、`rm -rf`）會在你不注意時悄悄執行

WakaWaka 透過 **PreToolUse hook** 機制攔截每一個工具呼叫（支援 Claude Code 與 agy 雙代理），路由到 macOS menubar app **WakaWaka** 進行人工審批，同時即時顯示 5h rolling window 的 token 用量與費用估算。

### 核心功能

| 功能                 | 說明                                                                                                     |
| -------------------- | -------------------------------------------------------------------------------------------------------- |
| **三層風險分類**     | CRITICAL（彈窗，需明確確認）→ HIGH（強制彈窗）→ MEDIUM（可設定 allowlist）                               |
| **Auto 模式**        | per-agent 開關；開啟後自動放行白名單 MEDIUM（Edit/Write/MultiEdit + 未知 bash），HIGH/CRITICAL 與 MCP 仍彈窗；30 分鐘 TTL + fail-closed 稽核（`~/.wakawaka/auto-audit.jsonl`） |
| **多代理支援**       | 同時守護 Claude Code（`pretooluse.mjs`）與 agy（`pretooluse-agy.mjs`），agent badge 顯示來源             |
| **agy Quota Bar**    | 每個 agy 審批卡片即時顯示 Gemini quota 用量（%）與重置倒數（↻ Xh Xm），從 agy local language server 取得 |
| **Token 用量追蹤**   | 從 `~/.claude/projects/` JSONL 解析，全域合併去重，誤差 < 3%                                             |
| **Server 驗證用量**  | `claude -p "/usage"` 每 10 分鐘校正一次，進度條旁綠點表示資料已驗證                                      |
| **5h 配額進度條**    | 對應 Claude 實際 rate limit 窗口，含重置倒數計時                                                         |
| **P90 自動校準**     | 分析歷史 session peaks 估算方案上限（詳見[注意事項](#已知限制與注意事項)）                               |
| **手動校正**         | 輸入 Claude Desktop 顯示的 %，一次校正後長期有效                                                         |
| **審批計時器**       | 8 分鐘警告 → 9m50s 自動拒絕，不讓 hook 無限等待                                                          |
| **展開全文**         | diff / 檔案內容超過預覽高度時，點擊底部按鈕展開至完整內容                                                |
| **Session 歷史紀錄** | 每分鐘寫入 `~/.wakawaka/session-log.jsonl`，可回測準確度                                                 |

---

## 系統架構

```
┌──────────────────────────────────────────────────────────────┐
│                    Claude Code（使用者端）                    │
│  Claude AI ──tool call──► pretooluse.mjs                    │
│                              │ write pending_<sid>.json      │
│                              ▼  agent: "claude-code"         │
│                    ~/.wakawaka/state/                        │
└──────────────────────────────────────────────────────────────┘
                         ▲              │
┌──────────────────────────────────────────────────────────────┐
│                      agy（使用者端）                          │
│  Gemini AI ──tool call──► pretooluse-agy.mjs                │
│                              │ write pending_<sid>.json      │
│                              ▼  agent: "agy"                 │
│                    ~/.wakawaka/state/  ◄──────────────────   │
└──────────────────────────────────────────────────────────────┘
                                        │ poll decision_<sid>
                                        ▼
┌──────────────────────────────────────────────────────────────┐
│                  WakaWaka（menubar app）                     │
│                                                              │
│  ┌──────────────┐   ┌──────────────────────────────────┐    │
│  │  AppDelegate  │   │        Parser（TypeScript）       │    │
│  │  - 1s poll    │   │  usage-calculator.ts             │    │
│  │  - 60s fetch  │◄──│  - JSONL 兩遍掃描 + 去重         │    │
│  │  - P90 detect │   │  - Global unified timeline merge │    │
│  │  - 10m /usage │   │  p90-detector.ts                 │    │
│  └──────────────┘   └──────────────────────────────────┘    │
│          │                                                   │
│          ▼                                                   │
│  ┌──────────────────────────────────────┐                   │
│  │  PopoverViewModel + ContentView      │                   │
│  │  - 待審批佇列（agent badge 顏色區分）  │                   │
│  │  - 5h 用量進度條 + server 驗證綠點    │                   │
│  │  - diff 展開全文 toggle              │                   │
│  └──────────────────────────────────────┘                   │
└──────────────────────────────────────────────────────────────┘
```

### 元件職責

```
cost-aware-approval/
├── hooks/
│   ├── pretooluse.mjs          # Claude Code PreToolUse hook
│   └── pretooluse-agy.mjs      # agy (Antigravity CLI) PreToolUse hook
├── parser/
│   ├── usage-calculator.ts     # Token 用量計算（兩遍掃描 + global dedup）
│   ├── p90-detector.ts         # 歷史 peak 分析 → 方案上限自動估算
│   └── pricing.json            # Anthropic 定價表（手動維護）
└── app/WakaWaka/
    └── Sources/WakaWaka/
        ├── AppDelegate.swift       # 主控：1s 輪詢 + 60s session 刷新 + 10m /usage 校正
        ├── ContentView.swift       # 待審批佇列 UI（agent badge、展開全文）
        ├── SessionStatusView.swift # 5h 用量進度條 + 重置倒數 + server 驗證綠點
        ├── PopoverViewModel.swift  # UI 狀態管理（含 claudeUsageInfo、agyQuota）
        ├── AgyQuotaService.swift   # agy local language server quota 查詢（port 探測 + HTTP）
        ├── ParserRunner.swift      # npx tsx bridge + claude /usage 呼叫
        └── Models.swift            # PendingData、UsageOutput、ClaudeUsageInfo、P90Result

~/.gemini/config/hooks.json         # agy 全局 hook 配置（指向 pretooluse-agy.mjs）
~/.claude/settings.json             # Claude Code hook 配置（指向 pretooluse.mjs）
```

### 關鍵資料流

#### 審批流程（Hook ↔ App）

```
pretooluse.mjs stdin
  └─► 解析 tool_name + tool_input
      └─► 風險分類（CRITICAL / HIGH / MEDIUM）
          ├─ CRITICAL → 立即 exit 2（auto-deny）
          ├─ 在 AUTO_ALLOW_TOOLS 清單中 → exit 0（auto-allow）
          └─ 其他 → 寫 pending_<sid>.json → 等待 decision_<sid>.json
                           ↑                         ↓
                     WakaWaka 每 1s poll       使用者在 popover 點擊 Allow / Deny
```

#### Token 用量計算（避免重複計算）

```
~/.claude/projects/**/*.jsonl（多 conversation）
  └─► Pass 1：全域合併 + dedup by (requestId|message.id)，last-write wins
      └─► Pass 2：Sliding window — 只計入 timestamp >= (now - 5h) 的 entries
              └─► sessionOutput / planLimit = 用量百分比

sessionStartISO = 視窗內最舊 entry 的 timestamp
sessionReset    = sessionStartISO + 5h（隨 sliding window 緩慢往後推移）
```

---

## 使用技術

### Hook（`hooks/`）

| 技術                                | 版本     | 用途                           |
| ----------------------------------- | -------- | ------------------------------ |
| **Node.js**                         | v20.14.0 | hook runtime                   |
| **ES Modules** (`.mjs`)             | —        | 無需 build，直接執行           |
| `node:crypto`                       | —        | `randomUUID()` 產生 session ID |
| `node:fs` / `node:path` / `node:os` | —        | 檔案輪詢 IPC（無 socket）      |

### Parser（`parser/`）

| 技術                          | 版本   | 用途                                    |
| ----------------------------- | ------ | --------------------------------------- |
| **TypeScript**                | 5.x    | 型別安全的 JSONL 解析器                 |
| **tsx**                       | v4.22+ | 零設定直接執行 `.ts`（無需 `tsc` 編譯） |
| Node.js `readline`            | —      | 串流逐行讀取大型 JSONL                  |
| Node.js `fs.createReadStream` | —      | 非阻塞檔案讀取                          |
| `Promise.all`                 | —      | 多檔案平行讀取                          |

### macOS App（`app/WakaWaka/`）

| 技術                       | 版本      | 用途                              |
| -------------------------- | --------- | --------------------------------- |
| **Swift**                  | 5.9       | 主要語言                          |
| **SwiftUI**                | macOS 14+ | 宣告式 UI                         |
| **AppKit** (`NSStatusBar`) | —         | menubar status item               |
| **UserNotifications**      | —         | 80% / 95% 用量警告推播            |
| **Swift Package Manager**  | —         | 無第三方依賴，純原生 build        |
| `Process` + `Pipe`         | —         | 從 Swift 呼叫 `npx tsx`（bridge） |
| `DispatchQueue`            | —         | 背景 I/O + serial log queue       |
| `UserDefaults`             | —         | 持久化方案上限、手動校準值        |

### IPC 機制

| 機制                   | 說明                                                                                  |
| ---------------------- | ------------------------------------------------------------------------------------- |
| **File-based polling** | Hook 寫 `pending_<sid>.json`，App 每 1s 讀取，App 寫 `decision_<sid>.json`，Hook 輪詢 |
| **Tombstone pattern**  | Hook 超時時標記 `hookExited:true`（而非刪除），App 顯示「已逾時」讓使用者手動清除     |
| **Session log**        | App 每 60s 寫入 `~/.wakawaka/session-log.jsonl`（append-only via serial queue）       |

---

## 安裝與啟動

### 前置需求

- macOS 14 Sonoma 以上
- Node.js 20+（建議透過 nvm 安裝）
- Swift 5.9（Xcode 15+ 或 Command Line Tools）

### 一鍵啟動

```bash
git clone https://github.com/Pito0713/WakaWaka.git
cd WakaWaka
./start.sh
```

腳本會自動完成以下三步驟：

1. **Build**：偵測 binary 是否存在，不存在時自動執行 `swift build`
2. **啟動 App**：在背景執行 WakaWaka menubar app
3. **寫入 Hook**：自動將 PreToolUse hook 路徑寫入 `~/.claude/settings.json`（重複執行不會重複寫入）

> 加 `--build` 旗標可強制重新 build：`./start.sh --build`

### 確認運作

啟動 Claude Code 後，執行任何 Bash 指令，menubar 應出現 👻 icon 並彈出審批視窗。

---

## 檔案路徑規範

所有 runtime 檔案統一存放於 `~/.wakawaka/`：

```
~/.wakawaka/
├── state/
│   ├── pending_<session_id>.json   # hook 寫入，等待審批
│   └── decision_<session_id>.json  # app 寫入，hook 讀取
├── allowlist.json                   # 使用者自定義 MEDIUM 指令白名單
└── session-log.jsonl                # Token 用量歷史紀錄（每分鐘一筆）
```

---

## 風險分類說明

| 等級           | 行為                            | 範例                                                                      |
| -------------- | ------------------------------- | ------------------------------------------------------------------------- |
| **CRITICAL**   | 自動拒絕，不彈窗                | `rm -rf /`、`curl \| sh`、`dd of=/dev/disk0`                              |
| **HIGH**       | 強制彈窗（無法 allowlist 略過） | `sudo`、`git push --force`、`chmod`、`kill`                               |
| **MEDIUM**     | 彈窗，可加入 allowlist          | 一般 Bash 指令                                                            |
| **Auto-allow** | 靜默放行                        | `Read`、`Glob`、`Grep`、`WebSearch` 等純讀取操作（`Edit`/`Write` 需審批） |

---

## 用量進度條校正（首次建議執行）

### 為什麼需要校正

WakaWaka 的進度條公式：

```
進度 % = sessionOutput（5h 內 output tokens）/ planLimit（方案上限）
```

- **分子（sessionOutput）**：從本地 JSONL 計算，準確
- **分母（planLimit）**：P90 自動偵測，**可能大幅低估**

**P90 偵測的限制**：偵測器以你歷史上的 session 峰值估算上限。若你從未在單一 5h 視窗內使用超過 X tokens，偵測器就會把 X 誤認為是方案上限。

實測案例（2026-06-20）：

|              | P90 偵測               | Claude Desktop（實際） |
| ------------ | ---------------------- | ---------------------- |
| 方案上限     | 181,200 tokens         | 356,484 tokens         |
| 同一時間進度 | **104.3%**（顯示超限） | **53%**（實際用量）    |
| 誤差         | **±51%**               | 0%（基準）             |

### 一次性校正步驟

> 校正值存在 `UserDefaults`，只要方案不變就永久有效，**不需要每次重新校正**。

**步驟：**

1. 打開 **Claude Desktop**，查看目前顯示的用量百分比（例如 `53%`）
2. 在 WakaWaka 進度條旁點擊 **⚡ 標章**，開啟校正面板
3. 在輸入框填入 Claude Desktop 顯示的數字（例如 `53`）
4. 面板會自動反推：`上限 = sessionOutput ÷ 53% = 356K`
5. 點擊**套用**

校正後 WakaWaka 的 % 應與 Claude Desktop 一致。

### 何時需要重新校正

| 情況                                      | 需要重新校正 |
| ----------------------------------------- | ------------ |
| 升級或降級 Anthropic 方案                 | ✅ 是        |
| Anthropic 調整方案配額（如 2026-05 倍增） | ✅ 是        |
| 換新電腦（UserDefaults 不跨裝置）         | ✅ 是        |
| 5h 視窗重置 / 每次新 session              | ❌ 不需要    |
| 日常使用                                  | ❌ 不需要    |

---

## 已知限制與注意事項

### 1. 只追蹤 Claude Code 的用量

WakaWaka 讀取 `~/.claude/projects/` 下的 JSONL 檔案，這些檔案由 **Claude Code CLI** 寫入。

Claude Desktop 的**純聊天對話**（非 Claude Code session）存放於 Electron app 的 IndexedDB（LevelDB 格式），WakaWaka 目前無法讀取。

實際影響：若你同時在 Claude Desktop 聊天且用量不低，WakaWaka 的分子會略低於 Desktop 顯示的實際用量。透過定期校正可修正分母，但兩者之間仍可能有 1–5% 的即時誤差。

**若你的主要使用方式是 Claude Code（含從 Desktop 啟動的 Code session），兩者數字應高度一致。**

### 2. Reset 時間是 Sliding Window，不是固定重置

「Resets in」顯示的是**最舊 entry 滑出 5h 視窗**的時間，不是所有 token 一次清零。

```
意義：「再過 X 分鐘，最早那批 token 會從配額中釋放」
不是：「再過 X 分鐘，配額歸零重新開始」
```

Claude 的 rate limit 是真正的 rolling window：舊 token 逐漸滑出，你的可用配額持續緩慢回升。

### 3. P90 偵測僅作為初始估算

P90 偵測在以下情況會有大誤差：

- **新用戶 / 歷史資料少**：樣本不足，估算偏低
- **用量從未逼近上限**：歷史峰值遠低於真實方案上限
- **方案剛升級**：舊的峰值反映舊方案上限

**建議**：首次使用後執行一次 ⚡ 手動校正，之後無需再動。

---

## Changelog

版本格式：`v主版本.功能版本.修補版本`，遵循 [Keep a Changelog](https://keepachangelog.com/zh-TW/1.0.0/) 規範。

---

### v0.8.0 — 2026-07-06

#### Added

- **Auto 模式（per-agent 自動放行）**：menubar 新增每個 agent 獨立的 auto 開關，開啟後該 agent 的 MEDIUM 風險操作自動放行、跳過人工審批
  - 白名單限縮：僅 `Edit` / `Write` / `MultiEdit` + 未知 bash（Claude Code）、shell 工具 + write 工具（agy）自動放行；MCP 與未分類工具即使 auto 開啟仍走人工審批
  - HIGH（`sudo`、`git push --force`、`kill`…）與 CRITICAL 永不被 auto 放行，硬編碼不可繞過
  - 30 分鐘 TTL：開啟後自動過期，menubar 顯示倒數（`Auto ↻ 27m`），到期由 30 秒 sweep 自動歸位
  - fail-closed 稽核：每筆自動放行寫入 `~/.wakawaka/auto-audit.jsonl`（`0o600`）；稽核寫入失敗則不放行、退回人工審批
  - 新增 `~/.wakawaka/settings.json`（`0o600`，atomic write）作為 app 與 hook 的共用契約
  - 新增 `SettingsService.swift`（app 端讀寫）；hook 端 `loadAutoMode()` 讀取設定，壞檔 / 過期一律視為停用（安全預設）

---

### v0.7.0 — 2026-06-23

#### Added

- **agy Quota Bar**：每個 agy 審批卡片顯示即時 quota 用量，含倒數至重置
  - 新增 `AgyQuotaService.swift`：動態探測 agy local language server port（`ps` + `lsof`），呼叫 `GetUserStatus` gRPC/HTTP API
  - quota bar 顯示位於 summary 行下方（第二行），寬度 60pt（較前版 1.5x）
  - 顯示內容：`[████████████░░░░░░░]  88%  ↻ 3h 21m`（remaining fraction + 重置倒數）
  - 不足 15% 轉紅色，15–30% 轉橘色，其餘為 agy 紫色
  - `PopoverViewModel.agyQuota` 每 5 分鐘輪詢更新
- **agy Hook 格式修正**：修正 agy 實際送出的 stdin 格式與假設不符的問題
  - 正確解析 `input.toolCall.name`（tool 名稱）、`input.toolCall.args`（參數）
  - `session_id` 改用 `input.conversationId`（同一 conversation 共用同一個 session）
  - `transcript_path` 改用 `input.transcriptPath`
  - 指令 key 支援 `CommandLine`（agy PascalCase 格式）除原有 `command` / `cmd`
  - PascalCase tool 名稱自動正規化（`ListDir` → `list_dir`，`ListPermissions` → `list_permissions`）
- **CRITICAL 工具改為彈窗審查**：`delete_file` 等 CRITICAL_TOOLS 不再自動拒絕，改以 CRITICAL 風險等級顯示審批 popover，需使用者明確確認
- **Auto-allow 新增 `list_permissions`**：純讀取工具，不需人工審批

#### Fixed

- `Bash` / `run_command` summary 支援 `CommandLine` key（agy 格式），修正「(no input)」誤顯示
- agy shell risk 評估正確取用 `CommandLine` 欄位進行 CRITICAL/HIGH 模式比對

---

### v0.6.0 — 2026-06-22

#### Added

- **多代理支援（Multi-Agent）**：新增 `pretooluse-agy.mjs`，讓 agy（Antigravity CLI / Gemini）工具呼叫同樣路由到 WakaWaka 審批
  - Auto-allow：`view_file`、`list_dir`、`grep_search`、`manage_task`、`schedule`
  - Auto-deny：`delete_file`（不彈窗，直接拒絕）
  - `run_command` / `run_shell_command` 套用與 Claude Code 相同的 CRITICAL/HIGH 風險分析
  - 雙格式輸入容錯：`{ tool_name, tool_input }` 和 `{ name, args }` 均支援
  - `~/.gemini/config/hooks.json` 全局 agy hook 配置
- **Agent Badge**：每個待審批項目顯示來源 agent badge（Claude = 橘色、agy = 紫色），`PendingData` 新增 `agent` 欄位
- **展開全文 toggle**：diff / 檔案內容超過預覽高度（220px）時，底部顯示「展開全文 ↕」按鈕
  - 展開後移除文字截斷（`cap()`），高度擴展至 520px
  - LCS fallback 上限從 150 → 500 行（full 模式），動畫 `easeInOut(0.22s)`
  - `buildSections` 新增 `full` 參數，同時儲存 `toolInputSections`（截斷）與 `toolInputSectionsFull`（完整）

---

### v0.5.0 — 2026-06-20

#### Added

- **Server 驗證用量**：每 10 分鐘自動執行 `claude -p "/usage"`，取得 server 端準確的 session % 與重置時間
  - 進度條優先顯示 server 資料，本地 JSONL 估算為 fallback
  - 新鮮資料（< 11 分鐘）時，進度條旁顯示 🟢 綠點
  - 手動 ↺ refresh 同時觸發 JSONL 解析與 `/usage` 呼叫
  - `ClaudeUsageInfo` struct 儲存 `sessionPct`、`sessionReset`、`weeklyPct`、`fetchedAt`
  - `ParserRunner.runClaudeUsage()` 解析 `/usage` 輸出，支援多時區日期格式

---

### v0.4.0 — 2026-06-20

#### Fixed

- **Session 計算改為真正的 Sliding Window**：原固定邊界（fixed-boundary）算法導致「Resets in」時間錯誤（顯示 4h43m，實際剩 5 分鐘）。改為 `windowCutoff = now - 5h`，與 Claude server 邏輯一致
- **Notification 誤重置修正**：Sliding window 讓 `sessionStartISO` 隨時間緩慢推移，原邏輯在 `sessionStartISO` 改變時就清除 `notifiedThresholds`，導致 80%/95% 警告反覆發送。加入 `progress < 0.15` 防護，只有用量真正歸零才重置

#### Added

- **QueueItemRow Hover 預覽**：Collapsed 狀態的審批列表項目，滑鼠懸停時背景高亮、摘要文字展開至 3 行，加入 `easeInOut` 動畫

#### Docs

- README 新增「用量進度條校正」章節：說明 ⚡ 一次性校正步驟、實測誤差數據（P90 偵測 ±51% vs 校正後 0%）
- README 新增「已知限制與注意事項」：說明只追蹤 Claude Code 用量、Sliding window 語意、P90 適用範圍
- 修正 README 功能表中「P90 誤差 ~0.1%」的錯誤描述

---

### v0.3.0 — 2026-06-20

#### Added

- **Edit / MultiEdit diff 紅綠對比顯示**：使用 LCS（Longest Common Subsequence）演算法產生行級 unified diff，interleaved 紅（刪除）/ 綠（新增）/ 灰（不變）色塊，取代原本的純文字前後對比

#### Changed

- `DiffSection.Kind` 加入 `Equatable` conformance（LCS 比對所需）
- `buildSections` Edit / MultiEdit case 改呼叫 `lineDiff(old:new:)`，超過 150 行 fallback 至截斷顯示

---

### v0.2.0 — 2026-06-20

#### Changed

- 專案從 `CostNotch` 重新命名為 `WakaWaka`
- App bundle、路徑、log 目錄、狀態檔統一更新

---

### v0.1.0 — 2026-06-16

#### Added

- **PreToolUse Hook**（`hooks/pretooluse.mjs`）：攔截 Claude Code 所有工具呼叫，三層風險分類（CRITICAL / HIGH / MEDIUM），File-based IPC 等待審批
- **TypeScript Parser**（`parser/usage-calculator.ts`）：JSONL 兩遍掃描 + 全域去重，計算 5h rolling window token 用量與費用
- **P90 Detector**（`parser/p90-detector.ts`）：分析歷史 session peaks 估算方案上限
- **macOS Menubar App**（SwiftUI）：待審批佇列、5h 進度條、⚡ 手動校正、80%/95% 用量通知、Ghost icon 動畫、8m 審批計時器
