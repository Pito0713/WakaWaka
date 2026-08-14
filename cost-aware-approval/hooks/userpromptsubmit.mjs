#!/usr/bin/env node
/**
 * userpromptsubmit.mjs — UserPromptSubmit hook.
 *
 * Marks the session as working, and records a skill name when the turn was
 * started by a slash command. Only the command name is stored — never the
 * prompt text, which is what keeps the registry free of user content.
 */

import {
  detectKind, detectSessionId, isInternalInvocation,
  isValidSessionId, readHookInput, updateEntry,
} from './agent-registry.mjs';

/**
 * Extracts the command name from a slash-command prompt.
 *
 * Deliberately narrow: the name must look like a command, so an ordinary
 * message that happens to begin with "/" (a path, a fraction) does not get
 * recorded, and no part of the prompt body can leak into the registry.
 */
export function slashCommandName(prompt) {
  if (typeof prompt !== 'string') return null;
  const match = prompt.trimStart().match(/^\/([A-Za-z0-9][A-Za-z0-9:_-]{0,63})(?=\s|$)/);
  return match ? match[1] : null;
}

async function main() {
  if (isInternalInvocation()) return;

  const payload = await readHookInput();
  const kind = detectKind(payload);
  const sessionId = detectSessionId(payload);
  if (!kind || !isValidSessionId(sessionId)) return;

  const skill = slashCommandName(payload.prompt);
  updateEntry(kind, sessionId, () => (
    skill
      ? { state: 'working', skill, skillSource: 'slash' }
      : { state: 'working' }
  ));
}

main()
  .catch(() => { /* never fail a turn over a panel entry */ })
  .finally(() => process.exit(0));
