#!/usr/bin/env node
/**
 * WakaWaka PreToolUse Hook
 *
 * Intercepts Claude Code tool calls and routes them through WakaWaka for
 * human approval. Three-tier classification:
 *
 *   AUTO_ALLOW_TOOLS   — tool names that never need approval (read-only)
 *   SAFE_BASH_PREFIXES — bash command prefixes that are always safe (MEDIUM risk only)
 *   User allowlist     — ~/.wakawaka/allowlist.json  (user-managed MEDIUM bypasses)
 *   HIGH / CRITICAL    — always show popover (HIGH) or deny immediately (CRITICAL)
 *
 * Tombstone mechanism (fixes "not showing / can't click" bug):
 *   When the hook exits without receiving a decision (timeout or Claude Code kill),
 *   the pending file is NOT deleted — instead it's updated with hookExited:true so
 *   WakaWaka can show an "已逾時" indicator and let the user dismiss cleanly.
 */

import * as fs from 'fs';
import * as os from 'os';
import * as path from 'path';
import { randomUUID } from 'node:crypto';
import { spawnSync } from 'node:child_process';

const STATE_DIR      = path.join(os.homedir(), '.wakawaka', 'state');
const ALLOWLIST_PATH = path.join(os.homedir(), '.wakawaka', 'allowlist.json');

// ── Timing constants ─────────────────────────────────────────────────────────
const POLL_INTERVAL_MS   = 200;
// pgrep check interval (expensive; keep infrequent)
const APP_CHECK_EVERY_MS = parseInt(process.env.APP_CHECK_EVERY_MS ?? '5000',  10);
// Grace period after WakaWaka first seen dead before we fall back to defer
const APP_DEAD_GRACE_MS  = parseInt(process.env.APP_DEAD_GRACE_MS  ?? '30000', 10);
// 8-minute warning: mark hookUrgent=true so WakaWaka auto-opens its popover
// and shows a red "2 minutes left" banner. Hook keeps waiting.
const WARN_TIMEOUT_MS    = parseInt(process.env.WARN_TIMEOUT_MS    ?? '480000', 10); // 8 min
// 9m50s final deadline: auto-deny the tool call.
// Must be < Claude Code's 600s default hook timeout so we exit cleanly.
const FINAL_TIMEOUT_MS   = parseInt(process.env.FINAL_TIMEOUT_MS   ?? '590000', 10); // 9m 50s

// ── Category 1: Tool-level auto-allow ────────────────────────────────────────
// Tools that are read-only or have no dangerous side effects.
// These never write a pending file or show a popover.
const AUTO_ALLOW_TOOLS = new Set([
  // File system reads
  'Read', 'Glob', 'Grep', 'LS',
  // In-memory todo list (no disk/network side effects)
  'TodoRead', 'TodoWrite',
  // Read-only web operations
  'WebSearch', 'WebFetch',
  // Notebook reads / edits
  'NotebookRead', 'NotebookEdit',
]);

// Edit / MultiEdit / Write intentionally excluded — routed through WakaWaka
// so the user can review file changes before they are applied.

