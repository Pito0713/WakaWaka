#!/usr/bin/env node
import { assessBashRisk, readStdin } from './codex-hook-shared.mjs';

function denyToolUse(reason) {
  process.stdout.write(`${JSON.stringify({
    hookSpecificOutput: {
      hookEventName: 'PreToolUse',
      permissionDecision: 'deny',
      permissionDecisionReason: reason,
    },
  })}\n`);
}

async function main() {
  let input;
  try {
    input = JSON.parse(await readStdin());
  } catch {
    denyToolUse('WakaWaka received malformed hook input');
    return;
  }

  const toolName = input?.tool_name ?? input?.toolName ?? input?.name;
  const toolInput = input?.tool_input ?? input?.toolInput ?? input?.arguments ?? {};
  if (toolName !== 'Bash') return;
  if (assessBashRisk(toolInput?.command) !== 'critical') return;
  denyToolUse('WakaWaka blocked a critical shell action');
}

main();
