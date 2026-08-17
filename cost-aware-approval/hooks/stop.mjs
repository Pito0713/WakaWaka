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

  // Update only: the end of a turn is also when `SessionEnd` fires, and a Stop
  // hook that lands after it would re-create the entry its own session just
  // deleted — a finished session back on the panel until the liveness sweep
  // notices. Registering belongs to the events that open a turn, not close one.
  updateEntry(kind, sessionId, () => ({
    state: 'idle',
    skill: null,
    skillSource: null,
  }));
}

main()
  .catch(() => { /* never fail a turn over a panel entry */ })
  .finally(() => process.exit(0));
