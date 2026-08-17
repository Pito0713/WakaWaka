/**
 * Tests for the lifecycle hooks and the PreToolUse heartbeat (plan §9-3..7, 13).
 *
 * Each case drives the real hook scripts as subprocesses with a private
 * WAKAWAKA_STATE_DIR, the same isolation rule as the other hook tests.
 */
import { test } from 'node:test';
import assert from 'node:assert/strict';
import * as fs from 'node:fs';
import * as os from 'node:os';
import * as path from 'node:path';
import { spawnSync } from 'node:child_process';

const HOOKS = {
  sessionStart: new URL('./sessionstart.mjs', import.meta.url).pathname,
  userPrompt: new URL('./userpromptsubmit.mjs', import.meta.url).pathname,
  stop: new URL('./stop.mjs', import.meta.url).pathname,
  sessionEnd: new URL('./sessionend.mjs', import.meta.url).pathname,
  preToolUse: new URL('./pretooluse.mjs', import.meta.url).pathname,
};

function createHarness() {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'agent-lifecycle-test-'));
  const stateDir = path.join(root, 'state');
  fs.mkdirSync(stateDir, { recursive: true });
  fs.writeFileSync(path.join(root, 'settings.json'), JSON.stringify({ autoMode: {} }));

  return {
    root,
    stateDir,
    environment: {
      WAKAWAKA_STATE_DIR: stateDir,
      WAKAWAKA_ALLOWLIST_PATH: path.join(root, 'allowlist.json'),
      WAKAWAKA_SETTINGS_PATH: path.join(root, 'settings.json'),
      WAKAWAKA_AUDIT_PATH: path.join(root, 'audit.jsonl'),
      WARN_TIMEOUT_MS: '2000',
      FINAL_TIMEOUT_MS: '3000',
    },
    entry(kind, sessionId) {
      const file = path.join(stateDir, `agent_${kind}_${sessionId}.json`);
      return fs.existsSync(file) ? JSON.parse(fs.readFileSync(file, 'utf8')) : null;
    },
    cleanup() { fs.rmSync(root, { recursive: true, force: true }); },
  };
}

/** Runs a lifecycle hook to completion; they are short-lived by design. */
function runHook(harness, hookPath, payload, extraEnv = {}) {
  return spawnSync(process.execPath, [hookPath], {
    input: JSON.stringify(payload),
    encoding: 'utf8',
    env: { ...process.env, ...harness.environment, ...extraEnv },
    timeout: 10_000,
  });
}

const CLAUDE_SESSION = { session_id: 'sess-abc', cwd: '/tmp/demo-project', model: 'claude-opus-5' };

// ── §9-1: SessionStart ───────────────────────────────────────────────────────

test('SessionStart registers the session and exits 0', () => {
  const h = createHarness();
  try {
    const r = runHook(h, HOOKS.sessionStart, { ...CLAUDE_SESSION, gitBranch: 'main' });
    assert.equal(r.status, 0);

    const entry = h.entry('claude-code', 'sess-abc');
    assert.ok(entry, 'registry entry created');
    assert.equal(entry.kind, 'claude-code');
    assert.equal(entry.state, 'idle', 'a new session is idle until a prompt arrives');
    assert.equal(entry.gitBranch, 'main');
    assert.equal(entry.model, 'claude-opus-5');
    assert.ok(entry.pid > 0 && entry.pidStartedAt > 0);
  } finally { h.cleanup(); }
});

test('SessionStart tolerates a malformed payload without failing the session', () => {
  const h = createHarness();
  try {
    const r = spawnSync(process.execPath, [HOOKS.sessionStart], {
      input: 'not json at all',
      encoding: 'utf8',
      env: { ...process.env, ...h.environment },
    });
    assert.equal(r.status, 0, 'a hook must never break session start');
    assert.deepEqual(fs.readdirSync(h.stateDir), []);
  } finally { h.cleanup(); }
});

// ── §9-13 / §9-2: self-recursion guard ───────────────────────────────────────

