/**
 * pricing.ts — per-model price table loading and cost arithmetic.
 *
 * Shared by daily-usage.ts and usage-calculator.ts so both price identically.
 * Before this module, both applied one hardcoded Sonnet 4.6 rate to every
 * model, which made every cost figure in the app wrong for the ~96% of recent
 * calls that are not Sonnet 4.6 (phase-usage-plan.md §7).
 *
 * Two rules the rest of the parser depends on:
 *   1. An unknown model prices to `null` — never a default rate. A confidently
 *      wrong number is worse than a missing one.
 *   2. Cache writes are billed by TTL: 5-minute writes at 1.25x the input rate,
 *      1-hour writes at 2x. On this machine 84% of cache-creation tokens are
 *      1h, so collapsing the two understates cache-write cost by ~60%.
 */

import * as fs from 'fs';
import * as path from 'path';
import { fileURLToPath } from 'url';

const MTok = 1_000_000;

/**
 * Models that must never be priced or counted as "unpriced".
 * `<synthetic>` rows are Claude Code's own local placeholders — they carry a
 * usage block but were never billed as an API call.
 */
export const NON_BILLED_MODELS = new Set(['<synthetic>']);

export interface ModelPricing {
  inputPerMTok: number;
  outputPerMTok: number;
  cacheReadPerMTok: number;
  cacheWrite5mPerMTok: number;
  cacheWrite1hPerMTok: number;
  /**
   * Rates that replace these from `date` (inclusive, `YYYY-MM-DD`) onward.
   * Introductory pricing needs this: charging a promotional rate after it
   * lapses — or the standard rate while it is still in force — is wrong in
   * both directions, and a daily report prices past days as well as today.
   */
  after?: { date: string; pricing: ModelPricing };
}

export interface CodexPricing {
  inputPerMTok: number;
  cachedInputPerMTok: number;
  outputPerMTok: number;
  cacheCreationPerMTok: number;
}

/** Claude token counts for one bucket, already split by how each is billed. */
export interface ClaudeTokens {
  /** `input_tokens` — excludes cache reads (Claude semantics). */
  uncachedInput: number;
  cacheRead: number;
  cacheWrite5m: number;
  cacheWrite1h: number;
  output: number;
}

export interface PricingTable {
  /** Date the prices were last verified against the official source. */
  asOf: string;
  claudeModels: Map<string, ModelPricing>;
  codex: CodexPricing | null;
}

const CLAUDE_PRICE_FIELDS: (keyof ModelPricing)[] = [
  'inputPerMTok',
  'outputPerMTok',
  'cacheReadPerMTok',
  'cacheWrite5mPerMTok',
  'cacheWrite1hPerMTok',
];

const CODEX_PRICE_FIELDS: (keyof CodexPricing)[] = [
  'inputPerMTok',
  'cachedInputPerMTok',
  'outputPerMTok',
  'cacheCreationPerMTok',
];

function defaultPricingPath(): string {
  return path.join(path.dirname(fileURLToPath(import.meta.url)), 'pricing.json');
}

/**
 * Returns the entry only when every price is a finite number. A partially
 * filled entry is treated as absent so a missing field can never be read as 0.
 */
function extractPrices<T>(node: unknown, fields: (keyof T)[]): T | null {
  if (!node || typeof node !== 'object') return null;
  const raw = node as Record<string, unknown>;
  const out = {} as T;
  for (const field of fields) {
    const value = raw[field as string];
    if (typeof value !== 'number' || !Number.isFinite(value)) return null;
    out[field] = value as T[keyof T];
  }
  return out;
}

const ISO_DATE = /^\d{4}-\d{2}-\d{2}$/;

/** Parses one model entry plus any chained future rate change. */
function extractModelPricing(entry: unknown): ModelPricing | null {
  const priced = extractPrices<ModelPricing>(entry, CLAUDE_PRICE_FIELDS);
  if (!priced) return null;

  const after = (entry as Record<string, unknown>).after;
  if (after && typeof after === 'object') {
    const node = after as Record<string, unknown>;
    const next = extractModelPricing(node);
    // A malformed successor is dropped rather than guessed at, leaving the
    // current rates in force — the same no-fallback rule as unknown models.
    if (next && typeof node.date === 'string' && ISO_DATE.test(node.date)) {
      priced.after = { date: node.date, pricing: next };
    }
  }
  return priced;
}

/** Parses the `claude.models` map, skipping `_`-prefixed annotation keys. */
function extractClaudeModels(node: unknown): Map<string, ModelPricing> {
  const models = new Map<string, ModelPricing>();
  if (!node || typeof node !== 'object') return models;
  for (const [name, entry] of Object.entries(node as Record<string, unknown>)) {
    if (name.startsWith('_')) continue;
    const priced = extractModelPricing(entry);
    if (priced) models.set(name, priced);
  }
  return models;
}

