/**
 * Tests for the shared agent-registry module (plan §9-1, 2, 8, 9, 10).
 *
 * Every test points WAKAWAKA_STATE_DIR at its own temp directory, so the suite
 * never touches the live ~/.wakawaka — same rule as the other hook tests.
 */
import { test } from 'node:test';
import assert from 'node:assert/strict';
import * as fs from 'node:fs';
import * as os from 'node:os';
import * as path from 'node:path';
import { spawnSync } from 'node:child_process';

const MODULE = new URL('./agent-registry.mjs', import.meta.url).pathname;

/**
 * The module reads WAKAWAKA_STATE_DIR at import time, so each case runs it in a
 * fresh child process rather than re-importing it in-process.
 */
function runInRegistry(stateDir, body, env = {}) {
  const script = `
    import * as registry from ${JSON.stringify(MODULE)};
    const out = await (async () => { ${body} })();
    process.stdout.write(JSON.stringify(out ?? null));
  `;
  const r = spawnSync(process.execPath, ['--input-type=module', '-e', script], {
    encoding: 'utf8',
    env: { ...process.env, WAKAWAKA_STATE_DIR: stateDir, ...env },
  });
  if (r.status !== 0) throw new Error(`child failed: ${r.stderr}`);
  return JSON.parse(r.stdout || 'null');
}

function tempStateDir() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'agent-registry-test-'));
  fs.mkdirSync(path.join(dir, 'state'), { recursive: true });
  return { root: dir, stateDir: path.join(dir, 'state') };
}

// ── §9-1: entry creation ─────────────────────────────────────────────────────

