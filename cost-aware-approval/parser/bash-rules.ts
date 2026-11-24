/**
 * Rule tables for bash-classify.ts: which commands read, write, verify or
 * merely wrap another command. Data only; the logic lives in bash-classify.
 */

// ── Rule tables ───────────────────────────────────────────────────────────────

/** Wrappers that say nothing about intent; drop them and look at what follows. */
export const TRANSPARENT_PREFIXES = new Set(['sudo', 'time', 'command', 'nohup', 'nice', 'exec']);

/** Two-token runners, e.g. `pnpm exec vitest` → `vitest`. */
export const RUNNER_PAIRS: [string, string][] = [
  ['pnpm', 'exec'], ['pnpm', 'dlx'], ['npm', 'exec'], ['yarn', 'dlx'],
  ['bundle', 'exec'], ['poetry', 'run'], ['pipenv', 'run'], ['uv', 'run'],
];

/** Single-token runners that delegate to whatever comes next. */
export const RUNNER_SINGLES = new Set(['npx', 'bunx', 'uvx']);

/**
 * Commands that only read — but only once the write-detection below has
 * cleared them. `tee` is deliberately absent: its whole purpose is to write.
 */
export const READ_ONLY = new Set([
  'cat', 'bat', 'less', 'more', 'head', 'tail', 'ls', 'tree', 'find', 'fd',
  'grep', 'rg', 'ag', 'ack', 'wc', 'stat', 'file', 'du', 'df', 'pwd', 'whoami',
  'which', 'whereis', 'type', 'printenv', 'uname', 'ps', 'awk', 'cut', 'sort',
  'uniq', 'tr', 'jq', 'yq', 'xxd', 'od', 'realpath', 'basename', 'dirname',
  'readlink', 'echo', 'printf', 'man', 'diff', 'comm', 'nl', 'column', 'date',
  'sed', // demoted by MUTATING_FLAGS when `-i` is present
]);

/** Commands whose purpose is to write, wherever they appear in a pipeline. */
export const WRITERS = new Set(['tee', 'dd']);

/** Runtimes that become test runners with `--test`, and are ambiguous without it. */
export const RUNTIMES_WITH_TEST_FLAG = new Set(['node', 'tsx', 'bun', 'deno']);

/**
 * Shell keywords that introduce a command: `then pytest` runs pytest. They are
 * stripped so the command behind them is classified — dropping the segment
 * loses every command inside a one-line `if`/`while`/loop body.
 */
export const CLAUSE_KEYWORDS = new Set(['then', 'do', 'else', 'elif', 'if', 'while', 'until', '!']);

/** Segments that are pure block punctuation — no command to classify. */
export const BLOCK_PUNCTUATION = new Set(['fi', 'done', 'esac', '{', '}']);

/** Loop and case headers name a variable and a word list, never a command. */
export const HEADER_KEYWORDS = new Set(['for', 'select', 'case']);

/** Shell no-ops, usually a loop or `if` condition; they carry no intent. */
export const NO_OP_COMMANDS = new Set(['true', 'false', ':']);

/**
 * Flags that turn an otherwise read-only command into one that writes.
 * Without these, `find . -delete` and `sort -o out in` read as `understand`.
 */
export const MUTATING_FLAGS: Record<string, string[]> = {
  find: ['-delete', '-exec', '-execdir', '-ok', '-okdir', '-fls', '-fprint', '-fprintf'],
  fd: ['-x', '--exec', '-X', '--exec-batch'],
  sort: ['-o', '--output'],
  sed: ['-i', '--in-place'],
  rg: ['--replace'],
};

/** Commands whose whole purpose is to test, build, or check. */
export const VERIFY_DIRECT = new Set([
  'pytest', 'py.test', 'tox', 'nose2', 'unittest', 'jest', 'vitest', 'mocha',
  'ava', 'karma', 'cypress', 'playwright', 'rspec', 'phpunit', 'ctest',
  'tsc', 'eslint', 'biome', 'oxlint', 'ruff', 'flake8', 'pylint', 'mypy',
  'pyright', 'shellcheck', 'hadolint', 'golangci-lint', 'rubocop', 'staticcheck',
  'cmake', 'ninja', 'xcodebuild', 'gcc', 'g++', 'clang', 'clang++', 'rustc', 'javac',
]);

/** Tool → subcommands that mean test/build/check. Others fall through to `other`. */
export const VERIFY_SUBCOMMANDS: Record<string, Set<string>> = {
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
export const GIT_READ_ONLY = new Set([
  'log', 'diff', 'show', 'status', 'blame', 'shortlog', 'whatchanged',
  'describe', 'ls-files', 'ls-tree', 'rev-parse', 'rev-list', 'cat-file',
  'for-each-ref', 'grep',
]);

/** `git remote <verb>` is read-only only for these verbs. */
export const GIT_REMOTE_READ_ONLY = new Set(['show', 'get-url', '-v', '--verbose']);

/** `gh <noun> <verb>` — matched structurally, never by scanning for any verb. */
export const GH_READ_ONLY_VERBS = new Set(['view', 'list', 'status', 'checks', 'diff']);

/** Package-manager frontends whose `run <script>` needs the script name to decide. */
export const SCRIPT_RUNNERS = new Set(['npm', 'pnpm', 'yarn', 'bun']);

/**
 * Script/target names that mean verification. Anchored at the start so
 * `test:unit` and `build:prod` match while `dev` and `start` do not — the
 * distinction phase-usage-plan.md §4.2 requires (`npm run dev` is not verify).
 */
export const VERIFY_SCRIPT = /^(tests?|spec|lint|typecheck|type-check|tsc|check|verify|validate|ci|build|compile|e2e|coverage|audit|fmt:check|format:check)\b/i;
export const ENV_ASSIGNMENT = /^[A-Za-z_][A-Za-z0-9_]*=/;
