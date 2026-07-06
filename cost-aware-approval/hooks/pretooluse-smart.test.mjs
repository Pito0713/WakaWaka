/**
 * Tests for hook smart permission logic:
 * - Auto-allow: readonly + low-risk tools (TodoWrite, WebSearch, NotebookRead)
 * - Bash CRITICAL: auto-deny
 * - Bash HIGH: popover (even if prefix is allowlisted)
 * - Bash MEDIUM: allowlist bypass + Always Allow saves prefix
 * - Session-scoped IPC: independent pending/decision files per session
 */
import { test } from 'node:test';
import assert from 'node:assert/strict';
import * as fs from 'fs';
import * as os from 'os';
import * as path from 'path';
import { spawn } from 'node:child_process';

const STATE_DIR = path.join(os.homedir(), '.wakawaka', 'state');
const ALLOWLIST = path.join(os.homedir(), '.wakawaka', 'allowlist.json');
const HOOK      = new URL('./pretooluse.mjs', import.meta.url).pathname;
const HOOK_AGY  = new URL('./pretooluse-agy.mjs', import.meta.url).pathname;

function pendingPath(sid)  { return path.join(STATE_DIR, `pending_${sid}.json`); }
function decisionPath(sid) { return path.join(STATE_DIR, `decision_${sid}.json`); }

function cleanupSession(sid) {
  for (const p of [pendingPath(sid), decisionPath(sid)]) {
    try { fs.unlinkSync(p); } catch { /* ok */ }
  }
}
function resetAllowlist() {
  try { fs.unlinkSync(ALLOWLIST); } catch { /* ok */ }
}

function runHook(input, env = {}) {
  return new Promise((resolve) => {
    const child = spawn(process.execPath, [HOOK], {
      env: { ...process.env, POLL_TIMEOUT_MS: '5000', ...env },
      stdio: ['pipe', 'pipe', 'pipe'],
    });
    let stdout = '', stderr = '';
    child.stdout.on('data', (d) => { stdout += d; });
    child.stderr.on('data', (d) => { stderr += d; });
    child.stdin.write(JSON.stringify(input));
    child.stdin.end();
    child.on('close', (code) => resolve({ code, stdout: stdout.trim(), stderr: stderr.trim() }));
  });
}

function parseDecision(stdout) {
  try { return JSON.parse(stdout).hookSpecificOutput?.permissionDecision; } catch { return null; }
}

function runHookAt(hookPath, input, env = {}) {
  return new Promise((resolve) => {
    const child = spawn(process.execPath, [hookPath], {
      env: { ...process.env, POLL_TIMEOUT_MS: '5000', ...env },
      stdio: ['pipe', 'pipe', 'pipe'],
    });
    let stdout = '', stderr = '';
    child.stdout.on('data', (d) => { stdout += d; });
    child.stderr.on('data', (d) => { stderr += d; });
    child.stdin.write(JSON.stringify(input));
    child.stdin.end();
    child.on('close', (code) => resolve({ code, stdout: stdout.trim(), stderr: stderr.trim() }));
  });
}

// ── Auto-allow tools ──────────────────────────────────────────────────────────

test('Read → auto allow, no pending file', async () => {
  const sid = 'test-read';
  cleanupSession(sid);
  const r = await runHook({ session_id: sid, tool_name: 'Read', tool_input: { file_path: '/tmp/x' } });
  assert.equal(r.code, 0);
  assert.equal(parseDecision(r.stdout), 'allow');
  assert.ok(!fs.existsSync(pendingPath(sid)));
});

test('TodoWrite → auto allow (low-risk)', async () => {
  const sid = 'test-todowrite';
  cleanupSession(sid);
  const r = await runHook({ session_id: sid, tool_name: 'TodoWrite', tool_input: { todos: [] } });
  assert.equal(r.code, 0);
  assert.equal(parseDecision(r.stdout), 'allow');
  assert.ok(!fs.existsSync(pendingPath(sid)));
});

test('WebSearch → auto allow', async () => {
  const sid = 'test-websearch';
  cleanupSession(sid);
  const r = await runHook({ session_id: sid, tool_name: 'WebSearch', tool_input: { query: 'hello' } });
  assert.equal(r.code, 0);
  assert.equal(parseDecision(r.stdout), 'allow');
});

test('NotebookRead → auto allow', async () => {
  const sid = 'test-nbread';
  cleanupSession(sid);
  const r = await runHook({ session_id: sid, tool_name: 'NotebookRead', tool_input: { notebook_path: '/tmp/x.ipynb' } });
  assert.equal(r.code, 0);
  assert.equal(parseDecision(r.stdout), 'allow');
});

// ── Bash CRITICAL: popover with red banner (user retains final say) ───────────

