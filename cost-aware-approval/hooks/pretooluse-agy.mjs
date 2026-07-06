#!/usr/bin/env node
/**
 * WakaWaka PreToolUse Hook — agy (Antigravity CLI)
 *
 * Same IPC protocol as pretooluse.mjs but adapted for agy's tool names.
 * agy uses snake_case tool names (run_command, view_file, replace_file_content…)
 * and may send either { tool_name, tool_input } or { name, args } in stdin.
 *
 * Routing:
 *   AUTO_ALLOW_TOOLS    — read-only tools, never show popover
 *   SAFE_SHELL_PREFIXES — safe shell prefixes for run_command (MEDIUM risk)
 *   HIGH / CRITICAL     — always show or auto-deny
 *   Writes / Deletes    — always show popover
 */

import * as fs from 'fs';
import * as os from 'os';
import * as path from 'path';
import { randomUUID } from 'node:crypto';
import { spawnSync } from 'node:child_process';

const STATE_DIR      = path.join(os.homedir(), '.wakawaka', 'state');
const ALLOWLIST_PATH = path.join(os.homedir(), '.wakawaka', 'allowlist.json');
const SETTINGS_PATH  = process.env.WAKAWAKA_SETTINGS_PATH
  ?? path.join(os.homedir(), '.wakawaka', 'settings.json');
const AUTO_AUDIT_PATH = process.env.WAKAWAKA_AUDIT_PATH
  ?? path.join(os.homedir(), '.wakawaka', 'auto-audit.jsonl');
const AGENT_NAME     = 'agy';

// ── Timing constants (match pretooluse.mjs) ───────────────────────────────────
const POLL_INTERVAL_MS   = 200;
const APP_CHECK_EVERY_MS = parseInt(process.env.APP_CHECK_EVERY_MS ?? '5000',  10);
const APP_DEAD_GRACE_MS  = parseInt(process.env.APP_DEAD_GRACE_MS  ?? '30000', 10);
const WARN_TIMEOUT_MS    = parseInt(process.env.WARN_TIMEOUT_MS    ?? '480000', 10);
const FINAL_TIMEOUT_MS   = parseInt(process.env.FINAL_TIMEOUT_MS   ?? '590000', 10);

// ── Auto-allow: read-only agy tools ──────────────────────────────────────────
const AUTO_ALLOW_TOOLS = new Set([
  'view_file',
  'read_file',
  'list_dir',
  'list_permissions',   // read-only permission info
  'grep_search',
  'search_files',
  'manage_task',        // in-memory task list, no disk side-effects
  'schedule',           // scheduling only, no execution
  'search_web',
  'read_url_content',
  'define_subagent',
  'invoke_subagent',
  'manage_subagents',
  'send_message',
  'ask_permission',
  'ask_question',
  'generate_image',
]);

// ── Safe shell prefixes for run_command (MEDIUM risk) ────────────────────────
const SAFE_SHELL_PREFIXES = new Set([
  'ls', 'find', 'which', 'whereis', 'type', 'file', 'stat', 'du', 'df', 'tree',
  'cat', 'head', 'tail', 'wc', 'diff', 'less', 'more',
  'grep', 'egrep', 'fgrep', 'rg', 'ag', 'awk', 'jq',
  'echo', 'printf', 'env', 'printenv', 'uname', 'hostname', 'whoami', 'id',
  'pwd', 'date', 'time', 'cd', 'sleep',
  'pgrep', 'ps', 'lsof', 'uptime',
  'git',
  'curl', 'wget', 'ping', 'nslookup', 'dig', 'host', 'traceroute', 'netstat', 'ss',
  'base64', 'xxd', 'hexdump', 'md5', 'md5sum', 'sha256sum', 'shasum',
  'open', 'defaults', 'pbpaste', 'pbcopy', 'osascript', 'plutil',
  'codesign', 'otool', 'nm', 'say',
  'swift', 'swiftc', 'npx', 'node', 'python', 'python3', 'pip', 'pip3',
  'npm', 'yarn', 'pnpm', 'bun', 'brew', 'go', 'cargo', 'make',
]);

