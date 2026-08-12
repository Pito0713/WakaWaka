import { test } from 'node:test';
import assert from 'node:assert/strict';
import * as fs from 'fs';
import * as os from 'os';
import * as path from 'path';
import { spawn } from 'node:child_process';

const HOOK = new URL('./pretooluse.mjs', import.meta.url).pathname;

/**
 * Every test gets its own ~/.wakawaka equivalent under a temp root.
 *
 * These tests used to read and write the real `~/.wakawaka/state`, which made
 * them depend on two things that have nothing to do with the code: whether
 * auto mode happened to be enabled (an auto-allow turns an expected `defer`
 * into `allow`), and whether the WakaWaka app was running to answer the
 * pending file. They also left `decision_test-*.json` behind in the live state
 * directory, which the running app would then act on.
 *
 * `settings.json` is written with auto mode explicitly OFF so a decision is
 * always required — the tests exercise the approval path, not the bypass.
 */
function createHarness() {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'pretooluse-test-'));
  const stateDir = path.join(root, 'state');
  fs.mkdirSync(stateDir, { recursive: true });
  fs.writeFileSync(
    path.join(root, 'settings.json'),
    JSON.stringify({ autoMode: { 'claude-code': { enabled: false, expiresAt: null } } })
  );

  return {
    root,
    stateDir,
    environment: {
      WAKAWAKA_STATE_DIR: stateDir,
      WAKAWAKA_ALLOWLIST_PATH: path.join(root, 'allowlist.json'),
      WAKAWAKA_SETTINGS_PATH: path.join(root, 'settings.json'),
      WAKAWAKA_AUDIT_PATH: path.join(root, 'audit.jsonl'),
      // A decision that never arrives must fail the test in seconds, not stall
      // the whole suite for the production 9m50s.
      WARN_TIMEOUT_MS: '3000',
      FINAL_TIMEOUT_MS: '5000',
    },
    cleanup() {
      fs.rmSync(root, { recursive: true, force: true });
    },
  };
}

/**
 * `pgrep -x` decides whether the app is considered alive. `node` always
 * matches (the test runner itself), `__nonexistent__` never does — so both
 * branches are reachable without starting or killing the real app.
 */
const APP_ALIVE = { WAKAWAKA_PROCESS_NAME: 'node' };
const APP_DEAD = { WAKAWAKA_PROCESS_NAME: '__nonexistent__' };

function pendingPath(harness, sid) { return path.join(harness.stateDir, `pending_${sid}.json`); }
function decisionPath(harness, sid) { return path.join(harness.stateDir, `decision_${sid}.json`); }

function runHook(harness, sid, env = {}) {
  const fixture = JSON.stringify({
    session_id: sid,
    tool_name: 'Bash',
    tool_input: { command: 'cp src dst' },
    transcript_path: '/tmp/test.jsonl',
  });

  return new Promise((resolve) => {
    const child = spawn(process.execPath, [HOOK], {
      env: { ...process.env, ...harness.environment, ...env },
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

/** Waits for the hook to write its pending file, rather than guessing a delay. */
async function waitForPending(harness, sid, timeoutMs = 4000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (fs.existsSync(pendingPath(harness, sid))) return;
    await new Promise((r) => setTimeout(r, 20));
  }
  throw new Error(`pending file for ${sid} never appeared`);
}

test('no decision file and app dead → exit 0 with defer', async () => {
  const harness = createHarness();
  try {
    const { code, stdout } = await runHook(harness, 'timeout-dead', {
      ...APP_DEAD,
      APP_DEAD_GRACE_MS: '600',
      APP_CHECK_EVERY_MS: '0',
    });
    assert.equal(code, 0);
    assert.equal(JSON.parse(stdout).hookSpecificOutput?.permissionDecision, 'defer');
  } finally {
    harness.cleanup();
  }
});

test('decision allow → exit 0', async () => {
  const harness = createHarness();
  try {
    const sid = 'allow';
    const hookPromise = runHook(harness, sid, APP_ALIVE);
    await waitForPending(harness, sid);
    fs.writeFileSync(decisionPath(harness, sid), JSON.stringify({ decision: 'allow' }));

    const { code } = await hookPromise;
    assert.equal(code, 0);
    assert.ok(!fs.existsSync(decisionPath(harness, sid)), 'decision file should be deleted');
  } finally {
    harness.cleanup();
  }
});

test('decision deny → exit 2 + reason on stderr', async () => {
  const harness = createHarness();
  try {
    const sid = 'deny';
    const hookPromise = runHook(harness, sid, APP_ALIVE);
    await waitForPending(harness, sid);
    fs.writeFileSync(
      decisionPath(harness, sid),
      JSON.stringify({ decision: 'deny', reason: 'User denied' }),
    );

    const { code, stderr } = await hookPromise;
    assert.equal(code, 2);
    assert.equal(stderr, 'User denied');
    assert.ok(!fs.existsSync(decisionPath(harness, sid)), 'decision file should be deleted');
  } finally {
    harness.cleanup();
  }
});

test('pending file contains correct fields', async () => {
  const harness = createHarness();
  try {
    const sid = 'fields';
    const hookPromise = runHook(harness, sid, APP_ALIVE);
    await waitForPending(harness, sid);

    const pending = JSON.parse(fs.readFileSync(pendingPath(harness, sid), 'utf8'));
    assert.equal(pending.session_id, sid);
    assert.equal(pending.tool_name, 'Bash');
    assert.deepEqual(pending.tool_input, { command: 'cp src dst' });
    assert.ok(pending.timestamp, 'should have timestamp');

    // Let the hook exit rather than leaving it to time out.
    fs.writeFileSync(decisionPath(harness, sid), JSON.stringify({ decision: 'allow' }));
    await hookPromise;
  } finally {
    harness.cleanup();
  }
});

test('the suite never touches the real ~/.wakawaka', async () => {
  // A guard against the isolation regressing: if a future change drops one of
  // the env overrides, the hook falls back to the home directory and this
  // catches it instead of the damage showing up in the user's live state.
  const harness = createHarness();
  const liveState = path.join(os.homedir(), '.wakawaka', 'state');
  const before = fs.existsSync(liveState) ? fs.readdirSync(liveState).sort() : [];
  try {
    const sid = 'isolation-guard';
    const hookPromise = runHook(harness, sid, APP_ALIVE);
    await waitForPending(harness, sid);
    fs.writeFileSync(decisionPath(harness, sid), JSON.stringify({ decision: 'allow' }));
    await hookPromise;

    const after = fs.existsSync(liveState) ? fs.readdirSync(liveState).sort() : [];
    assert.deepEqual(after, before, 'the live state directory must be untouched');
  } finally {
    harness.cleanup();
  }
});
