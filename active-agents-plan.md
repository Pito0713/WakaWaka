# 計劃書：Popover 活躍 Agent 與 Skill 面板

> 狀態：**v3 — 架構定案（heartbeat registry），待實作**
> 對象：WakaWaka menu bar app（`cost-aware-approval/app/WakaWaka`）
> 建立 2026-08-08 ｜ v2 納入 Codex 對抗式評估 ｜ v3 改採 heartbeat 架構

---

## 版本沿革

| 版本 | 架構 | 結果 |
|------|------|------|
| v1 | 掃 transcript，宣稱可得知「正在執行」 | 送 Codex 評估，回收 12 條問題（2 BLOCKER / 6 HIGH / 4 MEDIUM） |
| v2 | 掃 transcript，語義降級為「最近活動」 | 修掉 v1 的錯誤宣稱，但仍受限於落盤資料的先天不足 |
| **v3** | **lifecycle hook heartbeat registry** | 一次解掉 v2 殘留的語義、效能、隱私三個問題 |

v3 的取捨與 v2 的差異：

| | v2（零 hook） | **v3（heartbeat）** |
|---|---|---|
| 語義 | 只能叫「最近活動」，有 stale 殭屍列 | **真「正在執行」**，pid 存活檢查 |
| 掃描成本 | 遞迴列舉 1,153 檔 → 只能 popover 開啟時掃 | 讀幾個小 JSON → **可常駐，menu bar 可反映活動** |
| 隱私 | 必須讀 transcript 尾端 256 KB，含 prompt 與可能的 secrets | **完全不讀 transcript** |
| skill 準確度 | Claude 已確認 / Codex 只能推測 | hook 直接寫入，兩家皆準確 |
| 代價 | 無 | 改 `start.sh` 安裝流程、需處理 hook 版本相容 |

---

## 一、Codex 對抗式評估的處置（v2 保留，仍然有效）

v1 送交 Codex 獨立評估，每一條關鍵證據我都自己重跑驗證。

| # | Codex 指出 | 我的驗證 | v3 處置 |
|---|-----------|---------|--------|
| 1 | Codex 未閉合 `task_started` ≠ 正在跑 | **成立且更嚴重**：99 個 rollout 有 **51 個**以未閉合 turn 結尾，最舊 4.9 天 | 架構改 heartbeat 後**根本消失**（改用 pid 存活） |
| 2 | Claude human-message 規則大量誤判 | **成立**：400 檔抽樣 825 筆候選中 **397 筆 `isMeta`**（48%） | 不再需要推斷回合邊界 |
| 3 | 需依 `turn_id` 建 FSM | 成立：431 started / 354 complete / 24 aborted，全帶 `turn_id` | 不再需要 |
| 4 | fork/subagent 複製祖先 meta | 成立：99 檔含 150 筆 `session_meta` | 不再需要 |
| 5 | 「不讀取訊息內文」是錯誤聲明 | 成立，v1 自相矛盾 | **v3 真的不讀 transcript**，聲明成立 |
| 6 | 缺少 `CodexUsageService` 既有安全邊界 | 成立（symlink 拒絕 / path containment / 讀取預算 / 單行 1 MB） | registry 讀取沿用同一套 |
| 7 | 5 秒輪詢漏算全樹 enumerate | 方向成立、**數據錯誤**：它稱 `~/.codex/sessions` 1,152 檔 / 148 MB，實測 **99 檔 / 41 MB**（那個量級是 `~/.claude/projects`：1,054 檔 / 108 MB） | 改讀單一 state 目錄，成本問題消失 |
| 8 | Codex pending 檔名是 approval UUID 非 session id | **成立**：真 id 在 `codex_session_id`，Swift `PendingData` 沒解此欄 | ✅ 仍需修，見 §5.4 |
| 9 | Codex skill 反推只證明「曾讀取」 | 成立 | 改由 hook 直接寫入，啟發式廢除 |
| 10 | 未定義 App Sandbox / distribution | 成立但本 app 為本機直跑 dev build | ⚠️ 限制條款，見 §8 |
| 11 | 解析失敗靜默隱藏會偽裝成「沒有 agent」 | 成立 | ✅ 保留 `sourceStatus` 設計 |
| 12 | 建議砍 `model`/`gitBranch`/`lastTool`/`subagentCount` | **部分不同意** | 只砍 `subagentCount`，理由見 §10 |

