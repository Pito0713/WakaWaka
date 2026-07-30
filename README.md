# WakaWaka — Cost-Aware Approval for AI Coding Agents

> macOS menubar 守門員：攔截 Claude Code、Codex 與 agy（Antigravity CLI）的工具呼叫，顯示用量、評估操作風險，並讓你決定放行或拒絕。

---

## 專案介紹

AI coding agent 會代表使用者呼叫 shell、修改檔案或連接外部服務，但這帶來兩個問題：

1. **成本失控**：你不知道目前 rolling window 還剩多少用量，也不知道這次操作會消耗多少額度
2. **操作失控**：高風險指令（`sudo`、`git push --force`、`rm -rf`）會在你不注意時悄悄執行

WakaWaka 透過各 agent 的 **PreToolUse hook** 攔截本機工具呼叫，依風險分類後自動放行、立即拒絕或路由到 macOS menubar app 進行人工審批。App 同時整合 Claude Code、Codex 與 agy 的可用量資訊。

### 核心功能

| 功能                 | 說明                                                                                                     |
| -------------------- | -------------------------------------------------------------------------------------------------------- |
| **三層風險分類**     | CRITICAL → HIGH → MEDIUM；各 agent adapter 採 fail-closed 策略，Codex 的 CRITICAL shell 操作會立即拒絕 |
| **Auto 模式**        | per-agent 開關；開啟後自動放行白名單 MEDIUM（Edit/Write/MultiEdit + 未知 bash），HIGH/CRITICAL 與 MCP 仍彈窗；30 分鐘 TTL + fail-closed 稽核（`~/.wakawaka/auto-audit.jsonl`） |
| **多代理支援**       | 同時守護 Claude Code、Codex 與 agy，agent badge 顯示工具呼叫來源                                         |
| **Codex Usage**      | 從本機 Codex session 資料彙整 5h 與 weekly 用量，獨立於 Claude Code usage 顯示                            |
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
                                        │
┌──────────────────────────────────────────────────────────────┐
│                       Codex（使用者端）                       │
│  Codex ──tool call──► pretooluse-codex.mjs                  │
│                          │ classify + write pending          │
│                          ▼  agent: "codex"                   │
│                    ~/.wakawaka/state/                        │
└──────────────────────────────────────────────────────────────┘
                                        │
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
│   ├── pretooluse-codex.mjs    # Codex PreToolUse adapter
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
        ├── CodexUsageService.swift # Codex 5h / weekly 本機用量彙整
        ├── SettingsService.swift   # per-agent Auto Mode 設定與期限
        ├── ParserRunner.swift      # npx tsx bridge + claude /usage 呼叫
        └── Models.swift            # PendingData、UsageOutput、ClaudeUsageInfo、P90Result

~/.gemini/config/hooks.json         # agy 全局 hook 配置（指向 pretooluse-agy.mjs）
~/.claude/settings.json             # Claude Code hook 配置（指向 pretooluse.mjs）
.codex/hooks.json                   # Codex 專案 hook 配置（指向 pretooluse-codex.mjs）
```

### 關鍵資料流

#### 審批流程（Hook ↔ App）

```
PreToolUse adapter stdin
  └─► 解析 tool_name + tool_input
      └─► 風險分類（CRITICAL / HIGH / MEDIUM）
          ├─ 安全 read / allowlist → auto-allow
          ├─ Codex CRITICAL shell → immediate deny
          └─ 其他需審批操作 → 寫 pending_<approval_id>.json
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

風險順序固定為 `CRITICAL > HIGH > MEDIUM`。分類器會先檢查 `rm` 目標及 CRITICAL pattern，再檢查 HIGH pattern；未命中者預設為 MEDIUM。外部或未知工具不因「無法分類」而自動視為安全。

### Codex

| 等級 | Codex 攔截行為 | 代表範例 |
| ---- | -------------- | -------- |
| **CRITICAL** | hook 立即回傳 `deny`，不建立人工審批；Auto Mode 與 allowlist 均不可繞過 | `rm -rf /`、`rm -rf ~`、`sudo rm`、`curl ... \| sh`、`dd ... of=/dev/disk0`、`mkfs` |
| **HIGH** | 一律建立 pending item，等待 WakaWaka 人工決定；Auto Mode 與 allowlist 均不可繞過 | `sudo`、`git push --force`、`git reset --hard`、`git clean -f`、`chmod`、`chown`、`kill`、`rsync --delete`、`ssh` |
| **MEDIUM** | 預設建立 pending item；簡單 read command、使用者 allowlist，或符合條件且稽核成功的 Auto Mode 可放行 | `cp source target`、`apply_patch`、MCP／未知 local tool、其他未命中高風險 pattern 的 Bash |

