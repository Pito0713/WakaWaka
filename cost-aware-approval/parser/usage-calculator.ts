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

const SESSION_WINDOW_MS = 5 * 60 * 60 * 1000; // 5-hour rolling window

/**
 * One JSONL entry normalised for usage processing.
 * The same API response (requestId + message.id) can be written to the JSONL
 * multiple times by Claude Desktop/Code (e.g. once per tool-use in the reply).
 * We keep only the LAST write per unique (requestId, message.id) pair so that
 * every API call is counted exactly once.
 */
interface NormalisedEntry {
  tsMs: number;
  timestampISO: string;
  delta: CumulativePoint;
  isHumanTurn: boolean; // genuine human message (not tool-result)
}

export async function calculateUsage(transcriptPath: string): Promise<UsageSnapshot> {
  const fileStream = fs.createReadStream(transcriptPath);
  const rl = readline.createInterface({ input: fileStream, crlfDelay: Infinity });

  // ── Pass 1: collect & deduplicate ──────────────────────────────────────────
  // Key: `${requestId}|${message.id}` — keeps the LAST occurrence (latest state
  // of a streaming response is the most complete).
  // Human-turn markers (no requestId/usage) are stored with a unique sentinel key
  // so they are never deduplicated away.
  const dedupMap = new Map<string, NormalisedEntry>();
  let humanSeq = 0;
  let nokeySeq  = 0; // independent counter for entries that lack requestId+msgId

  for await (const line of rl) {
    const trimmed = line.trim();
    if (!trimmed) continue;

    let obj: Record<string, unknown>;
    try {
      obj = JSON.parse(trimmed);
    } catch {
      continue;
    }

    const tsRaw = typeof obj.timestamp === 'string' ? obj.timestamp : '';
    const tsMs  = tsRaw ? new Date(tsRaw).getTime() : NaN;

    // Genuine human messages (turn markers — no usage data but needed for turn
    // tracking).  Tool-result messages also have type=user; skip them.
    if (obj.type === 'user') {
      const msg     = obj.message as Record<string, unknown> | undefined;
      const content = msg?.content;
      const isToolResult =
        Array.isArray(content) &&
        (content as unknown[]).some(
          (c) => typeof c === 'object' && c !== null && 'tool_use_id' in c
        );
      if (!isToolResult) {
        dedupMap.set(`__human_${humanSeq++}`, {
          tsMs:         Number.isNaN(tsMs) ? 0 : tsMs,
          timestampISO: tsRaw,
          delta:        { input: 0, output: 0, cacheRead: 0, cacheCreation: 0 },
          isHumanTurn:  true,
        });
      }
      continue; // human entries never carry usage
    }

    const delta = extractUsage(obj);
    if (!delta) continue;

    const requestId = typeof obj.requestId === 'string' ? obj.requestId : '';
    const msgId     = (obj.message as Record<string, unknown> | undefined)?.id;
    const msgIdStr  = typeof msgId === 'string' ? msgId : '';

    // Dedup key: if we have both IDs use them; otherwise assign a unique sentinel.
    // Using a dedicated counter (nokeySeq) mirrors p90-detector.ts and is clearer
    // than relying on dedupMap.size, which can stay flat when a duplicate key is
    // overwritten (making the pattern harder to reason about).
    const key = requestId && msgIdStr
      ? `${requestId}|${msgIdStr}`
      : `__nokey_${nokeySeq++}`;

    // Always overwrite → last-seen wins (final streaming value is most complete)
    dedupMap.set(key, {
      tsMs:         Number.isNaN(tsMs) ? 0 : tsMs,
      timestampISO: tsRaw,
      delta,
      isHumanTurn: false,
    });
  }

  // ── Sort deduplicated entries by timestamp ─────────────────────────────────
  const entries = Array.from(dedupMap.values()).sort((a, b) => a.tsMs - b.tsMs);

  // ── Pass 2: accumulate (same logic as before, but on deduplicated data) ────
  let allTime: CumulativePoint = { input: 0, output: 0, cacheRead: 0, cacheCreation: 0 };
  let prev: CumulativePoint | null = null;
  let seen = 0;

  let sessionRunning: CumulativePoint = { input: 0, output: 0, cacheRead: 0, cacheCreation: 0 };
  let sessionStartISO: string | null = null;

  let turnRunning: CumulativePoint = { input: 0, output: 0, cacheRead: 0, cacheCreation: 0 };
  let inTurn = false;

  for (const entry of entries) {
    // Human-turn marker → reset turn accumulator
    if (entry.isHumanTurn) {
      turnRunning = { input: 0, output: 0, cacheRead: 0, cacheCreation: 0 };
      inTurn = true;
      continue;
    }

    const { tsMs, timestampISO, delta } = entry;

    prev = { ...allTime };
    allTime = {
      input:         allTime.input         + delta.input,
      output:        allTime.output        + delta.output,
      cacheRead:     allTime.cacheRead     + delta.cacheRead,
      cacheCreation: allTime.cacheCreation + delta.cacheCreation,
    };
    seen++;

    if (inTurn) {
      turnRunning = {
        input:         turnRunning.input         + delta.input,
        output:        turnRunning.output        + delta.output,
        cacheRead:     turnRunning.cacheRead     + delta.cacheRead,
        cacheCreation: turnRunning.cacheCreation + delta.cacheCreation,
      };
    }

  }

  // True sliding window: recompute session totals from entries within last 5h.
  // Overrides the old fixed-boundary approach so the result matches Claude's
  // actual server-side logic (reset = oldest counted entry + 5h).
  {
    const windowCutoff = Date.now() - SESSION_WINDOW_MS;
    sessionStartISO = null;
    sessionRunning  = { input: 0, output: 0, cacheRead: 0, cacheCreation: 0 };
    for (const entry of entries) {
      if (entry.isHumanTurn || entry.tsMs < windowCutoff) continue;
      if (sessionStartISO === null) sessionStartISO = entry.timestampISO;
      sessionRunning = {
        input:         sessionRunning.input         + entry.delta.input,
        output:        sessionRunning.output        + entry.delta.output,
        cacheRead:     sessionRunning.cacheRead     + entry.delta.cacheRead,
        cacheCreation: sessionRunning.cacheCreation + entry.delta.cacheCreation,
      };
    }
  }

  let lastTurnDelta: { input: number; output: number } | null = null;
  if (seen >= 2 && prev) {
    lastTurnDelta = {
      input: allTime.input - prev.input,
      output: allTime.output - prev.output,
    };
  } else if (seen === 1) {
    lastTurnDelta = { input: allTime.input, output: allTime.output };
  }

  return {
    // All-time totals (for the cost display)
    cumulativeInput: allTime.input,
    cumulativeOutput: allTime.output,
    cumulativeCacheRead: allTime.cacheRead,
    cumulativeCacheCreation: allTime.cacheCreation,
    lastTurnDelta,
    // Rolling 5-hour window info (for the progress bar + reset countdown)
    sessionStartISO,
    sessionWindowMs: SESSION_WINDOW_MS,
    // Rolling 5-hour window token counts (for token-based quota progress)
    sessionInput: sessionRunning.input,
    sessionOutput: sessionRunning.output,
    sessionCacheRead: sessionRunning.cacheRead,
    sessionCacheCreation: sessionRunning.cacheCreation,
    // Current task: accumulated since last genuine human message
    turnInput: turnRunning.input,
    turnOutput: turnRunning.output,
    turnCacheRead: turnRunning.cacheRead,
    turnCacheCreation: turnRunning.cacheCreation,
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

/** Cost for the rolling 5-hour session window only (not all-time). */
export function estimateSessionCost(usage: UsageSnapshot, pricing: PricingTable): number {
  const MTok = 1_000_000;
  return (
    (usage.sessionInput / MTok) * pricing.inputPerMTok +
    (usage.sessionOutput / MTok) * pricing.outputPerMTok +
    (usage.sessionCacheRead / MTok) * pricing.cacheReadPerMTok +
    (usage.sessionCacheCreation / MTok) * pricing.cacheCreationPerMTok
  );
}

// ── Multi-file aggregation ────────────────────────────────────────────────────

function scanForJSONL(dir: string): string[] {
  const files: string[] = [];
  try {
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
      const full = path.join(dir, entry.name);
      if (entry.isDirectory()) files.push(...scanForJSONL(full));
      else if (entry.name.endsWith('.jsonl')) files.push(full);
    }
  } catch { /* skip */ }
  return files;
}

/**
 * Merge all entries from multiple JSONL files into a single unified timeline
 * and detect the current 5-hour window using the same fixed-boundary algorithm
 * as p90-detector.ts.
 *
 * Root cause this fixes: the old per-file aggregation summed tokens from
 * windows with DIFFERENT start times (main session vs subagent files), which
 * caused double-counting after the main window expired and WakaWaka fell back
 * to stale subagent windows.
 *
 * The fix: treat all files as one unified stream.  A single window boundary
 * scan correctly handles window expiry and new-window detection across all
 * files simultaneously — exactly how Claude's server tracks the rate limit.
 */
async function computeGlobalSession(files: string[]): Promise<{
  sessionStartISO: string | null;
  sessionOutput: number;
  sessionInput: number;
  sessionCacheRead: number;
  sessionCacheCreation: number;
}> {
  interface GEntry { tsMs: number; timestampISO: string; out: number; inp: number; cr: number; cw: number; }

  // Pass 1: read all files, dedup across the entire corpus
  const dedup = new Map<string, GEntry>();
  let nokey = 0;

  await Promise.all(files.map(async (file) => {
    try {
      const fileStream = fs.createReadStream(file);
      const rl = readline.createInterface({ input: fileStream, crlfDelay: Infinity });
      for await (const line of rl) {
        const trimmed = line.trim();
        if (!trimmed) continue;
        let obj: Record<string, unknown>;
        try { obj = JSON.parse(trimmed); } catch { continue; }

        if (typeof obj.timestamp !== 'string') continue;
        const tsMs = new Date(obj.timestamp).getTime();
        if (Number.isNaN(tsMs)) continue;

        // Accept entries with a usage field — including out=0 entries which
        // anchor the session window start (same rule as calculateUsage).
        const usage = (obj?.message as Record<string, unknown>)?.usage;
        if (!usage || typeof usage !== 'object') continue;
        const u = usage as Record<string, unknown>;
        if (typeof u['input_tokens'] !== 'number') continue;

        const out = Math.max(0, Math.floor(Number(u['output_tokens']        ?? 0)));
        const inp = Math.max(0, Math.floor(Number(u['input_tokens']         ?? 0)));
        const cr  = Math.max(0, Math.floor(Number(u['cache_read_input_tokens']    ?? 0)));
        const cw  = Math.max(0, Math.floor(Number(u['cache_creation_input_tokens'] ?? 0)));

        const requestId = typeof obj.requestId === 'string' ? obj.requestId : '';
        const msgId     = (obj.message as Record<string, unknown>)?.id;
        const msgIdStr  = typeof msgId === 'string' ? msgId : '';
        const key = requestId && msgIdStr ? `${requestId}|${msgIdStr}` : `__nokey_${nokey++}`;

        // Last-write wins (same as per-file dedup in calculateUsage)
        dedup.set(key, { tsMs, timestampISO: obj.timestamp, out, inp, cr, cw });
      }
    } catch { /* skip unreadable files */ }
  }));

  if (dedup.size === 0) {
    return { sessionStartISO: null, sessionOutput: 0, sessionInput: 0, sessionCacheRead: 0, sessionCacheCreation: 0 };
  }

  // Pass 2: true sliding window — include every entry whose timestamp falls
  // within the last 5 hours from now.  This matches Claude's actual server-side
  // rate-limit logic: the quota resets when the oldest counted entry ages past
  // 5 hours, so sessionStartISO (= oldest entry in window) + 5h = reset time.
  const entries = Array.from(dedup.values()).sort((a, b) => a.tsMs - b.tsMs);

  const windowCutoff = Date.now() - SESSION_WINDOW_MS;
  let sessionStartISO: string | null = null;
  let out = 0, inp = 0, cr = 0, cw = 0;

  for (const entry of entries) {
    if (entry.tsMs < windowCutoff) continue;
    if (sessionStartISO === null) sessionStartISO = entry.timestampISO;
    out += entry.out;
    inp += entry.inp;
    cr  += entry.cr;
    cw  += entry.cw;
  }

  return { sessionStartISO, sessionOutput: out, sessionInput: inp, sessionCacheRead: cr, sessionCacheCreation: cw };
}

/**
 * Aggregate session-window usage across ALL JSONL transcripts found under
 * `projectsDir`.  Files that haven't been modified in the last 6 hours are
 * skipped (they cannot have entries in the current 5h quota window).
 *
 * Session window fields (sessionOutput etc.) come from a global unified
 * timeline merge across all recent files — same fixed-boundary algorithm as
 * p90-detector — so window expiry and cross-file boundaries are handled
 * correctly.  Cumulative and turn fields still come from the most-recently-
 * modified file (single-conversation stats).
 */
export async function aggregateSessionUsage(projectsDir: string): Promise<UsageSnapshot & { estimatedCostUSD: number; session5hCostUSD: number; turnCostUSD: number }> {
  const SIX_HOURS_MS = 6 * 60 * 60 * 1000;
  const cutoffMs = Date.now() - SIX_HOURS_MS;

  const allFiles = scanForJSONL(projectsDir);
  // Single stat pass — reused for the 6-hour filter, fallback sort, and anchor
  // selection. Avoids three separate statSync loops over the same file list.
  const allWithMtime = allFiles.map((f) => {
    try { return { f, mt: fs.statSync(f).mtimeMs }; } catch { return { f, mt: 0 }; }
  });
  let recent = allWithMtime.filter((x) => x.mt >= cutoffMs);

  const pricingPath = path.join(path.dirname(fileURLToPath(import.meta.url)), 'pricing.json');
  const pricing: PricingTable = JSON.parse(fs.readFileSync(pricingPath, 'utf8'));

  // If no recent files, fall back to the single most-recently-modified file
  if (recent.length === 0) {
    const sorted = allWithMtime.slice().sort((a, b) => b.mt - a.mt);
    if (sorted.length === 0) {
      const empty: UsageSnapshot = {
        cumulativeInput: 0, cumulativeOutput: 0, cumulativeCacheRead: 0,
        cumulativeCacheCreation: 0, lastTurnDelta: null, sessionStartISO: null,
        sessionWindowMs: SESSION_WINDOW_MS, sessionInput: 0, sessionOutput: 0,
        sessionCacheRead: 0, sessionCacheCreation: 0, turnInput: 0, turnOutput: 0,
        turnCacheRead: 0, turnCacheCreation: 0,
      };
      return { ...empty, estimatedCostUSD: 0, session5hCostUSD: 0, turnCostUSD: 0 };
    }
    recent = [sorted[0]];
  }

  const recentFiles = recent.map((x) => x.f);
  // Anchor file: most recently modified — provides cumulative totals + turn data
  const anchorFile = recent.slice().sort((a, b) => b.mt - a.mt)[0].f;
  const anchorSnap = await calculateUsage(anchorFile).catch(() => null);

  // Global session window: unified timeline merge across ALL recent files
  const global = await computeGlobalSession(recentFiles);

  const aggregated: UsageSnapshot = {
    // All-time and turn data from the anchor (most-recently-modified) file
    cumulativeInput:         anchorSnap?.cumulativeInput         ?? 0,
    cumulativeOutput:        anchorSnap?.cumulativeOutput        ?? 0,
    cumulativeCacheRead:     anchorSnap?.cumulativeCacheRead     ?? 0,
    cumulativeCacheCreation: anchorSnap?.cumulativeCacheCreation ?? 0,
    lastTurnDelta:           anchorSnap?.lastTurnDelta           ?? null,
    turnInput:               anchorSnap?.turnInput               ?? 0,
    turnOutput:              anchorSnap?.turnOutput              ?? 0,
    turnCacheRead:           anchorSnap?.turnCacheRead           ?? 0,
    turnCacheCreation:       anchorSnap?.turnCacheCreation       ?? 0,
    // Session window: from global unified timeline (p90-detector algorithm)
    sessionStartISO:         global.sessionStartISO,
    sessionWindowMs:         SESSION_WINDOW_MS,
    sessionInput:            global.sessionInput,
    sessionOutput:           global.sessionOutput,
    sessionCacheRead:        global.sessionCacheRead,
    sessionCacheCreation:    global.sessionCacheCreation,
  };

  const estimatedCostUSD = estimateCost(aggregated, pricing);
  const session5hCostUSD = estimateSessionCost(aggregated, pricing);
  const MTok = 1_000_000;
  const turnCostUSD =
    (aggregated.turnInput         / MTok) * pricing.inputPerMTok +
    (aggregated.turnOutput        / MTok) * pricing.outputPerMTok +
    (aggregated.turnCacheRead     / MTok) * pricing.cacheReadPerMTok +
    (aggregated.turnCacheCreation / MTok) * pricing.cacheCreationPerMTok;

  return { ...aggregated, estimatedCostUSD, session5hCostUSD, turnCostUSD };
}

// ── CLI entry point ───────────────────────────────────────────────────────────
async function main() {
  // --aggregate mode: scan all projects and sum up session usage
  if (process.argv[2] === '--aggregate') {
    const projectsDir = process.argv[3]
      ?? path.join(process.env.HOME ?? '', '.claude', 'projects');
    const result = await aggregateSessionUsage(projectsDir);
    process.stdout.write(JSON.stringify(result, null, 2) + '\n');
    return;
  }

  const transcriptPath = process.argv[2];
  if (!transcriptPath) {
    process.stderr.write('Usage: npx tsx parser/usage-calculator.ts <transcriptPath>\n       npx tsx parser/usage-calculator.ts --aggregate [projectsDir]\n');
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
  const session5hCost = estimateSessionCost(usage, pricing);
  const MTok = 1_000_000;
  const turnCost =
    (usage.turnInput / MTok) * pricing.inputPerMTok +
    (usage.turnOutput / MTok) * pricing.outputPerMTok +
    (usage.turnCacheRead / MTok) * pricing.cacheReadPerMTok +
    (usage.turnCacheCreation / MTok) * pricing.cacheCreationPerMTok;

  process.stdout.write(
    JSON.stringify({ ...usage, estimatedCostUSD: cost, session5hCostUSD: session5hCost, turnCostUSD: turnCost }, null, 2) + '\n',
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
