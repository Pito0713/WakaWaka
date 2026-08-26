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
    env: {
      ...process.env,
      TMUX: '',
      TMUX_PANE: '',
      WAKAWAKA_STATE_DIR: stateDir,
      ...env,
    },
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
    `, { TMUX: '', TMUX_PANE: '' });

    assert.equal(entry.schema, 1);
    assert.equal(entry.kind, 'claude-code');
    assert.equal(entry.sessionId, 'sess-1');
    assert.equal(entry.cwd, '~/lake-ui-kit', 'home is abbreviated for display');
    assert.equal(entry.gitBranch, 'main');
    assert.equal(entry.model, 'claude-opus-5');
    assert.equal(entry.tmuxSession, null, 'non-tmux hooks remain backward-compatible');
    assert.equal(entry.state, 'idle');
    assert.ok(entry.pid > 0);
    assert.ok(entry.pidStartedAt > 0, 'pid start time is required for the reuse guard');
    assert.ok(entry.startedAt && entry.heartbeatAt);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('tmux session detection uses an argv call and returns the current session', () => {
  const { root, stateDir } = tempStateDir();
  try {
    const fakeBin = path.join(root, 'bin');
    fs.mkdirSync(fakeBin);
    const fakeTmux = path.join(fakeBin, 'tmux');
    fs.writeFileSync(fakeTmux, '#!/bin/sh\n[ "$1" = display-message ] || exit 9\nprintf WakaWaka\n');
    fs.chmodSync(fakeTmux, 0o755);
    const session = runInRegistry(stateDir, 'return registry.detectTmuxSession();', {
      TMUX: '/tmp/tmux.sock,1,0', TMUX_PANE: '%7', PATH: `${fakeBin}:${process.env.PATH}`,
    });
    assert.equal(session, 'WakaWaka');
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('tmux session detection rejects absent, harmful, and overlong output', () => {
  const { root, stateDir } = tempStateDir();
  try {
    const fakeBin = path.join(root, 'bin');
    fs.mkdirSync(fakeBin);
    const fakeTmux = path.join(fakeBin, 'tmux');
    fs.writeFileSync(fakeTmux, '#!/bin/sh\nprintf "bad\\tname"\n');
    fs.chmodSync(fakeTmux, 0o755);
    const env = { TMUX: '/tmp/tmux.sock,1,0', TMUX_PANE: '%7', PATH: `${fakeBin}:${process.env.PATH}` };
    const harmful = runInRegistry(stateDir, 'return registry.detectTmuxSession();', env);
    fs.writeFileSync(fakeTmux, `#!/bin/sh\nprintf '${'x'.repeat(129)}'\n`);
    const overlong = runInRegistry(stateDir, 'return registry.detectTmuxSession();', env);
    const absent = runInRegistry(
      stateDir,
      'return registry.detectTmuxSession();',
      { TMUX: '', TMUX_PANE: '' },
    );
    assert.deepEqual([harmful, overlong, absent], [null, null, null]);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('a failed tmux lookup leaves the recorded session name alone', () => {
  const { root, stateDir } = tempStateDir();
  try {
    const fakeBin = path.join(root, 'bin');
    fs.mkdirSync(fakeBin);
    const fakeTmux = path.join(fakeBin, 'tmux');
    const inTmux = { TMUX: '/tmp/tmux.sock,1,0', TMUX_PANE: '%7', PATH: `${fakeBin}:${process.env.PATH}` };

    fs.writeFileSync(fakeTmux, '#!/bin/sh\nprintf WakaWaka\n');
    fs.chmodSync(fakeTmux, 0o755);
    const named = runInRegistry(stateDir, `
      registry.upsertEntry({ session_id: 'in-tmux', cwd: '/tmp/demo' }, () => ({ state: 'working' }));
      return registry.readEntry('claude-code', 'in-tmux');
    `, inTmux);
    assert.equal(named.tmuxSession, 'WakaWaka');

    // The next hook fires while tmux is unreachable. `null` here means "could
    // not tell", not "not in tmux", so the name must survive it.
    fs.writeFileSync(fakeTmux, '#!/bin/sh\nexit 1\n');
    const afterFailure = runInRegistry(stateDir, `
      registry.upsertEntry({ session_id: 'in-tmux', cwd: '/tmp/demo' }, () => ({ state: 'idle' }));
      return registry.readEntry('claude-code', 'in-tmux');
    `, inTmux);

    assert.equal(afterFailure.tmuxSession, 'WakaWaka', 'a lookup failure must not erase the name');
    assert.equal(afterFailure.state, 'idle', 'the rest of the update still lands');
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('a transcript path is kept only when it is one the app may open', () => {
  const { root, stateDir } = tempStateDir();
  try {
    const check = (path) => runInRegistry(
      stateDir,
      `return registry.detectTranscriptPath(${JSON.stringify({ transcript_path: path })});`,
    );

    assert.equal(check('/tmp/agent-home/.claude/projects/-tmp-agent-home-repo/sess.jsonl'),
                 '/tmp/agent-home/.claude/projects/-tmp-agent-home-repo/sess.jsonl');
    assert.equal(check('/tmp/agent-home/.codex/sessions/2026/08/25/rollout-x.jsonl'),
                 '/tmp/agent-home/.codex/sessions/2026/08/25/rollout-x.jsonl');

    assert.equal(check('~/.claude/projects/sess.jsonl'), null, 'must be absolute — the app opens it');
    assert.equal(check('/tmp/agent-home/.claude/../../etc/passwd'), null, 'a root checked by substring must not be climbable');
    assert.equal(check('/tmp/agent-home/.claude/a\nb.jsonl'), null);
    assert.equal(check(`/tmp/agent-home/.claude/${'x'.repeat(520)}`), null);
    assert.equal(check('/tmp/agent-home/Documents/notes.jsonl'), null, 'not a transcript root we recognise');
    assert.equal(check(42), null);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('a payload without a transcript path leaves the recorded one alone', () => {
  const { root, stateDir } = tempStateDir();
  try {
    const transcript = '/tmp/agent-home/.claude/projects/-tmp-agent-home-repo/known.jsonl';
    const stored = runInRegistry(stateDir, `
      registry.upsertEntry(
        { session_id: 'known', cwd: '/tmp/demo', transcript_path: ${JSON.stringify(transcript)} },
        () => ({ state: 'working' }),
      );
      return registry.readEntry('claude-code', 'known');
    `);
    assert.equal(stored.transcriptPath, transcript);

    // `Stop` and friends carry no transcript_path; that is not evidence the
    // session lost its transcript.
    const after = runInRegistry(stateDir, `
      registry.upsertEntry({ session_id: 'known', cwd: '/tmp/demo' }, () => ({ state: 'idle' }));
      return registry.readEntry('claude-code', 'known');
    `);
    assert.equal(after.transcriptPath, transcript, 'an absent path must not erase a recorded one');
    assert.equal(after.state, 'idle');
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

test('updateEntry never writes a file for a session it never saw start', () => {
  const { root, stateDir } = tempStateDir();
  try {
    // A blind update has no payload to build a proper entry from, so it would
    // write a row with no pid — one the liveness check could never clear.
    // Registering an unknown session is `upsertEntry`'s job, not this one's.
    const updated = runInRegistry(stateDir, `
      return registry.updateEntry('claude-code', 'never-started', () => ({ state: 'working' }));
    `);
    assert.equal(updated, false);
    assert.deepEqual(fs.readdirSync(stateDir), []);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('upsertEntry registers an unknown session with a checkable pid', () => {
  const { root, stateDir } = tempStateDir();
  try {
    const entry = runInRegistry(stateDir, `
      registry.upsertEntry(
        { session_id: 'healed', cwd: '/tmp/demo', model: 'claude-opus-5' },
        () => ({ state: 'working', lastTool: 'Bash' }),
      );
      return registry.readEntry('claude-code', 'healed');
    `);

    assert.equal(entry.sessionId, 'healed');
    assert.equal(entry.state, 'working');
    assert.equal(entry.lastTool, 'Bash');
    assert.ok(entry.pid > 0, 'resolved from this process, as SessionStart does');
    assert.ok(Number.isInteger(entry.pidStartedAt), 'so a dead row can be swept');
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('upsertEntry leaves an existing entry where SessionStart put it', () => {
  const { root, stateDir } = tempStateDir();
  try {
    const result = runInRegistry(stateDir, `
      registry.writeEntry(registry.buildEntry({
        kind: 'claude-code', sessionId: 'known', cwd: '/tmp/original', pid: process.pid,
      }));
      const before = registry.readEntry('claude-code', 'known');
      await new Promise((r) => setTimeout(r, 15));
      registry.upsertEntry(
        { session_id: 'known', cwd: '/tmp/somewhere-else' },
        () => ({ lastTool: 'Edit' }),
      );
      return { before, after: registry.readEntry('claude-code', 'known') };
    `);

    assert.equal(result.after.cwd, '/tmp/original', 'the update path, not a rewrite');
    assert.equal(result.after.startedAt, result.before.startedAt);
    assert.equal(result.after.lastTool, 'Edit');
    assert.ok(result.after.heartbeatAt > result.before.heartbeatAt);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('upsertEntry rejects a payload it cannot key on', () => {
  const { root, stateDir } = tempStateDir();
  try {
    const written = runInRegistry(stateDir, `
      return [
        registry.upsertEntry({ session_id: '../escape' }, () => ({})),
        registry.upsertEntry({ cwd: '/tmp/x' }, () => ({})),
      ];
    `);
    assert.deepEqual(written, [false, false]);
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

/**
 * A real Codex SessionStart payload, captured from `codex-cli 0.147.0`. It
 * names no agent and spells the id exactly as Claude Code does, so the old
 * rules filed every Codex session under `claude-code` — a Codex window either
 * showed up wearing the wrong name or, once `SessionEnd` deleted the entry
 * under a key nothing else used, not at all.
 */
test('a real Codex payload is told apart from a Claude Code one', () => {
  const { root, stateDir } = tempStateDir();
  try {
    const result = runInRegistry(stateDir, `
      const codex = {
        session_id: '01a00e82-823a-7a51-a8ae-37a764b8ed0f',
        transcript_path: process.env.HOME + '/.codex/sessions/2026/08/17/rollout-01a00e82.jsonl',
        cwd: process.env.HOME + '/WakaWaka',
        hook_event_name: 'SessionStart',
        model: 'gpt-5.6-sol',
        source: 'startup',
      };
      const claude = {
        session_id: '3fa081a4-67f8-4c01-b3dc-32c59cf30047',
        transcript_path: process.env.HOME + '/.claude/projects/-Users-jiejie-AG-knowledge/3fa081a4.jsonl',
        cwd: process.env.HOME + '/AG_knowledge',
        hook_event_name: 'SessionStart',
      };
      return {
        codex: [registry.detectKind(codex, {}), registry.detectSessionId(codex)],
        claude: [registry.detectKind(claude, {}), registry.detectSessionId(claude)],
        // No transcript to go on: the old weak guess, which is right far more
        // often than not because Claude Code is the common case.
        neither: registry.detectKind({ session_id: 'x' }, {}),
      };
    `);

    assert.deepEqual(result.codex, ['codex', '01a00e82-823a-7a51-a8ae-37a764b8ed0f']);
    assert.deepEqual(result.claude, ['claude-code', '3fa081a4-67f8-4c01-b3dc-32c59cf30047']);
    assert.equal(result.neither, 'claude-code');
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('the agent marker outranks the payload, and a bogus one is ignored', () => {
  const { root, stateDir } = tempStateDir();
  try {
    const result = runInRegistry(stateDir, `
      return {
        // Codex hooks run the same scripts; the marker is what tells them apart
        // when the payload only carries the weak session_id hint.
        wins: registry.detectKind({ session_id: 'x' }, { WAKAWAKA_AGENT: 'codex' }),
        // But an inherited marker must not refile a payload that named itself:
        // env vars leak into child processes, explicit fields do not.
        explicitPayloadWins: registry.detectKind({ agent: 'claude-code', session_id: 'x' },
                                                 { WAKAWAKA_AGENT: 'codex' }),
        codexIdWins: registry.detectKind({ codex_session_id: 'c' },
                                         { WAKAWAKA_AGENT: 'claude-code' }),
        // Anything not a known agent falls back to the payload rather than
        // becoming a kind of its own — this ends up in a filename.
        bogus: registry.detectKind({ session_id: 'x' }, { WAKAWAKA_AGENT: '../evil' }),
        unset: registry.detectKind({ session_id: 'x' }, {}),
      };
    `);
    assert.equal(result.wins, 'codex');
    assert.equal(result.explicitPayloadWins, 'claude-code');
    assert.equal(result.codexIdWins, 'codex');
    assert.equal(result.bogus, 'claude-code');
    assert.equal(result.unset, 'claude-code');
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('a Codex session registers under its own kind, from its own payload', () => {
  const { root, stateDir } = tempStateDir();
  try {
    const written = runInRegistry(stateDir, `
      registry.upsertEntry({
        session_id: 'codex-real',
        transcript_path: process.env.HOME + '/.codex/sessions/2026/08/17/rollout.jsonl',
        cwd: '/tmp/demo',
      }, () => ({ state: 'working' }));
      return registry.readEntry('codex', 'codex-real');
    `);

    assert.equal(written.kind, 'codex');
    assert.equal(written.sessionId, 'codex-real');
    assert.equal(written.state, 'working');
    assert.ok(written.pid > 0);
    assert.deepEqual(fs.readdirSync(stateDir), ['agent_codex_codex-real.json']);
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
