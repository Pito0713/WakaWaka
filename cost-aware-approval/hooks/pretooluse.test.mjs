import { test } from 'node:test';
import assert from 'node:assert/strict';
import * as fs from 'fs';
import * as os from 'os';
import * as path from 'path';
import { spawn } from 'node:child_process';

const STATE_DIR = path.join(os.homedir(), '.wakawaka', 'state');
const HOOK = new URL('./pretooluse.mjs', import.meta.url).pathname;

function pendingPath(sid)  { return path.join(STATE_DIR, `pending_${sid}.json`); }
function decisionPath(sid) { return path.join(STATE_DIR, `decision_${sid}.json`); }

function cleanup(sid) {
  for (const p of [pendingPath(sid), decisionPath(sid)]) {
    try { fs.unlinkSync(p); } catch { /* ok */ }
  }
}

function runHook(sid, env = {}) {
  const fixture = JSON.stringify({
    session_id: sid,
    tool_name: 'Bash',
    tool_input: { command: 'cp src dst' },
    transcript_path: '/tmp/test.jsonl',
  });

  return new Promise((resolve) => {
    const child = spawn(process.execPath, [HOOK], {
      env: { ...process.env, ...env },
      stdio: ['pipe', 'pipe', 'pipe'],
    });

    let stderr = '';
    let stdout = '';
    child.stdout.on('data', (d) => { stdout += d.toString(); });
    child.stderr.on('data', (d) => { stderr += d.toString(); });
    child.stdin.write(fixture);
    child.stdin.end();

    child.on('close', (code) => {
      resolve({ code, stdout: stdout.trim(), stderr: stderr.trim() });
    });
  });
}

// ── Test 1: app dead → exit 0 with defer ─────────────────────────────────────
// WAKAWAKA_PROCESS_NAME=__nonexistent__ makes pgrep always return dead
// without needing to kill the real WakaWaka process.
test('no decision file and app dead → exit 0 with defer', async () => {
  const sid = 'test-timeout-dead';
  cleanup(sid);
  const { code, stdout } = await runHook(sid, {
    WAKAWAKA_PROCESS_NAME: '__nonexistent__',
    APP_DEAD_GRACE_MS: '600',
    APP_CHECK_EVERY_MS: '0',
  });
  assert.equal(code, 0);
  const parsed = JSON.parse(stdout);
  assert.equal(parsed.hookSpecificOutput?.permissionDecision, 'defer');
});

// ── Test 2: allow → exit 0 ────────────────────────────────────────────────
test('decision allow → exit 0', async () => {
  const sid = 'test-allow';
  cleanup(sid);
  fs.mkdirSync(STATE_DIR, { recursive: true });

  const hookPromise = runHook(sid, { FINAL_TIMEOUT_MS: '5000' });
  await new Promise((r) => setTimeout(r, 300));
  fs.writeFileSync(decisionPath(sid), JSON.stringify({ decision: 'allow' }));

  const { code } = await hookPromise;
  assert.equal(code, 0);
  assert.ok(!fs.existsSync(decisionPath(sid)), 'decision file should be deleted');
  cleanup(sid);
});

// ── Test 3: deny → exit 2 + reason on stderr ─────────────────────────────
test('decision deny → exit 2 + reason on stderr', async () => {
  const sid = 'test-deny';
  cleanup(sid);
  fs.mkdirSync(STATE_DIR, { recursive: true });

  const hookPromise = runHook(sid, { FINAL_TIMEOUT_MS: '5000' });
  await new Promise((r) => setTimeout(r, 300));
  fs.writeFileSync(
    decisionPath(sid),
    JSON.stringify({ decision: 'deny', reason: 'User denied' }),
  );

  const { code, stderr } = await hookPromise;
  assert.equal(code, 2);
  assert.equal(stderr, 'User denied');
  assert.ok(!fs.existsSync(decisionPath(sid)), 'decision file should be deleted');
  cleanup(sid);
});

// ── Test 4: pending file written correctly ────────────────────────────────
test('pending file contains correct fields', async () => {
  const sid = 'test-fields';
  cleanup(sid);
  fs.mkdirSync(STATE_DIR, { recursive: true });

  const hookPromise = runHook(sid, { FINAL_TIMEOUT_MS: '5000' });
  await new Promise((r) => setTimeout(r, 300));

  const pending = JSON.parse(fs.readFileSync(pendingPath(sid), 'utf8'));
  assert.equal(pending.session_id, sid);
  assert.equal(pending.tool_name, 'Bash');
  assert.deepEqual(pending.tool_input, { command: 'cp src dst' });
  assert.ok(pending.timestamp, 'should have timestamp');

  // Clean up by letting hook exit with allow
  fs.writeFileSync(decisionPath(sid), JSON.stringify({ decision: 'allow' }));
  await hookPromise;
  cleanup(sid);
});
