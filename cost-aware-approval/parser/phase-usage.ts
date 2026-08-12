/**
 * phase-usage.ts — how token spend distributes across activity phases.
 *
 * Answers "where did this session's tokens go" by bucketing each API call into
 * understand / develop / verify / reply / other. Implements
 * phase-usage-plan.md; the parts that are easy to get subtly wrong:
 *
 *   1. Attribution unit is `(requestId, message.id)`. Usage is taken from the
 *      LAST record with that key (streaming writes grow), but tool content is
 *      the UNION of every record with it — early writes have not emitted their
 *      tool_use blocks yet, so first-record content sends ~80% of volume into
 *      `reply`.
 *   2. The five buckets must be conservative: their calls, output and token
 *      fields sum exactly to the segment total. Anything excluded (a
 *      `<synthetic>` placeholder, a record with no usage) is counted in
 *      `diagnostics.excluded` and enters no bucket.
 *   3. Only `session` granularity is produced. Prompt granularity needs
 *      compact/resume/sidechain linkage that is not solved (plan §10-1), and
 *      would otherwise emit precise-looking segments that are not comparable.
 *
 * The three metrics (`calls`, `output`, `costUSD`) are deliberately reported
 * side by side. `output` measures generation volume, not effort or time — see
 * plan §3 before building any ranking on top of it.
 *
 * Usage:  npx tsx phase-usage.ts [--days N] [--granularity session]
 */

import * as os from 'os';
import * as path from 'path';
import { fileURLToPath } from 'url';
import { scanCalls, dedupeInvocations, type Call } from './phase-scan.js';
import {
  claudeCost, claudeModelPricing, loadPricing, round4,
  type ClaudeTokens, type PricingTable,
} from './pricing.js';
import {
  classifyCall, loadToolPhases, type Phase, type ToolPhaseTable,
} from './phase-classify.js';

const ALL_PHASES: Phase[] = ['understand', 'develop', 'verify', 'reply', 'other'];

// ── Output shape ──────────────────────────────────────────────────────────────

export interface PhaseTotals {
  calls: number;
  output: number;
  uncachedInput: number;
  cacheRead: number;
  cacheWrite: number;
  /** Null when any call in the bucket used a model with no published price. */
  costUSD: number | null;
}

/** Sidechain (subagent) work is an orthogonal split, not a sixth bucket. */
export interface PhaseBucket extends PhaseTotals {
  direct: { calls: number; output: number };
  sidechain: { calls: number; output: number };
}

export interface Segment {
  id: string;
  label: string;
  startedAt: string;
  total: PhaseTotals;
  phases: Record<Phase, PhaseBucket>;
}

export interface PhaseUsageResult {
  generatedAt: string;
  granularity: 'session';
  pricingAsOf: string;
  toolPhasesVersion: number;
  segments: Segment[];
  diagnostics: {
    unclassifiedTools: { name: string; calls: number; output: number }[];
    unknownBash: { head: string; calls: number; output: number }[];
    mixedCalls: { combo: string; calls: number }[];
    excluded: { synthetic: number; noUsage: number };
    /** Share of output that landed in `other` — the plan's stop-and-rethink gauge. */
    unknownRate: number;
    pricedCalls: number;
    totalCalls: number;
  };
  warnings: string[];
}

// ── Accumulators ──────────────────────────────────────────────────────────────

/**
 * A fresh bucket starts at `costUSD: 0`, not null.
 *
 * This differs from `bucketCost()` in usage-calculator.ts, which returns null
 * for an empty bucket. The convention differs because the question does: there,
 * an empty bucket means "no usage was measured at all"; here, the five buckets
 * partition a known set of calls, so a bucket with zero calls genuinely cost
 * zero and must still add up with its siblings. Null is reserved for the one
 * case it means something else — a bucket holding calls that cannot be priced.
 */
function emptyTotals(): PhaseTotals {
  return { calls: 0, output: 0, uncachedInput: 0, cacheRead: 0, cacheWrite: 0, costUSD: 0 };
}

function emptyBucket(): PhaseBucket {
  return { ...emptyTotals(), direct: { calls: 0, output: 0 }, sidechain: { calls: 0, output: 0 } };
}

function addTokens(target: PhaseTotals, tokens: ClaudeTokens, output: number): void {
  target.calls += 1;
  target.output += output;
  target.uncachedInput += tokens.uncachedInput;
  target.cacheRead += tokens.cacheRead;
  target.cacheWrite += tokens.cacheWrite5m + tokens.cacheWrite1h;
}

// ── Aggregation ───────────────────────────────────────────────────────────────

interface Tally {
  unclassifiedTools: Map<string, { calls: number; output: number }>;
  unknownBash: Map<string, { calls: number; output: number }>;
  mixedCalls: Map<string, number>;
  pricedCalls: number;
  totalCalls: number;
}

function bump(map: Map<string, { calls: number; output: number }>, key: string, output: number): void {
  const entry = map.get(key) ?? { calls: 0, output: 0 };
  entry.calls += 1;
  entry.output += output;
  map.set(key, entry);
}