### 我對第 2 條的修正

Codex 把 slash command 列為「會打破 human-message 判定」的情況。實測不成立：

```
isMeta ∩ slash-command = 0
slash-command only     = 390   ← 真人打 /foo，是合法的回合邊界
isMeta only            = 397   ← Stop hook feedback、skill 注入，不是邊界
純文字 human prompt     = 38
```

兩者零重疊。此結論在 v3 已不影響實作，但保留為記錄。

---

## 二、Hook 能力盤點（實測本機安裝版本）

從兩家已安裝的 binary 直接萃取事件名，非文件推測。

**Claude Code 2.1.226**（`~/.local/share/claude/versions/2.1.226`）

```
Stop 286  PostToolUse 134  PreToolUse 133  SessionStart 83
SubagentStop 73  UserPromptSubmit 61  Notification 58  PreCompact 43  SessionEnd 29
```

**Codex 0.146.0**（`~/.codex/packages/standalone/releases/0.146.0-aarch64-apple-darwin/bin/codex`）

```
SessionStart  SessionEnd  UserPromptSubmit  PreToolUse  PostToolUse  Stop  PermissionRequest
```

本計劃需要的四個事件（SessionStart / UserPromptSubmit / PreToolUse / SessionEnd）**兩家都支援**。

現況安裝面：

- `~/.claude/settings.json` 已註冊全域 PreToolUse hook（`pretooluse.mjs`，matcher `*`）
- `start.sh:83` 已有 python3 區塊冪等寫入該 hook，擴充成本低
- `~/.codex/hooks.json` 目前是空的 `{"hooks":{}}` —— Codex 側 hook 尚未安裝，需新增安裝步驟

---

## 三、Registry 設計

### 3.1 檔案格式

`~/.wakawaka/state/agent_<kind>_<sessionId>.json`，mode `0600`

```json
{
  "schema": 1,
  "kind": "claude-code",
  "sessionId": "2ef6421b-2451-44da-9b4d-7a4c3300cdfc",
  "cwd": "~/lake-ui-kit",
  "gitBranch": "main",
  "model": "claude-opus-5",
  "pid": 12345,
  "pidStartedAt": 1786095074,
  "state": "working",
  "skill": "code-review",
  "skillSource": "tool",
  "lastTool": "Edit",
  "startedAt": "2026-08-08T06:07:51.728Z",
  "heartbeatAt": "2026-08-08T06:15:44.855Z"
}
```

**檔案只寫 metadata，絕不寫 prompt 內文、tool input 或 tool output。**
`skill` 只存名稱，`lastTool` 只存工具名。這使 §8 的隱私聲明成立 —— 這是 v2 做不到的。

### 3.2 事件對應

| 事件 | 動作 | 成本 |
|------|------|------|
| `SessionStart` | 建立 registry；解析並記錄 pid + 行程啟動時間；寫 cwd / model | 每 session 一次 |
| `UserPromptSubmit` | `state=working`；prompt 以 `/` 開頭 → `skill=<命令名>`, `skillSource=slash` | 每回合一次 |
| `PreToolUse` | **搭載既有 `pretooluse.mjs`**：更新 `heartbeatAt` / `lastTool`；`tool_name=="Skill"` → `skill=input.skill`, `skillSource=tool` | **零額外 process** |
| `Stop` | `state=idle`；清除 `skill`（回合結束） | 每回合一次 |
| `SessionEnd` | 刪除 registry 檔 | 每 session 一次 |

最高頻的事件（PreToolUse）搭載在**已經在跑的 hook** 上，不增加任何 process spawn —— 這是本架構
成本低的關鍵。新增的獨立 hook 只在每 session / 每回合觸發一次。

### 3.3 Crash 殘留清理（本架構存在的理由）

v2 最大的缺陷是無法區分「還在跑」與「crash 了沒人收屍」（51/99 的 rollout 就是後者）。

registry 用 pid 解決：

1. WakaWaka 讀取時對 `pid` 執行 `kill(pid, 0)`；`ESRCH` → 行程已死，刪檔不顯示
2. **pid 重用防護**：以 `sysctl(KERN_PROC_PID)` 取得行程啟動時間，與 `pidStartedAt` 比對，
   不符表示 pid 已被回收給別的行程 → 視為已死
   （純 syscall，不 fork 子行程）
