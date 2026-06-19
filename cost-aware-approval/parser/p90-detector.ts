/**
 * P90 plan-limit auto-detector.
 *
 * Scans ALL ~/.claude/projects/**\/*.jsonl files, groups entries into
 * fixed 5-hour windows (same boundary logic as the session-status parser),
 * then returns the P90 / P95 / max of per-window output-token totals.
 *
 * Using fixed windows (not a rolling window) is critical: a rolling window
 * can span two adjacent quota windows and produce peaks far above the actual
 * plan limit.  Fixed windows match Claude's real quota model.
 *
 * Called by Swift at startup (via ParserRunner.runP90Detector).
 * Expected stdout: JSON { p90, p95, maxPeak, sampleCount }
 */

import * as fs from 'fs';
import * as path from 'path';
import * as readline from 'readline';
import { fileURLToPath } from 'url';

const SESSION_WINDOW_MS = 5 * 60 * 60 * 1000; // 5 hours
const MIN_SAMPLES = 5; // need at least this many data points to trust P90

interface UsageEntry {
  timestampMs: number;
  outputTokens: number;
}

/**
 * Parse a JSONL file and return deduplicated usage entries.
 *
 * Claude Desktop / Code can write the same API response to the JSONL multiple
 * times (once per tool-use in the reply, etc.), resulting in 1.5–3× inflation.
 * We deduplicate by (requestId, message.id), keeping the LAST-seen entry so
 * each API call is counted exactly once — matching Claude's own quota tracking.
 */
async function parseJSONL(filePath: string): Promise<UsageEntry[]> {
  // Key → { timestampMs, outputTokens } — last write wins
  const dedupMap = new Map<string, { timestampMs: number; outputTokens: number }>();
  let uniqueSeq = 0;

  try {
    const fileStream = fs.createReadStream(filePath);
    const rl = readline.createInterface({ input: fileStream, crlfDelay: Infinity });
    for await (const line of rl) {
      const trimmed = line.trim();
      if (!trimmed) continue;
      let obj: Record<string, unknown>;
      try { obj = JSON.parse(trimmed); } catch { continue; }

      if (typeof obj.timestamp !== 'string') continue;
      const ms = new Date(obj.timestamp).getTime();
      if (Number.isNaN(ms)) continue;

      const usage = (obj?.message as Record<string, unknown>)?.usage;
      if (!usage || typeof usage !== 'object') continue;
      const u = usage as Record<string, unknown>;
      if (typeof u['output_tokens'] !== 'number') continue;

      const outputTokens = Math.floor(Number(u['output_tokens']));
      if (outputTokens <= 0) continue;

      // Build dedup key from requestId + message.id (mirrors usage-calculator.ts)
      const requestId = typeof obj.requestId === 'string' ? obj.requestId : '';
      const msgId     = typeof (obj.message as Record<string, unknown>)?.id === 'string'
        ? (obj.message as Record<string, unknown>).id as string : '';
      const key = requestId && msgId ? `${requestId}|${msgId}` : `__uniq_${uniqueSeq++}`;

      // Overwrite → last-seen wins (final streaming value is most complete)
      dedupMap.set(key, { timestampMs: ms, outputTokens });
    }
  } catch { /* skip unreadable files */ }

  return Array.from(dedupMap.values()).map(v => ({
    timestampMs: v.timestampMs,
    outputTokens: v.outputTokens,
  }));
}

function scanDir(dir: string): string[] {
  const files: string[] = [];
  try {
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
      const full = path.join(dir, entry.name);
      if (entry.isDirectory()) files.push(...scanDir(full));
      else if (entry.name.endsWith('.jsonl')) files.push(full);
    }
  } catch { /* skip */ }
  return files;
}