test("WakaWaka's own agent invocations never register", () => {
  const h = createHarness();
  try {
    // ParserRunner runs `claude -p "/usage"` every ten minutes with this set.
    for (const hook of [HOOKS.sessionStart, HOOKS.userPrompt, HOOKS.stop, HOOKS.sessionEnd]) {
      const r = runHook(h, hook, CLAUDE_SESSION, { WAKAWAKA_INTERNAL: '1' });
      assert.equal(r.status, 0);
    }
    assert.deepEqual(fs.readdirSync(h.stateDir), [], 'no phantom session in the panel');
  } finally { h.cleanup(); }
});

// ── §9-5: UserPromptSubmit ───────────────────────────────────────────────────

test('UserPromptSubmit marks the session working', () => {
  const h = createHarness();
  try {
    runHook(h, HOOKS.sessionStart, CLAUDE_SESSION);
    runHook(h, HOOKS.userPrompt, { ...CLAUDE_SESSION, prompt: 'please refactor this' });

    const entry = h.entry('claude-code', 'sess-abc');
    assert.equal(entry.state, 'working');
    assert.equal(entry.skill, null, 'an ordinary prompt names no skill');
  } finally { h.cleanup(); }
});

test('a slash command records the command name and its source', () => {
  const h = createHarness();
  try {
    runHook(h, HOOKS.sessionStart, CLAUDE_SESSION);
    runHook(h, HOOKS.userPrompt, { ...CLAUDE_SESSION, prompt: '/code-review the parser' });

    const entry = h.entry('claude-code', 'sess-abc');
    assert.equal(entry.skill, 'code-review');
    assert.equal(entry.skillSource, 'slash');
  } finally { h.cleanup(); }
});

test('only the command name is stored, never the prompt body', () => {
  const h = createHarness();
  try {
    runHook(h, HOOKS.sessionStart, CLAUDE_SESSION);
    const secret = 'my-api-key-should-never-be-written';
    runHook(h, HOOKS.userPrompt, { ...CLAUDE_SESSION, prompt: `/deploy ${secret}` });

    const raw = fs.readFileSync(
      path.join(h.stateDir, 'agent_claude-code_sess-abc.json'), 'utf8');
    assert.equal(JSON.parse(raw).skill, 'deploy');
    assert.ok(!raw.includes(secret), 'the privacy claim depends on this');
  } finally { h.cleanup(); }
});

test('a prompt that merely starts with a slash is not a command', () => {
  const h = createHarness();
  try {
    runHook(h, HOOKS.sessionStart, CLAUDE_SESSION);
    runHook(h, HOOKS.userPrompt, { ...CLAUDE_SESSION, prompt: '/opt/data/file.txt is broken' });

    const entry = h.entry('claude-code', 'sess-abc');
    assert.equal(entry.skill, null, 'a path is not a skill name');
    assert.equal(entry.state, 'working');
  } finally { h.cleanup(); }
});

// ── §9-6: Stop ───────────────────────────────────────────────────────────────

test('Stop returns the session to idle and clears the skill', () => {
  const h = createHarness();
  try {
    runHook(h, HOOKS.sessionStart, CLAUDE_SESSION);
    runHook(h, HOOKS.userPrompt, { ...CLAUDE_SESSION, prompt: '/code-review x' });
    runHook(h, HOOKS.stop, CLAUDE_SESSION);

    const entry = h.entry('claude-code', 'sess-abc');
    assert.equal(entry.state, 'idle');
    assert.equal(entry.skill, null, 'a skill belongs to the turn that invoked it');
    assert.equal(entry.skillSource, null);
  } finally { h.cleanup(); }
});

// ── §9-7: SessionEnd ─────────────────────────────────────────────────────────

test('SessionEnd removes the registry entry', () => {
  const h = createHarness();
  try {
    runHook(h, HOOKS.sessionStart, CLAUDE_SESSION);
    assert.ok(h.entry('claude-code', 'sess-abc'));

    runHook(h, HOOKS.sessionEnd, CLAUDE_SESSION);
    assert.equal(h.entry('claude-code', 'sess-abc'), null);
    assert.deepEqual(fs.readdirSync(h.stateDir), []);
  } finally { h.cleanup(); }
});

// ── §9-3 / §9-4: PreToolUse heartbeat ────────────────────────────────────────