// ── Category 2: Safe bash command prefixes ────────────────────────────────────
// When a Bash command is MEDIUM risk (not CRITICAL/HIGH), and its first token
// is in this set, it is auto-allowed without a popover.
//
// Safety rationale:
//  • CRITICAL patterns (rm -rf /, dd of=, curl|sh…) are checked FIRST — they
//    cannot be bypassed by being in this set.
//  • HIGH patterns (sudo, git push --force, kill…) are checked FIRST — they
//    skip this set and always show the popover.
//  • This set only applies to MEDIUM risk (no matching CRITICAL/HIGH pattern).
const SAFE_BASH_PREFIXES = new Set([
  // ── Process inspection (read-only) ──────────────────────────────────────
  'pgrep', 'ps', 'lsof', 'uptime',

  // ── File system info (no writes) ────────────────────────────────────────
  'ls', 'find', 'which', 'whereis', 'type', 'file', 'stat', 'du', 'df', 'tree',

  // ── Text reading / querying ──────────────────────────────────────────────
  'cat', 'head', 'tail', 'wc', 'diff', 'less', 'more',
  'grep', 'egrep', 'fgrep', 'rg', 'ag',
  'awk', 'jq',

  // ── Build / compile / test ───────────────────────────────────────────────
  // (creates build artifacts but not destructive to source; HIGH patterns still
  // catch dangerous package manager flags like npm install -g)
  'swift', 'swiftc', 'xcode-select', 'xcodebuild',
  'npx', 'node', 'deno',
  'python', 'python3', 'pip', 'pip3',
  'ruby', 'gem', 'bundle',
  'go', 'cargo', 'rustc',
  'make', 'cmake', 'ninja',
  'javac', 'java', 'mvn', 'gradle',
  'npm', 'yarn', 'pnpm', 'bun',
  'brew',

  // ── Environment / shell info ─────────────────────────────────────────────
  'echo', 'printf', 'env', 'printenv',
  'uname', 'hostname', 'whoami', 'id',
  'pwd', 'date', 'time',
  'cd', 'sleep',

  // ── Git (HIGH patterns still catch force-push, reset --hard, clean -f) ──
  'git',

  // ── Network read-only ────────────────────────────────────────────────────
  // (CRITICAL patterns still catch curl/wget piped to shell)
  'curl', 'wget',
  'ping', 'nslookup', 'dig', 'host', 'traceroute', 'netstat', 'ss',

  // ── Encoding / hashing (read-only transformations) ──────────────────────
  'base64', 'xxd', 'hexdump', 'md5', 'md5sum', 'sha256sum', 'shasum',

  // ── macOS utilities ──────────────────────────────────────────────────────
  'open', 'defaults', 'pbpaste', 'pbcopy', 'osascript', 'plutil',
  'codesign', 'otool', 'nm',
  'say',
]);

// ── Category 3: CRITICAL patterns — auto-deny ────────────────────────────────
// Catastrophic and nearly irreversible. Denied before ever showing a popover.
const CRITICAL_PATTERNS = [
  // rm -rf / or rm -rf ~/
  /\brm\b[^|&;\n]*-[a-zA-Z]*[rf][a-zA-Z]*[^|&;\n]*\s+(\/|~\/?)(\s|$)/,
  // dd writing to raw block devices
  /\bdd\b[^|&;\n]*\bof=\/dev\/(sd[a-z]+|nvme[0-9]+n[0-9]+|disk[0-9]+)/,
  // Filesystem format commands
  /\b(mkfs|newfs)\b/,
  // Fork bomb
  /:\(\)\s*\{[^}]*:\s*\|\s*:&/,
  // Fetch-and-execute from internet (curl/wget piped to shell)
  /\b(curl|wget|fetch)\b[^|&;\n]*\|\s*-?\s*(su|ba|da|z|fi|c)?sh\b/,
  // Direct write to block device
  />\s*\/dev\/(sd[a-z]+|nvme[0-9]+n[0-9]+|disk[0-9]+)(\s|$)/,
  // sudo rm (any target)
  /\bsudo\s+rm\b/,
];

// ── Category 4: HIGH patterns — always show popover (orange/red) ─────────────
// Risky but not catastrophic. Always show a warning popover even if the prefix
// is in SAFE_BASH_PREFIXES or the user's allowlist.
const HIGH_PATTERNS = [
  /\bsudo\b/,                                    // any sudo
  /\bgit\s+push\b[^|&;\n]*(--force|-f)\b/,       // git push --force / -f
  /\bgit\s+reset\s+--hard\b/,                    // git reset --hard
  /\bgit\s+clean\b[^|&;\n]*-[a-zA-Z]*f/,        // git clean -f / -fd
  /\bchmod\b/,                                   // permission changes
  /\bchown\b/,                                   // ownership changes
  /\bkill\b|\bpkill\b|\bkillall\b/,             // process termination
  /\bnpm\s+(install|i)\s+(-g|--global)\b/,       // global npm install
  /\bpip3?\s+install\b(?!\s+--user)/,            // pip install (not --user)
  /\brsync\b[^|&;\n]*--delete\b/,               // rsync --delete (destructive)
  /\bssh\s+/,                                    // ssh connections
  /\bdrop\s+(database|table|schema)\b/i,         // SQL destructive DDL
  /\btruncate\s+(table\s+)?\w/i,                // SQL TRUNCATE
];