/** Folds one call into its segment, keeping the buckets conservative. */
function applyCall(segment: Segment, call: Call, table: ToolPhaseTable, pricing: PricingTable, tally: Tally): void {
  const invocations = dedupeInvocations(call.invocations);
  const result = classifyCall(invocations, table);
  const bucket = segment.phases[result.phase];
  const output = call.tokens.output;

  addTokens(segment.total, call.tokens, output);
  addTokens(bucket, call.tokens, output);
  const side = call.isSidechain ? bucket.sidechain : bucket.direct;
  side.calls += 1;
  side.output += output;

  const price = claudeModelPricing(pricing, call.model);
  if (price) {
    const cost = claudeCost(call.tokens, price);
    if (bucket.costUSD !== null) bucket.costUSD += cost;
    if (segment.total.costUSD !== null) segment.total.costUSD += cost;
    tally.pricedCalls += 1;
  } else {
    // One unpriced call makes the whole bucket's total an under-report.
    bucket.costUSD = null;
    segment.total.costUSD = null;
  }
  tally.totalCalls += 1;

  for (const name of result.unclassifiedTools) bump(tally.unclassifiedTools, name, output);
  for (const head of result.unknownBashHeads) bump(tally.unknownBash, head, output);
  if (result.combo.length > 1) {
    const combo = result.combo.join('+');
    tally.mixedCalls.set(combo, (tally.mixedCalls.get(combo) ?? 0) + 1);
  }
}

function newSegment(call: Call): Segment {
  const phases = Object.fromEntries(ALL_PHASES.map((p) => [p, emptyBucket()])) as Record<Phase, PhaseBucket>;
  return { id: call.sessionId, label: call.label, startedAt: call.timestampISO, total: emptyTotals(), phases };
}

function roundCosts(segment: Segment): void {
  if (segment.total.costUSD !== null) segment.total.costUSD = round4(segment.total.costUSD);
  for (const phase of ALL_PHASES) {
    const bucket = segment.phases[phase];
    if (bucket.costUSD !== null) bucket.costUSD = round4(bucket.costUSD);
  }
}

export interface PhaseUsageOptions {
  /** Override the Claude projects dir (default ~/.claude/projects). For tests. */
  claudeDir?: string;
  /** Override "now" so the window is deterministic. For tests. */
  now?: Date;
  /** Override the tool→phase table path. For tests. */
  toolPhasesPath?: string;
}

export async function computePhaseUsage(days: number, opts: PhaseUsageOptions = {}): Promise<PhaseUsageResult> {
  const now = opts.now ?? new Date();
  const claudeDir = opts.claudeDir ?? path.join(os.homedir(), '.claude', 'projects');
  const sinceMs = now.getTime() - days * 24 * 60 * 60 * 1000;

  const pricing = loadPricing();
  const table = loadToolPhases(opts.toolPhasesPath);
  const { calls, excluded } = await scanCalls(claudeDir, sinceMs);

  const tally: Tally = {
    unclassifiedTools: new Map(), unknownBash: new Map(), mixedCalls: new Map(),
    pricedCalls: 0, totalCalls: 0,
  };
  const segments = new Map<string, Segment>();

  // Oldest first so `startedAt` is the segment's first call.
  for (const call of Array.from(calls.values()).sort((a, b) => a.tsMs - b.tsMs)) {
    let segment = segments.get(call.sessionId);
    if (!segment) {
      segment = newSegment(call);
      segments.set(call.sessionId, segment);
    }
    applyCall(segment, call, table, pricing, tally);
  }

  const ordered = Array.from(segments.values()).sort((a, b) => b.total.output - a.total.output);
  ordered.forEach(roundCosts);

  const totalOutput = ordered.reduce((sum, s) => sum + s.total.output, 0);
  const otherOutput = ordered.reduce((sum, s) => sum + s.phases.other.output, 0);

  return {
    generatedAt: new Date().toISOString(),
    granularity: 'session',
    pricingAsOf: pricing.asOf,
    toolPhasesVersion: table.version,
    segments: ordered,
    diagnostics: {
      unclassifiedTools: Array.from(tally.unclassifiedTools, ([name, v]) => ({ name, ...v }))
        .sort((a, b) => b.output - a.output),
      unknownBash: Array.from(tally.unknownBash, ([head, v]) => ({ head, ...v }))
        .sort((a, b) => b.output - a.output),
      mixedCalls: Array.from(tally.mixedCalls, ([combo, calls]) => ({ combo, calls }))
        .sort((a, b) => b.calls - a.calls),
      excluded,
      unknownRate: totalOutput > 0 ? otherOutput / totalOutput : 0,
      pricedCalls: tally.pricedCalls,
      totalCalls: tally.totalCalls,
    },
    warnings: buildWarnings(totalOutput > 0 ? otherOutput / totalOutput : 0),
  };
}

function buildWarnings(unknownRate: number): string[] {
  const warnings = [
    'output token 衡量的是生成量，不是工作量、時間或認知負荷；三個指標請並列閱讀，勿做績效解讀。',
    'cache read 使 session 後段的階段系統性偏貴，與該階段本身的成本無關。',
  ];
  if (unknownRate > 0.25) {
    warnings.push(
      `unknownRate ${(unknownRate * 100).toFixed(1)}% 高於 25%：分類法覆蓋不足，` +
      '請先看 diagnostics.unclassifiedTools 與 unknownBash，不要直接解讀階段佔比。'
    );
  }
  return warnings;
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

/** Only `session` is accepted; prompt granularity is deferred (plan §10-1). */
function parseGranularity(argv: string[]): 'session' {
  const i = argv.indexOf('--granularity');
  const value = i >= 0 ? argv[i + 1] : 'session';
  if (value !== undefined && value !== 'session') {
    process.stderr.write(`--granularity: only "session" is supported (got "${value}")\n`);
    process.exit(1);
  }
  return 'session';
}

const thisFile = fileURLToPath(import.meta.url);
if (thisFile === path.resolve(process.argv[1] ?? '')) {
  parseGranularity(process.argv);
  computePhaseUsage(parseDays(process.argv))
    .then((result) => process.stdout.write(JSON.stringify(result, null, 2) + '\n'))
    .catch((err) => {
      process.stderr.write(`phase-usage failed: ${err instanceof Error ? err.message : String(err)}\n`);
      process.exit(1);
    });
}
