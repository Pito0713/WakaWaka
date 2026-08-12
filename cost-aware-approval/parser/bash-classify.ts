/**
 * bash-classify.ts — decides which activity phase a Bash command represents.
 *
 * Taking the first token of a command does not work: of 64 unclassified Bash
 * calls measured for phase-usage-plan.md §4.2, 60 began with `cd`. A command
 * is a chain, and the interesting part is rarely at the front.
 *
 * The approach: drop heredoc bodies, split the chain into segments, strip the
 * noise that wraps the real command (`cd x &&`, `env A=b`, `sudo`, `npx`),
 * classify each segment, and take the highest-priority result. Anything the
 * rules cannot place lands in `other` with the head token recorded — an honest
 * gap is reportable and fixable, a guess is neither.
 *
 * The error that matters is a false `verify` or `understand`, not a false
 * `other`: a wrong label corrupts the report silently, while `other` shows up
 * in the `unknownBash` diagnostic and gets fixed. Every ambiguous case below
 * therefore resolves to `other`.
 */

import { splitSegments, tokenize, writesViaRedirect } from './shell-split.js';

export { splitSegments, stripHeredocBodies } from './shell-split.js';

/** Bash never counts as `develop`; edits go through the file-editing tools. */
export type BashPhase = 'understand' | 'verify' | 'other';

export interface BashClassification {
  phase: BashPhase;
  /** Which rule fired, e.g. `verify:runner-script(test:unit)`. For audits. */
  reason: string;
  /**
   * Head token of the segment that decided the phase, or of the first
   * unclassifiable segment. Feeds the `unknownBash` diagnostic.
   */
  head: string;
}

// ── Rule tables ───────────────────────────────────────────────────────────────

/** Wrappers that say nothing about intent; drop them and look at what follows. */
const TRANSPARENT_PREFIXES = new Set(['sudo', 'time', 'command', 'nohup', 'nice', 'exec']);

/** Two-token runners, e.g. `pnpm exec vitest` → `vitest`. */
const RUNNER_PAIRS: [string, string][] = [
  ['pnpm', 'exec'], ['pnpm', 'dlx'], ['npm', 'exec'], ['yarn', 'dlx'],
  ['bundle', 'exec'], ['poetry', 'run'], ['pipenv', 'run'], ['uv', 'run'],
];

/** Single-token runners that delegate to whatever comes next. */
const RUNNER_SINGLES = new Set(['npx', 'bunx', 'uvx']);

/**
 * Commands that only read — but only once the write-detection below has
 * cleared them. `tee` is deliberately absent: its whole purpose is to write.
 */
const READ_ONLY = new Set([
  'cat', 'bat', 'less', 'more', 'head', 'tail', 'ls', 'tree', 'find', 'fd',
  'grep', 'rg', 'ag', 'ack', 'wc', 'stat', 'file', 'du', 'df', 'pwd', 'whoami',
  'which', 'whereis', 'type', 'printenv', 'uname', 'ps', 'awk', 'cut', 'sort',
  'uniq', 'tr', 'jq', 'yq', 'xxd', 'od', 'realpath', 'basename', 'dirname',
  'readlink', 'echo', 'printf', 'man', 'diff', 'comm', 'nl', 'column', 'date',
  'sed', // demoted by MUTATING_FLAGS when `-i` is present
]);

/** Commands whose purpose is to write, wherever they appear in a pipeline. */
const WRITERS = new Set(['tee', 'dd']);

/** Runtimes that become test runners with `--test`, and are ambiguous without it. */
const RUNTIMES_WITH_TEST_FLAG = new Set(['node', 'tsx', 'bun', 'deno']);

/**
 * Shell keywords that introduce a command: `then pytest` runs pytest. They are
 * stripped so the command behind them is classified — dropping the segment
 * loses every command inside a one-line `if`/`while`/loop body.
 */
const CLAUSE_KEYWORDS = new Set(['then', 'do', 'else', 'elif', 'if', 'while', 'until', '!']);

/** Segments that are pure block punctuation — no command to classify. */
const BLOCK_PUNCTUATION = new Set(['fi', 'done', 'esac', '{', '}']);

/** Loop and case headers name a variable and a word list, never a command. */
const HEADER_KEYWORDS = new Set(['for', 'select', 'case']);

/** Shell no-ops, usually a loop or `if` condition; they carry no intent. */
const NO_OP_COMMANDS = new Set(['true', 'false', ':']);

/**
 * Flags that turn an otherwise read-only command into one that writes.
 * Without these, `find . -delete` and `sort -o out in` read as `understand`.
 */
