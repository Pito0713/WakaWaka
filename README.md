# WakaWaka — Cost-Aware Approval for Claude Code

> macOS menubar 守門員：在 Claude Code 執行任何工具前，顯示 token 用量、評估操作風險，並讓你決定放行或拒絕。

---

## 專案介紹

Claude Code 預設會自動執行所有工具（Bash、Edit、Write、WebFetch…），但這帶來兩個問題：

1. **成本失控**：你不知道目前 5 小時用量窗口還剩多少 token，也不知道這次操作會燒掉多少
2. **操作失控**：高風險指令（`sudo`、`git push --force`、`rm -rf`）會在你不注意時悄悄執行

WakaWaka 透過 Claude Code 的 **PreToolUse hook** 機制攔截每一個工具呼叫，路由到 macOS menubar app **WakaWaka** 進行人工審批，同時即時顯示 5h rolling window 的 token 用量與費用估算。

### 核心功能

| 功能 | 說明 |
|------|------|
| **三層風險分類** | CRITICAL（自動拒絕）→ HIGH（強制彈窗）→ MEDIUM（可設定 allowlist） |
| **Token 用量追蹤** | 從 `~/.claude/projects/` JSONL 解析，全域合併去重，誤差 < 3% |
| **5h 配額進度條** | 對應 Claude 實際 rate limit 窗口，含重置倒數計時 |
| **P90 自動校準** | 分析歷史 session peaks，估算你的方案上限（誤差 ~0.1%） |
| **審批計時器** | 8 分鐘警告 → 9m50s 自動拒絕，不讓 hook 無限等待 |
| **Session 歷史紀錄** | 每分鐘寫入 `~/.wakawaka/session-log.jsonl`，可回測準確度 |

---

## 系統架構

```
┌─────────────────────────────────────────────────────────────┐
│                     Claude Code（使用者端）                   │
│                                                             │
│  Claude AI ──tool call──► PreToolUse Hook                  │
│                              pretooluse.mjs                 │
│                              │                              │
│                              │ write pending_<sid>.json     │
│                              ▼                              │
│                    ~/.wakawaka/state/                      │
│                              │                              │
│                              │ poll decision_<sid>.json     │
│                              ▼                              │
│              exit 0 (allow) / exit 2 (deny)                │
└─────────────────────────────────────────────────────────────┘
                         ▲              │
              read state │              │ write decision
                         │              ▼
┌─────────────────────────────────────────────────────────────┐
│                  WakaWaka（menubar app）                    │
│                                                             │
│  ┌──────────────┐   ┌──────────────────────────────────┐   │
│  │  AppDelegate  │   │        Parser（TypeScript）       │   │
│  │  - 1s poll    │   │  usage-calculator.ts             │   │
│  │  - 60s fetch  │◄──│  - JSONL 兩遍掃描 + 去重         │   │
│  │  - P90 detect │   │  - Global unified timeline merge │   │
│  └──────────────┘   │  p90-detector.ts                 │   │
│          │          │  - 歷史 peak 分布 → 方案上限估算  │   │
│          ▼          └──────────────────────────────────┘   │
│  ┌──────────────────────────────────┐                      │
│  │  PopoverViewModel + ContentView  │                      │
│  │  - 待審批佇列（多 session 支援）   │                      │
│  │  - 5h 用量進度條 + 倒數           │                      │
│  │  - Ghost icon 動畫               │                      │
│  └──────────────────────────────────┘                      │
└─────────────────────────────────────────────────────────────┘
```

### 元件職責

```
cost-aware-approval/
├── hooks/
│   └── pretooluse.mjs          # PreToolUse hook：攔截 → 等待審批 → 回傳決策
├── parser/
│   ├── usage-calculator.ts     # Token 用量計算（兩遍掃描 + global dedup）
│   ├── p90-detector.ts         # 歷史 peak 分析 → 方案上限自動估算
│   └── pricing.json            # Anthropic 定價表（手動維護）
└── app/WakaWaka/
    └── Sources/WakaWaka/
        ├── AppDelegate.swift       # 主控：1s 輪詢 + 60s session 刷新 + P90 偵測
        ├── ContentView.swift       # 待審批佇列 UI
        ├── SessionStatusView.swift # 5h 用量進度條 + 重置倒數
        ├── PopoverViewModel.swift  # UI 狀態管理
        ├── ParserRunner.swift      # 以 Process 呼叫 `npx tsx` 執行 TypeScript parser
        └── Models.swift            # PendingData、UsageOutput、P90Result 資料模型
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
      └─► Pass 2：Fixed-boundary 5h window scan（與 Claude server 邏輯相同）
              └─► sessionOutput / planLimit = 用量百分比
```

---

## 使用技術

### Hook（`hooks/`）

| 技術 | 版本 | 用途 |
|------|------|------|
| **Node.js** | v20.14.0 | hook runtime |
| **ES Modules** (`.mjs`) | — | 無需 build，直接執行 |
| `node:crypto` | — | `randomUUID()` 產生 session ID |
| `node:fs` / `node:path` / `node:os` | — | 檔案輪詢 IPC（無 socket） |

### Parser（`parser/`）

| 技術 | 版本 | 用途 |
|------|------|------|
| **TypeScript** | 5.x | 型別安全的 JSONL 解析器 |
| **tsx** | v4.22+ | 零設定直接執行 `.ts`（無需 `tsc` 編譯） |
| Node.js `readline` | — | 串流逐行讀取大型 JSONL |
| Node.js `fs.createReadStream` | — | 非阻塞檔案讀取 |
| `Promise.all` | — | 多檔案平行讀取 |

### macOS App（`app/WakaWaka/`）

| 技術 | 版本 | 用途 |
|------|------|------|
| **Swift** | 5.9 | 主要語言 |
| **SwiftUI** | macOS 14+ | 宣告式 UI |
| **AppKit** (`NSStatusBar`) | — | menubar status item |
| **UserNotifications** | — | 80% / 95% 用量警告推播 |
| **Swift Package Manager** | — | 無第三方依賴，純原生 build |
| `Process` + `Pipe` | — | 從 Swift 呼叫 `npx tsx`（bridge） |
| `DispatchQueue` | — | 背景 I/O + serial log queue |
| `UserDefaults` | — | 持久化方案上限、手動校準值 |

### IPC 機制

| 機制 | 說明 |
|------|------|
| **File-based polling** | Hook 寫 `pending_<sid>.json`，App 每 1s 讀取，App 寫 `decision_<sid>.json`，Hook 輪詢 |
| **Tombstone pattern** | Hook 超時時標記 `hookExited:true`（而非刪除），App 顯示「已逾時」讓使用者手動清除 |
| **Session log** | App 每 60s 寫入 `~/.wakawaka/session-log.jsonl`（append-only via serial queue）|

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

| 等級 | 行為 | 範例 |
|------|------|------|
| **CRITICAL** | 自動拒絕，不彈窗 | `rm -rf /`、`curl \| sh`、`dd of=/dev/disk0` |
| **HIGH** | 強制彈窗（無法 allowlist 略過）| `sudo`、`git push --force`、`chmod`、`kill` |
| **MEDIUM** | 彈窗，可加入 allowlist | 一般 Bash 指令 |
| **Auto-allow** | 靜默放行 | `Read`、`Edit`、`Write`、`WebSearch` 等唯讀操作 |
