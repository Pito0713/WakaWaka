#!/usr/bin/env node
import * as fs from 'fs';
import * as os from 'os';
import * as path from 'path';

const STATE_DIR    = path.join(os.homedir(), '.costnotch', 'state');
const PENDING_PATH = path.join(STATE_DIR, 'pending.json');
const DECISION_PATH= path.join(STATE_DIR, 'decision.json');
const ALLOWLIST_PATH = path.join(os.homedir(), '.costnotch', 'allowlist.json');

const POLL_INTERVAL_MS = 200;
const POLL_TIMEOUT_MS  = parseInt(process.env.POLL_TIMEOUT_MS ?? '30000', 10);

// ── Auto-approve: read-only tools, no popover needed ─────────────────────────
const READONLY_TOOLS = new Set([
  'Read', 'Glob', 'Grep', 'LS', 'TodoRead',
]);

// ── Allowlist helpers ─────────────────────────────────────────────────────────
function loadAllowlist() {
  try {
    return JSON.parse(fs.readFileSync(ALLOWLIST_PATH, 'utf8'));
  } catch {
    return { bashPrefixes: [] };
  }
}

function saveAllowlist(list) {
  try {
    fs.mkdirSync(path.dirname(ALLOWLIST_PATH), { recursive: true });
    fs.writeFileSync(ALLOWLIST_PATH, JSON.stringify(list, null, 2), 'utf8');
  } catch { /* best-effort */ }
}

/** First whitespace-separated token of a shell command, e.g. "git" from "git status" */
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

// ── Decision poller ───────────────────────────────────────────────────────────
function pollDecision() {
  return new Promise((resolve) => {
    const deadline = Date.now() + POLL_TIMEOUT_MS;
    const timer = setInterval(() => {
      if (Date.now() > deadline) {
        clearInterval(timer);
        resolve({ timedOut: true });
        return;
      }
      try {
        const raw = fs.readFileSync(DECISION_PATH, 'utf8');
        const decision = JSON.parse(raw);
        clearInterval(timer);
        try { fs.unlinkSync(DECISION_PATH); } catch { /* already gone */ }
        resolve({ decision });
      } catch {
        // file not yet present — keep polling
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
    process.exit(1);
  }

  const { session_id, tool_name, tool_input, transcript_path } = input ?? {};

  // 1. Auto-allow read-only tools (no popover)
  if (READONLY_TOOLS.has(tool_name)) {
    process.exit(0);
  }

  // 2. Bash: check prefix allowlist (no popover if already "always allowed")
  if (tool_name === 'Bash') {
    const prefix = bashPrefix(tool_input?.command);
    const allowlist = loadAllowlist();
    if (prefix && allowlist.bashPrefixes.includes(prefix)) {
      process.exit(0);
    }
  }

  // 3. Everything else → write pending.json and wait for MenuBar decision
  try {
    fs.mkdirSync(STATE_DIR, { recursive: true });
    fs.writeFileSync(
      PENDING_PATH,
      JSON.stringify({
        session_id:      session_id      ?? null,
        tool_name:       tool_name       ?? null,
        tool_input:      tool_input      ?? null,
        transcript_path: transcript_path ?? null,
        timestamp:       new Date().toISOString(),
      }),
      { encoding: 'utf8', mode: 0o600 },
    );
  } catch {
    process.exit(1);
  }

  let result;
  try {
    result = await pollDecision();
  } catch {
    process.exit(1);
  }

  if (result.timedOut) {
    process.exit(1);
  }

  const { decision } = result.decision ?? {};

  if (decision === 'allow') {
    process.exit(0);
  }

  if (decision === 'deny') {
    const reason = result.decision?.reason ?? 'Denied';
    process.stderr.write(reason + '\n');
    process.exit(2);
  }

  // 4. "always" → save prefix to allowlist, then allow
  if (decision === 'always') {
    if (tool_name === 'Bash') {
      const prefix = bashPrefix(tool_input?.command);
      if (prefix) {
        const allowlist = loadAllowlist();
        if (!allowlist.bashPrefixes.includes(prefix)) {
          allowlist.bashPrefixes.push(prefix);
          saveAllowlist(allowlist);
        }
      }
    }
    process.exit(0);
  }

  // Unexpected value → neutral fallback
  process.exit(1);
}

main();
