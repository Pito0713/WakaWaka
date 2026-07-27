#!/usr/bin/env node
import * as fs from 'node:fs';
import * as os from 'node:os';
import * as path from 'node:path';
import { randomUUID } from 'node:crypto';
import {
  assessBashRisk,
  getBashPrefix,
  hasUnsafeShellSyntax,
  isSimpleShellCommand,
  readStdin,
  sanitizeIdentifier,
} from './codex-hook-shared.mjs';

const AGENT_NAME = 'codex';
const STATE_DIRECTORY = process.env.WAKAWAKA_STATE_DIR
  ?? path.join(os.homedir(), '.wakawaka', 'state');
const ALLOWLIST_PATH = process.env.WAKAWAKA_ALLOWLIST_PATH
  ?? path.join(os.homedir(), '.wakawaka', 'allowlist.json');
const SETTINGS_PATH = process.env.WAKAWAKA_SETTINGS_PATH
  ?? path.join(os.homedir(), '.wakawaka', 'settings.json');
const AUTO_AUDIT_PATH = process.env.WAKAWAKA_AUDIT_PATH
  ?? path.join(os.homedir(), '.wakawaka', 'auto-audit.jsonl');
const POLL_INTERVAL_MS = Number.parseInt(process.env.POLL_INTERVAL_MS ?? '200', 10);
const FINAL_TIMEOUT_MS = Number.parseInt(process.env.FINAL_TIMEOUT_MS ?? '590000', 10);

function respond(behavior, message) {
  const decision = { behavior };
  if (message) decision.message = message;
  process.stdout.write(`${JSON.stringify({
    hookSpecificOutput: { hookEventName: 'PermissionRequest', decision },
  })}\n`);
}

function loadJson(jsonPath, fallback) {
  try {
    return JSON.parse(fs.readFileSync(jsonPath, 'utf8'));
  } catch {
    return fallback;
  }
}

function isAutoModeEnabled() {
  const autoMode = loadJson(SETTINGS_PATH, {})?.autoMode?.[AGENT_NAME];
  if (autoMode?.enabled !== true) return false;
  if (autoMode.expiresAt == null) return true;
  const expiry = new Date(autoMode.expiresAt).getTime();
  return !Number.isNaN(expiry) && expiry >= Date.now();
}

function appendAutoAudit(toolName, toolInput) {
  try {
    const command = toolInput?.command;
    const summary = typeof command === 'string'
      ? command.split('\n')[0].slice(0, 80)
      : `${toolName} ${toolInput?.file_path ?? ''}`.trim();
    fs.mkdirSync(path.dirname(AUTO_AUDIT_PATH), { recursive: true, mode: 0o700 });
    fs.appendFileSync(AUTO_AUDIT_PATH, `${JSON.stringify({
      ts: new Date().toISOString(),
      agent: AGENT_NAME,
      tool_name: toolName,
      risk_level: 'medium',
      summary,
    })}\n`, { encoding: 'utf8', mode: 0o600 });
    return true;
  } catch {
    return false;
  }
}

function isAllowlisted(command) {
  if (hasUnsafeShellSyntax(command)) return false;
  const prefix = getBashPrefix(command);
  if (!prefix) return false;
  const allowlist = loadJson(ALLOWLIST_PATH, { bashPrefixes: [] });
  return Array.isArray(allowlist.bashPrefixes) && allowlist.bashPrefixes.includes(prefix);
}

function saveBashPrefix(command) {
  const prefix = getBashPrefix(command);
  if (!prefix || hasUnsafeShellSyntax(command)) return false;
  try {
    const allowlist = loadJson(ALLOWLIST_PATH, { bashPrefixes: [] });
    const prefixes = Array.isArray(allowlist.bashPrefixes) ? allowlist.bashPrefixes : [];
    if (prefixes.includes(prefix)) return true;
    fs.mkdirSync(path.dirname(ALLOWLIST_PATH), { recursive: true, mode: 0o700 });
    fs.writeFileSync(ALLOWLIST_PATH,
      JSON.stringify({ ...allowlist, bashPrefixes: [...prefixes, prefix] }),
      { encoding: 'utf8', mode: 0o600 });
    return true;
  } catch {
    return false;
  }
}

function normalizeInput(input) {
  const sessionId = input?.session_id ?? input?.sessionId;
  const toolName = input?.tool_name ?? input?.toolName ?? input?.name;
  if (typeof sessionId !== 'string' || !sessionId || typeof toolName !== 'string' || !toolName) {
    throw new Error('Missing required PermissionRequest fields');
  }
  return {
    sessionId,
    turnId: input?.turn_id ?? input?.turnId ?? null,
    toolName,
    toolInput: input?.tool_input ?? input?.toolInput ?? input?.arguments ?? {},
    permissionMode: input?.permission_mode ?? input?.permissionMode ?? null,
    transcriptPath: input?.transcript_path ?? input?.transcriptPath ?? null,
  };
}

