<!-- agent-skill:begin -->
## Agent Skill adapter（claude）

@~/.claude/skills/rules/coding-standards.md
@~/.claude/skills/rules/security.md

其餘 skill 優先使用 native discovery（`.claude/skills/`）；未命中時讀取
`~/Agent_skill/skills/index.json` 查 package 路徑，再完整載入對應 `SKILL.md`。
<!-- agent-skill:end -->

# WakaWaka

> 專案 AI 行為規範。由 Agent Skill 自動生成。

---

## 常駐載入（Agent Skill）

@~/.claude/skills/rules/coding-standards.md
@~/.claude/skills/rules/security.md
@~/.claude/skills/rules/git.md
@~/.claude/skills/coding-workflow-core/SKILL.md
@~/.claude/skills/handoff/SKILL.md
@~/.claude/skills/version-log/SKILL.md

## 按需載入（視任務加入）

> 以下項目預設註解，移除 # 即可啟用

@~/.claude/skills/agy-assist/SKILL.md
# @~/.claude/skills/rules/typescript.md
# @~/.claude/skills/rules/python.md
# @~/.claude/skills/coding-workflow-ref/SKILL.md
# @~/.claude/skills/feedback-loop/SKILL.md
# @~/.claude/skills/concrete-example/SKILL.md
# @~/.claude/skills/academic-mentor/SKILL.md
# @~/.claude/skills/mentor-neuro/SKILL.md
# @~/.claude/skills/mentor-society/SKILL.md
# @~/.claude/skills/mentor-science/SKILL.md
# @~/.claude/skills/mentor-tech/SKILL.md
# @~/.claude/skills/mentor-invest/SKILL.md
# @~/.claude/skills/wireframing/SKILL.md
# @~/.claude/skills/ui-visual-design/SKILL.md
# @~/.claude/skills/information-architecture/SKILL.md
# @~/.claude/skills/obsidian-query/SKILL.md
# @~/.claude/skills/obsidian-save/SKILL.md

## 制度層路由（governance，用到才讀，不要 @ 常駐）

> 情境命中時再讀對應檔案，讀完就動手：
> - 要委派 subagent / 選 model → ~/.claude/governance/model-orchestration.md
> - 判斷完成了沒 / 該不該升級 / 該不該問人 → ~/.claude/governance/judgment-rubrics.md
> - 要寫派工 prompt → ~/.claude/governance/delegation-templates.md
> - 踩坑教訓查詢與 append → ~/.claude/governance/lessons.md
---

## 溝通規範

- 繁體中文溝通，技術詞彙保留英文
- 回應給極短摘要，再給可執行內容
- 指出邏輯漏洞、不為友善而同意
