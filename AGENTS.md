<!-- agent-skill:begin -->
## Agent Skill adapter（codex）

**開工必讀**（安全底線，不得略過）：`~/Agent_skill/rules/coding-standards.md`、
`~/Agent_skill/rules/security.md`

其餘 skill 優先使用 native discovery（`.codex/skills/`）；未命中時讀取
`~/Agent_skill/skills/index.json` 查 package 路徑，再完整載入對應 `SKILL.md`。
<!-- agent-skill:end -->

# WakaWaka

> 專案 AI 行為規範。由 Agent Skill 自動生成。

---

## 常駐載入（Agent Skill）

@~/.Codex/skills/rules/coding-standards.md
@~/.Codex/skills/rules/security.md
@~/.Codex/skills/rules/git.md
@~/.Codex/skills/engineering/coding-workflow-core.md
@~/.Codex/skills/productivity/handoff.md
@~/.Codex/skills/productivity/version-log.md

## 按需載入（視任務加入）

> 以下項目預設註解，移除 # 即可啟用

@~/.Codex/skills/engineering/gemini-assist.md
# @~/.Codex/skills/rules/typescript.md
# @~/.Codex/skills/rules/python.md
# @~/.Codex/skills/engineering/coding-workflow-ref.md
# @~/.Codex/skills/learning/feedback-loop.md
# @~/.Codex/skills/learning/concrete-example.md
# @~/.Codex/skills/learning/academic-mentor.md
# @~/.Codex/skills/learning/mentor-neuro.md
# @~/.Codex/skills/learning/mentor-society.md
# @~/.Codex/skills/learning/mentor-science.md
# @~/.Codex/skills/learning/mentor-tech.md
# @~/.Codex/skills/learning/mentor-invest.md
# @~/.Codex/skills/design/wireframing.md
# @~/.Codex/skills/design/ui-visual-design.md
# @~/.Codex/skills/design/information-architecture.md
# @~/.Codex/skills/productivity/obsidian-query.md
# @~/.Codex/skills/productivity/obsidian-save.md

## 制度層路由（governance，用到才讀，不要 @ 常駐）

> 情境命中時再讀對應檔案，讀完就動手：
> - 要委派 subagent / 選 model → ~/.Codex/governance/model-orchestration.md
> - 判斷完成了沒 / 該不該升級 / 該不該問人 → ~/.Codex/governance/judgment-rubrics.md
> - 要寫派工 prompt → ~/.Codex/governance/delegation-templates.md
> - 踩坑教訓查詢與 append → ~/.Codex/governance/lessons.md
---

## 溝通規範

- 繁體中文溝通，技術詞彙保留英文
- 回應給極短摘要，再給可執行內容
- 指出邏輯漏洞、不為友善而同意