const MUTATING_FLAGS: Record<string, string[]> = {
  find: ['-delete', '-exec', '-execdir', '-ok', '-okdir', '-fls', '-fprint', '-fprintf'],
  fd: ['-x', '--exec', '-X', '--exec-batch'],
  sort: ['-o', '--output'],
  sed: ['-i', '--in-place'],
  rg: ['--replace'],
};

/** Commands whose whole purpose is to test, build, or check. */
const VERIFY_DIRECT = new Set([
  'pytest', 'py.test', 'tox', 'nose2', 'unittest', 'jest', 'vitest', 'mocha',
  'ava', 'karma', 'cypress', 'playwright', 'rspec', 'phpunit', 'ctest',
  'tsc', 'eslint', 'biome', 'oxlint', 'ruff', 'flake8', 'pylint', 'mypy',
  'pyright', 'shellcheck', 'hadolint', 'golangci-lint', 'rubocop', 'staticcheck',
  'cmake', 'ninja', 'xcodebuild', 'gcc', 'g++', 'clang', 'clang++', 'rustc', 'javac',
]);

/** Tool → subcommands that mean test/build/check. Others fall through to `other`. */
const VERIFY_SUBCOMMANDS: Record<string, Set<string>> = {
  cargo: new Set(['test', 'check', 'clippy', 'build', 'bench']),
  go: new Set(['test', 'vet', 'build']),
  swift: new Set(['test', 'build']),
  dotnet: new Set(['test', 'build']),
  bazel: new Set(['test', 'build']),
  mvn: new Set(['test', 'verify', 'package', 'compile']),
};

/**
 * Git subcommands that cannot mutate the repository in any form.
 * `remote`, `reflog`, `symbolic-ref`, `branch`, `tag` and `stash` are absent
 * on purpose — each reads in one form and writes in another (`git remote add`,
 * `git reflog expire`), and only `remote` is worth the special case below.
 */
const GIT_READ_ONLY = new Set([
  'log', 'diff', 'show', 'status', 'blame', 'shortlog', 'whatchanged',
  'describe', 'ls-files', 'ls-tree', 'rev-parse', 'rev-list', 'cat-file',
  'for-each-ref', 'grep',
]);

/** `git remote <verb>` is read-only only for these verbs. */
const GIT_REMOTE_READ_ONLY = new Set(['show', 'get-url', '-v', '--verbose']);

/** `gh <noun> <verb>` — matched structurally, never by scanning for any verb. */
const GH_READ_ONLY_VERBS = new Set(['view', 'list', 'status', 'checks', 'diff']);

/** Package-manager frontends whose `run <script>` needs the script name to decide. */
const SCRIPT_RUNNERS = new Set(['npm', 'pnpm', 'yarn', 'bun']);

/**
 * Script/target names that mean verification. Anchored at the start so
 * `test:unit` and `build:prod` match while `dev` and `start` do not — the
 * distinction phase-usage-plan.md §4.2 requires (`npm run dev` is not verify).
 */
const VERIFY_SCRIPT = /^(tests?|spec|lint|typecheck|type-check|tsc|check|verify|validate|ci|build|compile|e2e|coverage|audit|fmt:check|format:check)\b/i;

const PHASE_RANK: Record<BashPhase, number> = { verify: 3, understand: 2, other: 1 };

const ENV_ASSIGNMENT = /^[A-Za-z_][A-Za-z0-9_]*=/;

/** Drops env assignments, transparent wrappers, and delegating runners. */
function stripPrefixes(tokens: string[]): string[] {
  let rest = tokens;
  for (;;) {
    const [head, next] = rest;
    if (!head) return rest;

    if (ENV_ASSIGNMENT.test(head)) { rest = rest.slice(1); continue; }
    if (head === 'env') { rest = rest.slice(1); continue; }
    if (CLAUSE_KEYWORDS.has(head)) { rest = rest.slice(1); continue; }
    if (TRANSPARENT_PREFIXES.has(head)) { rest = rest.slice(1); continue; }
    if (RUNNER_SINGLES.has(head)) {
      rest = rest.slice(1);
      while (rest[0]?.startsWith('-')) rest = rest.slice(1); // e.g. `npx -y`
      continue;
    }
    if (next && RUNNER_PAIRS.some(([a, b]) => a === head && b === next)) { rest = rest.slice(2); continue; }
    // `python -m pytest` / `node -m …` — the module is the real command.
    if (/^(python3?|node|deno)$/.test(head) && next === '-m') { rest = rest.slice(2); continue; }
    return rest;
  }
}

// ── Segment classification ────────────────────────────────────────────────────

/** Normalises `./gradlew`, `/usr/bin/pytest`, `bin/rspec` down to the tool name. */
function baseName(token: string): string {
  const base = token.split('/').pop() ?? token;
  return base === 'gradlew' ? 'gradle' : base;
}