/** Returns 'critical' | 'high' | 'medium' for a bash command string. */
function assessBashRisk(command) {
  const cmd = (command ?? '').trim();
  for (const p of CRITICAL_PATTERNS) { if (p.test(cmd)) return 'critical'; }
  for (const p of HIGH_PATTERNS)     { if (p.test(cmd)) return 'high';     }
  return 'medium';
}

// ── Permission decision output ────────────────────────────────────────────────
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

// ── Allowlist helpers ─────────────────────────────────────────────────────────
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

/** First whitespace-separated token of a shell command */
function bashPrefix(command) {
  return (command ?? '').trim().split(/\s+/)[0] || null;
}

// ── Stdin reader ──────────────────────────────────────────────────────────────
async function readStdin() {
  return new Promise((resolve, reject) => {
    const chunks = [];
    process.stdin.on('data',  (d) => chunks.push(d));
    process.stdin.on('end',   ()  => resolve(Buffer.concat(chunks).toString('utf8').trim()));
    process.stdin.on('error', reject);
  });
}

// ── WakaWaka liveness check ─────────────────────────────────────────────────
// WAKAWAKA_PROCESS_NAME overrides the pgrep target — tests pass '__nonexistent__'
// to simulate a dead app without killing the real process.
function isWakaWakaRunning() {
  const name = process.env.WAKAWAKA_PROCESS_NAME ?? 'WakaWaka';
  try {
    const r = spawnSync('pgrep', ['-x', name], { stdio: 'ignore', timeout: 1000 });
    return r.status === 0;
  } catch { return false; }
}

// ── Mark pending file as urgent (called at WARN_TIMEOUT_MS) ──────────────────
// Adds hookUrgent:true so WakaWaka detects the change, auto-opens its popover,
// and shows a red "auto-deny in ~2 minutes" banner. The hook keeps polling.
function markUrgent(pendingPath) {
  try {
    const prev = JSON.parse(fs.readFileSync(pendingPath, 'utf8'));
    prev.hookUrgent = true;
    fs.writeFileSync(pendingPath, JSON.stringify(prev), { encoding: 'utf8', mode: 0o600 });
  } catch { /* best-effort */ }
}

