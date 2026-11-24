/** Session-window usage across every recent transcript, merged into one timeline. */
import * as fs from 'fs';
import { dedupKey, eachJSONLine, scanForJSONL, timestampMs, TranscriptDedup } from './transcript-scan.js';
import { loadPricing, type ClaudeTokens } from './pricing.js';
import {
  accumulateModel,
  bucketCost,
  extractUsage,
  SESSION_WINDOW_MS,
  unpricedIn,
  type UsageSnapshot,
} from './usage-rows.js';
import { calculateUsage } from './transcript-usage.js';

/**
 * Merge all entries from multiple JSONL files into a single unified timeline
 * and detect the current 5-hour window with a sliding cutoff (`now − 5h`),
 * matching `calculateUsage`. This is deliberately NOT the fixed-boundary
 * algorithm in p90-detector.ts — the quota resets when the oldest counted
 * entry ages out, so the boundary moves with the data.
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
  byModel: Map<string, ClaudeTokens>;
}> {
  interface GEntry {
    tsMs: number;
    timestampISO: string;
    out: number; inp: number; cr: number; cw: number;
    model: string;
    tokens: ClaudeTokens;
  }

  // Pass 1: read all files, dedup across the entire corpus. Files are read in
  // parallel, so the survivor is chosen by timestamp rather than by whichever
  // stream finished last — see TranscriptDedup.
  const dedup = new TranscriptDedup<GEntry>();

  await Promise.all(files.map(async (file) => {
    try {
      await eachJSONLine(file, (obj, lineNo) => {
        const tsMs = timestampMs(obj);
        if (Number.isNaN(tsMs)) return;

        // Accept entries with a usage field — including out=0 entries which
        // anchor the session window start (same rule as calculateUsage).
        const row = extractUsage(obj);
        if (!row) return;

        dedup.offer(
          dedupKey(obj, dedup.nextSeq),
          {
            tsMs,
            timestampISO: obj.timestamp as string,
            out: row.point.output,
            inp: row.point.input,
            cr: row.point.cacheRead,
            cw: row.point.cacheCreation,
            model: row.model,
            tokens: row.tokens,
          },
          tsMs,
          file,
          lineNo
        );
      });
    } catch { /* skip unreadable files */ }
  }));

  if (dedup.size === 0) {
    return {
      sessionStartISO: null, sessionOutput: 0, sessionInput: 0,
      sessionCacheRead: 0, sessionCacheCreation: 0, byModel: new Map(),
    };
  }

  // Pass 2: true sliding window — include every entry whose timestamp falls
  // within the last 5 hours from now.  This matches Claude's actual server-side
  // rate-limit logic: the quota resets when the oldest counted entry ages past
  // 5 hours, so sessionStartISO (= oldest entry in window) + 5h = reset time.
  const entries = Array.from(dedup.values()).sort((a, b) => a.tsMs - b.tsMs);

  const windowCutoff = Date.now() - SESSION_WINDOW_MS;
  let sessionStartISO: string | null = null;
  let out = 0, inp = 0, cr = 0, cw = 0;
  const byModel = new Map<string, ClaudeTokens>();

  for (const entry of entries) {
    if (entry.tsMs < windowCutoff) continue;
    if (sessionStartISO === null) sessionStartISO = entry.timestampISO;
    out += entry.out;
    inp += entry.inp;
    cr  += entry.cr;
    cw  += entry.cw;
    accumulateModel(byModel, entry.model, entry.tokens);
  }

  return {
    sessionStartISO, sessionOutput: out, sessionInput: inp,
    sessionCacheRead: cr, sessionCacheCreation: cw, byModel,
  };
}

/**
 * Aggregate session-window usage across ALL JSONL transcripts found under
 * `projectsDir`.  Files that haven't been modified in the last 6 hours are
 * skipped (they cannot have entries in the current 5h quota window).
 *
 * Session window fields (sessionOutput etc.) come from a global unified
 * timeline merge across all recent files, using the same sliding 5-hour
 * cutoff as `calculateUsage`, so window expiry and cross-file boundaries are
 * handled consistently.  Cumulative and turn fields still come from the
 * most-recently-modified file (single-conversation stats).
 */
/**
 * The shape handed to Swift. `session5hCostUSD` and `turnCostUSD` are null
 * when nothing in that bucket could be priced — the UI already treats both as
 * optional and hides the row. `estimatedCostUSD` stays a plain number because
 * Swift decodes it non-optionally; it is not displayed anywhere today.
 */
export interface CostedUsage extends UsageSnapshot {
  estimatedCostUSD: number;
  session5hCostUSD: number | null;
  turnCostUSD: number | null;
  /** Model ids seen with no entry in pricing.json, so gaps are visible. */
  unpricedModels: string[];
  /** Date the price table was last verified against the official source. */
  pricingAsOf: string;
}

export async function aggregateSessionUsage(projectsDir: string): Promise<CostedUsage> {
  const SIX_HOURS_MS = 6 * 60 * 60 * 1000;
  const cutoffMs = Date.now() - SIX_HOURS_MS;

  const allFiles = scanForJSONL(projectsDir);
  // Single stat pass — reused for the 6-hour filter, fallback sort, and anchor
  // selection. Avoids three separate statSync loops over the same file list.
  const allWithMtime = allFiles.map((f) => {
    try { return { f, mt: fs.statSync(f).mtimeMs }; } catch { return { f, mt: 0 }; }
  });
  let recent = allWithMtime.filter((x) => x.mt >= cutoffMs);

  const pricing = loadPricing();

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
      return {
        ...empty, estimatedCostUSD: 0, session5hCostUSD: 0, turnCostUSD: 0,
        unpricedModels: [], pricingAsOf: pricing.asOf,
      };
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

  // Cumulative and turn buckets come from the anchor file; the session bucket
  // comes from the global merge — each priced at its own models' rates.
  const cumulativeBuckets = anchorSnap?.byModel.cumulative ?? new Map();
  const turnBuckets = anchorSnap?.byModel.turn ?? new Map();

  return {
    ...aggregated,
    estimatedCostUSD: bucketCost(cumulativeBuckets, pricing) ?? 0,
    session5hCostUSD: bucketCost(global.byModel, pricing),
    turnCostUSD: bucketCost(turnBuckets, pricing),
    unpricedModels: unpricedIn([cumulativeBuckets, turnBuckets, global.byModel], pricing),
    pricingAsOf: pricing.asOf,
  };
}