// ── CRITICAL patterns ─────────────────────────────────────────────────────────
const CRITICAL_PATTERNS = [
  /\brm\b[^|&;\n]*-[a-zA-Z]*[rf][a-zA-Z]*[^|&;\n]*\s+(\/|~\/?)(\s|$)/,
  /\bdd\b[^|&;\n]*\bof=\/dev\/(sd[a-z]+|nvme[0-9]+n[0-9]+|disk[0-9]+)/,
  /\b(mkfs|newfs)\b/,
  /:\(\)\s*\{[^}]*:\s*\|\s*:&/,
  /\b(curl|wget|fetch)\b[^|&;\n]*\|\s*-?\s*(su|ba|da|z|fi|c)?sh\b/,
  />\s*\/dev\/(sd[a-z]+|nvme[0-9]+n[0-9]+|disk[0-9]+)(\s|$)/,
  /\bsudo\s+rm\b/,
];

// ── HIGH patterns ─────────────────────────────────────────────────────────────
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

// ── CRITICAL tools: show popover at CRITICAL risk (no auto-deny) ─────────────
const CRITICAL_TOOLS = new Set(['delete_file']);

// ── Write tools: always show popover ─────────────────────────────────────────
const WRITE_TOOLS = new Set([
  'write_file', 'write_to_file',
  'edit_file', 'replace_file_content',
  'multi_replace_file_content',
  'create_file',
]);

function assessShellRisk(command) {
  const cmd = (command ?? '').trim();
  for (const p of CRITICAL_PATTERNS) { if (p.test(cmd)) return 'critical'; }
  for (const p of HIGH_PATTERNS)     { if (p.test(cmd)) return 'high';     }
  return 'medium';
}

function shellPrefix(command) {
  return (command ?? '').trim().split(/\s+/)[0] || null;
}

// ── Auto mode ─────────────────────────────────────────────────────────────────
// ~/.wakawaka/settings.json → { autoMode: { "agy": { enabled, expiresAt } } }
// Any missing file, malformed JSON, missing block, or expired window is treated
// as DISABLED (safe default) — auto mode must be explicitly and validly enabled.
function loadAutoMode(agent) {
  try {
    const settings = JSON.parse(fs.readFileSync(SETTINGS_PATH, 'utf8'));
    const block = settings?.autoMode?.[agent];
    if (!block || block.enabled !== true) return false;

    if (block.expiresAt != null) {
      const expiresAtMs = new Date(block.expiresAt).getTime();
      if (Number.isNaN(expiresAtMs) || expiresAtMs < Date.now()) return false;
    }

    return true;
  } catch {
    return false;
  }
}

// Only shell tools (run_command / run_shell_command) and WRITE_TOOLS may be
// auto-approved. MCP tools and any other unclassified MEDIUM tool are excluded —
// they fall through to the normal pending flow so a human decides.
function isAutoEligible(tool_name) {
  return tool_name === 'run_command'
      || tool_name === 'run_shell_command'
      || WRITE_TOOLS.has(tool_name);
}

/**
 * Append one line to the auto-approval audit log.
 * Returns true on success, false on any failure. The caller MUST NOT auto-approve
 * when this returns false — the audit trail must not silently break (fail-closed).
 * The command summary may contain secrets, so the file is created 0o600 / dir 0o700.
 */