test('PreToolUse records the tool and advances the heartbeat', async () => {
  const h = createHarness();
  try {
    runHook(h, HOOKS.sessionStart, CLAUDE_SESSION);
    const before = h.entry('claude-code', 'sess-abc').heartbeatAt;
    await new Promise((r) => setTimeout(r, 15));

    // Read is auto-allowed, so the hook returns immediately.
    const r = runHook(h, HOOKS.preToolUse, {
      ...CLAUDE_SESSION, tool_name: 'Read', tool_input: { file_path: '/tmp/x' },
    });
    assert.equal(r.status, 0);

    const entry = h.entry('claude-code', 'sess-abc');
    assert.equal(entry.lastTool, 'Read');
    assert.equal(entry.state, 'working');
    assert.ok(entry.heartbeatAt > before, 'heartbeat moved forward');
  } finally { h.cleanup(); }
});

test('the Skill tool records which skill is running', () => {
  const h = createHarness();
  try {
    runHook(h, HOOKS.sessionStart, CLAUDE_SESSION);
    runHook(h, HOOKS.preToolUse, {
      ...CLAUDE_SESSION, tool_name: 'Skill', tool_input: { skill: 'code-review' },
    });

    const entry = h.entry('claude-code', 'sess-abc');
    assert.equal(entry.skill, 'code-review');
    assert.equal(entry.skillSource, 'tool');
  } finally { h.cleanup(); }
});

test('the heartbeat does not change what PreToolUse decides', () => {
  const h = createHarness();
  try {
    runHook(h, HOOKS.sessionStart, CLAUDE_SESSION);

    // Read is auto-allowed with or without a registry entry present.
    const withEntry = runHook(h, HOOKS.preToolUse, {
      ...CLAUDE_SESSION, tool_name: 'Read', tool_input: { file_path: '/tmp/x' },
    });
    const decision = JSON.parse(withEntry.stdout).hookSpecificOutput.permissionDecision;
    assert.equal(decision, 'allow');

    // Same decision for a session the registry has never seen — registering it
    // is a side effect of the heartbeat, never an input to the decision.
    const withoutEntry = runHook(h, HOOKS.preToolUse, {
      session_id: 'unregistered', tool_name: 'Read', tool_input: { file_path: '/tmp/x' },
    });
    assert.equal(
      JSON.parse(withoutEntry.stdout).hookSpecificOutput.permissionDecision, 'allow');
  } finally { h.cleanup(); }
});

// ── Self-healing: a session the panel never saw start ────────────────────────

/**
 * The failure this prevents: install the hooks while windows are already open,
 * and those sessions stay invisible for as long as they live. Only SessionStart
 * wrote entries, every later hook declined to, and no amount of refreshing can
 * conjure a file that nobody writes.
 */
test('a session that predates the hooks appears on its next prompt', () => {
  const h = createHarness();
  try {
    // No SessionStart — this window was already running when the hooks landed.
    runHook(h, HOOKS.userPrompt, { ...CLAUDE_SESSION, prompt: 'carry on' });

    const entry = h.entry('claude-code', 'sess-abc');
    assert.ok(entry, 'the session registers itself rather than staying hidden');
    assert.equal(entry.state, 'working');
    assert.equal(entry.cwd, '/tmp/demo-project');
    assert.equal(entry.model, 'claude-opus-5');
  } finally { h.cleanup(); }
});

/**
 * A healed entry has to be liveness-checkable. One with no pid or no start time
 * would be worse than no row at all: the reader could never retire it, so it
 * would sit in the panel until the state directory was cleared by hand.
 */
test('a healed entry carries the pid the liveness check needs', () => {
  const h = createHarness();
  try {
    runHook(h, HOOKS.userPrompt, { ...CLAUDE_SESSION, prompt: 'go' });

    const entry = h.entry('claude-code', 'sess-abc');
    assert.ok(entry, 'the turn registers an unknown session');
    assert.equal(entry.schema, 1);
    assert.ok(Number.isInteger(entry.pid) && entry.pid > 0, 'a real pid');
    assert.ok(Number.isInteger(entry.pidStartedAt), 'and its start time');
  } finally { h.cleanup(); }
});