3. 兜底：`heartbeatAt` 超過 30 分鐘且無法驗證存活 → 刪除

hook 端 pid 解析（僅 SessionStart 執行一次）：hook 由 shell 啟動，`process.ppid` 可能是即將結束的
`sh`，因此需沿 parent chain 向上尋找 comm 匹配 `claude` / `codex` 的行程，上限 4 層。

### 3.4 自我遞迴防護（實作前發現的坑）

`ParserRunner.swift:138` 每 ~10 分鐘執行 `claude -p "/usage"`。裝上 SessionStart hook 之後，
**WakaWaka 會把自己註冊成一個活躍 agent**，面板每 10 分鐘閃一個假的 Claude session。

處置：`ParserRunner.buildEnv()`（`ParserRunner.swift:245`）注入 `WAKAWAKA_INTERNAL=1`，
heartbeat hook 偵測到該變數時直接 no-op 返回。需納入測試（§9-13）。

### 3.5 已知涵蓋範圍限制

- registry 只涵蓋**安裝 hook 之後啟動**的 session。安裝當下已在跑的 session 不會出現，
  直到它重啟。屬預期行為，UI 不需特別處理。
- Codex 側需要使用者信任 hook（`--dangerously-bypass-hook-trust` 之外的正常信任流程），
  安裝步驟需說明。

---

## 四、資料模型

```swift
enum AgentKind: String, Decodable { case claudeCode = "claude-code", codex }

enum AgentState: Equatable {
    case working          // 正在跑某個回合
    case idle             // session 活著但等待輸入
    case waitingApproval  // 卡在 WakaWaka 待審批（由 pending 檔疊加）
}

enum SkillSource: String, Decodable { case tool, slash }

struct AgentRegistryEntry: Decodable {
    let schema: Int
    let kind: AgentKind
    let sessionId: String
    let cwd: String
    let gitBranch: String?
    let model: String?
    let pid: Int32
    let pidStartedAt: Int64
    let state: String
    let skill: String?
    let skillSource: SkillSource?
    let lastTool: String?
    let startedAt: Date
    let heartbeatAt: Date
}

struct ActiveAgentRow: Identifiable, Equatable {
    let id: String            // "<kind>_<sessionId>"
    let kind: AgentKind
    let projectName: String   // cwd 最後一段；完整路徑只進 tooltip
    let gitBranch: String?
    let model: String?
    let skill: String?
    let skillSource: SkillSource?
    let lastTool: String?
    let state: AgentState
    let heartbeatAt: Date
}

/// 解析失敗不得偽裝成「沒有 agent」（Codex 評估第 11 條）
enum SourceStatus: Equatable {
    case ok(lastScan: Date)
    case unavailable
    case permissionDenied
    case schemaIncompatible(found: Int, expected: Int)
}

struct ActiveAgentsSnapshot: Equatable {
    let rows: [ActiveAgentRow]
    let status: SourceStatus
}
```

`schema` 欄位是版本相容閘門：讀到不認得的 `schema` → `schemaIncompatible`，
不猜測欄位語意，UI 提示使用者重跑 `start.sh`。

---

## 五、架構與檔案異動

### 5.1 新 hook 檔

| 檔案 | 事件 | 說明 |
|------|------|------|
| `hooks/agent-registry.mjs` | — | 共用模組：atomic write（temp + rename）、pid 解析、`WAKAWAKA_INTERNAL` 防護、schema 版本 |
| `hooks/sessionstart.mjs` | SessionStart | Claude 與 Codex 共用，以 payload 判斷 kind |
| `hooks/userpromptsubmit.mjs` | UserPromptSubmit | 標記 working + slash command skill |
| `hooks/stop.mjs` | Stop | 標記 idle |
| `hooks/sessionend.mjs` | SessionEnd | 刪檔 |

`hooks/pretooluse.mjs`：**修改**，在既有分類邏輯之前加一行 heartbeat 更新（不改變任何審批行為）。

寫入一律 atomic（寫 temp 再 `rename`），避免 WakaWaka 讀到半個 JSON。

### 5.2 新 Swift 檔

| 檔案 | 內容 | 預估 |
|------|------|------|
| `AgentRegistryService.swift` | 讀 registry、pid 存活驗證、pending overlay、殘留清理 | ~180 行 |
| `ActiveAgentsView.swift` | SwiftUI section | ~130 行 |