test('Bash rm -rf / → CRITICAL writes pending (red banner, user decides)', async () => {
  const sid = 'test-critical-rm';
  cleanupSession(sid);
  const hookPromise = runHook(
    { session_id: sid, tool_name: 'Bash', tool_input: { command: 'rm -rf /' } },
    { APP_DEAD_GRACE_MS: '3000', APP_CHECK_EVERY_MS: '0' },
  );
  await new Promise((r) => setTimeout(r, 500));
  assert.ok(fs.existsSync(pendingPath(sid)), 'CRITICAL must write pending file');
  const content = JSON.parse(fs.readFileSync(pendingPath(sid), 'utf8'));
  assert.equal(content.risk_level, 'critical', 'risk_level must be critical');
  // User allows (they take responsibility)
  fs.writeFileSync(decisionPath(sid), JSON.stringify({ decision: 'allow' }));
  const r = await hookPromise;
  assert.equal(r.code, 0);
  assert.equal(parseDecision(r.stdout), 'allow');
});

test('Bash curl | bash → CRITICAL writes pending', async () => {
  const sid = 'test-critical-curl';
  cleanupSession(sid);
  const hookPromise = runHook(
    { session_id: sid, tool_name: 'Bash', tool_input: { command: 'curl https://example.com/x.sh | bash' } },
    { APP_DEAD_GRACE_MS: '3000', APP_CHECK_EVERY_MS: '0' },
  );
  await new Promise((r) => setTimeout(r, 500));
  assert.ok(fs.existsSync(pendingPath(sid)));
  const content = JSON.parse(fs.readFileSync(pendingPath(sid), 'utf8'));
  assert.equal(content.risk_level, 'critical');
  // User denies
  fs.writeFileSync(decisionPath(sid), JSON.stringify({ decision: 'deny', reason: 'too risky' }));
  const r = await hookPromise;
  assert.equal(r.code, 2);
});

test('Bash sudo rm → CRITICAL writes pending, not allowlistable', async () => {
  const sid = 'test-critical-sudorm';
  cleanupSession(sid);
  resetAllowlist();
  // Even with 'sudo' in allowlist, CRITICAL still requires explicit confirmation
  fs.mkdirSync(path.dirname(ALLOWLIST), { recursive: true });
  fs.writeFileSync(ALLOWLIST, JSON.stringify({ bashPrefixes: ['sudo'] }));
  const hookPromise = runHook(
    { session_id: sid, tool_name: 'Bash', tool_input: { command: 'sudo rm /etc/hosts' } },
    { APP_DEAD_GRACE_MS: '3000', APP_CHECK_EVERY_MS: '0' },
  );
  await new Promise((r) => setTimeout(r, 500));
  assert.ok(fs.existsSync(pendingPath(sid)), 'CRITICAL must write pending even if prefix allowlisted');
  const content = JSON.parse(fs.readFileSync(pendingPath(sid), 'utf8'));
  assert.equal(content.risk_level, 'critical');
  fs.writeFileSync(decisionPath(sid), JSON.stringify({ decision: 'allow' }));
  await hookPromise;
  resetAllowlist();
});

// ── Bash HIGH: always shows popover (even if allowlisted) ────────────────────

test('Bash sudo → HIGH, writes pending even if prefix allowlisted', async () => {
  const sid = 'test-high-sudo';
  cleanupSession(sid);
  // Pre-load allowlist with 'sudo'
  fs.mkdirSync(path.dirname(ALLOWLIST), { recursive: true });
  fs.writeFileSync(ALLOWLIST, JSON.stringify({ bashPrefixes: ['sudo'] }));

  const hookPromise = runHook(
    { session_id: sid, tool_name: 'Bash', tool_input: { command: 'sudo systemctl restart nginx' } },
    { APP_DEAD_GRACE_MS: '3000', APP_CHECK_EVERY_MS: '0' },
  );
  await new Promise((r) => setTimeout(r, 500));
  assert.ok(fs.existsSync(pendingPath(sid)), 'HIGH must write pending even if prefix allowlisted');

  // Check risk_level in pending file
  const content = JSON.parse(fs.readFileSync(pendingPath(sid), 'utf8'));
  assert.equal(content.risk_level, 'high');

  // Clean up
  fs.writeFileSync(decisionPath(sid), JSON.stringify({ decision: 'allow' }));
  await hookPromise;
  resetAllowlist();
});

