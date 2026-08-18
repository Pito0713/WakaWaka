# 計劃書：懸浮 Active Agents HUD

> 狀態：**v1 — 待實作**
> 對象：WakaWaka menu bar app（`cost-aware-approval/app/WakaWaka`）
> 建立 2026-08-18
> 前置：`active-agents-plan.md` v3（heartbeat registry）已實作完成

---

## 一、這份計劃要解決什麼

現有的 ACTIVE AGENTS 面板釘在 popover 底部（`ActiveAgentsView.swift`），代價是**要先點 menu bar 圖示才看得到**。多個 agent 並行跑時，使用者真正想要的是「不用動作就知道誰在跑、誰卡住」——這需要一個常駐、置頂、不搶焦點的小視窗。

範圍定案：**純狀態 HUD**。只顯示 + 點擊跳終端機，approval 決策仍然只走 popover。理由見 §7。

---

## 二、關鍵前提：資料層已經完成

這個功能之所以便宜，是因為它不需要任何新的資料來源。以下全部沿用，一行不改：

| 能力 | 位置 | 說明 |
|------|------|------|
| 1 Hz 狀態掃描 | `AppDelegate.swift:679` `poll()` | 已在跑，與 pending approval 共用同一次目錄列舉 |
| snapshot 建構與淨化 | `AgentRegistryService.snapshot()` | schema 檢查、大小上限、symlink 拒絕、控制字元剝除 |
| pid 存活 / 身分驗證 | `AgentRegistry.swift:117` `ProcessLiveness` | `kill(pid,0)` + `p_starttime` 比對，防 pid 回收 |
| 去重 | `ActiveAgentsSnapshot: Equatable` | 內容沒變就不 republish |
| 點擊跳終端機 | `AgentWindowFocus.focus(_:)` | tmux pane + Terminal.app 兩跳都處理好了 |
| degraded 狀態語義 | `SourceStatus` | 「讀不到」與「沒有 agent」必須可區分 |

**本計劃不新增 timer、不新增檔案掃描、不讀 transcript。** 隱私邊界與現有面板完全相同（metadata-only）。

資料流：

```
hooks → ~/.wakawaka/state/agent_*.json
          ↓ 既有 1 Hz poll
    AgentRegistryService.snapshot()
          ↓
    PopoverViewModel.activeAgents        ← 唯一 source of truth
          ↓                        ↓
   ActiveAgentsView          FloatingAgentsPanelController
   （popover 內，既有）        （常駐視窗，新增）
```

---

## 三、核心技術決策

### 3.1 必須是 `NSPanel`，不能是 `NSWindow`

**這是整個計劃唯一可能被推翻的假設，Phase 0 先驗。**

app 以 `.accessory` 執行（`main.swift:4`）。`.accessory` 的一般 `NSWindow` 要接收點擊、成為 key window，必須先 `NSApp.activate(ignoringOtherApps:)`——`UsageDashboardWindowController.present()` 就是這樣做的（`UsageDashboardWindow.swift:44`），對一個使用者主動打開的儀表板視窗是對的。

但對常駐 HUD 是錯的：使用者點一列 agent 想跳去它的終端機，流程會變成「焦點先被 WakaWaka 搶走 → `AgentWindowFocus` 再把終端機拉到前面」，焦點彈兩次，而且中間那一跳會把使用者原本在打字的視窗踢掉。

```swift
final class FloatingAgentsPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .borderless, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true        // 只有真的需要輸入才變 key
        level = .floating                    // 不用 .statusBar：那層會蓋住系統選單與通知
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isMovableByWindowBackground = true   // borderless 沒有 title bar，拖曳得自己給
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
    }

    // borderless 預設不能成為 key window，鍵盤事件與部分 SwiftUI 互動會失效
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }   // 永遠不當 main，避免搶 app 焦點語義
}
```

`collectionBehavior` 三個旗標各自對應一個需求，缺一不可：

| 旗標 | 沒有它會怎樣 |
|------|-------------|
| `.canJoinAllSpaces` | 切到另一個桌面就看不到 HUD |
| `.fullScreenAuxiliary` | 別的 app 進全螢幕時 HUD 消失（這正是最需要它的時候） |
| `.stationary` | Mission Control / 桌面切換動畫中 HUD 會跟著飛 |

### 3.2 顯示形態：三段式狀態機

| 形態 | 尺寸（pt） | 內容 | 進入條件 |
|------|-----------|------|---------|
| `dot` | 30 × 30 | 彩色圓點 + agent 數 | 使用者點圓點摺疊；或無 agent 時自動 |
| `compact` | 220 × (28 × n + 14) | 狀態點 · 專案名 · 相對時間 | 預設 |
| `expanded` | 300 × (46 × n + 22) | 加 branch / skill / model | hover 時暫時展開；或使用者釘選 |

