import { test } from 'node:test';
import assert from 'node:assert/strict';
import { classifyBash, splitSegments } from './bash-classify.js';

/** Asserts the phase, surfacing the rule that fired when it disagrees. */
function assertPhase(command: string, expected: string) {
  const result = classifyBash(command);
  assert.equal(result.phase, expected, `${command} → ${result.phase} via ${result.reason}`);
  return result;
}

// ── Chain splitting (the reason first-token classification fails) ─────────────

test('splitSegments: splits on &&, ||, ;, | and newlines', () => {
  assert.deepEqual(splitSegments('a && b || c ; d | e'), ['a', 'b', 'c', 'd', 'e']);
  assert.deepEqual(splitSegments('a\nb'), ['a', 'b']);
});

test('splitSegments: separators inside quotes are not separators', () => {
  assert.deepEqual(splitSegments('grep "a && b" file'), ['grep "a && b" file']);
  assert.deepEqual(splitSegments("echo 'x | y'"), ["echo 'x | y'"]);
});

test('splitSegments: separators inside $(…) and backticks are not separators', () => {
  assert.deepEqual(splitSegments('echo $(a && b)'), ['echo $(a && b)']);
  assert.deepEqual(splitSegments('echo `a | b`'), ['echo `a | b`']);
});

// ── Plan §11-8: the regression this module exists for ────────────────────────

test('`cd app && npm test` is verify — the v1 first-token rule said other', () => {
  const result = assertPhase('cd app && npm test', 'verify');
  assert.equal(result.head, 'npm', 'the deciding segment is reported, not `cd`');
});

test('a chain of nothing but cd is other, and says so', () => {
  const result = assertPhase('cd /tmp && cd app', 'other');
  assert.match(result.reason, /navigation-only/);
});

// ── Plan §11-9: npm run must not blanket-count as verify ─────────────────────

test('`npm run dev` is NOT verify', () => {
  const result = assertPhase('npm run dev', 'other');
  assert.match(result.reason, /runner-script\(dev\)/);
});

test('`npm run test:unit` and `npm run build` are verify', () => {
  assertPhase('npm run test:unit', 'verify');
  assertPhase('npm run build', 'verify');
});

test('`npm install` / `npm ci` are not verify', () => {
  assertPhase('npm install', 'other');
  assertPhase('npm ci', 'other');
});

// ── Plan §11-10: prefix stripping and subcommand tools ───────────────────────

test('`env NODE_ENV=test pytest` is verify', () => {
  assertPhase('env NODE_ENV=test pytest', 'verify');
});

test('a bare leading assignment is stripped too', () => {
  assertPhase('NODE_ENV=test pytest -q', 'verify');
});

test('`git -C repo diff` is understand — the flag takes a path argument', () => {
  const result = assertPhase('git -C repo diff', 'understand');
  assert.match(result.reason, /git diff/);
});

test('`xcodebuild test` and `./gradlew test` are verify', () => {
  assertPhase('xcodebuild test', 'verify');
  assertPhase('./gradlew test', 'verify');
});

test('`./gradlew run` is not verify — the target name is the only signal', () => {
  assertPhase('./gradlew run', 'other');
});

test('transparent wrappers and runners are stripped', () => {
  assertPhase('sudo pytest', 'verify');
  assertPhase('time npx vitest run', 'verify');
  assertPhase('pnpm exec eslint .', 'verify');
  assertPhase('npx -y tsc --noEmit', 'verify');
  assertPhase('python3 -m pytest', 'verify');
});

// ── Read-only detection ──────────────────────────────────────────────────────

test('read-only commands are understand, including through a pipe', () => {
  assertPhase('rg TODO src', 'understand');
  assertPhase('grep -n foo file | wc -l', 'understand');
});

test('git subcommands that can mutate are not understand', () => {
  assertPhase('git commit -m x', 'other');
  assertPhase('git branch -D old', 'other');
});

test('`gh pr view 12` is understand via the second-word verb', () => {
  assertPhase('gh pr view 12', 'understand');
});

test('sed and prettier are judged by whether they write', () => {
  assertPhase('sed -n 1,5p file', 'understand');
  assertPhase('sed -i s/a/b/ file', 'other');
  assertPhase('prettier --check .', 'verify');
  assertPhase('prettier --write .', 'other');
});