test('Bash git push --force → HIGH, writes pending', async () => {
  const sid = 'test-high-forcepush';
  cleanupSession(sid);
  // Even with 'git' in allowlist, HIGH commands still get the popover
  fs.mkdirSync(path.dirname(ALLOWLIST), { recursive: true });
  fs.writeFileSync(ALLOWLIST, JSON.stringify({ bashPrefixes: ['git'] }));

  const hookPromise = runHook(
    { session_id: sid, tool_name: 'Bash', tool_input: { command: 'git push origin main --force' } },
    { APP_DEAD_GRACE_MS: '3000', APP_CHECK_EVERY_MS: '0' },
  );
  await new Promise((r) => setTimeout(r, 500));
  assert.ok(fs.existsSync(pendingPath(sid)), 'HIGH must write pending');
  const content = JSON.parse(fs.readFileSync(pendingPath(sid), 'utf8'));
  assert.equal(content.risk_level, 'high');

  fs.writeFileSync(decisionPath(sid), JSON.stringify({ decision: 'deny', reason: 'too risky' }));
  const r = await hookPromise;
  assert.equal(r.code, 2);
  resetAllowlist();
});

// ── Bash MEDIUM: allowlist bypass ────────────────────────────────────────────

test('Bash git (MEDIUM) with allowlisted prefix → auto allow', async () => {
  const sid = 'test-med-allowlist';
  cleanupSession(sid);
  fs.mkdirSync(path.dirname(ALLOWLIST), { recursive: true });
  fs.writeFileSync(ALLOWLIST, JSON.stringify({ bashPrefixes: ['git'] }));

  const r = await runHook({ session_id: sid, tool_name: 'Bash', tool_input: { command: 'git status' } });
  assert.equal(r.code, 0);
  assert.equal(parseDecision(r.stdout), 'allow');
  assert.ok(!fs.existsSync(pendingPath(sid)));
  resetAllowlist();
});

test('"always" decision saves prefix for MEDIUM, bypasses next time', async () => {
  const sid = 'test-always';
  cleanupSession(sid);
  resetAllowlist();

  // Use 'cp' — not in SAFE_BASH_PREFIXES, so it reaches the allowlist logic
  const hookPromise = runHook(
    { session_id: sid, tool_name: 'Bash', tool_input: { command: 'cp source.txt dest.txt' } },
    { APP_DEAD_GRACE_MS: '5000', APP_CHECK_EVERY_MS: '0' },
  );
  await new Promise((r) => setTimeout(r, 500));
  fs.writeFileSync(decisionPath(sid), JSON.stringify({ decision: 'always' }));
  const r = await hookPromise;
  assert.equal(r.code, 0);
  assert.equal(parseDecision(r.stdout), 'allow');
  const saved = JSON.parse(fs.readFileSync(ALLOWLIST, 'utf8'));
  assert.ok(saved.bashPrefixes.includes('cp'));
  resetAllowlist();
});

test('"always" on HIGH Bash does NOT save to allowlist', async () => {
  const sid = 'test-always-high';
  cleanupSession(sid);
  resetAllowlist();

  const hookPromise = runHook(
    { session_id: sid, tool_name: 'Bash', tool_input: { command: 'sudo apt-get install vim' } },
    { APP_DEAD_GRACE_MS: '5000', APP_CHECK_EVERY_MS: '0' },
  );
  await new Promise((r) => setTimeout(r, 500));
  fs.writeFileSync(decisionPath(sid), JSON.stringify({ decision: 'always' }));
  const r = await hookPromise;
  assert.equal(r.code, 0); // still allowed this time
  // allowlist must NOT contain 'sudo'
  let allowlist = { bashPrefixes: [] };
  try { allowlist = JSON.parse(fs.readFileSync(ALLOWLIST, 'utf8')); } catch { /* ok */ }
  assert.ok(!allowlist.bashPrefixes.includes('sudo'), 'sudo must never be saved to allowlist');
  resetAllowlist();
});

// ── File write tools → auto-allow (user sees diffs in Claude Code UI) ────────

test('Edit → auto allow, no pending file', async () => {
  const sid = 'test-edit';
  cleanupSession(sid);
  const r = await runHook({
    session_id: sid,
    tool_name: 'Edit',
    tool_input: { file_path: '/tmp/x', old_string: 'a', new_string: 'b' },
  });
  assert.equal(r.code, 0);
  assert.equal(parseDecision(r.stdout), 'allow');
  assert.ok(!fs.existsSync(pendingPath(sid)));
});

test('Write → auto allow, no pending file', async () => {
  const sid = 'test-write';
  cleanupSession(sid);
  const r = await runHook({
    session_id: sid,
    tool_name: 'Write',
    tool_input: { file_path: '/tmp/y', content: 'hello' },
  });
  assert.equal(r.code, 0);
  assert.equal(parseDecision(r.stdout), 'allow');
  assert.ok(!fs.existsSync(pendingPath(sid)));
});

// ── Concurrent sessions ───────────────────────────────────────────────────────

