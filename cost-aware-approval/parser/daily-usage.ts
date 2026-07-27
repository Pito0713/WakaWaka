/**
 * daily-usage.ts — per-day, per-agent token usage aggregation for the dashboard.
 *
 * Emits one entry per calendar day (LOCAL timezone) over the requested window,
 * broken down by agent. Only Claude Code and Codex are covered — agy exposes no
 * token data (see usage-dashboard-plan.md §1).
 *
 * Three counting pitfalls handled here (getting any of them wrong corrupts the
 * whole dashboard — see plan §1):
 *   1. Claude writes the same API response to the JSONL multiple times; dedup by
 *      `${requestId}|${message.id}`, last-write-wins.
 *   2. Codex `total_token_usage` is a running session total; summing it double-
 *      counts. Sum `last_token_usage` per token_count event instead.
 *   3. `input_tokens` means OPPOSITE things: Claude's excludes cache reads,
 *      Codex's already INCLUDES cached_input_tokens. Normalise both to
 *      uncachedInput / cachedInput before they ever share a chart.
 *
 * Usage:  npx tsx daily-usage.ts [--days N]   (default N = 7)
 */

import * as fs from 'fs';
import * as os from 'os';
import * as path from 'path';
import * as readline from 'readline';
import { fileURLToPath } from 'url';

const MTok = 1_000_000;
const FILE_MTIME_BUFFER_MS = 6 * 60 * 60 * 1000; // clock-skew / cross-tz slack

// ── Output shape ──────────────────────────────────────────────────────────────

interface ClaudeDay {
  uncachedInput: number; // input_tokens (already excludes cache reads)
  cacheRead: number;
  cacheWrite: number;
  output: number;
  costUSD: number | null;
}

interface CodexDay {
  uncachedInput: number; // input_tokens − cached_input_tokens
  cachedInput: number; // cached_input_tokens
  output: number; // output_tokens (already includes reasoning tokens)
  reasoningOutput: number; // reasoning_output_tokens (subset of output, informational)
  costUSD: number | null;
}

interface DayEntry {
  date: string; // YYYY-MM-DD, local
  agents: {
    'claude-code'?: ClaudeDay;
    codex?: CodexDay;
  };
}

interface DailyUsageResult {
  generatedAt: string;
  days: DayEntry[];
}

// ── Pricing ───────────────────────────────────────────────────────────────────

interface ClaudePricing {
  inputPerMTok: number;
  outputPerMTok: number;
  cacheReadPerMTok: number;
  cacheCreationPerMTok: number;
}

interface CodexPricing {
  inputPerMTok: number;
  cachedInputPerMTok: number;
  outputPerMTok: number;
  cacheCreationPerMTok: number;
}

function loadPricing(): { claude: ClaudePricing; codex: CodexPricing | null } {
  const pricingPath = path.join(path.dirname(fileURLToPath(import.meta.url)), 'pricing.json');
  const raw = JSON.parse(fs.readFileSync(pricingPath, 'utf8')) as Record<string, unknown>;
  const claude: ClaudePricing = {
    inputPerMTok: Number(raw.inputPerMTok),
    outputPerMTok: Number(raw.outputPerMTok),
    cacheReadPerMTok: Number(raw.cacheReadPerMTok),
    cacheCreationPerMTok: Number(raw.cacheCreationPerMTok),
  };
  const codex = extractCodexPricing(raw.codex);
  return { claude, codex };
}

/** Returns null unless every Codex price is a finite number (plan §1: no guessing). */
function extractCodexPricing(node: unknown): CodexPricing | null {
  if (!node || typeof node !== 'object') return null;
  const c = node as Record<string, unknown>;
  const fields = ['inputPerMTok', 'cachedInputPerMTok', 'outputPerMTok', 'cacheCreationPerMTok'];
  for (const f of fields) {
    if (typeof c[f] !== 'number' || !Number.isFinite(c[f] as number)) return null;
  }
  return {
    inputPerMTok: c.inputPerMTok as number,
    cachedInputPerMTok: c.cachedInputPerMTok as number,
    outputPerMTok: c.outputPerMTok as number,
    cacheCreationPerMTok: c.cacheCreationPerMTok as number,
  };
}

// ── Date helpers (LOCAL timezone) ─────────────────────────────────────────────

/** YYYY-MM-DD in the machine's local timezone. */
function localDateKey(tsMs: number): string {
  return new Date(tsMs).toLocaleDateString('en-CA'); // en-CA renders ISO YYYY-MM-DD
}

/** Continuous axis of the last `days` local dates, oldest → newest. */
function buildDateAxis(days: number, now: Date): string[] {
  const axis: string[] = [];
  for (let i = days - 1; i >= 0; i--) {
    const d = new Date(now);
    d.setDate(d.getDate() - i);
    axis.push(d.toLocaleDateString('en-CA'));
  }
  return axis;
}

