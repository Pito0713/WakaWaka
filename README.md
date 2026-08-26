# WakaWaka — Cost-Aware Approval for AI Coding Agents

> macOS menubar 守門員：攔截 Claude Code 與 Codex 的工具呼叫，顯示用量、評估操作風險，並讓你決定放行或拒絕。

---

## 專案介紹

AI coding agent 會代表使用者呼叫 shell、修改檔案或連接外部服務，但這帶來兩個問題：

1. **成本失控**：你不知道目前 rolling window 還剩多少用量，也不知道這次操作會消耗多少額度
2. **操作失控**：高風險指令（`sudo`、`git push --force`、`rm -rf`）會在你不注意時悄悄執行

WakaWaka 透過各 agent 的 **PreToolUse hook** 攔截本機工具呼叫，依風險分類後自動放行、立即拒絕或路由到 macOS menubar app 進行人工審批。目前已接通 Claude Code 與 Codex；agy hook 尚未接通，因此不列為支援中的審批來源。

### 核心功能

| 功能                 | 說明                                                                                                     |
| -------------------- | -------------------------------------------------------------------------------------------------------- |
| **Active Agents 面板** | popover 底部列出現在活著的 agent session：專案、branch、狀態、正在跑的工具或 skill。以 pid 判定存活而非時間新舊，崩潰的 session 會消失而不是繼續顯示。點一列即切換到該 agent 的終端機視窗；旁邊的刷新鈕強制重新檢查所有行程 |
| **懸浮 Agent HUD**   | 把上面那份清單拉出 popover：常駐置頂、不搶焦點的小視窗，不必點 menu bar 就知道誰在跑、誰卡住。`NSPanel` + `.nonactivatingPanel`，點一列直接跳該 agent 的終端機而不會先把焦點搶過來；位置與可見狀態記在偏好設定 |
| **三層風險分類**     | CRITICAL → HIGH → MEDIUM；各 agent adapter 採 fail-closed 策略，Codex 的 CRITICAL shell 操作會立即拒絕 |
| **Auto 模式**        | per-agent 開關；開啟後自動放行白名單 MEDIUM（Edit/Write/MultiEdit + 未知 bash），HIGH/CRITICAL 與 MCP 仍彈窗；30 分鐘 TTL + fail-closed 稽核（`~/.wakawaka/auto-audit.jsonl`） |
| **多代理支援**       | 同時守護 Claude Code 與 Codex，agent badge 顯示工具呼叫來源                                               |
| **Codex Usage**      | 從本機 Codex session 資料彙整 5h 與 weekly 用量，獨立於 Claude Code usage 顯示                            |
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
│                              ▲                               │
│  SessionStart / UserPromptSubmit / Stop / SessionEnd         │
│         └──► agent_<kind>_<sid>.json（活躍 agent 登記）      │
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
│  │  - ACTIVE AGENTS 面板（pid 驗證存活） │                   │
│  │  - 待審批佇列（agent badge 顏色區分）  │                   │
│  │  - 5h 用量進度條 + server 驗證綠點    │                   │
│  │  - diff 展開全文 toggle              │                   │
│  └──────────────────────────────────────┘                   │
│          ├──► FloatingAgentsPanel（常駐置頂 HUD，不搶焦點）  │
│          │ 點擊 agent 列                                     │
│          ▼                                                   │
│  AgentWindowFocus ──► tmux 原 session / Terminal.app         │
└──────────────────────────────────────────────────────────────┘
```

### 元件職責

```
cost-aware-approval/
├── hooks/
│   ├── pretooluse.mjs          # Claude Code PreToolUse hook（順帶寫 agent 心跳）
│   ├── pretooluse-codex.mjs    # Codex PreToolUse adapter
│   ├── agent-registry.mjs      # active-agents registry 共用模組（原子寫入、pid 解析）
│   ├── sessionstart.mjs        # session 開始 → 建立 registry 檔
│   ├── userpromptsubmit.mjs    # 使用者送出 → working（並記錄 slash command 名稱）
│   ├── stop.mjs                # 回合結束 → idle
│   └── sessionend.mjs          # session 結束 → 刪除 registry 檔
├── parser/
│   ├── usage-calculator.ts     # Token 用量計算（兩遍掃描 + global dedup）
│   ├── p90-detector.ts         # 歷史 peak 分析 → 方案上限自動估算
│   └── pricing.json            # Anthropic 定價表（手動維護）
└── app/WakaWaka/
    └── Sources/WakaWaka/
        ├── AppDelegate.swift       # 主控：1s 輪詢 + 60s session 刷新 + 10m /usage 校正
        ├── ContentView.swift       # 待審批佇列 UI（agent badge、展開全文）
        ├── AgentRegistry.swift     # registry 檔案格式、顯示模型、pid 存活判定
        ├── AgentRegistryService.swift # registry 讀取、pid 驗證、崩潰殘留清理
        ├── ActiveAgentsView.swift  # ACTIVE AGENTS 面板（popover 底部、控制列之下）
        ├── AgentWindowFocus.swift  # 點擊列 → 跳到該 agent 的終端機（tmux 原 session / Terminal.app）
        ├── FloatingAgentsPanel.swift    # 懸浮 HUD 的視窗控制：NSPanel、位置記憶、螢幕拔除時 clamp
        ├── FloatingAgentsView.swift     # 懸浮 HUD 內容（含 degraded 與 focus 失敗列）
        ├── FloatingAgentRow.swift       # 懸浮 HUD 單列
        ├── FloatingPanelModel.swift     # HUD 的 ObservableObject：hover 高亮與計時器不隨快照重建
        ├── FloatingPanelSizing.swift    # HUD 高度量測（量測副本鎖定要渲染的形態）
        ├── FloatingPanelLayout.swift    # HUD 版面常數與 clamp 規則
        ├── FloatingPanelPreferences.swift # HUD 可見狀態與透明度偏好
        ├── PopoverSizing.swift     # popover 高度：向 SwiftUI 量測，不用常數加總
        ├── SessionStatusView.swift # 5h 用量進度條 + 重置倒數 + server 驗證綠點
        ├── PopoverViewModel.swift  # UI 狀態管理（含 claudeUsageInfo、agyQuota）
        ├── AgyQuotaService.swift   # agy local language server quota 查詢（port 探測 + HTTP）
        ├── CodexUsageService.swift # Codex 5h / weekly 本機用量彙整
        ├── SettingsService.swift   # per-agent Auto Mode 設定與期限
        ├── ParserRunner.swift      # npx tsx bridge + claude /usage 呼叫
        └── Models.swift            # PendingData、UsageOutput、ClaudeUsageInfo、P90Result