/** First token that is not an option or an option's value-looking neighbour. */
function firstNonFlag(tokens: string[]): string | undefined {
  for (let i = 0; i < tokens.length; i++) {
    const token = tokens[i];
    if (!token.startsWith('-')) return token;
    // `git -C repo diff` — a flag that takes a path argument.
    if (token === '-C' || token === '--work-tree' || token === '--git-dir') i++;
  }
  return undefined;
}

/** A segment result, plus whether that segment wrote anything to disk. */
interface SegmentResult extends BashClassification {
  writes: boolean;
}

function classifySegment(segment: string): SegmentResult | null {
  // `(cmd; cmd)` and `{ cmd; }` group commands — classify what is inside.
  const grouped = segment.match(/^\((.*)\)$/s) ?? segment.match(/^\{(.*)\}$/s);
  if (grouped) {
    const inner = classifyBash(grouped[1]);
    return inner.reason === 'other:empty' ? null : { ...inner, writes: false };
  }

  const tokens = stripPrefixes(tokenize(segment));
  const raw = tokens[0];
  if (!raw) return null;

  const head = baseName(raw);
  const args = tokens.slice(1);

  if (WRITERS.has(head)) {
    return { phase: 'other', reason: `other:writes-files(${head})`, head, writes: true };
  }

  // `cd somewhere` is navigation — it carries no intent of its own. Returning
  // null lets the rest of the chain decide, which is the whole point of §4.2.
  if (head === 'cd' || head === 'pushd' || head === 'popd') return null;

  // `{ a; b; }` and `if …; then …; fi` split on their own semicolons, leaving
  // bare punctuation and loop headers behind. Those carry no command — but the
  // keyword-prefixed segments do, and `stripPrefixes` has already unwrapped
  // them, so only the genuinely empty structures are dropped here.
  if (BLOCK_PUNCTUATION.has(head) || HEADER_KEYWORDS.has(head) || NO_OP_COMMANDS.has(head)) return null;

  const redirects = writesViaRedirect(segment);
  const mutating = MUTATING_FLAGS[head]?.find((flag) => args.some((a) => a === flag || a.startsWith(`${flag}=`)));
  const writes = redirects || mutating !== undefined;

  const decided =
    classifyScriptRunner(head, args) ??
    classifySubcommand(head, args) ??
    classifyDirect(head, args);

  if (!decided) return { phase: 'other', reason: `other:unknown(${head})`, head, writes };

  // `understand` claims the command only read. A redirect into a file or a
  // mutating flag contradicts that, so demote rather than mislabel.
  if (decided.phase === 'understand') {
    if (redirects) return { phase: 'other', reason: `other:redirects-output(${head})`, head, writes };
    if (mutating) return { phase: 'other', reason: `other:mutating-flag(${head} ${mutating})`, head, writes };
  }
  return { ...decided, writes };
}

function classifyScriptRunner(head: string, args: string[]): BashClassification | null {
  if (!SCRIPT_RUNNERS.has(head)) return null;
  const sub = firstNonFlag(args);
  if (!sub) return { phase: 'other', reason: `other:bare-runner(${head})`, head };

  if (sub === 'test' || sub === 't' || sub === 'audit') {
    return { phase: 'verify', reason: `verify:runner-builtin(${head} ${sub})`, head };
  }
  if (sub === 'run') {
    const script = firstNonFlag(args.slice(args.indexOf(sub) + 1));
    if (!script) return { phase: 'other', reason: `other:runner-no-script(${head})`, head };
    return VERIFY_SCRIPT.test(script)
      ? { phase: 'verify', reason: `verify:runner-script(${script})`, head }
      // `npm run dev` and friends: a script name we cannot judge.
      : { phase: 'other', reason: `other:runner-script(${script})`, head };
  }
  // install / ci / publish / exec-with-no-match — deliberately not verify.
  return { phase: 'other', reason: `other:runner-subcommand(${head} ${sub})`, head };
}

/** `git` and `gh`, whose subcommands read in one form and write in another. */
function classifyVcs(head: string, args: string[]): BashClassification | null {
  const sub = firstNonFlag(args);
  if (!sub) return { phase: 'other', reason: `other:bare-tool(${head})`, head };

  if (head === 'git') {
    if (GIT_READ_ONLY.has(sub)) {
      return { phase: 'understand', reason: `understand:subcommand(git ${sub})`, head };
    }
    if (sub === 'remote') {
      const verb = args[args.indexOf(sub) + 1];
      return verb && GIT_REMOTE_READ_ONLY.has(verb)
        ? { phase: 'understand', reason: `understand:subcommand(git remote ${verb})`, head }
        : { phase: 'other', reason: `other:subcommand(git remote)`, head };
    }
    return { phase: 'other', reason: `other:subcommand(git ${sub})`, head };
  }

  // `gh <noun> <verb>` — positional, so a branch or label named `view` in some
  // other position cannot fake a read-only match.
  const verb = args[args.indexOf(sub) + 1];
  if (verb && GH_READ_ONLY_VERBS.has(verb)) {
    return { phase: 'understand', reason: `understand:subcommand(gh ${sub} ${verb})`, head };
  }
  return { phase: 'other', reason: `other:subcommand(gh ${sub})`, head };
}