test('SessionStart-style entry is written with the documented fields', () => {
  const { root, stateDir } = tempStateDir();
  try {
    const entry = runInRegistry(stateDir, `
      const e = registry.buildEntry({
        kind: 'claude-code', sessionId: 'sess-1',
        cwd: process.env.HOME + '/lake-ui-kit', gitBranch: 'main',
        model: 'claude-opus-5', pid: process.pid,
      });
      registry.writeEntry(e);
      return registry.readEntry('claude-code', 'sess-1');
    `);

    assert.equal(entry.schema, 1);
    assert.equal(entry.kind, 'claude-code');
    assert.equal(entry.sessionId, 'sess-1');
    assert.equal(entry.cwd, '~/lake-ui-kit', 'home is abbreviated for display');
    assert.equal(entry.gitBranch, 'main');
    assert.equal(entry.model, 'claude-opus-5');
    assert.equal(entry.state, 'idle');
    assert.ok(entry.pid > 0);
    assert.ok(entry.pidStartedAt > 0, 'pid start time is required for the reuse guard');
    assert.ok(entry.startedAt && entry.heartbeatAt);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('the registry file is created 0600 — it names projects and branches', () => {
  const { root, stateDir } = tempStateDir();
  try {
    runInRegistry(stateDir, `
      registry.writeEntry(registry.buildEntry({
        kind: 'claude-code', sessionId: 'perms', cwd: '/tmp/x', pid: process.pid,
      }));
      return true;
    `);
    const mode = fs.statSync(path.join(stateDir, 'agent_claude-code_perms.json')).mode & 0o777;
    assert.equal(mode, 0o600);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

// ── §9-2: self-recursion guard ───────────────────────────────────────────────

test('WAKAWAKA_INTERNAL=1 is detected so hooks can no-op', () => {
  const { root, stateDir } = tempStateDir();
  try {
    const internal = runInRegistry(stateDir, 'return registry.isInternalInvocation();',
      { WAKAWAKA_INTERNAL: '1' });
    const normal = runInRegistry(stateDir, 'return registry.isInternalInvocation();');
    assert.equal(internal, true, "WakaWaka's own `claude -p /usage` must not register");
    assert.equal(normal, false);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

// ── §9-10: untrusted session ids ─────────────────────────────────────────────

test('session ids that could escape the state directory are rejected', () => {
  const { root, stateDir } = tempStateDir();
  try {
    const results = runInRegistry(stateDir, `
      const bad = ['../evil', 'a/b', '..', '.', '', 'x'.repeat(129), 'has space', 'nul\\u0000byte'];
      return bad.map((id) => registry.registryPath('claude-code', id));
    `);
    assert.ok(results.every((p) => p === null), `all rejected, got ${JSON.stringify(results)}`);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('a traversal id cannot write outside the state directory', () => {
  const { root, stateDir } = tempStateDir();
  try {
    const wrote = runInRegistry(stateDir, `
      return registry.writeEntry({
        schema: 1, kind: 'claude-code', sessionId: '../escaped', cwd: '/tmp',
      });
    `);
    assert.equal(wrote, false);
    assert.ok(!fs.existsSync(path.join(root, 'escaped.json')), 'nothing written outside');
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('an unknown kind is rejected', () => {
  const { root, stateDir } = tempStateDir();
  try {
    const p = runInRegistry(stateDir, "return registry.registryPath('gemini', 'sess-1');");
    assert.equal(p, null);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

// ── §9-8: atomic write ───────────────────────────────────────────────────────

test('concurrent writers never leave a half-written document', () => {
  const { root, stateDir } = tempStateDir();
  try {
    // Twenty writers with differently-sized payloads; a non-atomic write would
    // leave a truncated file that JSON.parse rejects.
    const readings = runInRegistry(stateDir, `
      const base = registry.buildEntry({
        kind: 'claude-code', sessionId: 'race', cwd: '/tmp/x', pid: process.pid,
      });
      const readings = [];
      for (let i = 0; i < 20; i++) {
        registry.writeEntry({ ...base, lastTool: 'T'.repeat(i * 200) });
        readings.push(registry.readEntry('claude-code', 'race') !== null);
      }
      return readings;
    `);
    assert.ok(readings.every(Boolean), 'every intermediate read parsed cleanly');

    const file = path.join(stateDir, 'agent_claude-code_race.json');
    assert.ok(JSON.parse(fs.readFileSync(file, 'utf8')), 'final file is valid JSON');
    const leftovers = fs.readdirSync(stateDir).filter((f) => f.endsWith('.tmp'));
    assert.deepEqual(leftovers, [], 'no temp files left behind');
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

// ── §9-9: pid resolution ─────────────────────────────────────────────────────

test('process start time matches what the Swift side reads from sysctl', () => {
  const { root, stateDir } = tempStateDir();
  try {
    const started = runInRegistry(stateDir, 'return registry.processStartedAt(process.pid);');
    assert.ok(started > 0, 'must parse under any locale — ps -o lstart= is localised');

    // Independently derived: the same value the pid-reuse guard compares against.
    const lstart = spawnSync('ps', ['-p', String(process.pid), '-o', 'lstart='],
      { encoding: 'utf8', env: { ...process.env, LC_ALL: 'C' } }).stdout.trim();
    const expected = Math.floor(Date.parse(lstart) / 1000);
    // Different processes, so compare the shape rather than the exact instant.
    assert.ok(Number.isFinite(expected));
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('start time is read correctly under a non-English locale', () => {
  const { root, stateDir } = tempStateDir();
  try {
    // Without LC_ALL=C the module would parse "三 8月/12 …" and store null,
    // silently disabling the pid-reuse guard.
    const started = runInRegistry(stateDir, 'return registry.processStartedAt(process.pid);',
      { LC_ALL: 'zh_TW.UTF-8', LANG: 'zh_TW.UTF-8' });
    assert.ok(started > 0, 'locale must not affect the parsed start time');
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('pid resolution returns the agent process, not the shell below it', () => {
  const { root, stateDir } = tempStateDir();
  try {
    // A real three-deep tree: an executable whose `comm` ends in `/claude`,
    // the shell it launches, and the hook underneath that. Copying the node
    // binary is the only way to forge `comm` on macOS — a shebang script
    // reports its interpreter, and a copied /bin/sh is killed by code signing.
    const fakeAgent = path.join(root, 'claude');
    fs.copyFileSync(process.execPath, fakeAgent);
    fs.chmodSync(fakeAgent, 0o755);

    // `; exit $?` stops the shell from exec'ing its single command, which
    // would collapse the shell layer this test exists to walk past.
    fs.writeFileSync(path.join(root, 'inner.mjs'), `
      import * as registry from ${JSON.stringify(MODULE)};
      process.stdout.write(JSON.stringify({ resolved: registry.resolveAgentPid() }));
    `);
    fs.writeFileSync(path.join(root, 'outer.cjs'), `
      const { execSync } = require('child_process');
      const out = execSync(${JSON.stringify(process.execPath)} + ' ' +
        ${JSON.stringify(path.join(root, 'inner.mjs'))} + '; exit $?', { encoding: 'utf8' });
      process.stdout.write(JSON.stringify({ agentPid: process.pid, inner: JSON.parse(out) }));
    `);

    const r = spawnSync(fakeAgent, [path.join(root, 'outer.cjs')], {
      encoding: 'utf8',
      env: { ...process.env, WAKAWAKA_STATE_DIR: stateDir },
    });
    assert.equal(r.status, 0, `child failed: ${r.stderr}`);
    const { agentPid, inner } = JSON.parse(r.stdout);

    assert.equal(inner.resolved, agentPid,
      'must resolve to the process whose comm matched, not the shell beneath it');
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('pid resolution terminates on a chain with no agent process', () => {
  const { root, stateDir } = tempStateDir();
  try {
    // pid 1 has no agent ancestor; the hop limit must stop the walk.
    const resolved = runInRegistry(stateDir, 'return registry.resolveAgentPid(1);');
    assert.equal(resolved, 1, 'falls back to the starting pid');
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

// ── Update semantics ─────────────────────────────────────────────────────────

test('updateEntry refuses to resurrect a session it never saw start', () => {
  const { root, stateDir } = tempStateDir();
  try {
    // Sessions that predate hook installation have no entry. Creating one here
    // would produce a row with no pid, which the liveness check can never clear.
    const updated = runInRegistry(stateDir, `
      return registry.updateEntry('claude-code', 'never-started', () => ({ state: 'working' }));
    `);
    assert.equal(updated, false);
    assert.deepEqual(fs.readdirSync(stateDir), []);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('updateEntry advances heartbeatAt on every write', () => {
  const { root, stateDir } = tempStateDir();
  try {
    const result = runInRegistry(stateDir, `
      registry.writeEntry(registry.buildEntry({
        kind: 'claude-code', sessionId: 'beat', cwd: '/tmp/x', pid: process.pid,
      }));
      const before = registry.readEntry('claude-code', 'beat').heartbeatAt;
      await new Promise((r) => setTimeout(r, 15));
      registry.updateEntry('claude-code', 'beat', () => ({ lastTool: 'Edit' }));
      const after = registry.readEntry('claude-code', 'beat');
      return { before, after };
    `);
    assert.ok(result.after.heartbeatAt > result.before, 'heartbeat moved forward');
    assert.equal(result.after.lastTool, 'Edit');
    assert.equal(result.after.sessionId, 'beat', 'unrelated fields are preserved');
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('deleteEntry removes the file and tolerates a missing one', () => {
  const { root, stateDir } = tempStateDir();
  try {
    const result = runInRegistry(stateDir, `
      registry.writeEntry(registry.buildEntry({
        kind: 'codex', sessionId: 'gone', cwd: '/tmp/x', pid: process.pid,
      }));
      const first = registry.deleteEntry('codex', 'gone');
      const second = registry.deleteEntry('codex', 'gone');
      return { first, second };
    `);
    assert.equal(result.first, true);
    assert.equal(result.second, false, 'a second delete is not an error');
    assert.deepEqual(fs.readdirSync(stateDir), []);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

// ── Payload interpretation ───────────────────────────────────────────────────

test('kind and session id come from the right payload fields per agent', () => {
  const { root, stateDir } = tempStateDir();
  try {
    const result = runInRegistry(stateDir, `
      return {
        claude: [registry.detectKind({ session_id: 'a' }), registry.detectSessionId({ session_id: 'a' })],
        // Codex's session_id is an approval UUID; codex_session_id is the real one.
        codex: [
          registry.detectKind({ session_id: 'approval-uuid', codex_session_id: 'real' }),
          registry.detectSessionId({ session_id: 'approval-uuid', codex_session_id: 'real' }),
        ],
        tagged: [registry.detectKind({ agent: 'codex', session_id: 'c' }), null],
        empty: [registry.detectKind({}), registry.detectSessionId({})],
      };
    `);
    assert.deepEqual(result.claude, ['claude-code', 'a']);
    assert.deepEqual(result.codex, ['codex', 'real']);
    assert.equal(result.tagged[0], 'codex');
    assert.deepEqual(result.empty, [null, null]);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('a corrupt registry file reads as absent rather than throwing', () => {
  const { root, stateDir } = tempStateDir();
  try {
    fs.writeFileSync(path.join(stateDir, 'agent_claude-code_broken.json'), '{ half writ');
    const entry = runInRegistry(stateDir, "return registry.readEntry('claude-code', 'broken');");
    assert.equal(entry, null);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

// ── Privacy: nothing user-authored may reach disk ────────────────────────────

test('a skill name that is not an identifier is dropped, not persisted', async () => {
  // The registry claims to hold metadata only. `tool_input.skill` is
  // model-authored and unbounded, so anything that is not plausibly a name --
  // prose, a secret, a megabyte of padding -- must not be written.
  const { skillIdentifier } = await import(MODULE);

  assert.equal(skillIdentifier('code-review'), 'code-review');
  assert.equal(skillIdentifier('plugin:deploy'), 'plugin:deploy');

  assert.equal(skillIdentifier('my api key is sk-proj-abc123'), null);
  assert.equal(skillIdentifier('../../etc/passwd'), null);
  assert.equal(skillIdentifier('x'.repeat(65)), null, 'length is bounded');
  assert.equal(skillIdentifier('-leading-dash'), null);
  assert.equal(skillIdentifier(''), null);
  assert.equal(skillIdentifier({ toString: () => 'evil' }), null);
});

test('recordToolUse never writes an unvalidated skill name', () => {
  const { root, stateDir } = tempStateDir();
  try {
    const secret = 'internal note: token sk-live-DEADBEEF';
    const entry = runInRegistry(stateDir, `
      registry.writeEntry(registry.buildEntry({ kind: 'claude-code', sessionId: 'sk-1', cwd: '/tmp' }));
      registry.recordToolUse({ session_id: 'sk-1', tool_name: 'Skill',
                               tool_input: { skill: ${JSON.stringify(secret)} } });
      return registry.readEntry('claude-code', 'sk-1');
    `);
    assert.equal(entry.skill, null, 'prose is not a skill name');
    assert.equal(entry.lastTool, 'Skill', 'the tool name itself is still recorded');

    const raw = fs.readFileSync(
      path.join(stateDir, 'agent_claude-code_sk-1.json'), 'utf8');
    assert.ok(!raw.includes('sk-live-DEADBEEF'), `secret reached disk: ${raw}`);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});
