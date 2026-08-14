#!/usr/bin/env node
/**
 * sessionend.mjs — SessionEnd hook.
 *
 * Removes the registry entry. This is the clean exit path; the pid liveness
 * check in WakaWaka exists for the sessions that never get here (a crash, a
 * `kill -9`), where no hook runs to tidy up.
 */

import {
  detectKind, detectSessionId, deleteEntry,
  isInternalInvocation, isValidSessionId, readHookInput,
} from './agent-registry.mjs';

async function main() {
  if (isInternalInvocation()) return;

  const payload = await readHookInput();
  const kind = detectKind(payload);
  const sessionId = detectSessionId(payload);
  if (!kind || !isValidSessionId(sessionId)) return;

  deleteEntry(kind, sessionId);
}

main()
  .catch(() => { /* never fail session teardown over a panel entry */ })
  .finally(() => process.exit(0));
