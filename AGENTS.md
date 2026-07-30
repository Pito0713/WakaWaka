<!-- agent-skill:begin -->
## Agent Skill adapter（codex）

**開工必讀**（安全底線，不得略過）：`~/Agent_skill/rules/coding-standards.md`、
`~/Agent_skill/rules/security.md`

其餘 skill 優先使用 native discovery（`.codex/skills/`）；未命中時讀取
`~/Agent_skill/skills/index.json` 查 package 路徑，再完整載入對應 `SKILL.md`。
<!-- agent-skill:end -->
