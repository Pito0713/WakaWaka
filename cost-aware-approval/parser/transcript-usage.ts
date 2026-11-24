/** Usage of a single transcript: cumulative, 5-hour window and current turn. */
import { dedupKey, eachJSONLine } from './transcript-scan.js';
import { emptyClaudeTokens, type ClaudeTokens } from './pricing.js';
import {
  accumulateModel,
  extractUsage,
  SESSION_WINDOW_MS,
  UNKNOWN_MODEL,
  type CumulativePoint,
  type ModelBuckets,
  type UsageSnapshot,
} from './usage-rows.js';

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
  model: string;
  tokens: ClaudeTokens;
  isHumanTurn: boolean; // genuine human message (not tool-result)
}

/** A snapshot plus the per-model buckets needed to price it. */
export interface UsageScan extends UsageSnapshot {
  byModel: ModelBuckets;
}

export async function calculateUsage(transcriptPath: string): Promise<UsageScan> {
  // ── Pass 1: collect & deduplicate ──────────────────────────────────────────
  // Key: `${requestId}|${message.id}` — keeps the LAST occurrence (latest state
  // of a streaming response is the most complete).
  // Human-turn markers (no requestId/usage) are stored with a unique sentinel key
  // so they are never deduplicated away.
  const dedupMap = new Map<string, NormalisedEntry>();
  let humanSeq = 0;
  let nokeySeq  = 0; // independent counter for entries that lack requestId+msgId

  await eachJSONLine(transcriptPath, (obj) => {
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
          model:        UNKNOWN_MODEL,
          tokens:       emptyClaudeTokens(),
          isHumanTurn:  true,
        });
      }
      return; // human entries never carry usage
    }

    const row = extractUsage(obj);
    if (!row) return;
    const delta = row.point;

    // Records lacking either id get a unique sentinel so they are never merged.
    const key = dedupKey(obj, () => nokeySeq++);

    // Always overwrite → last-seen wins (final streaming value is most complete).
    // A single file is read in order, so file order is the write order.
    dedupMap.set(key, {
      tsMs:         Number.isNaN(tsMs) ? 0 : tsMs,
      timestampISO: tsRaw,
      delta,
      model:        row.model,
      tokens:       row.tokens,
      isHumanTurn: false,
    });
  });

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

  // Per-model buckets mirror the three accumulators above, so each can be
  // priced at its own model's rate instead of one blended guess.
  const byModel: ModelBuckets = { cumulative: new Map(), session: new Map(), turn: new Map() };

  for (const entry of entries) {
    // Human-turn marker → reset turn accumulator
    if (entry.isHumanTurn) {
      turnRunning = { input: 0, output: 0, cacheRead: 0, cacheCreation: 0 };
      byModel.turn.clear();
      inTurn = true;
      continue;
    }

    const { delta } = entry;
    accumulateModel(byModel.cumulative, entry.model, entry.tokens);
    if (inTurn) accumulateModel(byModel.turn, entry.model, entry.tokens);

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
    byModel.session.clear();
    for (const entry of entries) {
      if (entry.isHumanTurn || entry.tsMs < windowCutoff) continue;
      if (sessionStartISO === null) sessionStartISO = entry.timestampISO;
      accumulateModel(byModel.session, entry.model, entry.tokens);
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
    byModel,
  };
}
