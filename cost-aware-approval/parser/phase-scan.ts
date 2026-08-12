/**
 * phase-scan.ts — turns transcripts into deduplicated API calls.
 *
 * Separate from the bucketing in phase-usage.ts because the merge rule is the
 * subtle part and deserves to be read on its own.
 *
 * The attribution unit is `(requestId, message.id)`, and the two halves of a
 * merged call come from different places:
 *
 *   - **Tool content is the union of every record with the key.** Early
 *     streaming writes have not emitted their tool_use blocks yet, so taking
 *     one record's content sends roughly 80% of the volume into `reply`.
 *   - **Usage comes from the newest record that has usage.** Streaming writes
 *     grow, so the last state is the complete one.
 *
 * Because those halves can live in different records, a record that carries
 * tool content but no usage still contributes, and exclusion is decided per
 * *call* after merging — never per record. Counting a half-written record as
 * an exclusion would report a call that was also successfully bucketed.
 */

import * as path from 'path';
import { dedupKey, eachJSONLine, recentFiles, timestampMs } from './transcript-scan.js';
import { claudeTokensFromUsage, NON_BILLED_MODELS, type ClaudeTokens } from './pricing.js';
import { extractInvocations, type ToolInvocation } from './phase-classify.js';

const FILE_MTIME_BUFFER_MS = 6 * 60 * 60 * 1000;

/** One deduplicated API call, with tool content merged across its records. */
export interface Call {
  sessionId: string;
  label: string;
  tsMs: number;
  timestampISO: string;
  isSidechain: boolean;
  model: string;
  tokens: ClaudeTokens;
  invocations: ToolInvocation[];
}

export interface ScanResult {
  calls: Map<string, Call>;
  /** Counted per call, never per record — see the merge note above. */
  excluded: { synthetic: number; noUsage: number };
}

/** A call under construction: content from every record, usage from the best. */
interface PartialCall {
  sessionId: string;
  label: string;
  isSidechain: boolean;
  invocations: ToolInvocation[];
  firstTsMs: number;
  firstTimestampISO: string;
  /** Null until a record carrying usage is seen. */
  usage: { tsMs: number; order: string; timestampISO: string; model: string; tokens: ClaudeTokens } | null;
}

/** Human-readable segment name: the working directory's last path component. */
function labelFor(obj: Record<string, unknown>, file: string): string {
  const cwd = typeof obj.cwd === 'string' ? obj.cwd : '';
  return cwd ? path.basename(cwd) : path.basename(path.dirname(file));
}

/**
 * Reads every transcript into deduplicated calls.
 *
 * Records outside the window are ignored entirely rather than counted as
 * exclusions — `diagnostics.excluded` describes the reported window, and a
 * recently touched transcript full of old rows must not pollute it.
 */
export async function scanCalls(dir: string, sinceMs: number): Promise<ScanResult> {
  const partials = new Map<string, PartialCall>();
  let seq = 0;

  for (const file of recentFiles(dir, sinceMs - FILE_MTIME_BUFFER_MS)) {
    await eachJSONLine(file, (obj, lineNo) => {
      const message = obj.message as Record<string, unknown> | undefined;
      if (obj.type !== 'assistant' || !message) return;

      // A record that cannot be placed on the timeline cannot be placed in the
      // window either, so it is out of scope rather than an exclusion.
      const tsMs = timestampMs(obj);
      if (Number.isNaN(tsMs) || tsMs < sinceMs) return;

      const key = dedupKey(obj, () => seq++);
      const timestampISO = typeof obj.timestamp === 'string' ? obj.timestamp : '';
      let partial = partials.get(key);
      if (!partial) {
        partial = {
          sessionId: typeof obj.sessionId === 'string' ? obj.sessionId : key,
          label: labelFor(obj, file),
          isSidechain: obj.isSidechain === true,
          invocations: [],
          firstTsMs: tsMs,
          firstTimestampISO: timestampISO,
          usage: null,
        };
        partials.set(key, partial);
      }

      // Every record contributes content, whether or not it carries usage.
      partial.invocations.push(...extractInvocations(message.content));
      partial.isSidechain = partial.isSidechain || obj.isSidechain === true;
      if (tsMs < partial.firstTsMs) {
        partial.firstTsMs = tsMs;
        partial.firstTimestampISO = timestampISO;
      }

      const usage = message.usage as Record<string, unknown> | undefined;
      if (!usage || typeof usage['input_tokens'] !== 'number') return;

      // Deterministic winner: newest timestamp, then (file, line). Without the
      // tie-break, equal timestamps resolve by directory traversal order.
      const order = `${file}:${String(lineNo).padStart(9, '0')}`;
      if (partial.usage && !(tsMs > partial.usage.tsMs || (tsMs === partial.usage.tsMs && order >= partial.usage.order))) {
        return;
      }
      partial.usage = {
        tsMs,
        order,
        timestampISO,
        model: typeof message.model === 'string' ? message.model : '(unknown)',
        tokens: claudeTokensFromUsage(usage),
      };
    });
  }

  return finalise(partials);
}

/** Splits merged calls into billable ones and per-call exclusions. */
function finalise(partials: Map<string, PartialCall>): ScanResult {
  const calls = new Map<string, Call>();
  const excluded = { synthetic: 0, noUsage: 0 };

  for (const [key, partial] of partials) {
    if (!partial.usage) {
      excluded.noUsage += 1;
      continue;
    }
    if (NON_BILLED_MODELS.has(partial.usage.model)) {
      excluded.synthetic += 1;
      continue;
    }
    calls.set(key, {
      sessionId: partial.sessionId,
      label: partial.label,
      tsMs: partial.firstTsMs,
      timestampISO: partial.firstTimestampISO,
      isSidechain: partial.isSidechain,
      model: partial.usage.model,
      tokens: partial.usage.tokens,
      invocations: partial.invocations,
    });
  }
  return { calls, excluded };
}

/**
 * Drops repeats of the same tool+command introduced by streaming writes.
 *
 * The key is name+command because that is exactly what classification reads:
 * a non-Bash tool's phase depends only on its name, and Bash's depends on its
 * command. Two `Read`s of different files therefore collapse to one entry,
 * which changes no output — phase and `mixedCalls` are both name-set based.
 */
export function dedupeInvocations(invocations: ToolInvocation[]): ToolInvocation[] {
  const seen = new Set<string>();
  const unique: ToolInvocation[] = [];
  for (const invocation of invocations) {
    const id = `${invocation.name} ${invocation.command ?? ''}`;
    if (seen.has(id)) continue;
    seen.add(id);
    unique.push(invocation);
  }
  return unique;
}