test('concurrent sessions have independent state', async () => {
  const sidA = 'test-conc-a', sidB = 'test-conc-b';
  cleanupSession(sidA); cleanupSession(sidB);
  resetAllowlist();

  // Use 'cp'/'mv' — not in SAFE_BASH_PREFIXES, so pending files are written
  const hA = runHook({ session_id: sidA, tool_name: 'Bash', tool_input: { command: 'cp a.txt b.txt' } }, { POLL_TIMEOUT_MS: '5000' });
  const hB = runHook({ session_id: sidB, tool_name: 'Bash', tool_input: { command: 'mv old.txt new.txt' } }, { POLL_TIMEOUT_MS: '5000' });

  await new Promise((r) => setTimeout(r, 600));
  assert.ok(fs.existsSync(pendingPath(sidA)));
  assert.ok(fs.existsSync(pendingPath(sidB)));

  fs.writeFileSync(decisionPath(sidA), JSON.stringify({ decision: 'allow' }));
  fs.writeFileSync(decisionPath(sidB), JSON.stringify({ decision: 'deny', reason: 'no' }));

  const [rA, rB] = await Promise.all([hA, hB]);
  assert.equal(rA.code, 0);
  assert.equal(rB.code, 2);
});

// ── Auto mode (MEDIUM auto-approval) ─────────────────────────────────────────
// Uses a private temp settings/audit path (via WAKAWAKA_SETTINGS_PATH /
// WAKAWAKA_AUDIT_PATH env overrides) so these tests never touch the real
// ~/.wakawaka/settings.json or leak state into other test files.

const AUTO_TMP_DIR       = fs.mkdtempSync(path.join(os.tmpdir(), 'wakawaka-automode-'));
const AUTO_SETTINGS_PATH = path.join(AUTO_TMP_DIR, 'settings.json');
const AUTO_AUDIT_PATH    = path.join(AUTO_TMP_DIR, 'auto-audit.jsonl');
const AUTO_ENV = {
  WAKAWAKA_SETTINGS_PATH: AUTO_SETTINGS_PATH,
  WAKAWAKA_AUDIT_PATH:    AUTO_AUDIT_PATH,
};

function writeAutoSettings(obj) {
  fs.writeFileSync(AUTO_SETTINGS_PATH, JSON.stringify(obj), 'utf8');
}
function writeAutoSettingsRaw(raw) {
  fs.writeFileSync(AUTO_SETTINGS_PATH, raw, 'utf8');
}
function resetAutoSettings() {
  try { fs.unlinkSync(AUTO_SETTINGS_PATH); } catch { /* ok */ }
}
function resetAutoAudit() {
  try { fs.unlinkSync(AUTO_AUDIT_PATH); } catch { /* ok */ }
}
function readAuditEntries() {
  try {
    return fs.readFileSync(AUTO_AUDIT_PATH, 'utf8')
      .trim().split('\n').filter(Boolean).map((line) => JSON.parse(line));
  } catch { return []; }
}
function futureIso(ms) { return new Date(Date.now() + ms).toISOString(); }
function pastIso(ms)   { return new Date(Date.now() - ms).toISOString(); }

// ── claude-code (pretooluse.mjs) ─────────────────────────────────────────────

test('auto mode enabled (claude-code) + Bash MEDIUM → auto-allow, no pending, audit appended', async () => {
  const sid = 'test-auto-cc-medium';
  cleanupSession(sid);
  resetAutoSettings();
  resetAutoAudit();
  writeAutoSettings({ autoMode: { 'claude-code': { enabled: true, expiresAt: null } } });

  const r = await runHook(
    { session_id: sid, tool_name: 'Bash', tool_input: { command: 'cp a.txt b.txt' } },
    AUTO_ENV,
  );

  assert.equal(r.code, 0);
  assert.equal(parseDecision(r.stdout), 'allow');
  assert.ok(!fs.existsSync(pendingPath(sid)), 'auto-approved medium must not write a pending file');

  const entries = readAuditEntries();
  assert.equal(entries.length, 1);
  assert.equal(entries[0].agent, 'claude-code');
  assert.equal(entries[0].tool_name, 'Bash');
  assert.equal(entries[0].risk_level, 'medium');
  assert.ok(entries[0].summary.includes('cp a.txt b.txt'));
  assert.ok(entries[0].ts, 'audit entry should have a timestamp');

  resetAutoSettings();
  resetAutoAudit();
});