~/.claude/settings.json             # Claude Code hook 配置（PreToolUse + 4 個 lifecycle）
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

## 測試

```bash
# Swift（menubar app）
cd cost-aware-approval/app/WakaWaka && swift test

# TypeScript parser
cd cost-aware-approval/parser && npx tsx --test *.test.ts

# Node hooks
node --test cost-aware-approval/hooks/*.test.mjs
```

### Swift 測試用 swift-testing，不用 XCTest

**不要把 `import Testing` 改回 `import XCTest`。** XCTest 隨 Xcode 一起安裝，而
`Testing.framework` 隨 Command Line Tools 一起安裝。本專案只需要 CLT 即可開發，
改用 XCTest 會讓沒裝 Xcode 的機器完全跑不了 `swift test`（症狀是
`error: no such module 'XCTest'`，且 `swift build` 正常、只有測試爆掉）。

對照表（若需手動遷移其他測試）：

| XCTest | swift-testing |
|---|---|
| `class X: XCTestCase` | `struct X` |
| `func testFoo()` | `@Test func foo()` |
| `XCTAssertEqual(a, b)` | `#expect(a == b)` |
| `XCTAssertTrue/False(x)` | `#expect(x)` / `#expect(!x)` |
| `XCTAssertNil/NotNil(x)` | `#expect(x == nil)` / `#expect(x != nil)` |
| `try XCTUnwrap(x)` | `try #require(x)` |
| `XCTFail("m")` | `Issue.record("m")` |
| `addTeardownBlock { … }` | `defer { … }`（無對應 API） |

一個行為差異值得注意：**swift-testing 預設平行執行測試**（XCTest 預設序列）。
會碰檔案系統的測試必須用各自獨立的路徑（本專案一律用 UUID 命名的暫存目錄）。

---

## 檔案路徑規範

所有 runtime 檔案統一存放於 `~/.wakawaka/`：