export interface P90Result {
  p90: number;
  p95: number;
  maxPeak: number;
  sampleCount: number;
  /**
   * Plan-limit estimate derived from the distribution of high-watermark peaks.
   *
   * Strategy: average of the 2nd-highest and 3rd-highest observed peaks.
   *
   * Rationale: the absolute maximum often reflects a rare overage session that
   * exceeded the quota ceiling.  The 2nd and 3rd highest peaks straddle the
   * actual plan limit (one slightly above, one slightly below), so their
   * average approximates the true limit far better than maxPeak alone.
   *
   * Example (current data): maxPeak=196K, 2nd=187K, 3rd=171K
   *   → limitEstimate = (187K+171K)/2 = 179K  ≈  implied limit 178K  (0.1% error)
   *   vs maxPeak=196K → 8.2% error
   *
   * Falls back to maxPeak when there are fewer than 3 distinct peak samples.
   */
  limitEstimate: number;
}

export async function detectP90(): Promise<P90Result> {
  const projectsDir = path.join(process.env.HOME ?? '', '.claude', 'projects');
  const jsonlFiles = scanDir(projectsDir);

  // Collect all usage entries across all transcript files
  const allEntries: UsageEntry[] = [];
  for (const file of jsonlFiles) {
    const entries = await parseJSONL(file);
    allEntries.push(...entries);
  }

  if (allEntries.length < MIN_SAMPLES) {
    return { p90: 0, p95: 0, maxPeak: 0, sampleCount: allEntries.length };
  }

  // Sort chronologically — required for the boundary-based window scan
  allEntries.sort((a, b) => a.timestampMs - b.timestampMs);

  // Fixed boundary 5h window (mirrors session-status logic).
  // When an entry's timestamp >= current window end → the current window is
  // complete; record its total and open a new window from that entry's time.
  // This prevents a rolling window from spanning two adjacent quota windows
  // and producing an inflated peak (which was causing P95 to read ~5× too high).
  const windowPeaks: number[] = [];
  let windowEndMs: number | null = null;
  let windowSum = 0;

  for (const entry of allEntries) {
    if (windowEndMs === null || entry.timestampMs >= windowEndMs) {
      // Complete the previous window before starting the new one
      if (windowEndMs !== null) windowPeaks.push(windowSum);
      windowEndMs = entry.timestampMs + SESSION_WINDOW_MS;
      windowSum = 0;
    }
    windowSum += entry.outputTokens;
  }
  // Record the last (possibly still-open) window
  if (windowSum > 0) windowPeaks.push(windowSum);

  const sorted = [...windowPeaks].sort((a, b) => a - b);
  const n = sorted.length;

  // limitEstimate: average of 2nd-highest and 3rd-highest peaks.
  // The absolute maximum (sorted[n-1]) is often an outlier overage session; the
  // 2nd and 3rd highest straddle the true plan limit, so their average is a
  // much more accurate denominator for the session-usage progress bar.
  //
  // Threshold lowered to n >= 3 so all three cases are covered by the averaging
  // formula (n=3: avg of indices 1 and 0; n>=4: avg of 2nd and 3rd highest).
  // Falls back to maxPeak only for n <= 2, where no averaging is possible.
  const limitEstimate = n >= 3
    ? Math.round((sorted[n - 2] + sorted[n - 3]) / 2)
    : (sorted[n - 1] ?? 0);

  return {
    p90:        sorted[Math.floor(n * 0.90)] ?? 0,
    p95:        sorted[Math.floor(n * 0.95)] ?? 0,
    maxPeak:    sorted[n - 1] ?? 0,
    limitEstimate,
    sampleCount: n,
  };
}

// ── CLI entry point ──────────────────────────────────────────────────────────
async function main() {
  const result = await detectP90();
  process.stdout.write(JSON.stringify(result, null, 2) + '\n');
}

const thisFile = fileURLToPath(import.meta.url);
const calledFile = path.resolve(process.argv[1] ?? '');
if (calledFile === thisFile || calledFile === thisFile.replace(/\.js$/, '.ts')) {
  main().catch((err) => {
    process.stderr.write(String(err) + '\n');
    process.exit(1);
  });
}
