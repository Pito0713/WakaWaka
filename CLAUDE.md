<!-- agent-skill:begin -->
## Agent Skill adapter（claude）

@~/.claude/skills/rules/coding-standards.md
@~/.claude/skills/rules/security.md

其餘 skill 優先使用 native discovery（`.claude/skills/`）；未命中時讀取
`~/Agent_skill/skills/index.json` 查 package 路徑，再完整載入對應 `SKILL.md`。
<!-- agent-skill:end -->