test('auto mode enabled (claude-code) + Bash HIGH (sudo) → still writes pending, not auto-allowed', async () => {
  const sid = 'test-auto-cc-high';
  cleanupSession(sid);
  resetAutoSettings();
  resetAutoAudit();
  writeAutoSettings({ autoMode: { 'claude-code': { enabled: true, expiresAt: null } } });

  const hookPromise = runHook(
    { session_id: sid, tool_name: 'Bash', tool_input: { command: 'sudo systemctl restart nginx' } },
    { ...AUTO_ENV, APP_DEAD_GRACE_MS: '3000', APP_CHECK_EVERY_MS: '0' },
  );
  await new Promise((r) => setTimeout(r, 500));
  assert.ok(fs.existsSync(pendingPath(sid)), 'HIGH must still write pending even with auto mode enabled');
  const content = JSON.parse(fs.readFileSync(pendingPath(sid), 'utf8'));
  assert.equal(content.risk_level, 'high');
  assert.equal(readAuditEntries().length, 0, 'HIGH must not be recorded as an auto-approval');

  fs.writeFileSync(decisionPath(sid), JSON.stringify({ decision: 'allow' }));
  await hookPromise;
  resetAutoSettings();
  resetAutoAudit();
});

test('auto mode enabled (claude-code) + Bash CRITICAL (rm -rf /) → still writes pending', async () => {
  const sid = 'test-auto-cc-critical';
  cleanupSession(sid);
  resetAutoSettings();
  resetAutoAudit();
  writeAutoSettings({ autoMode: { 'claude-code': { enabled: true, expiresAt: null } } });

  const hookPromise = runHook(
    { session_id: sid, tool_name: 'Bash', tool_input: { command: 'rm -rf /' } },
    { ...AUTO_ENV, APP_DEAD_GRACE_MS: '3000', APP_CHECK_EVERY_MS: '0' },
  );
  await new Promise((r) => setTimeout(r, 500));
  assert.ok(fs.existsSync(pendingPath(sid)), 'CRITICAL must still write pending even with auto mode enabled');
  const content = JSON.parse(fs.readFileSync(pendingPath(sid), 'utf8'));
  assert.equal(content.risk_level, 'critical');
  assert.equal(readAuditEntries().length, 0, 'CRITICAL must not be recorded as an auto-approval');

  fs.writeFileSync(decisionPath(sid), JSON.stringify({ decision: 'deny', reason: 'no' }));
  await hookPromise;
  resetAutoSettings();
  resetAutoAudit();
});

test('auto mode expired (claude-code) → falls back to normal pending flow', async () => {
  const sid = 'test-auto-cc-expired';
  cleanupSession(sid);
  resetAutoSettings();
  resetAutoAudit();
  writeAutoSettings({ autoMode: { 'claude-code': { enabled: true, expiresAt: pastIso(60_000) } } });

  const hookPromise = runHook(
    { session_id: sid, tool_name: 'Bash', tool_input: { command: 'cp a.txt b.txt' } },
    { ...AUTO_ENV, APP_DEAD_GRACE_MS: '3000', APP_CHECK_EVERY_MS: '0' },
  );
  await new Promise((r) => setTimeout(r, 500));
  assert.ok(fs.existsSync(pendingPath(sid)), 'expired auto mode must fall back to pending');
  assert.equal(readAuditEntries().length, 0);

  fs.writeFileSync(decisionPath(sid), JSON.stringify({ decision: 'allow' }));
  await hookPromise;
  resetAutoSettings();
  resetAutoAudit();
});

test('auto mode not-yet-expired (claude-code, future expiresAt) → auto-allow', async () => {
  const sid = 'test-auto-cc-future';
  cleanupSession(sid);
  resetAutoSettings();
  resetAutoAudit();
  writeAutoSettings({ autoMode: { 'claude-code': { enabled: true, expiresAt: futureIso(60_000) } } });

  const r = await runHook(
    { session_id: sid, tool_name: 'Bash', tool_input: { command: 'cp a.txt b.txt' } },
    AUTO_ENV,
  );
  assert.equal(r.code, 0);
  assert.equal(parseDecision(r.stdout), 'allow');
  assert.ok(!fs.existsSync(pendingPath(sid)));
  resetAutoSettings();
  resetAutoAudit();
});

test('auto mode disabled explicitly (claude-code) → normal pending flow', async () => {
  const sid = 'test-auto-cc-disabled';
  cleanupSession(sid);
  resetAutoSettings();
  resetAutoAudit();
  writeAutoSettings({ autoMode: { 'claude-code': { enabled: false, expiresAt: null } } });

  const hookPromise = runHook(
    { session_id: sid, tool_name: 'Bash', tool_input: { command: 'cp a.txt b.txt' } },
    { ...AUTO_ENV, APP_DEAD_GRACE_MS: '3000', APP_CHECK_EVERY_MS: '0' },
  );
  await new Promise((r) => setTimeout(r, 500));
  assert.ok(fs.existsSync(pendingPath(sid)));

  fs.writeFileSync(decisionPath(sid), JSON.stringify({ decision: 'allow' }));
  await hookPromise;
  resetAutoSettings();
  resetAutoAudit();
});