function classifySubcommand(head: string, args: string[]): BashClassification | null {
  if (head === 'git' || head === 'gh') return classifyVcs(head, args);

  const sub = firstNonFlag(args);
  const verifySubs = VERIFY_SUBCOMMANDS[head];
  if (verifySubs) {
    if (!sub) return { phase: 'other', reason: `other:bare-tool(${head})`, head };
    return verifySubs.has(sub)
      ? { phase: 'verify', reason: `verify:subcommand(${head} ${sub})`, head }
      : { phase: 'other', reason: `other:subcommand(${head} ${sub})`, head };
  }

  // `make check`, `./gradlew test` — the target name is the only signal.
  if (head === 'make' || head === 'gradle') {
    if (!sub) return { phase: 'other', reason: `other:bare-tool(${head})`, head };
    return VERIFY_SCRIPT.test(sub)
      ? { phase: 'verify', reason: `verify:target(${head} ${sub})`, head }
      : { phase: 'other', reason: `other:target(${head} ${sub})`, head };
  }
  return null;
}

/**
 * True when `--test` belongs to the runtime rather than to the script it runs.
 * In `node app.js --test` the flag is the application's, so the command is not
 * a test run; only flags appearing before the first script operand are the
 * runtime's own.
 */
function hasRuntimeTestFlag(args: string[]): boolean {
  for (const arg of args) {
    if (arg === '--test') return true;
    if (!arg.startsWith('-')) return false; // first positional = the script
  }
  return false;
}

function classifyDirect(head: string, args: string[]): BashClassification | null {
  if (VERIFY_DIRECT.has(head)) return { phase: 'verify', reason: `verify:command(${head})`, head };

  // `node --test` / `tsx --test` run a test suite; the same binaries without
  // the flag just execute a script, which says nothing about intent.
  if (RUNTIMES_WITH_TEST_FLAG.has(head) && hasRuntimeTestFlag(args)) {
    return { phase: 'verify', reason: `verify:runtime-test(${head} --test)`, head };
  }

  // `prettier --write` rewrites files; `--check` only reports. Bare prettier is
  // ambiguous enough that guessing either way would be wrong some of the time.
  if (head === 'prettier') {
    if (args.some((a) => a === '--write' || a === '-w')) {
      return { phase: 'other', reason: 'other:writes-files(prettier)', head };
    }
    return args.some((a) => a === '--check' || a === '-c' || a === '--list-different' || a === '-l')
      ? { phase: 'verify', reason: 'verify:command(prettier --check)', head }
      : { phase: 'other', reason: 'other:ambiguous(prettier)', head };
  }

  if (READ_ONLY.has(head)) return { phase: 'understand', reason: `understand:read-only(${head})`, head };
  return null;
}

// ── Entry point ───────────────────────────────────────────────────────────────

/**
 * Classifies a whole Bash command by taking the highest-priority segment
 * (verify > understand > other), matching the overall phase precedence in
 * phase-usage-plan.md §4.1.
 */
export function classifyBash(command: string): BashClassification {
  const segments = splitSegments(command);
  let best: SegmentResult | null = null;
  let writer: SegmentResult | null = null;

  for (const segment of segments) {
    const result = classifySegment(segment);
    if (!result) continue;
    if (result.writes && !writer) writer = result;
    if (!best || PHASE_RANK[result.phase] > PHASE_RANK[best.phase]) best = result;
  }

  if (best) {
    // `printf x | tee out` reads in one segment and writes in another. Taking
    // the highest-priority segment alone would report the whole chain as
    // read-only, so a write anywhere in the chain vetoes `understand`.
    // The head names the segment that actually writes — reporting the reading
    // segment would put `echo` at the top of the unknownBash diagnostic and
    // send whoever reads it looking in the wrong place.
    if (best.phase === 'understand' && writer) {
      return { phase: 'other', reason: `other:chain-writes(${writer.head})`, head: writer.head };
    }
    return { phase: best.phase, reason: best.reason, head: best.head };
  }
  // Every segment was navigation (`cd x && cd y`) or the command was empty.
  const head = baseName(tokenize(segments[0] ?? '')[0] ?? '');
  return { phase: 'other', reason: head ? `other:navigation-only(${head})` : 'other:empty', head };
}
