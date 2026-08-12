/**
 * transcript-scan.ts — shared JSONL discovery, reading, and deduplication.
 *
 * `daily-usage.ts`, `usage-calculator.ts` and `phase-usage.ts` all walk the
 * same transcript trees and all have to solve the same counting problem, so
 * the rules live here once rather than in three drifting copies.
 *
 * The rule that matters: one API response is written to the JSONL repeatedly
 * as it streams, so records must be deduplicated by `(requestId, message.id)`
 * with the LAST state winning — the final write is the complete one. Getting
 * this wrong inflates every number downstream. Records missing either id get a
 * unique sentinel key so they are never merged with anything else.
 */

import * as fs from 'fs';
import * as readline from 'readline';

/** Recursively collects every `.jsonl` file under `dir`. */
export function scanForJSONL(dir: string): string[] {
  const files: string[] = [];
  let entries: fs.Dirent[];
  try {
    entries = fs.readdirSync(dir, { withFileTypes: true });
  } catch {
    return files; // missing dir → agent simply absent, not an error
  }
  for (const entry of entries) {
    const full = `${dir}/${entry.name}`;
    if (entry.isDirectory()) files.push(...scanForJSONL(full));
    else if (entry.name.endsWith('.jsonl')) files.push(full);
  }
  return files;
}

/** Files whose mtime is too old to hold any entry in the window are skipped. */
export function recentFiles(dir: string, cutoffMs: number): string[] {
  return scanForJSONL(dir).filter((f) => {
    try {
      return fs.statSync(f).mtimeMs >= cutoffMs;
    } catch {
      return false;
    }
  });
}

/**
 * Streams one JSONL file, handing each parsed object to `fn` with its 1-based
 * line number. Unparseable lines are skipped rather than aborting the file —
 * a partially written last line is normal for a live transcript.
 */
export async function eachJSONLine(
  file: string,
  fn: (obj: Record<string, unknown>, lineNo: number) => void
): Promise<void> {
  const rl = readline.createInterface({
    input: fs.createReadStream(file),
    crlfDelay: Infinity,
  });
  let lineNo = 0;
  try {
    for await (const line of rl) {
      lineNo++;
      const trimmed = line.trim();
      if (!trimmed) continue;
      let obj: Record<string, unknown>;
      try {
        obj = JSON.parse(trimmed);
      } catch {
        continue;
      }
      fn(obj, lineNo);
    }
  } finally {
    rl.close();
  }
}

/**
 * Integer token count; corrupt, absent, or negative values read as 0.
 *
 * The clamp is a deliberate change from the per-file helpers this replaced,
 * which passed negatives through. A negative token count is not a smaller
 * bill, it is malformed input — letting it subtract from a total silently
 * under-reports the rest of the window.
 */
export function toInt(v: unknown): number {
  const n = Number(v);
  return Number.isFinite(n) ? Math.max(0, Math.floor(n)) : 0;
}

/** Milliseconds since epoch for a record's `timestamp`, or NaN when unusable. */
export function timestampMs(obj: Record<string, unknown>): number {
  const raw = typeof obj.timestamp === 'string' ? obj.timestamp : '';
  return raw ? new Date(raw).getTime() : NaN;
}

/**
 * Dedup key for one record: `requestId|message.id` when both are present,
 * otherwise a unique sentinel from `nextSeq` so the record survives on its own.
 * The two ids are not treated as interchangeable even though today's data has
 * one message id per request.
 */
export function dedupKey(obj: Record<string, unknown>, nextSeq: () => number): string {
  const requestId = typeof obj.requestId === 'string' ? obj.requestId : '';
  const message = obj.message as Record<string, unknown> | undefined;
  const msgId = typeof message?.id === 'string' ? message.id : '';
  return requestId && msgId ? `${requestId}|${msgId}` : `__nokey_${nextSeq()}`;
}

/**
 * Deduplicating accumulator with a deterministic winner.
 *
 * "Last write wins" is only well defined if reads are ordered. Files are often
 * read in parallel, so the survivor is chosen by timestamp, falling back to
 * `(file, line)` when timestamps tie — the same corpus then always produces
 * the same totals, however the I/O happened to interleave.
 *
 * This is a deliberate change from the traversal-order `Map.set` it replaced:
 * for duplicates whose timestamps run backwards across files, the newest
 * record now wins rather than the last one read. Plan §1 asks for the last
 * record "by timestamp / file order", and only the timestamp is stable.
 */
export class TranscriptDedup<T> {
  private readonly entries = new Map<string, { value: T; tsMs: number; order: string }>();
  private seq = 0;

  /** Unique sentinel source for records lacking `requestId`/`message.id`. */
  readonly nextSeq = (): number => this.seq++;

  /**
   * @param source `<file>:<line>` — the tie-break when timestamps are equal.
   *   Line numbers are zero-padded so they compare in numeric order.
   */
  offer(key: string, value: T, tsMs: number, file: string, lineNo: number): void {
    const order = `${file}:${String(lineNo).padStart(9, '0')}`;
    const prev = this.entries.get(key);
    if (!prev || this.beats(tsMs, order, prev.tsMs, prev.order)) {
      this.entries.set(key, { value, tsMs, order });
    }
  }

  /**
   * Total order over (timestamp, file, line). A usable timestamp always beats
   * an unusable one — without that rule the winner depends on arrival order,
   * since every comparison against NaN is false and whichever NaN record
   * landed first could never be displaced.
   */
  private beats(tsMs: number, order: string, prevTsMs: number, prevOrder: string): boolean {
    const valid = !Number.isNaN(tsMs);
    const prevValid = !Number.isNaN(prevTsMs);
    if (valid !== prevValid) return valid;
    if (valid && tsMs !== prevTsMs) return tsMs > prevTsMs;
    return order >= prevOrder;
  }

  /** The surviving record for `key`, if any — used to merge across writes. */
  peek(key: string): T | undefined {
    return this.entries.get(key)?.value;
  }

  values(): T[] {
    return Array.from(this.entries.values(), (e) => e.value);
  }

  get size(): number {
    return this.entries.size;
  }
}