`ContentView.swift` 已 735 行（本就超過 300 行標準），不再加重。

### 5.3 Swift 修改

| 檔案 | 異動 |
|------|------|
| `Models.swift` | 加 §4 型別；`PendingData` 補解 `codex_session_id` |
| `PopoverViewModel.swift` | 加 `@Published var activeAgents: ActiveAgentsSnapshot` |
| `ContentView.swift` | 待審批 header 上方插入 `ActiveAgentsView` |
| `AppDelegate.swift` | 併入既有 1 秒 `poll()`（已在掃同一個 state 目錄，邊際成本近零） |
| `ParserRunner.swift` | `buildEnv()` 注入 `WAKAWAKA_INTERNAL=1`（§3.4） |

**輪詢併入既有 `poll()`**：`AppDelegate.poll()` 每秒已經在列舉 `~/.wakawaka/state`
找 `pending_*.json`。registry 檔在同一個目錄，同一次列舉順手處理即可，
不新增 timer、不新增目錄走訪。v2 那個「每 5 秒掃 1,153 個檔」的成本問題在此架構下不存在。

pid 存活驗證做節流：每次 poll 只驗證 `heartbeatAt` 超過 60 秒的項目，新鮮的直接信任。

### 5.4 安裝流程（`start.sh`）

擴充既有的 python3 冪等寫入區塊（`start.sh:83`）：

- Claude：於 `~/.claude/settings.json` 註冊 SessionStart / UserPromptSubmit / Stop / SessionEnd
  （沿用既有依腳本路徑比對去重的邏輯，避免重複註冊造成競爭）
- Codex：於 `~/.codex/hooks.json` 註冊對應事件（目前為空 `{"hooks":{}}`，需新建結構）
- 移除舊路徑註冊，與現行 PreToolUse 的處理方式一致

### 5.5 pending overlay

以 `(kind, 真實 session id)` 為鍵：

| Agent | pending 檔名 | 真 session id 欄位 |
|-------|-------------|------------------|
| Claude Code | `pending_<session_id>.json` | `session_id` |
| Codex | `pending_permission_codex_<UUID>.json` | **`codex_session_id`**（`session_id` 是 approval UUID） |

已 tombstone（`hookExited == true`）或已過期的 pending 不參與 overlay。

---

## 六、UI

放在待審批清單**上方、常駐**（無資料時整段隱藏）。popover 寬 480。

```
┌─ ACTIVE AGENTS ─────────────── 2 ─┐
│ ● WakaWaka        main            │
│   Bash · opus-5          just now │
│ ● lake-ui-kit     HEAD            │
│   ⚡ code-review           12s ago │
└───────────────────────────────────┘
─────────────────────────────────────
  待審批 1
  ...
```

| 符號 | 意義 |
|------|------|
| `●` 綠 | `working` |
| `●` 灰 | `idle` |
| `●` 橘 | `waitingApproval` |
| `⚡ name` | skill（`skillSource` 進 tooltip：tool 呼叫／slash command） |

v2 需要的 `◐` 推估符號與 `⚠ stale` 狀態在 v3 **全部不需要** —— 狀態來自 hook 事件與 pid 驗證，
沒有推估成分。這是改架構最直接的收益。

- 只顯示 `projectName`（cwd 最後一段），完整路徑進 tooltip
- 上限 5 列，超出顯示「+N more」
- `status` 非 `ok` 時底部顯示一行細字（例：「registry schema 不相容，請重跑 start.sh」），不得靜默隱藏
- 顯示字串限長並移除控制字元，避免 UI spoofing
- 無待審批但有活躍 agent → 不顯示 PacMan；兩者皆空才回到 PacMan

menu bar icon 可反映活動（v2 做不到），但本版先不做，留待面板驗證後再說。

---

## 七、效能

| 項目 | 成本 |
|------|------|
| hook 端：PreToolUse | 搭載既有 hook，**零額外 process**；一次小 JSON atomic write |
| hook 端：SessionStart / UserPromptSubmit / Stop / SessionEnd | 每 session 或每回合一次 node 啟動 |
| app 端：列舉 | 併入既有每秒 `poll()`，同一目錄同一次列舉 |
| app 端：pid 驗證 | `kill(pid,0)` + `sysctl` 純 syscall，且只對 `heartbeatAt` > 60s 的項目做 |