// ── File discovery ────────────────────────────────────────────────────────────

function scanForJSONL(dir: string): string[] {
  const files: string[] = [];
  let entries: fs.Dirent[];
  try {
    entries = fs.readdirSync(dir, { withFileTypes: true });
  } catch {
    return files; // missing dir → agent simply absent (plan §6: no error)
  }
  for (const entry of entries) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) files.push(...scanForJSONL(full));
    else if (entry.name.endsWith('.jsonl')) files.push(full);
  }
  return files;
}

/** Files whose mtime is too old to hold any entry in the window are skipped. */
function recentFiles(dir: string, periodStartMs: number): string[] {
  const cutoff = periodStartMs - FILE_MTIME_BUFFER_MS;
  return scanForJSONL(dir).filter((f) => {
    try {
      return fs.statSync(f).mtimeMs >= cutoff;
    } catch {
      return false;
    }
  });
}

async function eachLine(file: string, fn: (obj: Record<string, unknown>) => void): Promise<void> {
  const rl = readline.createInterface({
    input: fs.createReadStream(file),
    crlfDelay: Infinity,
  });
  try {
    for await (const line of rl) {
      const trimmed = line.trim();
      if (!trimmed) continue;
      let obj: Record<string, unknown>;
      try {
        obj = JSON.parse(trimmed);
      } catch {
        continue;
      }
      fn(obj);
    }
  } finally {
    rl.close();
  }
}

function toInt(v: unknown): number {
  const n = Number(v);
  return Number.isFinite(n) ? Math.floor(n) : 0;
}

// ── Claude Code aggregation ───────────────────────────────────────────────────

interface ClaudeAcc {
  uncachedInput: number;
  cacheRead: number;
  cacheWrite: number;
  output: number;
}

function emptyClaudeAcc(): ClaudeAcc {
  return { uncachedInput: 0, cacheRead: 0, cacheWrite: 0, output: 0 };
}

async function aggregateClaude(
  dir: string,
  dates: Set<string>,
  periodStartMs: number
): Promise<Map<string, ClaudeAcc>> {
  const files = recentFiles(dir, periodStartMs);

  // Global dedup across all files: same API response can appear multiple times.
  // Value carries the day bucket so we only sum survivors once, after dedup.
  const dedup = new Map<string, { date: string; delta: ClaudeAcc }>();
  let nokeySeq = 0;

  for (const file of files) {
    await eachLine(file, (obj) => {
      const usage = (obj.message as Record<string, unknown> | undefined)?.usage as
        | Record<string, unknown>
        | undefined;
      if (!usage || typeof usage['input_tokens'] !== 'number') return;

      const tsRaw = typeof obj.timestamp === 'string' ? obj.timestamp : '';
      const tsMs = tsRaw ? new Date(tsRaw).getTime() : NaN;
      if (Number.isNaN(tsMs)) return;
      const date = localDateKey(tsMs);
      if (!dates.has(date)) return;

      const requestId = typeof obj.requestId === 'string' ? obj.requestId : '';
      const msgId = (obj.message as Record<string, unknown> | undefined)?.id;
      const msgIdStr = typeof msgId === 'string' ? msgId : '';
      const key = requestId && msgIdStr ? `${requestId}|${msgIdStr}` : `__nokey_${nokeySeq++}`;

      dedup.set(key, {
        date,
        delta: {
          uncachedInput: toInt(usage['input_tokens']),
          cacheRead: toInt(usage['cache_read_input_tokens']),
          cacheWrite: toInt(usage['cache_creation_input_tokens']),
          output: toInt(usage['output_tokens']),
        },
      });
    });
  }

  const daily = new Map<string, ClaudeAcc>();
  for (const { date, delta } of dedup.values()) {
    const acc = daily.get(date) ?? emptyClaudeAcc();
    acc.uncachedInput += delta.uncachedInput;
    acc.cacheRead += delta.cacheRead;
    acc.cacheWrite += delta.cacheWrite;
    acc.output += delta.output;
    daily.set(date, acc);
  }
  return daily;
}

// ── Codex aggregation ─────────────────────────────────────────────────────────

interface CodexAcc {
  uncachedInput: number;
  cachedInput: number;
  output: number;
  reasoningOutput: number;
}

function emptyCodexAcc(): CodexAcc {
  return { uncachedInput: 0, cachedInput: 0, output: 0, reasoningOutput: 0 };
}

