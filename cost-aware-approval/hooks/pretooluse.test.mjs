import { test } from 'node:test';
import assert from 'node:assert/strict';
import * as fs from 'fs';
import * as os from 'os';
import * as path from 'path';
import { spawn } from 'node:child_process';

const STATE_DIR = path.join(os.homedir(), '.costnotch', 'state');
const PENDING_PATH = path.join(STATE_DIR, 'pending.json');
const DECISION_PATH = path.join(STATE_DIR, 'decision.json');
const HOOK = new URL('./pretooluse.mjs', import.meta.url).pathname;

const FIXTURE = JSON.stringify({
  session_id: 'test-session',
  tool_name: 'Bash',
  tool_input: { command: 'ls' },
  transcript_path: '/tmp/test.jsonl',
});

function cleanup() {
  for (const p of [PENDING_PATH, DECISION_PATH]) {
    try { fs.unlinkSync(p); } catch { /* ok */ }
  }
}

function runHook(env = {}) {
  return new Promise((resolve) => {
    const child = spawn(process.execPath, [HOOK], {
      env: { ...process.env, ...env },
      stdio: ['pipe', 'pipe', 'pipe'],
    });

    let stderr = '';
    child.stderr.on('data', (d) => { stderr += d.toString(); });
    child.stdin.write(FIXTURE);
    child.stdin.end();

    child.on('close', (code) => resolve({ code, stderr: stderr.trim() }));
  });
}

// ── Test 1: timeout → exit 1 ──────────────────────────────────────────────
test('no decision file → exit 1 after timeout', async () => {
  cleanup();
  const { code } = await runHook({ POLL_TIMEOUT_MS: '600' });
  assert.equal(code, 1);
});

// ── Test 2: allow → exit 0 ────────────────────────────────────────────────
test('decision allow → exit 0', async () => {
  cleanup();
  fs.mkdirSync(STATE_DIR, { recursive: true });

  // Write decision after a short delay so hook has time to write pending first
  const hookPromise = runHook({ POLL_TIMEOUT_MS: '5000' });
  await new Promise((r) => setTimeout(r, 300));
  fs.writeFileSync(DECISION_PATH, JSON.stringify({ decision: 'allow' }));

  const { code } = await hookPromise;
  assert.equal(code, 0);
  assert.ok(!fs.existsSync(DECISION_PATH), 'decision.json should be deleted');
});

// ── Test 3: deny → exit 2 + reason on stderr ─────────────────────────────
test('decision deny → exit 2 + reason on stderr', async () => {
  cleanup();
  fs.mkdirSync(STATE_DIR, { recursive: true });

  const hookPromise = runHook({ POLL_TIMEOUT_MS: '5000' });
  await new Promise((r) => setTimeout(r, 300));
  fs.writeFileSync(
    DECISION_PATH,
    JSON.stringify({ decision: 'deny', reason: 'User denied' }),
  );

  const { code, stderr } = await hookPromise;
  assert.equal(code, 2);
  assert.equal(stderr, 'User denied');
  assert.ok(!fs.existsSync(DECISION_PATH), 'decision.json should be deleted');
});

// ── Test 4: pending.json written correctly ────────────────────────────────
test('pending.json contains correct fields', async () => {
  cleanup();
  fs.mkdirSync(STATE_DIR, { recursive: true });

  const hookPromise = runHook({ POLL_TIMEOUT_MS: '5000' });
  await new Promise((r) => setTimeout(r, 300));

  const pending = JSON.parse(fs.readFileSync(PENDING_PATH, 'utf8'));
  assert.equal(pending.session_id, 'test-session');
  assert.equal(pending.tool_name, 'Bash');
  assert.deepEqual(pending.tool_input, { command: 'ls' });
  assert.ok(pending.timestamp, 'should have timestamp');

  // Clean up by letting hook time out
  fs.writeFileSync(DECISION_PATH, JSON.stringify({ decision: 'allow' }));
  await hookPromise;
});