function waitForDecision(decisionPath) {
  return new Promise((resolve) => {
    const deadline = Date.now() + FINAL_TIMEOUT_MS;
    const timer = setInterval(() => {
      try {
        const decision = JSON.parse(fs.readFileSync(decisionPath, 'utf8'));
        clearInterval(timer);
        resolve(decision);
        return;
      } catch {
        // The reviewer has not written a valid decision yet.
      }
      if (Date.now() < deadline) return;
      clearInterval(timer);
      resolve({ decision: 'deny', reason: 'Review timeout', timedOut: true });
    }, POLL_INTERVAL_MS);
  });
}

function removeStateFile(statePath) {
  try {
    fs.rmSync(statePath);
    return true;
  } catch (error) {
    return error?.code === 'ENOENT';
  }
}

function markPendingExited(pendingPath) {
  try {
    const pending = JSON.parse(fs.readFileSync(pendingPath, 'utf8'));
    fs.writeFileSync(pendingPath, JSON.stringify({
      ...pending,
      hookExited: true,
      hookExitedAt: new Date().toISOString(),
    }), { encoding: 'utf8', mode: 0o600 });
    return true;
  } catch (error) {
    return error?.code === 'ENOENT';
  }
}

async function requestReview(input, riskLevel) {
  const approvalId = `permission_codex_${sanitizeIdentifier(randomUUID())}`;
  const pendingPath = path.join(STATE_DIRECTORY, `pending_${approvalId}.json`);
  const decisionPath = path.join(STATE_DIRECTORY, `decision_${approvalId}.json`);
  try {
    fs.mkdirSync(STATE_DIRECTORY, { recursive: true, mode: 0o700 });
    if (!removeStateFile(decisionPath)) {
      respond('deny', 'WakaWaka could not clear stale approval state');
      return;
    }
    fs.writeFileSync(pendingPath, JSON.stringify({
      session_id: approvalId,
      codex_session_id: input.sessionId,
      codex_turn_id: input.turnId,
      tool_name: input.toolName,
      tool_input: input.toolInput,
      risk_level: riskLevel,
      permission_mode: input.permissionMode,
      transcript_path: input.transcriptPath,
      timestamp: new Date().toISOString(),
      agent: AGENT_NAME,
      hook_event: 'PermissionRequest',
    }), { encoding: 'utf8', mode: 0o600 });
  } catch {
    respond('deny', 'WakaWaka state directory is unavailable');
    return;
  }

  const result = await waitForDecision(decisionPath);
  if (!removeStateFile(decisionPath)) {
    respond('deny', 'WakaWaka could not clean approval state');
    return;
  }
  const isPendingClean = result?.timedOut
    ? markPendingExited(pendingPath)
    : removeStateFile(pendingPath);
  if (!isPendingClean) {
    respond('deny', 'WakaWaka could not clean approval state');
    return;
  }

  if (result?.decision === 'allow') {
    respond('allow', 'Approved via WakaWaka');
    return;
  }
  if (result?.decision === 'always') {
    const canSave = input.toolName !== 'Bash'
      || riskLevel !== 'medium'
      || saveBashPrefix(input.toolInput?.command);
    if (!canSave) {
      respond('deny', 'WakaWaka could not save the allowlist rule');
      return;
    }
    respond('allow', 'User selected Always Allow');
    return;
  }
  respond('deny', result?.reason ?? 'Denied via WakaWaka');
}

async function main() {
  let input;
  try {
    input = normalizeInput(JSON.parse(await readStdin()));
  } catch {
    respond('deny', 'WakaWaka received malformed hook input');
    return;
  }
  const command = input.toolInput?.command;
  const riskLevel = input.toolName === 'Bash' ? assessBashRisk(command) : 'medium';
  if (riskLevel === 'critical') {
    respond('deny', 'WakaWaka blocked a critical shell action');
    return;
  }
  if (riskLevel === 'medium' && input.toolName === 'Bash' && isAllowlisted(command)) {
    respond('allow', `Bash prefix "${getBashPrefix(command)}" is in the user allowlist`);
    return;
  }
  const isAutoEligible = input.toolName === 'apply_patch'
    || (input.toolName === 'Bash' && isSimpleShellCommand(command));
  if (riskLevel === 'medium' && isAutoEligible && isAutoModeEnabled()
      && appendAutoAudit(input.toolName, input.toolInput)) {
    respond('allow', 'Auto mode: medium action auto-approved');
    return;
  }
  await requestReview(input, riskLevel);
}

main();