// ── Priority and honest gaps ─────────────────────────────────────────────────

test('the highest-priority segment wins (verify > understand > other)', () => {
  assertPhase('cat notes.md && pytest', 'verify');
  assertPhase('some-unknown-tool && cat notes.md', 'understand');
});

test('cargo/go subcommands split test-or-build from run', () => {
  assertPhase('cargo test', 'verify');
  assertPhase('go build ./...', 'verify');
  assertPhase('cargo run', 'other');
});

// ── Plan §11-11: undecidable → other, with the head recorded ─────────────────

test('an unknown command is other and records its head for unknownBash', () => {
  const result = assertPhase('frobnicate --all', 'other');
  assert.equal(result.head, 'frobnicate');
  assert.match(result.reason, /unknown\(frobnicate\)/);
});

test('an unknown command behind cd still reports the real head, not `cd`', () => {
  const result = assertPhase('cd svc && frobnicate', 'other');
  assert.equal(result.head, 'frobnicate');
});

test('a path-qualified binary is reported by its base name', () => {
  const result = assertPhase('/usr/local/bin/frobnicate', 'other');
  assert.equal(result.head, 'frobnicate');
});

test('empty input does not throw', () => {
  const result = classifyBash('');
  assert.equal(result.phase, 'other');
  assert.equal(result.reason, 'other:empty');
});

// ── Adversarial-review regressions ───────────────────────────────────────────
// Each case below was a false positive found by the Codex cross-check. A wrong
// `verify`/`understand` corrupts the report silently, so they are guarded.

test('an escaped separator does not start a new segment', () => {
  // `echo foo\;pytest` passes ";pytest" to echo — nothing is tested.
  assertPhase('echo foo\\;pytest', 'understand');
  assertPhase('echo foo\\|eslint', 'understand');
});

test('a backslash-newline is a line continuation, not a command boundary', () => {
  assertPhase('echo foo \\\npytest', 'understand');
});

test('a heredoc body is data, not a command chain', () => {
  assertPhase("cat <<EOF\nnpm test\nEOF", 'understand');
  assertPhase("python3 - <<'PY'\nnpm test\nPY", 'other');
});

test('a heredoc body cannot fake a verify, but a real command after it still counts', () => {
  assertPhase("cat <<EOF\nfoo\nEOF\npytest", 'verify');
});

test('output redirection means the command is not read-only', () => {
  assertPhase('echo foo > out', 'other');
  assertPhase('cat in > out', 'other');
  assertPhase('sort in >> log', 'other');
});

test('descriptor duplication is not a file write', () => {
  assertPhase('cat file 2>&1', 'understand');
  assertPhase('pytest 2>&1', 'verify');
});

test('discarding output to /dev/null is not a file write', () => {
  // The single most common redirect in practice; treating it as a write
  // demoted 28% of all real Bash calls, nearly all of them plain reads.
  assertPhase('ls -la ~/notes 2>/dev/null', 'understand');
  assertPhase('ls -d knowledge/*/ 2>/dev/null; echo "---"; ls knowledge/', 'understand');
  assertPhase('cat missing.txt > /dev/null', 'understand');
});

test('mutating flags demote otherwise read-only commands', () => {
  assertPhase('find . -delete', 'other');
  assertPhase('find . -exec rm {} ;', 'other');
  assertPhase('sort -o out in', 'other');
  assertPhase('find . -name "*.ts"', 'understand', );
});

test('tee writes, so it is never understand', () => {
  assertPhase('printf x | tee out', 'other');
});

test('polymorphic git subcommands are not blanket read-only', () => {
  assertPhase('git remote add origin url', 'other');
  assertPhase('git remote -v', 'understand');
  assertPhase('git reflog expire --all', 'other');
  assertPhase('git symbolic-ref HEAD refs/heads/main', 'other');
});

test('a branch or tag named like a read-only verb cannot fake understand', () => {
  assertPhase('git branch status', 'other');
  assertPhase('git tag diff', 'other');
});

test('gh matches noun+verb positionally', () => {
  assertPhase('gh pr view 12', 'understand');
  assertPhase('gh pr merge 12', 'other');
});

test('a subshell is classified by its contents', () => {
  assertPhase('(cat x; pytest)', 'verify');
  assertPhase('(cd app && npm test)', 'verify');
});