async function aggregateCodex(
  dir: string,
  dates: Set<string>,
  periodStartMs: number
): Promise<Map<string, CodexAcc>> {
  const files = recentFiles(dir, periodStartMs);
  const daily = new Map<string, CodexAcc>();

  for (const file of files) {
    await eachLine(file, (obj) => {
      const payload = obj.payload as Record<string, unknown> | undefined;
      if (!payload || payload.type !== 'token_count') return;
      const info = payload.info as Record<string, unknown> | undefined;
      const usage = info?.last_token_usage as Record<string, unknown> | undefined;
      if (!usage) return;

      const tsRaw = typeof obj.timestamp === 'string' ? obj.timestamp : '';
      const tsMs = tsRaw ? new Date(tsRaw).getTime() : NaN;
      if (Number.isNaN(tsMs)) return;
      const date = localDateKey(tsMs);
      if (!dates.has(date)) return;

      const input = toInt(usage['input_tokens']);
      const cached = toInt(usage['cached_input_tokens']);
      const acc = daily.get(date) ?? emptyCodexAcc();
      acc.uncachedInput += Math.max(0, input - cached); // Codex input already includes cache
      acc.cachedInput += cached;
      acc.output += toInt(usage['output_tokens']); // already includes reasoning
      acc.reasoningOutput += toInt(usage['reasoning_output_tokens']);
      daily.set(date, acc);
    });
  }
  return daily;
}

// ── Cost ──────────────────────────────────────────────────────────────────────

function claudeCost(a: ClaudeAcc, p: ClaudePricing): number {
  return (
    (a.uncachedInput / MTok) * p.inputPerMTok +
    (a.cacheRead / MTok) * p.cacheReadPerMTok +
    (a.cacheWrite / MTok) * p.cacheCreationPerMTok +
    (a.output / MTok) * p.outputPerMTok
  );
}

function codexCost(a: CodexAcc, p: CodexPricing): number {
  return (
    (a.uncachedInput / MTok) * p.inputPerMTok +
    (a.cachedInput / MTok) * p.cachedInputPerMTok +
    (a.output / MTok) * p.outputPerMTok
  );
}

function round4(n: number): number {
  return Math.round(n * 10_000) / 10_000;
}

// ── Assembly ──────────────────────────────────────────────────────────────────

export interface DailyUsageOptions {
  /** Override the Claude projects dir (default ~/.claude/projects). For tests. */
  claudeDir?: string;
  /** Override the Codex sessions dir (default ~/.codex/sessions). For tests. */
  codexDir?: string;
  /** Override "now" so the date axis is deterministic. For tests. */
  now?: Date;
}

export async function computeDailyUsage(
  days: number,
  opts: DailyUsageOptions = {}
): Promise<DailyUsageResult> {
  const now = opts.now ?? new Date();
  const claudeDir = opts.claudeDir ?? path.join(os.homedir(), '.claude', 'projects');
  const codexDir = opts.codexDir ?? path.join(os.homedir(), '.codex', 'sessions');

  const axis = buildDateAxis(days, now);
  const dateSet = new Set(axis);
  // Local start-of-day for the earliest day in the window.
  const periodStartMs = new Date(`${axis[0]}T00:00:00`).getTime();

  const { claude: claudePricing, codex: codexPricing } = loadPricing();
  const [claudeDaily, codexDaily] = await Promise.all([
    aggregateClaude(claudeDir, dateSet, periodStartMs),
    aggregateCodex(codexDir, dateSet, periodStartMs),
  ]);

  const daysOut: DayEntry[] = axis.map((date) => {
    const agents: DayEntry['agents'] = {};

    const c = claudeDaily.get(date);
    if (c) {
      agents['claude-code'] = {
        uncachedInput: c.uncachedInput,
        cacheRead: c.cacheRead,
        cacheWrite: c.cacheWrite,
        output: c.output,
        costUSD: round4(claudeCost(c, claudePricing)),
      };
    }

    const x = codexDaily.get(date);
    if (x) {
      agents.codex = {
        uncachedInput: x.uncachedInput,
        cachedInput: x.cachedInput,
        output: x.output,
        reasoningOutput: x.reasoningOutput,
        costUSD: codexPricing ? round4(codexCost(x, codexPricing)) : null,
      };
    }

    return { date, agents };
  });

  return { generatedAt: new Date().toISOString(), days: daysOut };
}

// ── CLI ───────────────────────────────────────────────────────────────────────

function parseDays(argv: string[]): number {
  const i = argv.indexOf('--days');
  if (i >= 0 && argv[i + 1]) {
    const n = Number(argv[i + 1]);
    if (Number.isFinite(n) && n >= 1 && n <= 366) return Math.floor(n);
  }
  return 7;
}

const thisFile = fileURLToPath(import.meta.url);
const calledFile = path.resolve(process.argv[1] ?? '');
if (thisFile === calledFile) {
  computeDailyUsage(parseDays(process.argv))
    .then((result) => {
      process.stdout.write(JSON.stringify(result, null, 2) + '\n');
    })
    .catch((err) => {
      process.stderr.write(`daily-usage failed: ${err instanceof Error ? err.message : String(err)}\n`);
      process.exit(1);
    });
}
