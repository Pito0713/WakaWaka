/** Per-day token scans for daily-usage.ts: Claude Code transcripts and Codex sessions. */
import {
  dedupKey,
  eachJSONLine,
  recentFiles,
  timestampMs,
  toInt,
  TranscriptDedup,
} from './transcript-scan.js';
import {
  addClaudeTokens,
  claudeTokensFromUsage,
  emptyClaudeTokens,
  NON_BILLED_MODELS,
  type ClaudeTokens,
} from './pricing.js';

const FILE_MTIME_BUFFER_MS = 6 * 60 * 60 * 1000; // clock-skew / cross-tz slack

// ── Date helpers (LOCAL timezone) ─────────────────────────────────────────────

/** YYYY-MM-DD in the machine's local timezone. */
export function localDateKey(tsMs: number): string {
  return new Date(tsMs).toLocaleDateString('en-CA'); // en-CA renders ISO YYYY-MM-DD
}

/** Continuous axis of the last `days` local dates, oldest → newest. */
export function buildDateAxis(days: number, now: Date): string[] {
  const axis: string[] = [];
  for (let i = days - 1; i >= 0; i--) {
    const d = new Date(now);
    d.setDate(d.getDate() - i);
    axis.push(d.toLocaleDateString('en-CA'));
  }
  return axis;
}

// ── Claude Code aggregation ───────────────────────────────────────────────────

/** Model id used when a transcript row carries usage but names no model. */
export const UNKNOWN_MODEL = '(unknown)';

/** Per-day, per-model token buckets. Outer key: local date; inner key: model id. */
export type ClaudeDaily = Map<string, Map<string, ClaudeTokens>>;

export interface ClaudeScan {
  daily: ClaudeDaily;
  /** Deduplicated billable calls per model, for pricing-coverage reporting. */
  callsByModel: Map<string, number>;
}

/** One deduplicated API response, tagged with the day and model it bills to. */
export interface ClaudeEntry {
  date: string;
  model: string;
  tokens: ClaudeTokens;
}

/**
 * Normalises one JSONL row into a dedup entry, or null when the row is not a
 * billable API response (no usage, unparseable timestamp, outside the window,
 * or a `<synthetic>` local placeholder).
 */
export function readClaudeRow(obj: Record<string, unknown>, dates: Set<string>): ClaudeEntry | null {
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

export async function aggregateClaude(
  dir: string,
  dates: Set<string>,
  periodStartMs: number
): Promise<ClaudeScan> {
  const files = recentFiles(dir, periodStartMs - FILE_MTIME_BUFFER_MS);

  // Global dedup across all files: the same API response is written to the
  // JSONL repeatedly as it streams, and the last state is the complete one.
  const dedup = new TranscriptDedup<ClaudeEntry>();

  for (const file of files) {
    await eachJSONLine(file, (obj, lineNo) => {
      const entry = readClaudeRow(obj, dates);
      if (entry) dedup.offer(dedupKey(obj, dedup.nextSeq), entry, timestampMs(obj), file, lineNo);
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

export interface CodexAcc {
  uncachedInput: number;
  cachedInput: number;
  output: number;
  reasoningOutput: number;
}

export function emptyCodexAcc(): CodexAcc {
  return { uncachedInput: 0, cachedInput: 0, output: 0, reasoningOutput: 0 };
}

export async function aggregateCodex(
  dir: string,
  dates: Set<string>,
  periodStartMs: number
): Promise<Map<string, CodexAcc>> {
  const files = recentFiles(dir, periodStartMs - FILE_MTIME_BUFFER_MS);
  const daily = new Map<string, CodexAcc>();

  for (const file of files) {
    await eachJSONLine(file, (obj) => {
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