```
~/.wakawaka/
├── state/
│   ├── pending_<session_id>.json   # hook 寫入，等待審批
│   ├── decision_<session_id>.json  # app 寫入，hook 讀取
│   └── agent_<kind>_<sid>.json     # lifecycle hook 寫入，active agents 面板讀取（只存 metadata）
├── allowlist.json                   # 使用者自定義 MEDIUM 指令白名單
├── settings.json                    # per-agent Auto 模式開關與到期時間（app 寫、hook 讀）
├── auto-audit.jsonl                 # Auto 模式自動放行稽核紀錄
├── skins/<name>/                    # menu bar 圖示 frame set（2x PNG）
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

### Claude Code

Claude Code 使用相同三層名稱，但 adapter 的最終處置可能與 Codex 不同；例如部分 CRITICAL 操作會保留人工最終決定。修改政策時應同步更新 hook 的 regression tests，不要從 Codex 表格推論 Claude Code 的行為。

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

### v0.20.0 — 2026-08-19

懸浮 Active Agents HUD：把 popover 裡的面板拉成一個常駐置頂、不搶焦點的小視窗。對應 `floating-agents-panel-plan.md`。

#### Added

- **懸浮 Agent HUD**（`FloatingAgentsPanel` / `FloatingAgentsView` / `FloatingAgentRow` / `FloatingPanelModel` / `FloatingPanelSizing` / `FloatingPanelLayout` / `FloatingPanelPreferences`）：ACTIVE AGENTS 面板只存在於 popover 內，要看一眼就得先點 menu bar 圖示。多個 agent 並行時，使用者真正要的是**不必動手**就知道誰在工作、誰卡住。從 popover footer 的 `macwindow.on.rectangle` 開關，位置以 `setFrameAutosaveName` 記住，螢幕拔除時 clamp 回可見範圍。
- **視窗是 `NSPanel` + `.nonactivatingPanel`，不是 `NSWindow`**。本 app 以 `.accessory` 執行，一般視窗要接得到點擊必須先 `NSApp.activate`（`UsageDashboardWindow` 就是這樣，對主動開啟的儀表板是對的）。但 HUD 點一列的語義是「跳到那個 agent 的終端機」，先啟動 WakaWaka 會讓焦點彈兩次，還會踢掉使用者正在打字的視窗。這是整個設計唯一可能被推翻的假設，因此獨立成第一階段先驗證；變異測試證明該測試有效（把 `show()` 換成 `NSApp.activate + makeKeyAndOrderFront`，測試確實轉紅）。
- **相對時間用 `Text(_, style: .relative)`，不自行計算字串**：閒置 agent 的心跳不會變，快照比較相等就不會重新發布，手算的標籤會永遠停在「3 秒前」而實際上已過了十分鐘。
- **HUD 不會因為沒有 agent 就自己隱藏**。會消失的視窗讓「沒有 agent 在跑」與「HUD 壞了」無法區分——與 `SourceStatus` 存在的理由相同。讀取 registry 失敗時，原因佔一整列顯示。
- **點擊失敗的原因也顯示在 HUD**。popover 早就會說明為什麼抬不起終端機（agent 已結束、沒有 tty、終端機無法從外部驅動），HUD 原本把訊息丟掉，於是點下去既沒反應也沒說明，讀起來像面板壞了而不是跳轉失敗。訊息會改變視窗高度，所以先寫入再重新量測——設定了卻不重算，那行「用來解釋失敗的字」自己會被裁掉。
- **透明度三段**，右鍵選單切換。

#### Changed

- **HUD 從三形態（dot / compact / expanded）收斂成單一形態**。形態會在游標底下切換，等於移動使用者正要點的那幾列。現在固定 300pt 寬、只畫明細列，hover 只上高亮。收合用的 dot 消失後，header 的控制項語義從「縮小」改為「關閉」，並且走 `setFloatingPanelVisible` 而非 `hide()`——否則偏好仍是啟用，下次啟動面板又會自己回來，而 popover 的開關卻顯示它是開著的。釘選只為了鎖住形態不被 hover 展開而存在，跟著 hover 行為一起移除。淨 −249 行。

#### Fixed

- **HUD 量測用的形態與實際渲染的形態不一致**（獨立審查發現）：高度取自 live model、寬度取自請求的形態。compact 被 hover 成 `.expanded` 時因此要了 300pt 的寬、卻量了背後 compact 的列——三個 agent 的情況短 48pt，hover 想露出的列反而被裁掉。`FloatingPanelSizing` 本來就有守衛（量測副本鎖定請求的形態），但 controller 為了把 `focusError` 算進高度另外寫了一份量測，修了 A 的同時把擋 B 的守衛拆掉。現在量測副本自己帶 `focusError`，量測路徑只剩一條。同一次修正也處理釘選只保留旗標、不保留螢幕上形狀的問題（釘選一個 hover 展開的面板會把它收回儲存的 compact 偏好，與「釘選目前形態」的承諾相反）。
- **點擊列開出來的 Terminal 視窗以指令命名**：標題是 `tmux attach-session -t wakawaka-<token>-view-0 …`，兩半都沒有意義——token 是 per-install 的 UUID 前綴，同一台機器每個視窗都一樣；尾碼是面板從不顯示的 tmux pane id。開個幾扇視窗就分不出哪扇裝著哪個 agent。改為顯示專案與 agent 種類。種類不是裝飾：回報者有兩列都叫 WakaWaka，一個 Claude Code、一個 Codex，光看專案分不開。這是第一份進到 AppleScript 的外部文字，因此套用與指令相同的字面值檢查；不安全的目錄名退回只顯示種類，而不是讓跳轉失敗——**到得了終端機比標得漂亮重要**。
- **`start.sh` 只在 binary 不存在時才 build**，所以改完 code 跑 `./start.sh` 會重新啟動舊的執行檔，app 與已提交的原始碼默默不一致——懸浮 HUD 一度看起來「沒做出來」，其實只是跑著的行程比它還舊。改為比較 `Sources/**/*.swift` 與 `Package.swift` 的最新 mtime 和 binary 自己的 mtime，binary 較舊就重建；測試檔不列入比較（不會進到 app binary）。`--build` 的語義從「要不要 build」變成「跳過這個比較」。過程中繞開三個在 `set -euo pipefail` 下會直接中止腳本的 shell 陷阱：`sort -rn | head -1` 會讓 sort 收到 SIGPIPE、`find` 掃不存在的路徑回傳非零、全形括號緊接在 `$BUILD_REASON` 後面會被吃掉第一個位元組當成變數名的一部分。

---

### v0.19.0 — 2026-08-17

Active Agents 面板的三個修正：補登記漏掉的 session、重用已經開著的視窗、把 Codex 與 Claude Code 分開。

#### Added

- **`upsertEntry` 會為沒被 `SessionStart` 登記過的 session 補建 entry**。原本只有 `SessionStart` 會建檔，其餘 hook 一律只更新不建立——hook 安裝前就開著的視窗，或是 entry 被清掉但視窗還活著的 session，從此再也不會出現在面板上，刷新鈕也救不了（reader 只能顯示存在的檔案）。補建走的是與 `SessionStart` 完全相同的建構路徑。原本反對補建的理由是「補出來的 entry 沒有 pid 與啟動時間，會留下存活判定永遠退不掉的殭屍列」，但那只對盲目 update 成立，對從 hook 自己的行程鏈建出來的 entry 不成立。
- 補建刻意不放在審批路徑上：`PreToolUse` 仍然只更新不建立（解析 pid 要跑好幾次 `ps`，而該 hook 跑在每一次審批決策之前），`Stop` 同理——否則一個晚到的 `Stop` 會把已經 `SessionEnd` 的 session 重新放回面板。

#### Fixed

- **Codex session 全被歸類成 Claude Code，面板從來沒顯示過任何 Codex 列**。Codex 的 hook payload 不指名 agent，session id 的拼法也與 Claude Code 一模一樣，`detectKind` 於是落到最弱的那條規則。判別依據改用 transcript 路徑：Codex 的 transcript 在 `~/.codex`、Claude Code 在 `~/.claude`——那是執行中 agent 的**性質**，而不是它自己選擇要送的欄位，而且不需要改 `.codex/hooks.json`。後者比看起來重要：先前試過在該檔用環境變數標記 agent 並實測，Codex 會為每個 hook 註冊存一份 trust hash，指令一旦改變就靜默跳過該註冊——六個 hook 全部停止執行。`detectKind` 仍然接受 `WAKAWAKA_AGENT`，但排在明確的 payload 欄位之後：環境變數會被繼承，一個忘了 unset 的 shell 不該把已經指名自己的 session 改判到別的 agent 名下。payload 形狀取自 codex-cli 0.147.0 實測，非推測。
- **已經在看的 pane 會再開一扇視窗**：點任何一列都無條件建立 grouped tmux 檢視 session 與新的 Terminal 視窗，於是點一下你正在看的那個 agent，會得到兩扇顯示同一件事的視窗。`focus()` 現在先問「有沒有哪個已連線的 client 正在顯示這個 pane 所屬的 window」，有就抬起它的分頁。比對用 window id 而非 session：grouped session 共用 window，使用者自己的連線與它的檢視顯示的是同一個 pane。停在別的 window 上的 client **刻意不算命中**——切過去會搬動使用者正在看的東西，而那正是這個功能寧可自己開視窗也不用 `switch-client` 的原因。若該 client 位於無法驅動的終端機（iTerm、VS Code），仍照舊開檢視視窗。

#### Changed

- **ACTIVE AGENTS 面板從 popover 頂端移到底部**，位於控制列之下，並自己畫上分隔線。

---

### v0.18.0 — 2026-08-14

Active Agents 面板可互動：點一列切到該 agent 的終端機，旁邊的刷新鈕強制重新檢查存活。連同 popover 版面的修正。

#### Added

- **點擊 agent 列開啟它的終端機視窗**。pid 到視窗不是一跳就到：tmux 裡的 agent 與 pane 共用 tty，而那個 pane 只有在有 client 連著時才在螢幕上——要抬起的視窗屬於 client 而非 agent。`AgentWindowFocus.swift` 處理兩跳，支援 tmux 與 Terminal.app；其他終端（含 VS Code 內建面板）沒有可靠的外部聚焦 API，會明說不支援而非靜默失敗。
- **面板刷新鈕**：面板本來就每秒更新，但新鮮的 entry 會跳過 pid 檢查（60 秒寬限期），所以崩潰的 agent 最多殘留一分鐘。刷新強制驗證每個行程，跳過寬限期。
- **`PopoverSizing`**：popover 高度改為向 SwiftUI 量測（`NSHostingView.fittingSize`）。抽成獨立型別是為了能對真的 `NSPopover` 斷言 `contentSize`——在 `AppDelegate` 裡量 `ContentView` 的測試，改回常數加總照樣會綠。

#### Fixed

- **popover 高度沒算進 ACTIVE AGENTS 面板**，底部的 Auto 列與用量條被裁掉；而且只在待審批佇列變動時重算，agent 變動時不會。手估常數已連續錯兩次（面板整個漏算；footer 實際 132pt 但常數寫 120），無 agent 時兩個誤差恰好抵消所以第一次沒被發現——改為量測後這類誤差不可能再發生。
- **有 agent 時 PacMan 動畫被換成一行文字**。理由是「agent 在跑還顯示 PacMan 會矛盾」，但那是實作者的判斷，不是使用者要的。已無條件恢復。
- **用量條貼底**：footer 下緣 padding 10 → 16。

以下由 Codex 對照驗證後找出（0 BLOCKER、2 HIGH、4 MEDIUM、2 LOW，全數為真）：

- **點擊會搶走使用者當前 tmux 畫面**。第一版用 `switch-client`，那會搬動使用者正坐著的 client。改用 grouped session 後仍然只對了一半：current-window 是 per-session（安全），但 **active pane 是 window 的屬性**，grouped session 共用 window——實測 `select-pane` 會改到別人的鍵盤焦點，tmux 的 `active-pane` client flag 也擋不住。因此不再選 pane：新視窗開在該 agent 的 tmux window 上，pane 看得見但不奪焦。
- **3 秒逾時永遠不會觸發**：`readDataToEndOfFile()` 等的是 EOF，而 EOF 通常在子行程結束才來，所以卡住的 `tmux` / `osascript` 會永久佔住一個 worker。改為背景排空 + 獨立等待逾時。
- **pid 回收可能開到無關行程的視窗**：列最多 60 秒未經 pid 驗證。`ActiveAgentRow` 補上 `pidStartedAt`，點擊當下重新驗證身分。
- **tmux 失敗被當成成功**：`do script` 只證明 Terminal 收下了字串，不代表指令成功。grouped session 改為先以 argv 建立並驗證再 attach；重用路徑也檢查回傳值。
- **檢視用的 session 名稱可能撞到使用者自己的 session**：改用 per-install token 命名，並加上 `@wakawaka-view` 擁有權標記，重用或刪除前都必須驗證。
- **focus 失敗訊息會改變版面卻不重算高度**——與上面同一類缺陷，訊息本身可能被裁掉。
- **手動刷新可能以較舊的快照覆蓋較新的輪詢結果**：加入 generation 守衛。
- **讀檔與刪檔之間 agent 若重新註冊，會刪掉活的檔案**。後果是永久的：lifecycle hook 只更新不建立，該 session 到重啟前都不會再出現。改為刪除前比對 modification date。

---

### v0.17.0 — 2026-08-14

對應 `active-agents-plan.md` 全部七個階段。popover 頂端新增「ACTIVE AGENTS」面板，顯示現在有哪些 agent session 活著、在做什麼。

#### Added

- **Agent registry（`hooks/agent-registry.mjs` + 四個 lifecycle hook）**：`SessionStart` / `UserPromptSubmit` / `Stop` / `SessionEnd` 各寫一個 `~/.wakawaka/state/agent_<kind>_<session>.json`，`PreToolUse` 順帶更新心跳。原子寫入（temp + rename）、權限 0600、帶 schema 版本。
- **以 pid 判定存活，而非以時間新舊**：崩潰的 agent 留下的檔案與「活著但閒置」完全一樣，靠 heartbeat 時間永遠分不出來——舊設計會把幾週前的 session 顯示成執行中。改為 `kill(pid,0)` 加上比對行程啟動時間（pid 會被回收，光是活著不算證據）。
- **`ActiveAgentsView`**：每列顯示專案、branch、狀態燈、最後工具或執行中的 skill、心跳時間。完整路徑只放 tooltip。最多 5 列，其餘顯示「+N more」。
- **面板永不靜默失敗**：讀不到狀態目錄時顯示原因，而不是顯示成「沒有 agent 在跑」——後者與正常空面板無法區分。
- **`WAKAWAKA_INTERNAL=1` 自我遞迴防護**：app 自己 spawn 的 parser / `claude -p` 不得被登記成 agent。

#### Fixed

以下由 Codex 對照驗證後找出（0 BLOCKER、4 HIGH、5 MEDIUM、2 LOW；其中 1 條 HIGH 經驗證為誤報）：

- **pid 起始時間讀不到時永久信任**：一個死掉的 session 只要 pid 被任何行程回收，就會永遠留在面板上——正是 pid 檢查本身要防的失效。改為 `alive` / `gone` / `unverifiable` 三態，無法證明身分的只信任到 `staleThreshold`（30 分）為止。該常數原本宣告了卻從未被使用。
- **`start.sh` 會刪掉第三方 hook**：比對用的是 script basename 子字串，而 `stop.mjs`、`sessionend.mjs` 這種名稱極易碰撞——一個位於 `/opt/security-audit/stop.mjs` 的無關 hook 會連同整個 entry 被移除。改為比對 repo 相對路徑，並逐一過濾 hook 而非整筆刪除，同 entry 的其他 hook 得以保留。
- **`settings.json` 解析失敗會被整檔覆寫**：任何讀取或 JSON 錯誤都走 `cfg = {}` 再寫回，等於用 WakaWaka 的五個 hook 取代使用者全部設定。改為中止並回報，且改用 temp + rename 原子寫入。
- **狀態目錄讀取失敗被當成「沒有 agent」**：`.unavailable` / `.permissionDenied` 在正式路徑從未被建構過，前述「永不靜默失敗」的設計實際上是空的。目錄列舉的錯誤現在會傳進 snapshot。
- **`tool_input.skill` 未經驗證就落地**：該值由模型撰寫且無長度限制，違反 registry「只存 metadata」的承諾。改為套用與 slash command 相同的識別字文法。
- **popover 高度沒算進新面板**：底部的 Auto 列與用量條被裁掉；且高度只在待審批佇列變動時重算，agent 變動時不會。改為以 `NSHostingView.fittingSize` 實際量測（手估常數每列短 2pt），並在 snapshot 變動時觸發重算。
- **`SourceStatus.ok` 帶著掃描時間戳**：整個 snapshot 是 `Equatable`，這使每次輪詢都比較不相等，面板每秒重新發布與重新排版一次。該欄位無人讀取，已移除。
- **registry 檔案讀取無防護**：加入 regular-file 檢查與 64KB 上限——輪詢跑在主執行緒，一個 fifo 會直接卡死整個 app。

#### Changed

- `parentOf(pid)` 更名為 `procInfo(pid)` 並回傳 `{ppid, comm}`。原本回傳 `{pid: 父pid, comm: 該 pid 自己的 comm}`，兩個欄位描述不同行程卻都叫 `parent`——驗證時雙方都據此誤判邏輯有錯並「修正」成真正的 bug，行程樹測試才揭穿。原邏輯正確，改的是命名。

---

### v0.16.0 — 2026-08-12

對應 `phase-usage-plan.md` 階段 4（Swift 模型與服務）與階段 5（儀表板 UI）。至此該計畫書五個階段全部完成。

#### Added

- **儀表板新增「活動分佈」分頁**：把每次 API 呼叫分入 理解／開發／驗證／回覆／其他 五桶並顯示佔比。依計畫書 §9 規格：未分類比例超過 25% 時頂端顯示紅字警告（**數字仍然顯示**，只是明標不可信）、三指標（Output／次數／成本）可切換、下方列出未分類明細與被排除的記錄筆數。無 leaderboard、無評分、無紅綠門檻。
- **`PhaseUsage.swift` / `PhaseUsageService.swift` / `PhaseUsageView.swift`**：模型、載入服務（60 秒快取、三態，與 `DailyUsageService` 一致）與檢視。活動分佈分頁**首次開啟才載入** —— 它需要讀取 message content 而非僅用量欄位，比每日用量慢。
- **`ParserRunner.runPhaseUsage(days:)`**：逾時 60 秒（每日用量為 30 秒），理由同上。
- **測試 fixture 採用真實 parser 輸出**（`phase-usage-sample.json`）而非手寫 JSON：只餵過假 JSON 的 Codable 模型會與 parser 悄悄脫節而無人察覺。

#### Fixed

- **慢的載入會覆寫使用者已切換的選擇**：30 天查詢可能耗時近一分鐘，完成後仍會蓋掉使用者已切回的 7 天內容，畫面與 picker 不一致。加入 generation 守衛。**`DailyUsageService` 有同一個既有缺陷**（新服務即照抄自它），一併修正。
- **bar 長度與旁邊百分比使用不同尺度**：bar 原本對「最大桶」正規化、百分比對「總和」，導致最大的桶永遠看起來像 100%。改為共用同一尺度。原本的理由是讓小桶保持可見，但那是拿誠實換易讀。
- **部分計價被重新正規化成 100%**：若某桶有價、另一桶無法定價，有價者會顯示 100%。改為**任一桶無法計價時不發布任何佔比**，只顯示已知金額並說明原因，與 parser 端「不以部分金額充當總額」的規則一致。
- **parser 的 caveats 解碼後從未顯示**：`warnings`（含 cache read 使 session 後段階段系統性偏貴）與 `pricingAsOf` 都已解碼卻沒有呈現，等於把計畫書 §3／§12 要求的限制留在看不見的 JSON 裡。已顯示於圖表下方。
- **subagent 佔比未標示單位**：該值固定以 output 計算，切換到「次數」或「成本」時會被誤讀為當前指標的佔比。已明確標為 output share。

---

### v0.15.2 — 2026-08-12

#### Fixed

- **hook 測試逾時變數名稱錯誤，導致整份 suite 卡 9 分 50 秒**：`pretooluse-smart.test.mjs` 設 `POLL_TIMEOUT_MS`，但**沒有任何 hook 讀取這個變數**，實際生效的是 `FINAL_TIMEOUT_MS` 的正式預設值。決定檔沒等到時，本該只有該題失敗，卻變成整份 suite 停擺。改用 hook 真正讀取的 `WARN_TIMEOUT_MS` / `FINAL_TIMEOUT_MS`。
- **hook 測試直接讀寫真實 `~/.wakawaka/`**：測試結果取決於 auto mode 當下是否生效、以及 WakaWaka 是否在執行（「預期 defer」會拿到 `allow`），並且會在 live state 目錄留下 `decision_test-*.json` 讓執行中的 app 誤判。改為每個測試獨立的暫存 root，並新增防迴歸守衛測試，任何覆寫遺漏都會當場被抓到而非污染使用者環境。
- **`Edit` / `Write` 的「auto allow」測試是假的**：它們靠讀取使用者真實的 auto mode 設定才通過。hook 其實刻意將這兩個工具排除在免審批清單外，好讓使用者能先審視檔案變更；auto mode 開啟的情境另有正確覆蓋。改為斷言真正的契約 —— auto mode 關閉時必須進審批。
- **`Stop` hook 斷言與現況不符**：`d84ba00` 刻意移除 Stop 掛載，但兩個測試仍斷言其存在，永久紅燈。改為對照該 config 現存的另一個 hook，保留「掛載某個 hook 不會弄丟其他 hook」的原意。

#### Changed

- **`pretooluse.mjs` / `pretooluse-agy.mjs` 補上 `WAKAWAKA_STATE_DIR` 與 `WAKAWAKA_ALLOWLIST_PATH` 覆寫**：`permissionrequest-codex.mjs` 早已支援，另兩支寫死 `os.homedir()`。未設定變數時行為完全不變。

結果：hook 測試 62/70（且會卡死）→ **71/71，20 秒**，連續執行結果一致，不再碰觸 live 環境。

---

### v0.15.1 — 2026-08-12

#### Changed

- **Swift 測試改用 swift-testing，不再依賴 XCTest**：XCTest 隨 Xcode 安裝，`Testing.framework` 隨 Command Line Tools 安裝。本專案只需 CLT 即可開發，但既有測試 `import XCTest`，在沒裝 Xcode 的機器上 `swift test` 直接失敗（`no such module 'XCTest'`；`swift build` 正常，只有測試爆掉）。20 個測試全數遷移，`swift test` 不需任何旗標即可執行。
- **`addTeardownBlock` 改為 `defer`**：swift-testing 無對應 API。另注意 swift-testing **預設平行執行**（XCTest 預設序列），會碰檔案系統的測試改用各自獨立的 UUID 暫存目錄。README 新增「測試」章節，含遷移對照表與「不要改回 XCTest」的說明。

---

### v0.15.0 — 2026-08-12

對應 `phase-usage-plan.md` 階段 2（共用掃描模組）與階段 3（活動分佈報表主體）。

#### Added

- **`parser/transcript-scan.ts`**：JSONL 探索、逐行讀取、dedup key 與 `TranscriptDedup` 去重累加器的單一實作，取代原本散在 `daily-usage.ts` 與 `usage-calculator.ts` 的兩份副本（`phase-usage` 會是第三份）。勝出者以 `(timestamp, 檔案, 行號)` 決定，平行讀檔不再影響結果。
- **`parser/phase-usage.ts` + `phase-scan.ts` + `phase-classify.ts` + `tool-phases.json`**：把每次 API 呼叫分入 理解／開發／驗證／回覆／其他 五桶。歸屬單位為 `(requestId, message.id)`：usage 取最新一筆，**工具內容取所有同鍵記錄的聯集** —— 早期 streaming 寫入尚未產生 tool_use block，只取單筆會讓約 80% 的量誤落「回覆」桶。輸出 `calls` / `output` / `costUSD` 三個並列指標，並附警語說明 output token 衡量的是生成量而非工作量。
- **`parser/shell-split.ts`**：從 `bash-classify.ts` 抽出的 shell 詞法層（切段、tokenize、heredoc、redirect 偵測），兩檔案皆回到 300 行規範內。

#### Fixed

- **`bash-classify` 丟棄一行式 `if` / 迴圈內的指令**：`if true; then pytest; fi` 會被切出 `then pytest` 段落，前一版把 `then` 當標點整段跳過，`pytest` 完全消失。改為剝除關鍵字後分類其後的指令。
- **`node app.js --test` 誤判為 verify**：`--test` 屬於被執行的腳本而非 runtime。改為只認第一個位置參數之前的旗標。
- **管線寫入的診斷 head 指向錯誤對象**：`printf x | tee out` 原本回報 `printf`，使 `echo` 之類的讀取指令佔據 `unknownBash` 榜首、誤導排查方向。改為指向實際寫入的段落。
- **`TranscriptDedup` 對 NaN timestamp 排序不對稱**：無效 timestamp 先到就再也無法被有效者取代。改為有效 timestamp 一律優先，構成全序。

#### 驗收

實測近 14 天：五桶守恆精確成立，`unknownRate` 15.9%（計畫書門檻 25%），992/992 全部可計價，重複執行結果一致。對照計畫書 §2 記錄的 v1 狀態（understand 2.7%、other 41.6%），三項必要條件皆達成。

---

### v0.14.0 — 2026-08-12

對應 `phase-usage-plan.md` 階段 0（逐模型定價）與階段 1（Bash 活動分類），兩者可獨立於後續階段出貨。

#### Added

- **`parser/pricing.ts`**：`daily-usage.ts` 與 `usage-calculator.ts` 共用的定價模組。兩條硬規則：未知模型一律回 `null`、**絕不** fallback 到任何預設費率（有把握的錯數字比缺數字更糟）；cache write 依 TTL 分開計價。定價表支援 `after` 生效日，逐日報表會依當日採用正確費率，介紹價到期不需人工改檔。
- **`parser/bash-classify.ts`**：把 Bash 指令分類為 `understand` / `verify` / `other`。切 shell chain（`&&`／`||`／`;`／`|`）、剝除包裝（`cd x &&`、`env A=b`、`sudo`、`npx`、`python -m`）、取最高優先序段落。舊的「取首個 token」規則失效，因為實測 64 筆未分類指令有 60 筆以 `cd` 開頭。判不出來一律落 `other` 並記錄 head token 供 `unknownBash` 診斷 —— 誠實的缺口可被回報並修補，猜測則不能。真實資料未分類率由 63.6% 降至 21.1%。

#### Fixed

- **成本估算對所有模型套用同一組 Sonnet 4.6 費率**：近 14 天有 96% 的 API call 不是 sonnet-4-6，儀表板與 popover 的每一個金額都是錯的。改為逐模型計價後，實測 14 天成本由 $96.91 修正為 $183.05（原本**低估 88.9%**）。此問題早於本次功能，非新引入。
- **cache write 一律以 5 分鐘費率計價**：官方 1 小時 TTL 為 input 的 2 倍、5 分鐘為 1.25 倍，而本機 84% 的 cache-creation token 是 1 小時。改為讀取 `usage.cache_creation` 的 TTL 明細分別計價；缺明細的舊 transcript 落回較便宜的 5m 費率（寧可低報也不灌水）。`cache_creation_input_tokens` 視為權威總額，兩個 TTL 分項恆等於它，避免損壞資料產生超額或負值成本。
- **Sonnet 5 採用尚未生效的標準價**：介紹價 $2/$10 適用至 2026-08-31，原本寫死 $3/$15，該模型用量在介紹期內高估 50%。
- **部分可計價的區間回傳看似完整的金額**：只要當日／當前 bucket 有任一模型無法計價，`costUSD` 一律回 `null`。回報「已計價的那一份」會是一個看起來權威的低報數字，而 UI 無從分辨。token 數仍照常回報，另輸出 `pricedCalls` / `totalCalls` / `unpricedModels` 標示缺口大小。
- **跨檔 dedup 結果取決於 I/O 完成順序**：`computeGlobalSession()` 平行讀檔後以 last-write-wins 覆寫，同一份資料重跑可能得到不同的 5h 用量與成本。改為依 timestamp 排序，同秒則以 `檔案:行號` 穩定 tie-break。
- **`<synthetic>` 佔位列被計入用量**：該類記錄帶 usage 欄位但從未實際計費，現已排除於 token 與成本之外。
- **`computeGlobalSession()` 註解稱 fixed-boundary**：實作其實是 `now − 5h` 的 sliding window，與 `calculateUsage` 一致，與 `p90-detector` 不同。註解已更正。

---

### v0.13.1 — 2026-08-07

#### Fixed

- **`start.sh` 自動還原 menubar skin**：新增 Step 2，啟動時若 `~/.wakawaka/skins/arcade/idle_0.png` 不存在就從 repo 複製一份（判準與 `SkinManager` 認定 skin 是否存在的條件一致）。此步排在重啟之前，首次安裝同一次執行即可載入。原本這是 `skins/README.md` 裡的手動指令，家目錄一被清掉就會退回內建繪製圖示。採 `cp -Rn`（no-clobber）：基準幀缺失但其他檔仍在時只補缺的檔，不覆寫使用者改過的圖。
- **`start.sh` 在缺少 skin 來源時會中斷**：警告訊息中全形逗號緊接變數（`$SKIN_SRC，`），bash 會將逗號首個 byte 併入變數名，`set -u` 下觸發 unbound variable 而非正常 warn。改用 `${SKIN_SRC}` 界定。

---

### v0.13.0 — 2026-08-03

#### Added

- **auto mode 開放 claude-in-chrome 唯讀 + loopback**：auto mode 下，`mcp__claude-in-chrome__*` 若同時滿足「名稱含讀取動詞」「名稱不含任何寫入動詞」「`tool_input` 內每個 URL 都是 loopback（`localhost` / `*.localhost` / `127.x.x.x` / `::1`，限 http(s)、不接受帶帳密）」則免審批放行；其餘 MCP 一律維持人工審批。採動詞比對而非硬編 tool 名單，不認得的名稱因缺少讀取動詞而 fail-closed 落回 popover。找不到 URL（例如對當前分頁操作）同樣不放行。

#### Fixed

- **auto 審計紀錄補上 URL**：`appendAutoAudit()` 原本只從 `command` / `file_path` 取 summary，MCP 兩者皆無會記成 `unknown`；改為 fallback 抓取 `tool_input` 中的 URL，自動放行的紀錄事後可查。

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

- ~~**Codex 成本待補**~~：已於 2026-08-25 補入 GPT-5.6 Sol 官方促銷 API 費率；儀表板顯示等值 API 成本估算，不代表訂閱帳單
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
