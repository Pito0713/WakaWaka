import { test } from 'node:test';
import assert from 'node:assert/strict';
import * as path from 'path';
import * as os from 'os';
import * as fs from 'fs';
import { computeDailyUsage, type DailyUsageOptions } from './daily-usage.js';

// Fixed "now" so the 7-day axis is deterministic: 2026-07-18 … 2026-07-24.
// Fixture timestamps use NOON UTC so a ±12h timezone shift never flips the day.
const NOW = new Date('2026-07-24T12:00:00Z');

function claudeLine(o: {
  ts: string;
  requestId?: string;
  msgId?: string;
  input: number;
  output: number;
  cacheRead?: number;
  cacheWrite?: number;
}): string {
  const message: Record<string, unknown> = {
    usage: {
      input_tokens: o.input,
      output_tokens: o.output,
      cache_read_input_tokens: o.cacheRead ?? 0,
      cache_creation_input_tokens: o.cacheWrite ?? 0,
    },
  };
  if (o.msgId) message.id = o.msgId;
  return JSON.stringify({ type: 'assistant', timestamp: o.ts, requestId: o.requestId, message });
}

function codexLine(o: {
  ts: string;
  input: number;
  cached: number;
  output: number;
  reasoning: number;
  /** running total — must NOT be summed; present to prove we ignore it */
  totalInput?: number;
}): string {
  return JSON.stringify({
    timestamp: o.ts,
    type: 'event_msg',
    payload: {
      type: 'token_count',
      info: {
        total_token_usage: {
          input_tokens: o.totalInput ?? o.input,
          cached_input_tokens: o.cached,
          output_tokens: o.output,
          reasoning_output_tokens: o.reasoning,
        },
        last_token_usage: {
          input_tokens: o.input,
          cached_input_tokens: o.cached,
          output_tokens: o.output,
          reasoning_output_tokens: o.reasoning,
        },
      },
    },
  });
}

/** Builds a tmp workspace with claude/ and codex/ dirs, returns computeDailyUsage opts. */
function makeWorkspace(claudeLines: string[], codexLines: string[]): DailyUsageOptions & { dir: string } {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'daily-usage-test-'));
  const claudeDir = path.join(dir, 'claude', 'projects', 'proj');
  const codexDir = path.join(dir, 'codex', 'sessions', '2026');
  fs.mkdirSync(claudeDir, { recursive: true });
  fs.mkdirSync(codexDir, { recursive: true });
  if (claudeLines.length) fs.writeFileSync(path.join(claudeDir, 'a.jsonl'), claudeLines.join('\n') + '\n');
  if (codexLines.length) fs.writeFileSync(path.join(codexDir, 'a.jsonl'), codexLines.join('\n') + '\n');
  return {
    dir,
    claudeDir: path.join(dir, 'claude', 'projects'),
    codexDir: path.join(dir, 'codex', 'sessions'),
    now: NOW,
  };
}

function findDay(result: Awaited<ReturnType<typeof computeDailyUsage>>, date: string) {
  return result.days.find((d) => d.date === date);
}

test('continuous date axis of length `days`, oldest → newest', async () => {
  const ws = makeWorkspace([], []);
  const result = await computeDailyUsage(7, ws);
  assert.equal(result.days.length, 7);
  assert.equal(result.days[0].date, '2026-07-18');
  assert.equal(result.days[6].date, '2026-07-24');
  fs.rmSync(ws.dir, { recursive: true, force: true });
});

test('Claude: same requestId|msgId deduped, last-write-wins (streaming)', async () => {
  // Three writes of ONE API response: output grows, input fixed.
  const ws = makeWorkspace(
    [
      claudeLine({ ts: '2026-07-23T12:00:00Z', requestId: 'r1', msgId: 'm1', input: 1000, output: 100, cacheRead: 500 }),
      claudeLine({ ts: '2026-07-23T12:00:01Z', requestId: 'r1', msgId: 'm1', input: 1000, output: 150, cacheRead: 500 }),
      claudeLine({ ts: '2026-07-23T12:00:02Z', requestId: 'r1', msgId: 'm1', input: 1000, output: 200, cacheRead: 500 }),
    ],
    []
  );
  const day = findDay(await computeDailyUsage(7, ws), '2026-07-23')!;
  assert.ok(day.agents['claude-code']);
  assert.equal(day.agents['claude-code']!.output, 200, 'last-wins, not first (100) or sum (450)');
  assert.equal(day.agents['claude-code']!.uncachedInput, 1000, 'input counted once, not 3×');
  assert.equal(day.agents['claude-code']!.cacheRead, 500);
  fs.rmSync(ws.dir, { recursive: true, force: true });
});

