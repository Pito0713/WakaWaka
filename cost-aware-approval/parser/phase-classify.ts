/**
 * phase-classify.ts — maps one API call to an activity phase.
 *
 * A call is classified from the union of every tool it invoked, per
 * phase-usage-plan.md §4.1. Two rules carry most of the weight:
 *
 *   - Priority is `develop > verify > understand > other`. Mixed-tool calls are
 *     only 1.8% of real traffic, so a sixth "mixed" bucket would cost every
 *     reader clarity to describe a rounding error; the combination is reported
 *     in the `mixedCalls` diagnostic instead.
 *   - `reply` means the response invoked no tools at all — 9.3% of calls. It is
 *     a separate bucket precisely so plain answers stop being counted as
 *     "unclassified", which is what made the v1 report unusable.
 *
 * An unrecognised tool lands in `other` and is named in the diagnostics. It is
 * never guessed at: a wrong phase is invisible, an honest gap is fixable.
 */

import * as fs from 'fs';
import * as path from 'path';
import { fileURLToPath } from 'url';
import { classifyBash, type BashClassification } from './bash-classify.js';

export type Phase = 'understand' | 'develop' | 'verify' | 'reply' | 'other';

/** `reply` is outside the ladder: it applies only when no tool ran at all. */
const PHASE_RANK: Record<Exclude<Phase, 'reply'>, number> = {
  develop: 4,
  verify: 3,
  understand: 2,
  other: 1,
};

export interface ToolPhaseTable {
  version: number;
  tools: Map<string, Phase>;
  patterns: { prefix: string; phase: Phase }[];
}

const VALID_PHASES = new Set<Phase>(['understand', 'develop', 'verify', 'reply', 'other']);

function asPhase(value: unknown): Phase | null {
  return typeof value === 'string' && VALID_PHASES.has(value as Phase) ? (value as Phase) : null;
}

function defaultTablePath(): string {
  return path.join(path.dirname(fileURLToPath(import.meta.url)), 'tool-phases.json');
}

export function loadToolPhases(tablePath = defaultTablePath()): ToolPhaseTable {
  const raw = JSON.parse(fs.readFileSync(tablePath, 'utf8')) as Record<string, unknown>;
  const tools = new Map<string, Phase>();
  for (const [name, value] of Object.entries((raw.tools ?? {}) as Record<string, unknown>)) {
    const phase = asPhase(value);
    if (phase) tools.set(name, phase);
  }
  const patterns: ToolPhaseTable['patterns'] = [];
  for (const entry of Array.isArray(raw.patterns) ? raw.patterns : []) {
    const node = entry as Record<string, unknown>;
    const phase = asPhase(node.phase);
    if (phase && typeof node.prefix === 'string') patterns.push({ prefix: node.prefix, phase });
  }
  return { version: typeof raw.version === 'number' ? raw.version : 0, tools, patterns };
}

/** One tool invocation extracted from a call's content blocks. */
export interface ToolInvocation {
  name: string;
  /** Present only for Bash; the shell command as written. */
  command?: string;
}

export interface CallClassification {
  phase: Phase;
  /** Sorted tool names that produced the decision — the `mixedCalls` combo key. */
  combo: string[];
  /** Tool names with no entry in the table, for `unclassifiedTools`. */
  unclassifiedTools: string[];
  /** Head tokens of Bash commands that could not be judged, for `unknownBash`. */
  unknownBashHeads: string[];
}

/** Phase for a non-Bash tool, or null when the table has no opinion. */
function lookupTool(table: ToolPhaseTable, name: string): Phase | null {
  const exact = table.tools.get(name);
  if (exact) return exact;
  for (const { prefix, phase } of table.patterns) {
    if (name.startsWith(prefix)) return phase;
  }
  return null;
}

/**
 * Classifies one API call from the union of its tool invocations.
 *
 * `invocations` must be the union across every JSONL record sharing the call's
 * `(requestId, message.id)` key. Using only the first record's content sends
 * roughly 80% of the volume into `reply`, because the early streaming writes
 * have not accumulated their tool_use blocks yet.
 */
export function classifyCall(
  invocations: ToolInvocation[],
  table: ToolPhaseTable
): CallClassification {
  if (invocations.length === 0) {
    return { phase: 'reply', combo: [], unclassifiedTools: [], unknownBashHeads: [] };
  }

  let best: Exclude<Phase, 'reply'> = 'other';
  const combo = new Set<string>();
  const unclassifiedTools = new Set<string>();
  const unknownBashHeads = new Set<string>();

  for (const invocation of invocations) {
    combo.add(invocation.name);
    let phase: Exclude<Phase, 'reply'>;

    if (invocation.name === 'Bash') {
      const bash: BashClassification = classifyBash(invocation.command ?? '');
      phase = bash.phase;
      if (bash.phase === 'other' && bash.head) unknownBashHeads.add(bash.head);
    } else {
      const mapped = lookupTool(table, invocation.name);
      if (mapped && mapped !== 'reply') {
        phase = mapped;
      } else {
        phase = 'other';
        if (!mapped) unclassifiedTools.add(invocation.name);
      }
    }

    if (PHASE_RANK[phase] > PHASE_RANK[best]) best = phase;
  }

  return {
    phase: best,
    combo: Array.from(combo).sort(),
    unclassifiedTools: Array.from(unclassifiedTools).sort(),
    unknownBashHeads: Array.from(unknownBashHeads).sort(),
  };
}

/**
 * Pulls tool invocations out of an assistant message's `content` array.
 * Non-array content (a plain string reply) yields none, which is what makes
 * the call a `reply`.
 */
export function extractInvocations(content: unknown): ToolInvocation[] {
  if (!Array.isArray(content)) return [];
  const invocations: ToolInvocation[] = [];
  for (const block of content) {
    if (!block || typeof block !== 'object') continue;
    const node = block as Record<string, unknown>;
    if (node.type !== 'tool_use' || typeof node.name !== 'string') continue;
    const input = node.input as Record<string, unknown> | undefined;
    const command = typeof input?.command === 'string' ? input.command : undefined;
    invocations.push(command === undefined ? { name: node.name } : { name: node.name, command });
  }
  return invocations;
}
