#!/usr/bin/env node
/**
 * stop.mjs — Stop hook.
 *
 * The turn is over: the session goes idle and the skill is cleared, because a
 * skill belongs to the turn that invoked it. Leaving it set would make the
 * panel claim a session is still running a skill it finished minutes ago.
 */

import {
  detectKind, detectSessionId, isInternalInvocation,
  isValidSessionId, readHookInput, updateEntry,
} from './agent-registry.mjs';

async function main() {
  if (isInternalInvocation()) return;

  const payload = await readHookInput();
  const kind = detectKind(payload);
  const sessionId = detectSessionId(payload);
  if (!kind || !isValidSessionId(sessionId)) return;

  updateEntry(kind, sessionId, () => ({
    state: 'idle',
    skill: null,
    skillSource: null,
  }));
}

main()
  .catch(() => { /* never fail a turn over a panel entry */ })
  .finally(() => process.exit(0));