function appendAutoAudit(agent, tool_name, tool_input) {
  try {
    const command = tool_input?.command ?? tool_input?.cmd ?? tool_input?.CommandLine;
    let summary;
    if (typeof command === 'string' && command.length > 0) {
      const firstLine = command.split('\n')[0];
      summary = firstLine.length > 80 ? `${firstLine.slice(0, 80)}…` : firstLine;
    } else {
      const filePath = tool_input?.file_path ?? tool_input?.path ?? tool_input?.TargetFile;
      summary = filePath ? `${tool_name} ${filePath}` : String(tool_name ?? 'unknown');
    }

    const entry = {
      ts:         new Date().toISOString(),
      agent,
      tool_name:  tool_name ?? null,
      risk_level: 'medium',
      summary,
    };
    fs.mkdirSync(path.dirname(AUTO_AUDIT_PATH), { recursive: true, mode: 0o700 });
    fs.appendFileSync(AUTO_AUDIT_PATH, JSON.stringify(entry) + '\n', { encoding: 'utf8', mode: 0o600 });
    return true;
  } catch {
    return false; // fail-closed: caller must not auto-approve without an audit record
  }
}

// ── Decision output ───────────────────────────────────────────────────────────
function decide(permission, reason) {
  const output = {
    hookSpecificOutput: {
      hookEventName: 'PreToolUse',
      permissionDecision: permission,
    },
  };
  if (reason) output.hookSpecificOutput.permissionDecisionReason = reason;
  process.stdout.write(JSON.stringify(output) + '\n');
}

// ── Allowlist ─────────────────────────────────────────────────────────────────
function loadAllowlist() {
  try { return JSON.parse(fs.readFileSync(ALLOWLIST_PATH, 'utf8')); }
  catch { return { bashPrefixes: [] }; }
}

function saveAllowlist(list) {
  try {
    fs.mkdirSync(path.dirname(ALLOWLIST_PATH), { recursive: true });
    fs.writeFileSync(ALLOWLIST_PATH, JSON.stringify(list, null, 2), 'utf8');
  } catch { /* best-effort */ }
}

// ── Stdin ─────────────────────────────────────────────────────────────────────
async function readStdin() {
  return new Promise((resolve, reject) => {
    const chunks = [];
    process.stdin.on('data',  (d) => chunks.push(d));
    process.stdin.on('end',   ()  => resolve(Buffer.concat(chunks).toString('utf8').trim()));
    process.stdin.on('error', reject);
  });
}

// ── WakaWaka liveness ─────────────────────────────────────────────────────────
function isWakaWakaRunning() {
  const name = process.env.WAKAWAKA_PROCESS_NAME ?? 'WakaWaka';
  try {
    const r = spawnSync('pgrep', ['-x', name], { stdio: 'ignore', timeout: 1000 });
    return r.status === 0;
  } catch { return false; }
}

function markUrgent(pendingPath) {
  try {
    const prev = JSON.parse(fs.readFileSync(pendingPath, 'utf8'));
    prev.hookUrgent = true;
    fs.writeFileSync(pendingPath, JSON.stringify(prev), { encoding: 'utf8', mode: 0o600 });
  } catch { /* best-effort */ }
}

// ── Decision poller ───────────────────────────────────────────────────────────
function pollDecision(decisionPath, onWarn) {
  return new Promise((resolve) => {
    let lastAppCheck  = Date.now() - APP_CHECK_EVERY_MS;
    let appDeadSince  = null;
    let warned        = false;
    const start       = Date.now();
    const warnAt      = start + WARN_TIMEOUT_MS;
    const denyAt      = start + FINAL_TIMEOUT_MS;

    const timer = setInterval(() => {
      const now = Date.now();

      if (now >= denyAt) {
        clearInterval(timer);
        resolve({ timedOut: true, reason: 'finalTimeout' });
        return;
      }

      try {
        const raw      = fs.readFileSync(decisionPath, 'utf8');
        const decision = JSON.parse(raw);
        clearInterval(timer);
        try { fs.unlinkSync(decisionPath); } catch {}
        resolve({ decision });
        return;
      } catch { /* not yet */ }

      if (now - lastAppCheck >= APP_CHECK_EVERY_MS) {
        lastAppCheck = now;
        if (isWakaWakaRunning()) { appDeadSince = null; }
        else if (!appDeadSince)   { appDeadSince = now;  }
      }

      if (appDeadSince !== null && now - appDeadSince >= APP_DEAD_GRACE_MS) {
        clearInterval(timer);
        resolve({ timedOut: true, reason: 'appDead' });
        return;
      }

      if (!warned && now >= warnAt) {
        warned = true;
        onWarn();
      }
    }, POLL_INTERVAL_MS);
  });
}

