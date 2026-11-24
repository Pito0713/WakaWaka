/**
 * Shared pieces of the Claude usage parsers: one transcript row's usage,
 * per-model token buckets, and their pricing.
 */
import {
  addClaudeTokens,
  claudeCost,
  claudeModelPricing,
  claudeTokensFromUsage,
  emptyClaudeTokens,
  NON_BILLED_MODELS,
  type ClaudeTokens,
  type PricingTable,
} from './pricing.js';

/** Model id used when a transcript row carries usage but names no model. */
export const UNKNOWN_MODEL = '(unknown)';

/**
 * Token buckets split by model, carried alongside the display totals so each
 * bucket can be priced at its own model's rate. Keys are model ids.
 */
export interface ModelBuckets {
  cumulative: Map<string, ClaudeTokens>;
  session: Map<string, ClaudeTokens>;
  turn: Map<string, ClaudeTokens>;
}

export interface UsageSnapshot {
  cumulativeInput: number;
  cumulativeOutput: number;
  cumulativeCacheRead: number;
  cumulativeCacheCreation: number;
  lastTurnDelta: { input: number; output: number } | null;
  /** ISO-8601 timestamp of the first assistant message in this transcript */
  sessionStartISO: string | null;
  /** Fixed 5-hour session window in milliseconds */
  sessionWindowMs: number;
  /** Rolling 5-hour window token counts */
  sessionInput: number;
  sessionOutput: number;
  sessionCacheRead: number;
  sessionCacheCreation: number;
  /** Accumulated tokens since the last genuine human message (current task) */
  turnInput: number;
  turnOutput: number;
  turnCacheRead: number;
  turnCacheCreation: number;
}

export interface CumulativePoint {
  input: number;
  output: number;
  cacheRead: number;
  cacheCreation: number;
}

/** Display totals (TTLs collapsed) paired with the model that billed them. */
export interface UsageRow {
  point: CumulativePoint;
  model: string;
  tokens: ClaudeTokens;
}

export function extractUsage(obj: Record<string, unknown>): UsageRow | null {
  const message = obj?.message as Record<string, unknown> | undefined;
  const usage = message?.usage;
  if (!usage || typeof usage !== 'object') return null;
  const u = usage as Record<string, unknown>;
  // Require at least input_tokens to be a positive-or-zero number
  if (typeof u['input_tokens'] !== 'number') return null;

  const model = typeof message?.model === 'string' ? message.model : UNKNOWN_MODEL;
  // `<synthetic>` rows are local placeholders that were never billed.
  if (NON_BILLED_MODELS.has(model)) return null;

  const tokens = claudeTokensFromUsage(u);
  return {
    model,
    tokens,
    point: {
      input: tokens.uncachedInput,
      output: tokens.output,
      cacheRead: tokens.cacheRead,
      cacheCreation: tokens.cacheWrite5m + tokens.cacheWrite1h,
    },
  };
}

/** Adds `tokens` into the per-model bucket map, creating the bucket if new. */
export function accumulateModel(buckets: Map<string, ClaudeTokens>, model: string, tokens: ClaudeTokens): void {
  const acc = buckets.get(model) ?? emptyClaudeTokens();
  addClaudeTokens(acc, tokens);
  buckets.set(model, acc);
}

/**
 * Cost of one per-model bucket map, or null unless *every* model in it could
 * be priced. An empty map is also null: nothing measured is not the same as
 * free. Returning the priced share of a partly priced map would show a
 * confident number that silently under-reports.
 */
export function bucketCost(buckets: Map<string, ClaudeTokens>, table: PricingTable): number | null {
  let cost = 0;
  let counted = 0;
  for (const [model, tokens] of buckets) {
    const price = claudeModelPricing(table, model);
    if (!price) return null;
    cost += claudeCost(tokens, price);
    counted++;
  }
  return counted > 0 ? cost : null;
}

export const SESSION_WINDOW_MS = 5 * 60 * 60 * 1000; // 5-hour rolling window

/** Model ids appearing in any bucket with no entry in the price table. */
export function unpricedIn(buckets: Map<string, ClaudeTokens>[], table: PricingTable): string[] {
  const missing = new Set<string>();
  for (const bucket of buckets) {
    for (const model of bucket.keys()) {
      if (!claudeModelPricing(table, model)) missing.add(model);
    }
  }
  return Array.from(missing).sort();
}
