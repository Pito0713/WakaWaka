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
import {
  addClaudeTokens,
  claudeCost,
  claudeModelPricing,
  claudeTokensFromUsage,
  emptyClaudeTokens,
  loadPricing,
  round4,
  NON_BILLED_MODELS,
  type ClaudeTokens,
  type CodexPricing,
  type PricingTable,
} from './pricing.js';

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

/**
 * How much of the window could actually be priced. Without this a partially
 * priced day is indistinguishable from a cheap one — the dashboard would
 * under-report and look authoritative doing it.
 */
interface PricingCoverage {
  /** Date the price table was last verified against the official source. */
  asOf: string;
  /** Deduplicated Claude API calls that matched a model in the price table. */
  pricedCalls: number;
  /** Deduplicated Claude API calls in the window, excluding non-billed rows. */
  totalCalls: number;
  /** Model ids seen in the window with no entry in the price table. */
  unpricedModels: string[];
}

interface DailyUsageResult {
  generatedAt: string;
  days: DayEntry[];
  pricing: PricingCoverage;
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

/** Model id used when a transcript row carries usage but names no model. */
const UNKNOWN_MODEL = '(unknown)';

/** Per-day, per-model token buckets. Outer key: local date; inner key: model id. */
type ClaudeDaily = Map<string, Map<string, ClaudeTokens>>;

interface ClaudeScan {
  daily: ClaudeDaily;
  /** Deduplicated billable calls per model, for pricing-coverage reporting. */
  callsByModel: Map<string, number>;
}

/** One deduplicated API response, tagged with the day and model it bills to. */
interface ClaudeEntry {
  date: string;
  model: string;
  tokens: ClaudeTokens;
}

/**
 * Normalises one JSONL row into a dedup entry, or null when the row is not a
 * billable API response (no usage, unparseable timestamp, outside the window,
 * or a `<synthetic>` local placeholder).
 */
function readClaudeRow(obj: Record<string, unknown>, dates: Set<string>): ClaudeEntry | null {
  const message = obj.message as Record<string, unknown> | undefined;
  const usage = message?.usage as Record<string, unknown> | undefined;
  if (!usage || typeof usage['input_tokens'] !== 'number') return null;

  const tsRaw = typeof obj.timestamp === 'string' ? obj.timestamp : '';
  const tsMs = tsRaw ? new Date(tsRaw).getTime() : NaN;
  if (Number.isNaN(tsMs)) return null;
  const date = localDateKey(tsMs);
  if (!dates.has(date)) return null;

  const model = typeof message?.model === 'string' ? message.model : UNKNOWN_MODEL;
  if (NON_BILLED_MODELS.has(model)) return null;

  return { date, model, tokens: claudeTokensFromUsage(usage) };
}

function dedupKey(obj: Record<string, unknown>, nokeySeq: () => number): string {
  const requestId = typeof obj.requestId === 'string' ? obj.requestId : '';
  const msgId = (obj.message as Record<string, unknown> | undefined)?.id;
  const msgIdStr = typeof msgId === 'string' ? msgId : '';
  return requestId && msgIdStr ? `${requestId}|${msgIdStr}` : `__nokey_${nokeySeq()}`;
}

async function aggregateClaude(
  dir: string,
  dates: Set<string>,
  periodStartMs: number
): Promise<ClaudeScan> {
  const files = recentFiles(dir, periodStartMs);

  // Global dedup across all files: the same API response is written to the
  // JSONL repeatedly as it streams, and last-write-wins is the complete state.
  const dedup = new Map<string, ClaudeEntry>();
  let seq = 0;
  const nextSeq = () => seq++;

  for (const file of files) {
    await eachLine(file, (obj) => {
      const entry = readClaudeRow(obj, dates);
      if (entry) dedup.set(dedupKey(obj, nextSeq), entry);
    });
  }

  const daily: ClaudeDaily = new Map();
  const callsByModel = new Map<string, number>();
  for (const { date, model, tokens } of dedup.values()) {
    const byModel = daily.get(date) ?? new Map<string, ClaudeTokens>();
    const acc = byModel.get(model) ?? emptyClaudeTokens();
    addClaudeTokens(acc, tokens);
    byModel.set(model, acc);
    daily.set(date, byModel);
    callsByModel.set(model, (callsByModel.get(model) ?? 0) + 1);
  }
  return { daily, callsByModel };
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

function codexCost(a: CodexAcc, p: CodexPricing): number {
  return (
    (a.uncachedInput / MTok) * p.inputPerMTok +
    (a.cachedInput / MTok) * p.cachedInputPerMTok +
    (a.output / MTok) * p.outputPerMTok
  );
}

/**
 * Folds one day's per-model buckets into the display totals plus a cost.
 *
 * `costUSD` is null unless *every* model that day could be priced. Reporting
 * the priced share of a partly priced day would be a confident-looking
 * under-report — the same failure the no-fallback rule exists to prevent, and
 * the UI has no way to know the figure was incomplete. Tokens are still
 * reported either way.
 *
 * `date` selects the rate in force that day, so a promotional price that
 * lapsed mid-window does not get applied to the whole window.
 */
function foldClaudeDay(byModel: Map<string, ClaudeTokens>, table: PricingTable, date: string): ClaudeDay {
  const totals = emptyClaudeTokens();
  let cost = 0;
  let allPriced = true;

  for (const [model, tokens] of byModel) {
    addClaudeTokens(totals, tokens);
    const price = claudeModelPricing(table, model, date);
    if (!price) { allPriced = false; continue; }
    cost += claudeCost(tokens, price);
  }

  return {
    uncachedInput: totals.uncachedInput,
    cacheRead: totals.cacheRead,
    cacheWrite: totals.cacheWrite5m + totals.cacheWrite1h,
    output: totals.output,
    costUSD: allPriced ? round4(cost) : null,
  };
}

function summarisePricing(callsByModel: Map<string, number>, table: PricingTable): PricingCoverage {
  let pricedCalls = 0;
  let totalCalls = 0;
  const unpricedModels: string[] = [];

  for (const [model, calls] of callsByModel) {
    totalCalls += calls;
    if (claudeModelPricing(table, model)) pricedCalls += calls;
    else unpricedModels.push(model);
  }

  return { asOf: table.asOf, pricedCalls, totalCalls, unpricedModels: unpricedModels.sort() };
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

  const pricing = loadPricing();
  const codexPricing = pricing.codex;
  const [claudeScan, codexDaily] = await Promise.all([
    aggregateClaude(claudeDir, dateSet, periodStartMs),
    aggregateCodex(codexDir, dateSet, periodStartMs),
  ]);

  const daysOut: DayEntry[] = axis.map((date) => {
    const agents: DayEntry['agents'] = {};

    const byModel = claudeScan.daily.get(date);
    if (byModel) {
      agents['claude-code'] = foldClaudeDay(byModel, pricing, date);
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

  return {
    generatedAt: new Date().toISOString(),
    days: daysOut,
    pricing: summarisePricing(claudeScan.callsByModel, pricing),
  };
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
