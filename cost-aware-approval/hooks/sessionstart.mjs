#!/usr/bin/env node
/**
 * sessionstart.mjs — SessionStart hook for Claude Code and Codex.
 *
 * Creates the registry entry that makes the session visible in WakaWaka's
 * active-agents panel, then exits. One process per session; the per-turn and
 * per-tool updates are handled by cheaper hooks.
 *
 * This hook never blocks or influences the agent: it always exits 0, whatever
 * happens. A panel that cannot list a session is a cosmetic problem; a hook
 * that fails a session start is not.
 */

import {
  buildEntry, detectKind, detectSessionId, isInternalInvocation,
  isValidSessionId, readHookInput, writeEntry,
} from './agent-registry.mjs';

async function main() {
  // WakaWaka runs `claude -p "/usage"` on a timer; without this it would
  // register itself and the panel would blink a phantom session every 10 min.
  if (isInternalInvocation()) return;

  const payload = await readHookInput();
  const kind = detectKind(payload);
  const sessionId = detectSessionId(payload);
  if (!kind || !isValidSessionId(sessionId)) return;

  writeEntry(buildEntry({
    kind,
    sessionId,
    cwd: payload.cwd ?? process.cwd(),
    gitBranch: payload.gitBranch ?? null,
    model: payload.model ?? null,
  }));
}

main()
  .catch(() => { /* never fail the session over a panel entry */ })
  .finally(() => process.exit(0));