Codex 的安全 read command 僅限無 pipe、redirect、command substitution 或危險 option 的單一命令，例如 `pwd`、`ls`、`rg`、`cat`、`ps`。`rg --pre`、複合命令及含 `$()`／backtick 的命令會回到 MEDIUM 人工審批。

> Coverage 限制：此 hook 是本機 Codex tool path 的審批層，不應視為完整 sandbox。Hosted tools 或平台明確不送入 `PreToolUse` 的 specialized path，不在這個 adapter 的攔截範圍內。

### Claude Code 與 agy

Claude Code 與 agy 使用相同三層名稱，但 adapter 的最終處置可能不同；例如部分 CRITICAL 操作會保留人工最終決定。修改政策時應同步更新各 hook 的 regression tests，不要從 Codex 表格推論其他 agent 的行為。

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

### v0.12.0 — 2026-07-30

#### Added

- **儀表板 Claude Weekly 額度行**：即時額度區在 Claude 5h 之下新增「Claude Weekly」行，顯示 weekly limit 用量 % 與重置倒數。資料來自 server-side `/usage` 快照（`ClaudeUsageInfo.weeklyPct` / 新增 `weeklyReset`）；取不到 weekly 資料時整行隱藏，不顯示假的 0%。

---

### v0.11.0 — 2026-07-28

#### Changed

- **popover 精簡**：idle / pending 兩態改用統一的 `PopoverFooter` —— Auto 開關 + 📊 儀表板 / ↻ 重整 + Claude 5h 與 Codex（動態窗口）兩條額度 bar；審批區改為可捲動、footer 常駐底部。burn rate、校正、Codex 詳細行等觀測細節移出 popover。

#### Added

- **儀表板即時額度區**：用量儀表板頂部新增「即時額度」—— Claude / Codex 兩條額度 bar + burn rate + 預估滿 % + 校正按鈕，資料由開啟時的即時 snapshot（`LiveQuotaSnapshot`）提供，`nil` 時顯示佔位。

---

### v0.10.0 — 2026-07-27

#### Added

- **每日用量儀表板**：popover 的 USAGE 列新增 📊 入口，開啟獨立視窗（720×520，可調整大小）顯示每日 token 用量與各 agent 佔比
  - 資料層 `parser/daily-usage.ts`：聚合 Claude Code 與 Codex 的每日 token，依**本地時區**分日；30 秒 timeout，缺 agent 目錄不報錯
  - 三個計數陷阱處理：Claude 以 `requestId|msgId` 去重（last-write-wins）、Codex 以 `last_token_usage` 逐 event 加總（不用 running total）、兩家 `input_tokens` 語意相反時正規化為 uncached / cached
  - 支援 7 / 14 / 30 天期間切換與 成本 / Token 分母切換（Swift Charts 堆疊長條）
  - `DailyUsageService` 60 秒記憶體快取，避免重複支付 `npx tsx` 冷啟動成本

#### 已知限制

- **Codex 成本待補**：`pricing.json` 尚未填入 Codex 價格，成本模式下 Codex 顯示「—」而非估算值（Token 模式正常顯示）
- **agy 未納入**：agy 本地 API 只提供剩餘額度 %，無 token 數據可聚合

---

### v0.9.0 — 2026-07-27

#### Added

- **Codex 接入審批流程**：Codex 透過 `.codex/hooks.json` + `pretooluse-codex.mjs` 走與 Claude Code 相同的檔案輪詢審批；CRITICAL 工具即時拒絕，其餘風險等級寫入 `pending_codex_<toolUseId>` 交付人工審查
- **Codex 帳號用量顯示**：menubar 讀取本地最新 Codex `token_count` event，popover 改為 Claude + Codex 雙 provider 版面
- **Codex per-agent auto 模式**：Codex 加入 30 分鐘 TTL 的自動放行開關，與既有 Claude Code / agy 開關並列
- **AGENTS.md**：Codex 面向的專案指南

#### Changed

- **hook 安全前綴新增 `sed`**：唯讀 sed 指令（如 `sed -n '1,80p' file`）自動放行，不再提示

#### Fixed

- **popover 高度**：pending 卡片高度公式改用具名常數並改為雙 provider 版面計算，修正多餘留白

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