test('settings.json missing (claude-code) → normal pending flow, no crash', async () => {
  const sid = 'test-auto-cc-missing';
  cleanupSession(sid);
  resetAutoSettings(); // ensure absent
  resetAutoAudit();

  const hookPromise = runHook(
    { session_id: sid, tool_name: 'Bash', tool_input: { command: 'cp a.txt b.txt' } },
    { ...AUTO_ENV, APP_DEAD_GRACE_MS: '3000', APP_CHECK_EVERY_MS: '0' },
  );
  await new Promise((r) => setTimeout(r, 500));
  assert.ok(fs.existsSync(pendingPath(sid)));

  fs.writeFileSync(decisionPath(sid), JSON.stringify({ decision: 'allow' }));
  await hookPromise;
  resetAutoAudit();
});

test('settings.json malformed JSON (claude-code) → treated as disabled, no crash', async () => {
  const sid = 'test-auto-cc-malformed';
  cleanupSession(sid);
  writeAutoSettingsRaw('{ this is not valid json ][');
  resetAutoAudit();

  const hookPromise = runHook(
    { session_id: sid, tool_name: 'Bash', tool_input: { command: 'cp a.txt b.txt' } },
    { ...AUTO_ENV, APP_DEAD_GRACE_MS: '3000', APP_CHECK_EVERY_MS: '0' },
  );
  await new Promise((r) => setTimeout(r, 500));
  assert.ok(fs.existsSync(pendingPath(sid)), 'malformed settings must be treated as disabled, not crash');
  assert.equal(readAuditEntries().length, 0);

  fs.writeFileSync(decisionPath(sid), JSON.stringify({ decision: 'allow' }));
  await hookPromise;
  resetAutoSettings();
  resetAutoAudit();
});

// ── agy (pretooluse-agy.mjs) — same contract, independent implementation ────

test('auto mode enabled (agy) + run_command MEDIUM → auto-allow, no pending, audit appended', async () => {
  const sid = 'test-auto-agy-medium';
  cleanupSession(sid);
  resetAutoSettings();
  resetAutoAudit();
  writeAutoSettings({ autoMode: { agy: { enabled: true, expiresAt: null } } });

  const r = await runHookAt(
    HOOK_AGY,
    { session_id: sid, tool_name: 'run_command', tool_input: { command: 'cp a.txt b.txt' } },
    AUTO_ENV,
  );

  assert.equal(r.code, 0);
  assert.equal(parseDecision(r.stdout), 'allow');
  assert.ok(!fs.existsSync(pendingPath(sid)));

  const entries = readAuditEntries();
  assert.equal(entries.length, 1);
  assert.equal(entries[0].agent, 'agy');
  assert.equal(entries[0].tool_name, 'run_command');
  assert.equal(entries[0].risk_level, 'medium');
  assert.ok(entries[0].summary.includes('cp a.txt b.txt'));

  resetAutoSettings();
  resetAutoAudit();
});

test('auto mode enabled (agy) + run_command HIGH (sudo) → still writes pending', async () => {
  const sid = 'test-auto-agy-high';
  cleanupSession(sid);
  resetAutoSettings();
  resetAutoAudit();
  writeAutoSettings({ autoMode: { agy: { enabled: true, expiresAt: null } } });

  const hookPromise = runHookAt(
    HOOK_AGY,
    { session_id: sid, tool_name: 'run_command', tool_input: { command: 'sudo systemctl restart nginx' } },
    { ...AUTO_ENV, APP_DEAD_GRACE_MS: '3000', APP_CHECK_EVERY_MS: '0' },
  );
  await new Promise((r) => setTimeout(r, 500));
  assert.ok(fs.existsSync(pendingPath(sid)), 'HIGH must still write pending even with auto mode enabled');
  const content = JSON.parse(fs.readFileSync(pendingPath(sid), 'utf8'));
  assert.equal(content.risk_level, 'high');
  assert.equal(readAuditEntries().length, 0);

  fs.writeFileSync(decisionPath(sid), JSON.stringify({ decision: 'allow' }));
  await hookPromise;
  resetAutoSettings();
  resetAutoAudit();
});

test('auto mode enabled (agy) + delete_file (CRITICAL tool) → still writes pending', async () => {
  const sid = 'test-auto-agy-critical';
  cleanupSession(sid);
  resetAutoSettings();
  resetAutoAudit();
  writeAutoSettings({ autoMode: { agy: { enabled: true, expiresAt: null } } });

  const hookPromise = runHookAt(
    HOOK_AGY,
    { session_id: sid, tool_name: 'delete_file', tool_input: { file_path: '/tmp/important.txt' } },
    { ...AUTO_ENV, APP_DEAD_GRACE_MS: '3000', APP_CHECK_EVERY_MS: '0' },
  );
  await new Promise((r) => setTimeout(r, 500));
  assert.ok(fs.existsSync(pendingPath(sid)), 'CRITICAL tool must still write pending even with auto mode enabled');
  const content = JSON.parse(fs.readFileSync(pendingPath(sid), 'utf8'));
  assert.equal(content.risk_level, 'critical');
  assert.equal(readAuditEntries().length, 0);

  fs.writeFileSync(decisionPath(sid), JSON.stringify({ decision: 'deny', reason: 'no' }));
  await hookPromise;
  resetAutoSettings();
  resetAutoAudit();
});