- hover 進 `expanded`、移開回原形態；**釘選（pin）狀態下 hover 不改變形態**，否則滑鼠經過就跳動。
- 列數上限沿用 `AgentRegistryService.maxRows = 5`，超出顯示 `+n more`。
- 尺寸計算不寫死常數：比照 `PopoverSizing`，用 `NSHostingView(...).fittingSize` 量測。`PopoverLayoutTests` 的註解已經記錄過「手算常數錯過兩次」的教訓，不要再犯一次。

### 3.3 偏好存 `UserDefaults`，不存 `~/.wakawaka/settings.json`

`settings.json` 是與 hooks 的共用契約（`SettingsService.swift:5` 的註解明確要求不得亂改鍵名）。HUD 的開關、形態、透明度是純 app 本地 UI 偏好，hooks 永遠不會讀。`SkinManager` 的 `UserDefaults["activeSkin"]` 已是同類前例。

鍵名：

```
floatingPanel.enabled   : Bool     預設 false（不打擾既有使用者）
floatingPanel.mode      : String   "dot" | "compact" | "expanded"
floatingPanel.pinned    : Bool     釘選後 hover 不改形態
floatingPanel.opacity   : Double   0.35…1.0，預設 0.95
```

視窗位置用 `setFrameAutosaveName("FloatingAgentsPanel")` 交給 AppKit，但**恢復後必須自己 clamp**，見 §4.2。

---

## 四、三個已識別的坑（設計時就要處理）

### 4.1 相對時間會凍結

`ActiveAgentsView.swift:205` 的 `relativeHeartbeat` 在 render 當下用 `Date()` 算差值。popover 只開幾秒，看不出問題；常駐視窗不同：

一個 idle agent 的 `heartbeatAt` 不會變 → `ActiveAgentsSnapshot` 判定相等 → `AppDelegate.poll()` 不 republish（`AppDelegate.swift:733`）→ view 不重繪 → 標籤永遠停在 `"3s ago"`，而實際已經過了十分鐘。這會讓使用者對「這個 agent 多久沒動」產生完全錯誤的判斷。

**解法：HUD 版改用 `Text(row.heartbeatAt, style: .relative)`**，由 SwiftUI 自行 tick，與 snapshot 是否 republish 無關。不要為此加一個 1 秒重繪 timer——那等於讓整個視窗每秒重新佈局，只為了更新一個字串。

註：popover 內既有的 `relativeHeartbeat` 不動。它的顯示壽命短，且改動要重跑既有 layout 測試，不屬本計劃範圍。

### 4.2 恢復的視窗位置可能在螢幕外

`setFrameAutosaveName` 會忠實還原上次的 frame。使用者把 HUD 放在外接螢幕右下角、隔天只帶筆電出門 → 視窗恢復到一個不存在的座標，完全看不見，而且沒有任何 UI 可以把它找回來（沒有 Dock 圖示、沒有視窗選單）。

**解法：純函式 clamp，可測。**

```swift
enum FloatingPanelPlacement {
    /// 把 frame 收進「任一螢幕 visibleFrame」的範圍內。
    /// 與所有螢幕都沒有足夠交集時，回落到主螢幕右上角的預設位置。
    static func clamp(_ frame: NSRect, into screens: [NSRect],
                      minVisible: CGFloat = 40) -> NSRect
}
```

`minVisible` 的意思是「至少要有 40×40 落在某個螢幕內」才算可見——只露出 2pt 邊角等同看不見。螢幕清單以參數傳入而非直接讀 `NSScreen.screens`，才能在測試裡構造多螢幕與拔線情境。

觸發時機：視窗建立時、`NSApplication.didChangeScreenParametersNotification` 時。

### 4.3 空狀態不可以自動隱藏

沒有 agent 在跑時，直覺是把視窗藏起來。**不要。**

視窗自己消失後，使用者無法區分三件事：沒有 agent 在跑、HUD 被關掉了、HUD 壞了。這正是 `SourceStatus` 註解裡已經寫死的原則——「a silent empty panel is indistinguishable from a working one showing nothing」（`AgentRegistry.swift:78`）。同一條原則對常駐視窗只會更強，因為它是使用者判斷系統狀態的唯一常駐依據。

**行為定義：**

| snapshot 狀態 | HUD 表現 |
|--------------|---------|
| 有 agent | 依 `mode` 顯示，狀態點沿用既有配色（working 綠 / idle 灰 / waitingApproval 橘） |
| 無 agent、`status == .ok` | 縮成 `dot`，灰點，opacity 降至 0.35 |
| `status.message != nil` | 縮成 `dot`，**黃點**，tooltip 顯示 `status.message`，opacity 不降 |

degraded 一定要比「正常但空」更顯眼，否則讀不到 registry 會被誤讀成「今天沒跑 agent」。

---

## 五、檔案計劃

### 新增（`Sources/WakaWaka/`）

