# WakaWaka TODO

> Menu bar 小精靈 / popover 的待辦與已停用功能紀錄。

---

## Menu bar icon — 停用中 / 待重啟的狀態

- [ ] **Urgent（快到期）狀態** — 已實作但 dormant
  - 現況：`IconUrgencyOverlay.swift` 已寫好（紅色疊色 + 呼吸脈動、尊重 Reduce Motion），但 `setIcon` **目前沒有呼叫** `urgencyOverlay.update()` → urgent 看起來跟一般 pending 一樣。
  - 資料源：`pendingQueue` 各項的 `hookUrgent`（hook 等 8 分鐘後轉 true，約 2 分鐘後自動拒絕）。
  - 復活方式：在 `setIcon` 末尾加回 `urgencyOverlay?.update(silhouette: image, urgency: ...)`；`IconUrgencyOverlay.urgency(pendingCount:hasUrgent:)` 已備。
  - 待決定：urgent 的視覺語言要用什麼（再換一色？加速掃描？脈動？）→ 待新需求。

---

## Popover（點小精靈開啟的面板）

> 現況紀錄，之後可能要調整或新增狀態。實作在 `ContentView.swift` + `PopoverViewModel.swift`，事件接線在 `AppDelegate`。

現有分區：
- **審批卡片區**：每個 pending 一張卡。動作 = Allow / Always Allow / Deny / Dismiss（過期項）。可展開看該 session 用量明細（`onToggleExpand`）。
- **Session 狀態列**（常駐）：近 5h token 用量 %、burn rate、成本估算。
- **Auto 模式列**：per-agent（claude-code / agy）自動放行開關，30 分鐘 TTL + 倒數。
- **agy quota**：agy 額度顯示。
- **空狀態**（無 pending）：只顯示 Session 狀態列 + Auto 模式列。

待辦（佔位，待補具體項目）：
- [ ] popover 要調整/新增的項目 → 待補充

---

## 已移除（歷史紀錄，避免重做）

- ~~T2 token% 水位填充~~（覺得不美觀 → 移除 `IconFillMeter.swift`）
- ~~T3 CPU 負載反轉 + `CPUMonitor.swift`~~（要求移除，腳擺回固定速度）
- ~~藍色 frightened 臉當 pending~~（改成**黃色 Blinky + 眼睛掃描**）