// ── Main ──────────────────────────────────────────────────────────────────────
async function main() {
  let input;
  try {
    const raw = await readStdin();
    input = JSON.parse(raw);
  } catch {
    decide('defer', 'Hook received malformed input');
    process.exit(0);
  }

  // agy actual format: { toolCall: { name, args }, conversationId, transcriptPath, ... }
  // Also support Claude Code style { tool_name, tool_input, session_id } for compat.
  const toolCall = input?.toolCall ?? null;
  const tool_name_raw = input?.tool_name
                     ?? toolCall?.name
                     ?? input?.name
                     ?? input?.toolName
                     ?? null;
  // Normalize PascalCase → snake_case so routing sets match (ListDir → list_dir)
  const tool_name = tool_name_raw
    ? tool_name_raw.replace(/([A-Z])/g, (c, _, i) => (i > 0 ? '_' : '') + c.toLowerCase())
    : null;
  const tool_input = input?.tool_input
                  ?? toolCall?.args
                  ?? input?.args
                  ?? input?.toolArgs
                  ?? null;
  const session_id_raw  = input?.session_id ?? input?.conversationId ?? null;
  const transcript_path = input?.transcript_path ?? input?.transcriptPath ?? null;

  const sanitized  = typeof session_id_raw === 'string'
    ? session_id_raw.replace(/[^a-zA-Z0-9_-]/g, '_') : '';
  const session_id = sanitized.length > 0 ? sanitized : randomUUID();
  const PENDING_PATH  = path.join(STATE_DIR, `pending_${session_id}.json`);
  const DECISION_PATH = path.join(STATE_DIR, `decision_${session_id}.json`);

  // ── Step 1: Auto-allow safe read-only tools ───────────────────────────────
  if (AUTO_ALLOW_TOOLS.has(tool_name)) {
    decide('allow', `${tool_name} is auto-approved (read-only / low-risk)`);
    process.exit(0);
  }

  let risk_level = 'medium';

  // ── Step 2: Critical tools — escalate to CRITICAL risk, show popover ────────
  if (CRITICAL_TOOLS.has(tool_name)) {
    risk_level = 'critical';
    // Fall through to Step 5 — user must explicitly approve
  }

  // ── Step 3: Shell risk assessment ───────────────────────────────────────

  const isShellTool = tool_name === 'run_command' || tool_name === 'run_shell_command';
  if (isShellTool) {
    const command = tool_input?.command ?? tool_input?.cmd ?? tool_input?.CommandLine ?? '';
    const shellRisk = assessShellRisk(command);
    // Never downgrade a risk already set by Step 2
    const riskOrder = { medium: 0, high: 1, critical: 2 };
    if ((riskOrder[shellRisk] ?? 0) > (riskOrder[risk_level] ?? 0)) {
      risk_level = shellRisk;
    }

    if (risk_level === 'medium') {
      const prefix = shellPrefix(command);

      if (prefix && SAFE_SHELL_PREFIXES.has(prefix)) {
        decide('allow', `"${prefix}" is a safe command (auto-approved)`);
        process.exit(0);
      }

      const allowlist = loadAllowlist();
      if (prefix && allowlist.bashPrefixes.includes(prefix)) {
        decide('allow', `Shell prefix "${prefix}" is in user allowlist`);
        process.exit(0);
      }
    }
  }

  // ── Step 4: Write/edit tools — always show popover ───────────────────────
  if (WRITE_TOOLS.has(tool_name)) {
    risk_level = 'medium';
    // Continue to Step 5 (write pending file)
  }

  // ── Step 4.5: Auto mode — MEDIUM auto-approved when user enabled it ──────
  // HIGH and CRITICAL never reach this branch — they always fall through to
  // Step 5 and require an explicit human decision, regardless of auto mode.
  // Only auto-eligible tools (shell / write-file tools) qualify; MCP and other
  // unclassified MEDIUM tools fall through to human review.
  // Fail-closed: if the audit record can't be written, do NOT auto-approve.
  if (risk_level === 'medium' && isAutoEligible(tool_name) && loadAutoMode(AGENT_NAME)) {
    if (appendAutoAudit(AGENT_NAME, tool_name, tool_input)) {
      decide('allow', 'Auto mode: medium auto-approved');
      process.exit(0);
    }
    // audit failed → fall through to Step 5 (write pending, human decides)
  }

  // ── Step 5: Write pending file and wait ──────────────────────────────────
  let gotDecision = false;

  try {
    fs.mkdirSync(STATE_DIR, { recursive: true });
    fs.writeFileSync(
      PENDING_PATH,
      JSON.stringify({
        session_id,
        tool_name:       tool_name       ?? null,
        tool_input:      tool_input      ?? null,
        risk_level,
        transcript_path: transcript_path ?? null,
        timestamp:       new Date().toISOString(),
        agent:           AGENT_NAME,
      }),
      { encoding: 'utf8', mode: 0o600 },
    );
  } catch {
    decide('defer', 'WakaWaka state directory unavailable');
    process.exit(0);
  }

  // ── Tombstone on unexpected exit ──────────────────────────────────────────
  process.on('exit', () => {
    if (gotDecision) {
      try { fs.unlinkSync(PENDING_PATH); } catch {}
    } else {
      try {
        const prev = (() => {
          try { return JSON.parse(fs.readFileSync(PENDING_PATH, 'utf8')); }
          catch { return null; }
        })();
        if (prev) {
          prev.hookExited   = true;
          prev.hookExitedAt = new Date().toISOString();
          fs.writeFileSync(PENDING_PATH, JSON.stringify(prev), { encoding: 'utf8', mode: 0o600 });
        }
      } catch { /* best-effort */ }
    }
  });
  process.once('SIGINT',  () => process.exit(130));
  process.once('SIGTERM', () => process.exit(143));

  // ── Poll for decision ─────────────────────────────────────────────────────
  let result;
  try {
    result = await pollDecision(DECISION_PATH, () => markUrgent(PENDING_PATH));
  } catch {
    decide('defer', 'WakaWaka poll failed');
    process.exit(0);
  }

  if (result.timedOut) {
    gotDecision = true;

    if (result.reason === 'appDead') {
      decide('defer', 'WakaWaka not running — falling back to native approval');
      process.exit(0);
    }

    decide('deny', 'Auto-denied: no approval received within the review window');
    process.stderr.write('agy tool auto-denied: review timeout (9m50s)\n');
    process.exit(2);
  }

  gotDecision = true;

  const { decision } = result.decision ?? {};

  if (decision === 'allow') {
    decide('allow');
    process.exit(0);
  }

  if (decision === 'deny') {
    const reason = result.decision?.reason ?? 'User denied via WakaWaka';
    decide('deny', reason);
    process.stderr.write(reason + '\n');
    process.exit(2);
  }

  if (decision === 'always') {
    if (isShellTool && risk_level === 'medium') {
      const command = tool_input?.command ?? tool_input?.cmd ?? tool_input?.CommandLine ?? '';
      const prefix = shellPrefix(command);
      if (prefix) {
        const allowlist = loadAllowlist();
        if (!allowlist.bashPrefixes.includes(prefix)) {
          allowlist.bashPrefixes.push(prefix);
          saveAllowlist(allowlist);
        }
      }
    }
    decide('allow', 'User selected Always Allow');
    process.exit(0);
  }

  decide('defer', `Unknown decision value: ${decision}`);
  process.exit(0);
}

main();