test('auto mode expired (agy) → falls back to normal pending flow', async () => {
  const sid = 'test-auto-agy-expired';
  cleanupSession(sid);
  resetAutoSettings();
  resetAutoAudit();
  writeAutoSettings({ autoMode: { agy: { enabled: true, expiresAt: pastIso(60_000) } } });

  const hookPromise = runHookAt(
    HOOK_AGY,
    { session_id: sid, tool_name: 'run_command', tool_input: { command: 'cp a.txt b.txt' } },
    { ...AUTO_ENV, APP_DEAD_GRACE_MS: '3000', APP_CHECK_EVERY_MS: '0' },
  );
  await new Promise((r) => setTimeout(r, 500));
  assert.ok(fs.existsSync(pendingPath(sid)));
  assert.equal(readAuditEntries().length, 0);

  fs.writeFileSync(decisionPath(sid), JSON.stringify({ decision: 'allow' }));
  await hookPromise;
  resetAutoSettings();
  resetAutoAudit();
});

test('auto mode for claude-code does not leak to agy (independent agent blocks)', async () => {
  const sid = 'test-auto-agy-not-leaked';
  cleanupSession(sid);
  resetAutoSettings();
  resetAutoAudit();
  // Only claude-code is enabled — agy must NOT be auto-approved.
  writeAutoSettings({ autoMode: { 'claude-code': { enabled: true, expiresAt: null }, agy: { enabled: false, expiresAt: null } } });

  const hookPromise = runHookAt(
    HOOK_AGY,
    { session_id: sid, tool_name: 'run_command', tool_input: { command: 'cp a.txt b.txt' } },
    { ...AUTO_ENV, APP_DEAD_GRACE_MS: '3000', APP_CHECK_EVERY_MS: '0' },
  );
  await new Promise((r) => setTimeout(r, 500));
  assert.ok(fs.existsSync(pendingPath(sid)), 'agy must not inherit claude-code auto mode');
  assert.equal(readAuditEntries().length, 0);

  fs.writeFileSync(decisionPath(sid), JSON.stringify({ decision: 'allow' }));
  await hookPromise;
  resetAutoSettings();
  resetAutoAudit();
});

// ── Round 2: narrowed allowlist, audit file perms, fail-closed ───────────────

test('auto mode + MCP tool (claude-code, mcp__*) → not eligible, writes pending, no audit', async () => {
  const sid = 'test-auto-cc-mcp';
  cleanupSession(sid);
  resetAutoSettings();
  resetAutoAudit();
  writeAutoSettings({ autoMode: { 'claude-code': { enabled: true, expiresAt: null } } });

  const hookPromise = runHook(
    { session_id: sid, tool_name: 'mcp__server__do_thing', tool_input: { foo: 'bar' } },
    { ...AUTO_ENV, APP_DEAD_GRACE_MS: '3000', APP_CHECK_EVERY_MS: '0' },
  );
  await new Promise((r) => setTimeout(r, 500));
  assert.ok(fs.existsSync(pendingPath(sid)), 'unclassified MCP tool must fall through to pending');
  const content = JSON.parse(fs.readFileSync(pendingPath(sid), 'utf8'));
  assert.equal(content.risk_level, 'medium');
  assert.equal(readAuditEntries().length, 0, 'ineligible tool must not be audited');

  fs.writeFileSync(decisionPath(sid), JSON.stringify({ decision: 'allow' }));
  await hookPromise;
  resetAutoSettings();
  resetAutoAudit();
});

test('auto mode + MCP tool (agy, mcp__*) → not eligible, writes pending, no audit', async () => {
  const sid = 'test-auto-agy-mcp';
  cleanupSession(sid);
  resetAutoSettings();
  resetAutoAudit();
  writeAutoSettings({ autoMode: { agy: { enabled: true, expiresAt: null } } });

  const hookPromise = runHookAt(
    HOOK_AGY,
    { session_id: sid, tool_name: 'mcp__server__do_thing', tool_input: { foo: 'bar' } },
    { ...AUTO_ENV, APP_DEAD_GRACE_MS: '3000', APP_CHECK_EVERY_MS: '0' },
  );
  await new Promise((r) => setTimeout(r, 500));
  assert.ok(fs.existsSync(pendingPath(sid)), 'unclassified MCP tool must fall through to pending');
  const content = JSON.parse(fs.readFileSync(pendingPath(sid), 'utf8'));
  assert.equal(content.risk_level, 'medium');
  assert.equal(readAuditEntries().length, 0, 'ineligible tool must not be audited');

  fs.writeFileSync(decisionPath(sid), JSON.stringify({ decision: 'allow' }));
  await hookPromise;
  resetAutoSettings();
  resetAutoAudit();
});

