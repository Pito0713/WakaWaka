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

import * as os from 'os';
import * as path from 'path';
import { fileURLToPath } from 'url';
import { aggregateClaude, aggregateCodex, buildDateAxis, type CodexAcc } from './daily-scan.js';
import {
  addClaudeTokens,
  claudeCost,
  claudeModelPricing,
  emptyClaudeTokens,
  loadPricing,
  round4,
  type ClaudeTokens,
  type CodexPricing,
  type PricingTable,
} from './pricing.js';

const MTok = 1_000_000;

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
