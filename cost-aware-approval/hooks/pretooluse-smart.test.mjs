/**
 * Tests for the smart permission logic added in the enhanced hook:
 * - Auto-allow readonly tools
 * - Bash prefix allowlist (auto-allow if already saved)
 * - "always" decision → saves prefix + exits 0
 */
import { test } from 'node:test';
import assert from 'node:assert/strict';
import * as fs from 'fs';
import * as os from 'os';
import * as path from 'path';
import { spawn } from 'node:child_process';

const STATE_DIR     = path.join(os.homedir(), '.costnotch', 'state');
const ALLOWLIST     = path.join(os.homedir(), '.costnotch', 'allowlist.json');
const PENDING_PATH  = path.join(STATE_DIR, 'pending.json');
const DECISION_PATH = path.join(STATE_DIR, 'decision.json');
const HOOK = new URL('./pretooluse.mjs', import.meta.url).pathname;

function cleanup() {
  for (const p of [PENDING_PATH, DECISION_PATH]) {
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
    let stderr = '';
    child.stderr.on('data', (d) => { stderr += d; });
    child.stdin.write(JSON.stringify(input));
    child.stdin.end();
    child.on('close', (code) => resolve({ code, stderr: stderr.trim() }));
  });
}

// ── Test 1: Read tool → auto exit 0 (no pending.json written) ────────────────
test('Read tool auto-approved: exit 0, no pending.json', async () => {
  cleanup();
  const { code } = await runHook({ tool_name: 'Read', tool_input: { file_path: '/tmp/x' } });
  assert.equal(code, 0);
  assert.ok(!fs.existsSync(PENDING_PATH), 'pending.json must not be written for readonly tools');
});

// ── Test 2: Glob → auto exit 0 ───────────────────────────────────────────────
test('Glob tool auto-approved: exit 0', async () => {
  cleanup();
  const { code } = await runHook({ tool_name: 'Glob', tool_input: { pattern: '**/*.ts' } });
  assert.equal(code, 0);
});

// ── Test 3: Bash with allowlisted prefix → auto exit 0 ───────────────────────
test('Bash with allowlisted prefix auto-approved: exit 0', async () => {
  cleanup();
  fs.mkdirSync(path.dirname(ALLOWLIST), { recursive: true });
  fs.writeFileSync(ALLOWLIST, JSON.stringify({ bashPrefixes: ['git'] }));

  const { code } = await runHook({ tool_name: 'Bash', tool_input: { command: 'git status' } });
  assert.equal(code, 0);
  assert.ok(!fs.existsSync(PENDING_PATH), 'no pending.json for allowlisted command');
  resetAllowlist();
});

// ── Test 4: Bash NOT in allowlist → writes pending.json ──────────────────────
test('Bash not in allowlist → writes pending.json and waits', async () => {
  cleanup();
  resetAllowlist();

  const hookPromise = runHook(
    { tool_name: 'Bash', tool_input: { command: 'rm -rf /tmp/test' } },
    { POLL_TIMEOUT_MS: '3000' },
  );
  // Give hook time to write pending.json
  await new Promise((r) => setTimeout(r, 500));
  assert.ok(fs.existsSync(PENDING_PATH), 'pending.json should be written');
  // Clean up: send allow so hook exits
  fs.writeFileSync(DECISION_PATH, JSON.stringify({ decision: 'allow' }));
  const { code } = await hookPromise;
  assert.equal(code, 0);
});

// ── Test 5: "always" decision → saves prefix to allowlist + exit 0 ───────────
test('"always" decision saves bash prefix to allowlist', async () => {
  cleanup();
  resetAllowlist();

  const hookPromise = runHook(
    { tool_name: 'Bash', tool_input: { command: 'npm install' } },
    { POLL_TIMEOUT_MS: '5000' },
  );
  await new Promise((r) => setTimeout(r, 500));
  fs.writeFileSync(DECISION_PATH, JSON.stringify({ decision: 'always' }));
  const { code } = await hookPromise;

  assert.equal(code, 0);
  const saved = JSON.parse(fs.readFileSync(ALLOWLIST, 'utf8'));
  assert.ok(saved.bashPrefixes.includes('npm'), 'npm prefix should be saved');
  resetAllowlist();
});

// ── Test 6: second run with saved prefix → auto exit 0 ───────────────────────
test('after "always", subsequent npm command auto-approved', async () => {
  cleanup();
  fs.mkdirSync(path.dirname(ALLOWLIST), { recursive: true });
  fs.writeFileSync(ALLOWLIST, JSON.stringify({ bashPrefixes: ['npm'] }));

  const { code } = await runHook({ tool_name: 'Bash', tool_input: { command: 'npm run dev' } });
  assert.equal(code, 0);
  assert.ok(!fs.existsSync(PENDING_PATH));
  resetAllowlist();
});

// ── Test 7: Write tool (not in readonly) → writes pending.json ───────────────
test('Write tool always requires approval', async () => {
  cleanup();
  const hookPromise = runHook(
    { tool_name: 'Write', tool_input: { file_path: '/tmp/x', content: 'hi' } },
    { POLL_TIMEOUT_MS: '3000' },
  );
  await new Promise((r) => setTimeout(r, 500));
  assert.ok(fs.existsSync(PENDING_PATH), 'Write must write pending.json');
  fs.writeFileSync(DECISION_PATH, JSON.stringify({ decision: 'allow' }));
  await hookPromise;
});