export function loadPricing(pricingPath = defaultPricingPath()): PricingTable {
  const raw = JSON.parse(fs.readFileSync(pricingPath, 'utf8')) as Record<string, unknown>;
  const claude = raw.claude as Record<string, unknown> | undefined;
  return {
    asOf: typeof raw.pricingAsOf === 'string' ? raw.pricingAsOf : 'unknown',
    claudeModels: extractClaudeModels(claude?.models),
    codex: extractPrices<CodexPricing>(raw.codex, CODEX_PRICE_FIELDS),
  };
}

/** Local `YYYY-MM-DD`, matching how daily-usage buckets its days. */
export function todayKey(now = new Date()): string {
  return now.toLocaleDateString('en-CA');
}

/**
 * Price for one model id on a given date, or null when the id is unknown.
 *
 * Deliberately an exact match: prefix/fuzzy matching would silently price a
 * new model at an older one's rate, which is the failure this module exists
 * to prevent. Dated aliases (`claude-haiku-4-5-20251001`) are listed
 * explicitly in pricing.json instead.
 */
export function claudeModelPricing(
  table: PricingTable,
  model: string,
  onDate: string = todayKey()
): ModelPricing | null {
  let entry = table.claudeModels.get(model);
  if (!entry) return null;
  while (entry.after && onDate >= entry.after.date) entry = entry.after.pricing;
  return entry;
}

export function claudeCost(tokens: ClaudeTokens, p: ModelPricing): number {
  return (
    (tokens.uncachedInput / MTok) * p.inputPerMTok +
    (tokens.cacheRead / MTok) * p.cacheReadPerMTok +
    (tokens.cacheWrite5m / MTok) * p.cacheWrite5mPerMTok +
    (tokens.cacheWrite1h / MTok) * p.cacheWrite1hPerMTok +
    (tokens.output / MTok) * p.outputPerMTok
  );
}

export function emptyClaudeTokens(): ClaudeTokens {
  return { uncachedInput: 0, cacheRead: 0, cacheWrite5m: 0, cacheWrite1h: 0, output: 0 };
}

export function addClaudeTokens(acc: ClaudeTokens, delta: ClaudeTokens): void {
  acc.uncachedInput += delta.uncachedInput;
  acc.cacheRead += delta.cacheRead;
  acc.cacheWrite5m += delta.cacheWrite5m;
  acc.cacheWrite1h += delta.cacheWrite1h;
  acc.output += delta.output;
}

/** Token counts are never negative; corrupt or absent values read as 0. */
function toInt(v: unknown): number {
  const n = Number(v);
  return Number.isFinite(n) ? Math.max(0, Math.floor(n)) : 0;
}

/**
 * Splits `cache_creation_input_tokens` into its 5m and 1h halves.
 *
 * `cache_creation_input_tokens` is the authoritative billed total; the
 * `usage.cache_creation` breakdown only says how to apportion it. The two are
 * therefore reconciled rather than trusted independently, so the invariant
 * `cacheWrite5m + cacheWrite1h === total` always holds — otherwise a corrupt
 * or drifting transcript could bill more cache than was ever written.
 *
 * With no breakdown (older transcripts) everything falls back to the 5m rate,
 * the cheaper of the two, so an unknown TTL under-reports rather than inflates.
 */
export function splitCacheCreation(usage: Record<string, unknown>): {
  cacheWrite5m: number;
  cacheWrite1h: number;
} {
  const total = toInt(usage['cache_creation_input_tokens']);
  const breakdown = usage['cache_creation'];
  if (!breakdown || typeof breakdown !== 'object') {
    return { cacheWrite5m: total, cacheWrite1h: 0 };
  }
  const detail = breakdown as Record<string, unknown>;
  const write1h = Math.min(toInt(detail['ephemeral_1h_input_tokens']), total);
  // Whatever the breakdown does not attribute to 1h is charged as 5m. That
  // covers both an under-reporting breakdown and a future TTL tier we do not
  // know about yet, and it keeps the two halves summing to the billed total.
  return { cacheWrite5m: total - write1h, cacheWrite1h: write1h };
}

/** Reads a Claude `message.usage` block into billable token buckets. */
export function claudeTokensFromUsage(usage: Record<string, unknown>): ClaudeTokens {
  const { cacheWrite5m, cacheWrite1h } = splitCacheCreation(usage);
  return {
    uncachedInput: toInt(usage['input_tokens']),
    cacheRead: toInt(usage['cache_read_input_tokens']),
    cacheWrite5m,
    cacheWrite1h,
    output: toInt(usage['output_tokens']),
  };
}

export function round4(n: number): number {
  return Math.round(n * 10_000) / 10_000;
}