對照 v2 的每小時 ~830,000 次 stat —— 此架構的常駐成本基本上是既有 `poll()` 的捨入誤差。

唯一新增的持續成本是每次工具呼叫多一次小檔寫入。`pretooluse.mjs` 本來就在寫 pending 檔，
量級相同。

---

## 八、隱私與安全

v1 曾錯誤宣稱「不讀取任何訊息內文」（Codex 評估第 5 條）。**v3 讓這個聲明真正成立**：

- registry 檔由 hook 寫入，**只含 metadata**：kind / sessionId / cwd / branch / model / pid /
  state / skill 名 / tool 名 / 時間戳
- WakaWaka **完全不讀取任何 transcript**
- 檔案 mode `0600`，位於既有的 `~/.wakawaka/state`（已是 `0700`）
- 不寫入 log / crash report / analytics，不對外傳輸
- 顯示前對所有字串限長並移除控制字元

讀取端沿用 `CodexUsageService.swift` 既有的安全邊界（Codex 評估第 6 條）：
symlink 拒絕、path containment、`isRegularFile` 檢查、檔數與位元組預算、單行 JSON 上限。

`sessionId` 需沿用 `AppDelegate.isValidSessionId` 等級的字元白名單檢查，防止路徑穿越。

**限制條款**：本 app 為本機直跑的非 sandbox dev build（`Package.swift` 為裸 executable target，
無 entitlement 宣告）。若日後 sandbox 化，讀 `~/.wakawaka` 需改用 security-scoped bookmark。
不阻擋本版。

---

## 九、測試計畫

**hook 端**（`hooks/agent-registry.test.mjs`，沿用既有 node test 慣例）

1. SessionStart 建立 registry，欄位與 mode `0600` 正確
2. `WAKAWAKA_INTERNAL=1` 時所有 hook 皆 no-op（自我遞迴防護）
3. PreToolUse 更新 `heartbeatAt` / `lastTool`，且**不改變既有審批決策行為**（回歸既有 38K 行測試）
4. `tool_name == "Skill"` → 寫入 `skill` 與 `skillSource=tool`
5. UserPromptSubmit 以 `/` 開頭 → `skillSource=slash`
6. Stop 清除 skill 並設 `idle`
7. SessionEnd 刪檔
8. atomic write：模擬並行寫入不產生半個 JSON
9. pid 解析能穿過中介 shell 找到 agent 行程
10. 惡意 `sessionId`（含 `../`）被拒絕

**Swift 端**（`AgentRegistryServiceTests.swift`）

11. pid 不存在 → 該列不顯示且檔案被清除
12. pid 存在但 `pidStartedAt` 不符（pid 重用）→ 視為已死
13. `WAKAWAKA_INTERNAL` 產生的 session 不出現在面板
14. `heartbeatAt` 超過 30 分鐘且無法驗證 → 清除
15. `pending_permission_codex_*.json` 以 `codex_session_id` 正確 overlay
16. tombstone（`hookExited`）的 pending 不 overlay
17. 未知 `schema` → `SourceStatus.schemaIncompatible`，非空清單
18. 半寫入 / 損毀 JSON 不造成崩潰
19. symlink candidate 被拒絕
20. state 目錄不存在 → `SourceStatus.unavailable`

現有 20 個 Swift 測試與既有 hook 測試不得退步。

---

## 十、範圍決策（含對 Codex 建議的部分不同意）

Codex 建議把 `model` / `gitBranch` / `lastTool` / `subagentCount` 全砍。**只採納一半**：

| 欄位 | 決定 | 理由 |
|------|------|------|
| `subagentCount` | **砍** | Claude 近 3 日 subagent 記錄為 0 筆，做了看不到效果；兩家成本不對等 |
| `model` / `gitBranch` / `lastTool` | **保留** | v3 下這三者由 hook 從既有 payload 直接取得，成本為零。`lastTool` 是讓「這個 session 在幹嘛」可讀的關鍵；砍掉只剩專案名，資訊量不足以支撐面板存在的理由。隱私由 §8 的 metadata-only 設計處理，不需靠砍欄位 |

其他非目標：agy（無 session 概念）、subagent 樹狀展開、跳轉終端、skill 耗時統計、
歷史記錄、menu bar icon 連動（架構已支援，但本版不做）。

---

## 十一、已定案事項