test('auto mode + Edit (claude-code) → eligible, auto-allow, no pending, audit appended', async () => {
  const sid = 'test-auto-cc-edit';
  cleanupSession(sid);
  resetAutoSettings();
  resetAutoAudit();
  writeAutoSettings({ autoMode: { 'claude-code': { enabled: true, expiresAt: null } } });

  const r = await runHook(
    { session_id: sid, tool_name: 'Edit', tool_input: { file_path: '/tmp/x', old_string: 'a', new_string: 'b' } },
    AUTO_ENV,
  );
  assert.equal(r.code, 0);
  assert.equal(parseDecision(r.stdout), 'allow');
  assert.ok(!fs.existsSync(pendingPath(sid)), 'Edit is auto-eligible → no pending');
  const entries = readAuditEntries();
  assert.equal(entries.length, 1);
  assert.equal(entries[0].tool_name, 'Edit');
  assert.ok(entries[0].summary.includes('/tmp/x'));
  resetAutoSettings();
  resetAutoAudit();
});

test('auto mode + write_file (agy) → eligible, auto-allow, no pending, audit appended', async () => {
  const sid = 'test-auto-agy-write';
  cleanupSession(sid);
  resetAutoSettings();
  resetAutoAudit();
  writeAutoSettings({ autoMode: { agy: { enabled: true, expiresAt: null } } });

  const r = await runHookAt(
    HOOK_AGY,
    { session_id: sid, tool_name: 'write_file', tool_input: { file_path: '/tmp/y' } },
    AUTO_ENV,
  );
  assert.equal(r.code, 0);
  assert.equal(parseDecision(r.stdout), 'allow');
  assert.ok(!fs.existsSync(pendingPath(sid)), 'write_file is auto-eligible → no pending');
  const entries = readAuditEntries();
  assert.equal(entries.length, 1);
  assert.equal(entries[0].tool_name, 'write_file');
  resetAutoSettings();
  resetAutoAudit();
});

test('audit file is created with 0o600 permissions', async () => {
  const sid = 'test-auto-audit-mode';
  cleanupSession(sid);
  resetAutoSettings();
  resetAutoAudit();
  writeAutoSettings({ autoMode: { 'claude-code': { enabled: true, expiresAt: null } } });

  const r = await runHook(
    { session_id: sid, tool_name: 'Bash', tool_input: { command: 'cp a.txt b.txt' } },
    AUTO_ENV,
  );
  assert.equal(parseDecision(r.stdout), 'allow');
  const mode = fs.statSync(AUTO_AUDIT_PATH).mode & 0o777;
  assert.equal(mode, 0o600, `audit file must be 0o600, got 0o${mode.toString(8)}`);
  resetAutoSettings();
  resetAutoAudit();
});

test('fail-closed: audit write fails → no auto-allow, writes pending instead', async () => {
  const sid = 'test-auto-audit-failclosed';
  cleanupSession(sid);
  resetAutoSettings();

  // Make the audit path unwritable: its parent directory is a regular file, so
  // mkdirSync/appendFileSync inside appendAutoAudit will throw → returns false.
  const blockerFile = path.join(AUTO_TMP_DIR, 'blocker-file');
  fs.writeFileSync(blockerFile, 'i am a file, not a dir');
  const unwritableAudit = path.join(blockerFile, 'audit.jsonl');

  writeAutoSettings({ autoMode: { 'claude-code': { enabled: true, expiresAt: null } } });

  const hookPromise = runHook(
    { session_id: sid, tool_name: 'Bash', tool_input: { command: 'cp a.txt b.txt' } },
    {
      WAKAWAKA_SETTINGS_PATH: AUTO_SETTINGS_PATH,
      WAKAWAKA_AUDIT_PATH:    unwritableAudit,
      APP_DEAD_GRACE_MS: '3000',
      APP_CHECK_EVERY_MS: '0',
    },
  );
  await new Promise((r) => setTimeout(r, 500));
  assert.ok(fs.existsSync(pendingPath(sid)), 'audit failure must fall through to pending, not auto-allow');
  assert.ok(!fs.existsSync(unwritableAudit), 'no audit file should exist when the write failed');

  fs.writeFileSync(decisionPath(sid), JSON.stringify({ decision: 'allow' }));
  await hookPromise;
  try { fs.unlinkSync(blockerFile); } catch { /* ok */ }
  resetAutoSettings();
});