test('Claude: entries land in the correct local day bucket', async () => {
  const ws = makeWorkspace(
    [
      claudeLine({ ts: '2026-07-22T12:00:00Z', requestId: 'r2', msgId: 'm2', input: 10, output: 77 }),
      claudeLine({ ts: '2026-07-23T12:00:00Z', requestId: 'r3', msgId: 'm3', input: 10, output: 88 }),
    ],
    []
  );
  const result = await computeDailyUsage(7, ws);
  assert.equal(findDay(result, '2026-07-22')!.agents['claude-code']!.output, 77);
  assert.equal(findDay(result, '2026-07-23')!.agents['claude-code']!.output, 88);
  fs.rmSync(ws.dir, { recursive: true, force: true });
});

test('Claude: entries without requestId/msgId are never deduped away', async () => {
  const ws = makeWorkspace(
    [
      claudeLine({ ts: '2026-07-21T12:00:00Z', input: 5, output: 5 }),
      claudeLine({ ts: '2026-07-21T12:00:00Z', input: 5, output: 5 }),
    ],
    []
  );
  const day = findDay(await computeDailyUsage(7, ws), '2026-07-21')!;
  assert.equal(day.agents['claude-code']!.output, 10, 'both no-key rows kept');
  fs.rmSync(ws.dir, { recursive: true, force: true });
});

test('Codex: sums last_token_usage per event, ignores running total', async () => {
  const ws = makeWorkspace(
    [],
    [
      codexLine({ ts: '2026-07-23T12:00:00Z', input: 1000, cached: 600, output: 50, reasoning: 10, totalInput: 1000 }),
      // total jumps to 3000 (running) but last_token_usage is the per-turn 2000
      codexLine({ ts: '2026-07-23T12:05:00Z', input: 2000, cached: 1500, output: 80, reasoning: 20, totalInput: 3000 }),
    ]
  );
  const day = findDay(await computeDailyUsage(7, ws), '2026-07-23')!;
  assert.ok(day.agents.codex);
  // uncached = (1000-600) + (2000-1500) = 900 — proves input−cached split AND last-not-total
  assert.equal(day.agents.codex!.uncachedInput, 900);
  assert.equal(day.agents.codex!.cachedInput, 2100, '600 + 1500');
  assert.equal(day.agents.codex!.output, 130, '50 + 80');
  assert.equal(day.agents.codex!.reasoningOutput, 30, '10 + 20');
  fs.rmSync(ws.dir, { recursive: true, force: true });
});

test('Codex: estimates cost using uncached, cached, and output prices', async () => {
  const ws = makeWorkspace(
    [],
    [codexLine({ ts: '2026-07-23T12:00:00Z', input: 1000, cached: 600, output: 50, reasoning: 0 })]
  );
  const day = findDay(await computeDailyUsage(7, ws), '2026-07-23')!;
  // 400 uncached × $5/MTok + 600 cached × $0.50/MTok + 50 output × $30/MTok
  assert.equal(day.agents.codex!.costUSD, 0.0038);
  fs.rmSync(ws.dir, { recursive: true, force: true });
});

test('Claude: costUSD is a finite number (pricing present)', async () => {
  const ws = makeWorkspace(
    [claudeLine({ ts: '2026-07-23T12:00:00Z', requestId: 'r', msgId: 'm', input: 1_000_000, output: 0 })],
    []
  );
  const day = findDay(await computeDailyUsage(7, ws), '2026-07-23')!;
  // 1M input × $3/MTok = $3.00
  assert.equal(day.agents['claude-code']!.costUSD, 3);
  fs.rmSync(ws.dir, { recursive: true, force: true });
});

test('missing agent directory → agent simply absent, no throw', async () => {
  const ws = makeWorkspace(
    [claudeLine({ ts: '2026-07-23T12:00:00Z', requestId: 'r', msgId: 'm', input: 10, output: 10 })],
    []
  );
  const result = await computeDailyUsage(7, { ...ws, codexDir: path.join(ws.dir, 'does-not-exist') });
  const day = findDay(result, '2026-07-23')!;
  assert.ok(day.agents['claude-code']);
  assert.equal(day.agents.codex, undefined);
  fs.rmSync(ws.dir, { recursive: true, force: true });
});

test('days with no data have an empty agents object', async () => {
  const ws = makeWorkspace(
    [claudeLine({ ts: '2026-07-23T12:00:00Z', requestId: 'r', msgId: 'm', input: 10, output: 10 })],
    []
  );
  const result = await computeDailyUsage(7, ws);
  assert.deepEqual(findDay(result, '2026-07-19')!.agents, {});
  fs.rmSync(ws.dir, { recursive: true, force: true });
});
