#!/usr/bin/env node
import * as fs from 'node:fs';
import * as os from 'node:os';
import * as path from 'node:path';
import { randomUUID } from 'node:crypto';
const AGENT_NAME = 'codex';
const STATE_DIR = process.env.WAKAWAKA_STATE_DIR
  ?? path.join(os.homedir(), '.wakawaka', 'state');
const ALLOWLIST_PATH = process.env.WAKAWAKA_ALLOWLIST_PATH
  ?? path.join(os.homedir(), '.wakawaka', 'allowlist.json');
const SETTINGS_PATH = process.env.WAKAWAKA_SETTINGS_PATH
  ?? path.join(os.homedir(), '.wakawaka', 'settings.json');
const AUTO_AUDIT_PATH = process.env.WAKAWAKA_AUDIT_PATH
  ?? path.join(os.homedir(), '.wakawaka', 'auto-audit.jsonl');
const POLL_INTERVAL_MS = Number.parseInt(process.env.POLL_INTERVAL_MS ?? '200', 10);
const FINAL_TIMEOUT_MS = Number.parseInt(process.env.FINAL_TIMEOUT_MS ?? '590000', 10);
const SAFE_BASH_PREFIXES = new Set([
  'ls', 'which', 'whereis', 'type', 'file', 'stat', 'du', 'df',
  'cat', 'head', 'tail', 'wc',
  'grep', 'egrep', 'fgrep', 'rg', 'ag', 'jq',
  'pgrep', 'ps', 'lsof', 'uptime', 'pwd', 'whoami',
]);
const CRITICAL_PATTERNS = [
  /\bdd\b[^|&;\n]*\bof=\/dev\/(sd[a-z]+|nvme[0-9]+n[0-9]+|disk[0-9]+)/,
  /\b(mkfs|newfs)\b/,
  /:\(\)\s*\{[^}]*:\s*\|\s*:&/,
  /\b(curl|wget|fetch)\b[^|&;\n]*\|\s*-?\s*(su|ba|da|z|fi|c)?sh\b/,
  />\s*\/dev\/(sd[a-z]+|nvme[0-9]+n[0-9]+|disk[0-9]+)(\s|$)/,
  /\bsudo\s+rm\b/,
];
const HIGH_PATTERNS = [
  /\bsudo\b/,
  /\bgit\s+push\b[^|&;\n]*(--force|-f)\b/,
  /\bgit\s+reset\s+--hard\b/,
  /\bgit\s+clean\b[^|&;\n]*-[a-zA-Z]*f/,
  /\bchmod\b/,
  /\bchown\b/,
  /\bkill\b|\bpkill\b|\bkillall\b/,
  /\bnpm\s+(install|i)\s+(-g|--global)\b/,
  /\bpip3?\s+install\b(?!\s+--user)/,
  /\brsync\b[^|&;\n]*--delete\b/,
  /\bssh\s+/,
  /\bdrop\s+(database|table|schema)\b/i,
  /\btruncate\s+(table\s+)?\w/i,
];
function decide(permissionDecision, permissionDecisionReason) {
  const hookSpecificOutput = {
    hookEventName: 'PreToolUse',
    permissionDecision,
  };
  if (permissionDecisionReason) {
    hookSpecificOutput.permissionDecisionReason = permissionDecisionReason;
  }
  process.stdout.write(`${JSON.stringify({ hookSpecificOutput })}\n`);
}
function assessBashRisk(command) {
  const normalizedCommand = typeof command === 'string' ? command.trim() : '';
  const rmRisk = assessRmRisk(normalizedCommand);
  if (rmRisk) return rmRisk;
  if (CRITICAL_PATTERNS.some((pattern) => pattern.test(normalizedCommand))) return 'critical';
  if (HIGH_PATTERNS.some((pattern) => pattern.test(normalizedCommand))) return 'high';
  return 'medium';
}
function stripWrappingQuotes(token) {
  if (token.length >= 2 && (
    (token.startsWith('"') && token.endsWith('"'))
    || (token.startsWith("'") && token.endsWith("'"))
  )) return token.slice(1, -1);
  return token;
}
function isCatastrophicRmTarget(rawTarget) {
  const target = stripWrappingQuotes(rawTarget);
  if (target === '~' || target.startsWith('~/')) return true;
  if (target === '$HOME' || target.startsWith('$HOME/')) return true;
  if (target === '${HOME}' || target.startsWith('${HOME}/')) return true;
  const normalizedTarget = path.posix.normalize(target);
  if (target.startsWith('/') && normalizedTarget === '/') return true;
  return /^\/+(?:[*?]|\[)/.test(normalizedTarget);
}
function assessRmRisk(command) {
  const tokens = command.split(/\s+/);
  const rmIndex = tokens.findIndex((token) => path.posix.basename(stripWrappingQuotes(token)) === 'rm');
  if (rmIndex < 0) return false;
  const argumentsList = tokens.slice(rmIndex + 1);
  const hasRecursive = argumentsList.some((argument) =>
    argument === '--recursive' || /^-[^-]*r/.test(argument));
  const hasForce = argumentsList.some((argument) =>
    argument === '--force' || /^-[^-]*f/.test(argument));
  if (!hasRecursive || !hasForce) return null;
  return argumentsList.some(isCatastrophicRmTarget) ? 'critical' : 'high';
}
function getBashPrefix(command) {
  if (typeof command !== 'string') return null;
  return command.trim().split(/\s+/)[0] || null;
}
function hasShellSubstitution(command) {
  return /\$\(|`/.test(command);
}
function hasDangerousToolOption(command) {
  const prefix = getBashPrefix(command);
  return prefix === 'rg' && /(?:^|\s)--pre(?:-glob)?(?:=|\s|$)/.test(command);
}
function isSimpleShellCommand(command) {
  return typeof command === 'string'
    && !/[|&;><\n]/.test(command)
    && !hasShellSubstitution(command)
    && !hasDangerousToolOption(command);
}
function isSafeReadCommand(command) {
  if (!isSimpleShellCommand(command)) return false;
  const prefix = getBashPrefix(command);
  if (!prefix || !SAFE_BASH_PREFIXES.has(prefix)) return false;
  if (hasDangerousToolOption(command)) return false;
  return true;
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
  const expiresAt = new Date(autoMode.expiresAt).getTime();
  return !Number.isNaN(expiresAt) && expiresAt >= Date.now();
}
function appendAutoAudit(toolName, toolInput) {
  try {
    const command = toolInput?.command;
    const summary = typeof command === 'string'
      ? command.split('\n')[0].slice(0, 80)
      : `${toolName} ${toolInput?.file_path ?? ''}`.trim();
    const auditEntry = {
      ts: new Date().toISOString(),
      agent: AGENT_NAME,
      tool_name: toolName,
      risk_level: 'medium',
      summary,
    };
    fs.mkdirSync(path.dirname(AUTO_AUDIT_PATH), { recursive: true, mode: 0o700 });
    fs.appendFileSync(AUTO_AUDIT_PATH, `${JSON.stringify(auditEntry)}\n`, {
      encoding: 'utf8',
      mode: 0o600,
    });
    return true;
  } catch {
    return false;
  }
}
function isAllowlisted(command) {
  if (typeof command !== 'string'
      || /[|&;><\n]/.test(command)
      || hasShellSubstitution(command)
      || hasDangerousToolOption(command)) {
    return false;
  }
  const prefix = getBashPrefix(command);
  if (!prefix) return false;
  const allowlist = loadJson(ALLOWLIST_PATH, { bashPrefixes: [] });
  return Array.isArray(allowlist.bashPrefixes) && allowlist.bashPrefixes.includes(prefix);
}
function saveBashPrefix(command) {
  const prefix = getBashPrefix(command);
  if (!prefix) return;
  const allowlist = loadJson(ALLOWLIST_PATH, { bashPrefixes: [] });
  const bashPrefixes = Array.isArray(allowlist.bashPrefixes) ? allowlist.bashPrefixes : [];
  if (bashPrefixes.includes(prefix)) return;
  fs.mkdirSync(path.dirname(ALLOWLIST_PATH), { recursive: true, mode: 0o700 });
  fs.writeFileSync(ALLOWLIST_PATH, JSON.stringify({ ...allowlist, bashPrefixes: [...bashPrefixes, prefix] }), {
    encoding: 'utf8',
    mode: 0o600,
  });
}
async function readStdin() {
  const chunks = [];
  for await (const chunk of process.stdin) chunks.push(chunk);
  return Buffer.concat(chunks).toString('utf8').trim();
}
function waitForDecision(decisionPath) {
  return new Promise((resolve) => {
    const deadline = Date.now() + FINAL_TIMEOUT_MS;
    const timer = setInterval(() => {
      try {
        const decision = JSON.parse(fs.readFileSync(decisionPath, 'utf8'));
        clearInterval(timer);
        try { fs.unlinkSync(decisionPath); } catch { /* already removed */ }
        resolve(decision);
        return;
      } catch { /* waiting for review */ }
      if (Date.now() >= deadline) {
        clearInterval(timer);
        resolve({ decision: 'deny', reason: 'Review timeout', timedOut: true });
      }
    }, POLL_INTERVAL_MS);
  });
}
function normalizeInput(input) {
  return {
    sessionId: input?.session_id ?? input?.sessionId ?? randomUUID(),
    toolUseId: input?.tool_use_id ?? input?.toolUseId ?? null,
    toolName: input?.tool_name ?? input?.toolName ?? input?.name ?? null,
    toolInput: input?.tool_input ?? input?.toolInput ?? input?.arguments ?? {},
    transcriptPath: input?.transcript_path ?? input?.transcriptPath ?? null,
  };
}
function sanitizeIdentifier(identifier) {
  return String(identifier).replace(/[^a-zA-Z0-9_-]/g, '_');
}
function markPendingExited(pendingPath) {
  try {
    const pending = JSON.parse(fs.readFileSync(pendingPath, 'utf8'));
    pending.hookExited = true;
    pending.hookExitedAt = new Date().toISOString();
    fs.writeFileSync(pendingPath, JSON.stringify(pending), { encoding: 'utf8', mode: 0o600 });
  } catch {
    // Pending may have been dismissed while the hook exited.
  }
}
async function main() {
  let normalizedInput;
  try {
    normalizedInput = normalizeInput(JSON.parse(await readStdin()));
  } catch {
    decide('deny', 'WakaWaka received malformed hook input');
    return;
  }
  const { toolName, toolInput, transcriptPath } = normalizedInput;
  const command = toolInput?.command;
  const riskLevel = toolName === 'Bash' ? assessBashRisk(command) : 'medium';

  if (riskLevel === 'critical') {
    decide('deny', 'WakaWaka blocked a critical shell action');
    return;
  }
  if (toolName === 'Bash' && riskLevel === 'medium') {
    const prefix = getBashPrefix(command);
    if (isSafeReadCommand(command)) {
      decide('allow', `"${prefix}" is an auto-approved read command`);
      return;
    }
    if (isAllowlisted(command)) {
      decide('allow', `Bash prefix "${prefix}" is in the user allowlist`);
      return;
    }
  }
  const isAutoEligible = toolName === 'apply_patch'
    || (toolName === 'Bash' && isSimpleShellCommand(command));
  if (riskLevel === 'medium' && isAutoEligible && isAutoModeEnabled()) {
    if (appendAutoAudit(toolName, toolInput)) {
      decide('allow', 'Auto mode: medium action auto-approved');
      return;
    }
  }
  const codexSessionId = sanitizeIdentifier(normalizedInput.sessionId) || randomUUID();
  const rawApprovalId = normalizedInput.toolUseId ?? randomUUID();
  const sanitizedToolUseId = sanitizeIdentifier(rawApprovalId) || randomUUID();
  const approvalId = `codex_${sanitizedToolUseId}`;
  const pendingPath = path.join(STATE_DIR, `pending_${approvalId}.json`);
  const decisionPath = path.join(STATE_DIR, `decision_${approvalId}.json`);
  try {
    fs.mkdirSync(STATE_DIR, { recursive: true, mode: 0o700 });
    try { fs.unlinkSync(decisionPath); } catch { /* no stale decision */ }
    fs.writeFileSync(pendingPath, JSON.stringify({
      session_id: approvalId,
      codex_session_id: codexSessionId,
      tool_use_id: normalizedInput.toolUseId,
      tool_name: toolName,
      tool_input: toolInput,
      risk_level: riskLevel,
      transcript_path: transcriptPath,
      timestamp: new Date().toISOString(),
      agent: AGENT_NAME,
    }), { encoding: 'utf8', mode: 0o600 });
  } catch {
    decide('deny', 'WakaWaka state directory is unavailable');
    return;
  }
  const result = await waitForDecision(decisionPath);
  try { fs.unlinkSync(decisionPath); } catch { /* already removed */ }
  if (result?.timedOut) {
    markPendingExited(pendingPath);
  } else {
    try { fs.unlinkSync(pendingPath); } catch { /* already removed */ }
  }
  if (result?.decision === 'allow') {
    decide('allow');
    return;
  }
  if (result?.decision === 'always') {
    if (toolName === 'Bash' && riskLevel === 'medium') saveBashPrefix(command);
    decide('allow', 'User selected Always Allow');
    return;
  }
  decide('deny', result?.reason ?? 'User denied via WakaWaka');
}
main();