// ── Decision poller ───────────────────────────────────────────────────────────
// Blocks until one of:
//   (a) user writes a decision file                  → resolved with { decision }
//   (b) WakaWaka dead for APP_DEAD_GRACE_MS         → { timedOut: true, reason: 'appDead' }
//   (c) FINAL_TIMEOUT_MS elapsed (app alive)         → { timedOut: true, reason: 'finalTimeout' }
//
// At WARN_TIMEOUT_MS (8 min), calls onWarn() which marks the pending file urgent
// so WakaWaka auto-opens its popover without yet deferring or denying.
//
// 'appDead'     → defer  (graceful fallback; user can't approve without the app)
// 'finalTimeout'→ deny   (security: no approval = not allowed)
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

      // (c) hard final deadline → deny
      if (now >= denyAt) {
        clearInterval(timer);
        resolve({ timedOut: true, reason: 'finalTimeout' });
        return;
      }

      // (a) decision file appeared?
      try {
        const raw      = fs.readFileSync(decisionPath, 'utf8');
        const decision = JSON.parse(raw);
        clearInterval(timer);
        try { fs.unlinkSync(decisionPath); } catch {}
        resolve({ decision });
        return;
      } catch { /* not yet present */ }

      // Liveness check
      if (now - lastAppCheck >= APP_CHECK_EVERY_MS) {
        lastAppCheck = now;
        if (isWakaWakaRunning()) { appDeadSince = null; }
        else if (!appDeadSince)   { appDeadSince = now;  }
      }

      // (b) app dead grace expired → defer
      if (appDeadSince !== null && now - appDeadSince >= APP_DEAD_GRACE_MS) {
        clearInterval(timer);
        resolve({ timedOut: true, reason: 'appDead' });
        return;
      }

      // Warn threshold: mark urgent, let WakaWaka open popover. Keep polling.
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

  const { session_id: rawSid, tool_name, tool_input, transcript_path } = input ?? {};

  // Sanitize session_id — prevent path traversal
  const sanitized  = typeof rawSid === 'string' ? rawSid.replace(/[^a-zA-Z0-9_-]/g, '_') : '';
  const session_id = sanitized.length > 0 ? sanitized : randomUUID();
  const PENDING_PATH  = path.join(STATE_DIR, `pending_${session_id}.json`);
  const DECISION_PATH = path.join(STATE_DIR, `decision_${session_id}.json`);

  // ── Step 1: Auto-allow safe tools ────────────────────────────────────────
  if (AUTO_ALLOW_TOOLS.has(tool_name)) {
    decide('allow', `${tool_name} is auto-approved (read-only / low-risk)`);
    process.exit(0);
  }

  // ── Step 2: Bash risk assessment + safe-prefix / allowlist bypass ─────────
  let risk_level = 'medium'; // default for non-Bash tools

  if (tool_name === 'Bash') {
    const command = tool_input?.command;
    risk_level = assessBashRisk(command);

    if (risk_level === 'medium') {
      const prefix = bashPrefix(command);

      // Built-in safe prefixes (no popover needed for diagnostic / build commands)
      if (prefix && SAFE_BASH_PREFIXES.has(prefix)) {
        decide('allow', `"${prefix}" is a safe command (auto-approved)`);
        process.exit(0);
      }

      // User-managed allowlist (added via "Always Allow" in WakaWaka)
      const allowlist = loadAllowlist();
      if (prefix && allowlist.bashPrefixes.includes(prefix)) {
        decide('allow', `Bash prefix "${prefix}" is in user allowlist`);
        process.exit(0);
      }
    }
  }

  // ── Step 3: Write pending file and wait for WakaWaka decision ────────────
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
      }),
      { encoding: 'utf8', mode: 0o600 },
    );
  } catch {
    decide('defer', 'WakaWaka state directory unavailable');
    process.exit(0);
  }

  // ── Tombstone on unexpected exit ──────────────────────────────────────────
  // If the hook exits WITHOUT a decision (timeout or Claude Code kills the process),
  // overwrite the pending file with hookExited:true instead of deleting it.
  // WakaWaka will detect this and show "已逾時" in the UI so the user knows
  // the tool call was NOT executed — they can dismiss it cleanly.
  //
  // If we DID get a decision (normal flow), delete the pending file as usual.
  process.on('exit', () => {
    if (gotDecision) {
      try { fs.unlinkSync(PENDING_PATH); } catch {}
    } else {
      // Tombstone: keep file so WakaWaka can show the expired state
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

  // ── Poll for user decision ────────────────────────────────────────────────
  let result;
  try {
    result = await pollDecision(DECISION_PATH, () => markUrgent(PENDING_PATH));
  } catch {
    decide('defer', 'WakaWaka poll failed');
    process.exit(0);
  }

  if (result.timedOut) {
    gotDecision = true; // exit handler will delete the pending file (no tombstone)

    if (result.reason === 'appDead') {
      // WakaWaka was not running — fall back gracefully so Claude Code can continue.
      decide('defer', 'WakaWaka not running — falling back to native approval');
      process.exit(0);
    }

    // finalTimeout: no human approval in 9m50s → enforce deny.
    // This is the security guarantee: unapproved = blocked.
    decide('deny', 'Auto-denied: no approval received within the review window');
    process.stderr.write('Tool auto-denied: review timeout (9m50s)\n');
    process.exit(2);
  }

  // Got a decision — mark gotDecision so exit handler deletes the pending file
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

  // Always Allow — save prefix only for MEDIUM risk Bash commands
  if (decision === 'always') {
    if (tool_name === 'Bash' && risk_level === 'medium') {
      const prefix = bashPrefix(tool_input?.command);
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