test('a healed session still goes away when it ends', () => {
  const h = createHarness();
  try {
    runHook(h, HOOKS.userPrompt, { ...CLAUDE_SESSION, prompt: 'go' });
    runHook(h, HOOKS.stop, CLAUDE_SESSION);
    assert.equal(h.entry('claude-code', 'sess-abc').state, 'idle');

    runHook(h, HOOKS.sessionEnd, CLAUDE_SESSION);
    assert.equal(h.entry('claude-code', 'sess-abc'), null);
  } finally { h.cleanup(); }
});

/**
 * Registering costs a pid resolution — several `ps` calls — and PreToolUse runs
 * ahead of the approval decision on every tool call. The turn-opening hooks do
 * that work instead, where nothing is waiting on it.
 */
test('the approval path never pays to register a session', () => {
  const h = createHarness();
  try {
    runHook(h, HOOKS.preToolUse, {
      ...CLAUDE_SESSION, tool_name: 'Read', tool_input: { file_path: '/tmp/x' },
    });
    assert.deepEqual(fs.readdirSync(h.stateDir), [],
      'an unknown session is left to UserPromptSubmit, not resolved here');

    // Once it exists, the heartbeat is an ordinary update again.
    runHook(h, HOOKS.userPrompt, { ...CLAUDE_SESSION, prompt: 'go' });
    runHook(h, HOOKS.preToolUse, {
      ...CLAUDE_SESSION, tool_name: 'Read', tool_input: { file_path: '/tmp/x' },
    });
    assert.equal(h.entry('claude-code', 'sess-abc').lastTool, 'Read');
  } finally { h.cleanup(); }
});

/**
 * A Stop that lands after SessionEnd must not put the finished session back.
 */
test('Stop cannot resurrect a session that has already ended', () => {
  const h = createHarness();
  try {
    runHook(h, HOOKS.sessionStart, CLAUDE_SESSION);
    runHook(h, HOOKS.sessionEnd, CLAUDE_SESSION);
    runHook(h, HOOKS.stop, CLAUDE_SESSION);

    assert.deepEqual(fs.readdirSync(h.stateDir), []);
  } finally { h.cleanup(); }
});

test("WakaWaka's own invocations are not healed into the panel either", () => {
  const h = createHarness();
  try {
    // `claude -p "/usage"` runs every 10 minutes; healing must not hand it the
    // entry SessionStart deliberately withholds.
    runHook(h, HOOKS.userPrompt, { ...CLAUDE_SESSION, prompt: '/usage' },
            { WAKAWAKA_INTERNAL: '1' });
    runHook(h, HOOKS.preToolUse, {
      ...CLAUDE_SESSION, tool_name: 'Read', tool_input: { file_path: '/tmp/x' },
    }, { WAKAWAKA_INTERNAL: '1' });

    assert.deepEqual(fs.readdirSync(h.stateDir), [], 'no phantom session in the panel');
  } finally { h.cleanup(); }
});

test('an unwritable state directory cannot break an approval', () => {
  const h = createHarness();
  try {
    runHook(h, HOOKS.sessionStart, CLAUDE_SESSION);
    fs.chmodSync(h.stateDir, 0o500); // read-only: registry writes will fail

    const r = runHook(h, HOOKS.preToolUse, {
      ...CLAUDE_SESSION, tool_name: 'Read', tool_input: { file_path: '/tmp/x' },
    });
    assert.equal(r.status, 0);
    assert.equal(JSON.parse(r.stdout).hookSpecificOutput.permissionDecision, 'allow');
  } finally {
    try { fs.chmodSync(h.stateDir, 0o700); } catch { /* already gone */ }
    h.cleanup();
  }
});

// ── Codex keying ─────────────────────────────────────────────────────────────

test('Codex sessions key on codex_session_id, not the approval UUID', () => {
  const h = createHarness();
  try {
    const payload = {
      session_id: 'approval-uuid-1234', codex_session_id: 'codex-real-id',
      cwd: '/tmp/demo', agent: 'codex',
    };
    runHook(h, HOOKS.sessionStart, payload);

    assert.ok(h.entry('codex', 'codex-real-id'), 'keyed on the real session id');
    assert.equal(h.entry('codex', 'approval-uuid-1234'), null);
  } finally { h.cleanup(); }
});
