import * as fs from 'fs';
import * as path from 'path';
import * as readline from 'readline';
import { fileURLToPath } from 'url';

export interface UsageSnapshot {
  cumulativeInput: number;
  cumulativeOutput: number;
  cumulativeCacheRead: number;
  cumulativeCacheCreation: number;
  lastTurnDelta: { input: number; output: number } | null;
}

export interface PricingTable {
  model: string;
  inputPerMTok: number;
  outputPerMTok: number;
  cacheReadPerMTok: number;
  cacheCreationPerMTok: number;
}

interface CumulativePoint {
  input: number;
  output: number;
  cacheRead: number;
  cacheCreation: number;
}

function toInt(v: unknown): number {
  const n = Number(v);
  return Number.isFinite(n) ? Math.floor(n) : 0;
}

function extractUsage(obj: Record<string, unknown>): CumulativePoint | null {
  const usage = (obj?.message as Record<string, unknown>)?.usage;
  if (!usage || typeof usage !== 'object') return null;
  const u = usage as Record<string, unknown>;
  // Require at least input_tokens to be a positive-or-zero number
  if (typeof u['input_tokens'] !== 'number') return null;
  return {
    input: toInt(u['input_tokens']),
    output: toInt(u['output_tokens']),
    cacheRead: toInt(u['cache_read_input_tokens']),
    cacheCreation: toInt(u['cache_creation_input_tokens']),
  };
}

export async function calculateUsage(transcriptPath: string): Promise<UsageSnapshot> {
  const fileStream = fs.createReadStream(transcriptPath);
  const rl = readline.createInterface({ input: fileStream, crlfDelay: Infinity });

  let running: CumulativePoint = { input: 0, output: 0, cacheRead: 0, cacheCreation: 0 };
  // Only keep the previous snapshot to compute lastTurnDelta — O(1) memory
  let prev: CumulativePoint | null = null;
  let seen = 0;

  for await (const line of rl) {
    const trimmed = line.trim();
    if (!trimmed) continue;

    let obj: Record<string, unknown>;
    try {
      obj = JSON.parse(trimmed);
    } catch {
      continue;
    }

    const delta = extractUsage(obj);
    if (!delta) continue;

    prev = { ...running };
    running = {
      input: running.input + delta.input,
      output: running.output + delta.output,
      cacheRead: running.cacheRead + delta.cacheRead,
      cacheCreation: running.cacheCreation + delta.cacheCreation,
    };
    seen++;
  }

  let lastTurnDelta: { input: number; output: number } | null = null;
  if (seen >= 2 && prev) {
    lastTurnDelta = {
      input: running.input - prev.input,
      output: running.output - prev.output,
    };
  } else if (seen === 1) {
    lastTurnDelta = { input: running.input, output: running.output };
  }

  return {
    cumulativeInput: running.input,
    cumulativeOutput: running.output,
    cumulativeCacheRead: running.cacheRead,
    cumulativeCacheCreation: running.cacheCreation,
    lastTurnDelta,
  };
}

export function estimateCost(usage: UsageSnapshot, pricing: PricingTable): number {
  const MTok = 1_000_000;
  return (
    (usage.cumulativeInput / MTok) * pricing.inputPerMTok +
    (usage.cumulativeOutput / MTok) * pricing.outputPerMTok +
    (usage.cumulativeCacheRead / MTok) * pricing.cacheReadPerMTok +
    (usage.cumulativeCacheCreation / MTok) * pricing.cacheCreationPerMTok
  );
}

// ── CLI entry point ───────────────────────────────────────────────────────────
async function main() {
  const transcriptPath = process.argv[2];
  if (!transcriptPath) {
    process.stderr.write('Usage: npx tsx parser/usage-calculator.ts <transcriptPath>\n');
    process.exit(1);
  }

  const pricingPath = path.join(path.dirname(fileURLToPath(import.meta.url)), 'pricing.json');
  const pricing: PricingTable = JSON.parse(fs.readFileSync(pricingPath, 'utf8'));

  const required: (keyof PricingTable)[] = ['inputPerMTok', 'outputPerMTok', 'cacheReadPerMTok', 'cacheCreationPerMTok'];
  for (const key of required) {
    if (typeof pricing[key] !== 'number' || !Number.isFinite(pricing[key])) {
      process.stderr.write(`pricing.json: invalid or missing field "${key}"\n`);
      process.exit(1);
    }
  }

  const usage = await calculateUsage(transcriptPath);
  const cost = estimateCost(usage, pricing);

  process.stdout.write(
    JSON.stringify({ ...usage, estimatedCostUSD: cost }, null, 2) + '\n',
  );
}

// Only run main when invoked directly (not when imported by tests)
const thisFile = fileURLToPath(import.meta.url);
const calledFile = path.resolve(process.argv[1] ?? '');
if (calledFile === thisFile || calledFile === thisFile.replace(/\.js$/, '.ts')) {
  main().catch((err) => {
    process.stderr.write(String(err) + '\n');
    process.exit(1);
  });
}