| 事項 | 決定 |
|------|------|
| 資料來源 | heartbeat registry（非 transcript 掃描） |
| 語義 | 真「正在執行」，pid 存活驗證 |
| 掃描時機 | 併入既有每秒 `poll()`，常駐 |
| 資料源開關 | 預設開啟（本機個人工具，讀的是使用者自己的 metadata） |
| `model`/`gitBranch`/`lastTool` | 保留 |
| `subagentCount` | 砍 |
| UI 位置 | 待審批清單上方，常駐，無資料時隱藏 |

---

## 十二、接手執行指南

### 動工前

```bash
git status                    # 多 harness 並行是常態，先確認工作樹
cd cost-aware-approval/app/WakaWaka && swift build && swift test   # 取得綠燈基準（現況 20 tests）
node --test cost-aware-approval/hooks/*.test.mjs                   # hook 測試基準
```

必讀既有檔（本計劃大量重用，不要重寫）：

- `cost-aware-approval/hooks/pretooluse.mjs` —— 要搭載 heartbeat 的宿主，**審批行為不得改動**
- `cost-aware-approval/app/WakaWaka/Sources/WakaWaka/CodexUsageService.swift:64-136` —— 安全掃描邊界正本
- `cost-aware-approval/app/WakaWaka/Sources/WakaWaka/AppDelegate.swift:675` `poll()` —— registry 讀取要併進這裡
- `start.sh:83` —— hook 註冊的 python3 冪等區塊

### 建議實作順序（每階段結束都應可獨立驗證）

| 階段 | 內容 | 驗證 |
|------|------|------|
| 1 | `hooks/agent-registry.mjs` 共用模組（atomic write、pid 解析、`WAKAWAKA_INTERNAL` 防護、schema 版本） | 單元測試 §9-1、2、8、9、10 |
| 2 | 四個 lifecycle hook（sessionstart / userpromptsubmit / stop / sessionend） | §9-1、5、6、7 |
| 3 | `pretooluse.mjs` 搭載 heartbeat | §9-3、4 + **既有審批測試全綠** |
| 4 | `start.sh` 註冊（Claude settings.json + Codex hooks.json） | 手動：開新 session 後確認 registry 檔生成，結束後消失 |
| 5 | `ParserRunner.buildEnv()` 注入 `WAKAWAKA_INTERNAL=1` | §9-2、13 —— **必須在階段 4 之後立刻做，否則面板會出現 WakaWaka 自己** |
| 6 | `AgentRegistryService.swift`（讀取 + pid 驗證 + pending overlay + 清理） | §9-11～20 |
| 7 | `Models.swift` 補 `codex_session_id`、`PopoverViewModel`、`ActiveAgentsView`、接線 | swift test + 實機目測 |

### 完成判準

- [ ] `swift test` ≥ 20 tests 全綠（不得退步）
- [ ] 既有 hook 測試全綠，特別是 `pretooluse-smart.test.mjs`（38K 行）
- [ ] 開兩個真實 session（不同專案）→ popover 同時顯示兩列，cwd / branch / skill 正確
- [ ] 呼叫一個 skill → 面板顯示該 skill；回合結束後 skill 消失
- [ ] `kill -9` 一個 session 的 claude process → 該列在下次 poll 後消失
- [ ] 等 10 分鐘讓 `ParserRunner` 跑一次 `/usage` → **面板不得出現 WakaWaka 自己**
- [ ] 依 `version-log` skill 更新 README 版本紀錄

---

## 附錄：v2 零 hook 方案（已否決，保留備查）

若日後 hook 安裝面出現阻礙，退路是 v2 的 transcript 掃描架構。其代價已充分量測：

- 語義只能是「最近活動」（51/99 rollout 以未閉合 turn 結尾，最舊 4.9 天）
- Claude 回合邊界需排除 `isMeta`（48% 誤判率）/ `isCompactSummary` / `isVisibleInTranscriptOnly`，
  但保留 `<command-name>` slash command
- Claude skill 可用兩種訊號：`Skill` tool_use（25 筆）與 `isMeta` 的
  `Base directory for this skill: <path>` 注入記錄（31 筆，語意更強）
- Codex skill 只能從工具呼叫 input 比對 `SKILL.md` 路徑反推，為啟發式
- 需遞迴列舉 1,153 個檔，只能在 popover 開啟時掃
- 必須讀 transcript 內文，隱私聲明需相應弱化