| 檔案 | 行數估 | 職責 |
|------|--------|------|
| `FloatingAgentsPanel.swift` | ~150 | `NSPanel` 子類 + `NSWindowController`；視窗層級、collectionBehavior、顯示/隱藏、螢幕變更處理 |
| `FloatingAgentsView.swift` | ~180 | SwiftUI HUD 根視圖；三形態切換、hover、拖曳把手 |
| `FloatingAgentRow.swift` | ~90 | 單列視圖（compact / expanded 兩種密度） |
| `FloatingPanelLayout.swift` | ~100 | **純函式**：形態 → 尺寸、`FloatingPanelPlacement.clamp`、形態狀態機轉移規則 |
| `FloatingPanelPreferences.swift` | ~60 | UserDefaults 讀寫，型別安全、含預設值 |

全部低於 `coding-standards.md` 的 300 行上限。

### 新增測試（`Tests/WakaWakaTests/`）

| 檔案 | 涵蓋 |
|------|------|
| `FloatingPanelLayoutTests.swift` | clamp 行為、尺寸隨列數成長、形態狀態機 |

比照既有 swift-testing 風格（`@MainActor struct ... { @Test ... }`），不用 XCTest。

### 修改既有

| 檔案 | 改動 | 估計 |
|------|------|------|
| `AppDelegate.swift` | 持有 `floatingPanelController`、把 `viewModel.activeAgents` 變更轉發給它、接 `onToggleFloatingPanel` | +40 |
| `PopoverViewModel.swift` | `@Published var isFloatingPanelVisible`、`var onToggleFloatingPanel: (Bool) -> Void` | +6 |
| `PopoverFooter.swift` | 開關按鈕（`macwindow.on.rectangle` 之類），放在 dashboard 按鈕旁 | +20 |

`AppDelegate.swift` 目前 1056 行，已遠超 300 行上限。本計劃只加 40 行，不擴大問題；但若 Phase 3 要再往裡面加東西，應先把視窗管理拆成獨立 coordinator。

---

## 六、分期與驗收條件

### Phase 0 — 風險驗證（先做，約 30 分鐘）

一個空白 `NSPanel`，不接任何資料。只驗三件事：

- [ ] 點擊面板**不會**讓 WakaWaka 變成 active app（用 `NSWorkspace.shared.frontmostApplication` 確認前景 app 沒變）
- [ ] 另一個 app 進入全螢幕後，面板仍在畫面上
- [ ] 切換桌面（Space）後面板仍在，且不參與切換動畫

任一項失敗就停下重新設計，不要往下做。

### Phase 1 — 可用的 MVP

- [ ] `compact` 形態顯示 agent 列表，資料來自既有 snapshot
- [ ] 拖曳移動、位置持久化、重開 app 後回到原位
- [ ] 位置 clamp 生效（拔掉外接螢幕後仍可見）
- [ ] popover footer 有開關，狀態持久化
- [ ] 相對時間會自己走（放著五分鐘，數字有變）
- [ ] `FloatingPanelLayoutTests` 通過

### Phase 2 — 互動

- [ ] `dot` / `compact` / `expanded` 三形態切換與 hover 行為
- [ ] 釘選開關（pin 後 hover 不改形態）
- [ ] 點一列 → 對應終端機到前景，且**焦點只跳一次**
- [ ] `AgentWindowFocus.Outcome` 的失敗訊息在 HUD 內顯示，不靜默

### Phase 3 — 打磨

- [ ] degraded 狀態視覺（黃點 + tooltip）
- [ ] 透明度設定
- [ ] `SkinManager` 整合（若使用者裝了 skin，狀態點改用 skin 的顏色集）

---

## 七、明確排除的範圍

| 排除項 | 理由 |
|--------|------|
| 在 HUD 內做 approval 決策（Allow/Deny） | 常駐視窗被誤點的代價遠高於 popover。一個永遠浮在畫面上的 Allow 按鈕，誤觸就等於未經審查放行一次工具呼叫，這牴觸整個 cost-aware-approval 的設計前提。若之後真要做，必須先設計 hover-hold 或二次確認，屬另一份計劃 |
| 用量摘要塞進 HUD | 與 popover / dashboard 職責重疊，維護成本翻倍 |
| App Sandbox / 簽章分發 | 沿用 `active-agents-plan.md` §8 的既有限制條款，本 app 為本機 dev build |
| 修改 popover 內既有 `relativeHeartbeat` | 見 §4.1 註記 |

---

## 八、安全與規範對照

- **無新增資料暴露**：HUD 顯示的欄位是 `ActiveAgentRow` 的子集，與現有面板相同，全部已經過 `AgentRegistryService.sanitize()`（控制字元剝除 + 長度上限）
- **不讀 transcript**：`active-agents-plan.md` v3 的聲明在本計劃中維持成立
- **不執行外部輸入**：點擊跳轉沿用 `AgentWindowFocus`，該模組已用 tmux id 定址、AppleScript 只內插整數
- **無新增權限需求**：置頂視窗不需要 Accessibility；終端機跳轉所需的 Automation 權限是既有的
- **無 secrets、無 `console.log` 等值物**：Swift 端一律走既有錯誤處理路徑
