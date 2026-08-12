import { test } from 'node:test';
import assert from 'node:assert/strict';
import * as path from 'path';
import * as os from 'os';
import * as fs from 'fs';
import { computeDailyUsage, type DailyUsageOptions } from './daily-usage.js';

// Fixed "now" so the 7-day axis is deterministic: 2026-07-18 … 2026-07-24.
// Fixture timestamps use NOON UTC so a ±12h timezone shift never flips the day.
const NOW = new Date('2026-07-24T12:00:00Z');

/**
 * `cacheWrite` is the 5-minute-TTL portion and `cacheWrite1h` the 1-hour one;
 * `cache_creation_input_tokens` is their sum, mirroring the real transcript
 * shape. Defaults to a model that exists in pricing.json so tests that only
 * care about token maths don't have to think about pricing.
 */
function claudeLine(o: {
  ts: string;
  requestId?: string;
  msgId?: string;
  model?: string;
  input: number;
  output: number;
  cacheRead?: number;
  cacheWrite?: number;
  cacheWrite1h?: number;
  /** Omit the `cache_creation` breakdown entirely (older transcript format). */
  noCacheBreakdown?: boolean;
}): string {
  const write5m = o.cacheWrite ?? 0;
  const write1h = o.cacheWrite1h ?? 0;
  const usage: Record<string, unknown> = {
    input_tokens: o.input,
    output_tokens: o.output,
    cache_read_input_tokens: o.cacheRead ?? 0,
    cache_creation_input_tokens: write5m + write1h,
  };
  if (!o.noCacheBreakdown) {
    usage.cache_creation = {
      ephemeral_5m_input_tokens: write5m,
      ephemeral_1h_input_tokens: write1h,
    };
  }
  const message: Record<string, unknown> = { usage, model: o.model ?? 'claude-opus-5' };
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

test('Claude: costUSD uses the row\'s own model price, not a fixed default', async () => {
  const ws = makeWorkspace(
    [
      claudeLine({
        ts: '2026-07-23T12:00:00Z', requestId: 'r', msgId: 'm',
        model: 'claude-opus-5', input: 1_000_000, output: 0,
      }),
    ],
    []
  );
  const result = await computeDailyUsage(7, ws);
  const day = findDay(result, '2026-07-23')!;
  // 1M input × $5/MTok (Opus 5) = $5.00 — the old code charged Sonnet's $3.
  assert.equal(day.agents['claude-code']!.costUSD, 5);
  assert.equal(result.pricing.pricedCalls, 1);
  assert.equal(result.pricing.totalCalls, 1);
  assert.deepEqual(result.pricing.unpricedModels, []);
  fs.rmSync(ws.dir, { recursive: true, force: true });
});

test('Claude: two models on one day are priced separately and summed', async () => {
  const ws = makeWorkspace(
    [
      claudeLine({ ts: '2026-07-23T12:00:00Z', requestId: 'r1', msgId: 'm1', model: 'claude-opus-5', input: 1_000_000, output: 0 }),
      claudeLine({ ts: '2026-07-23T12:01:00Z', requestId: 'r2', msgId: 'm2', model: 'claude-haiku-4-5', input: 1_000_000, output: 0 }),
    ],
    []
  );
  const day = findDay(await computeDailyUsage(7, ws), '2026-07-23')!;
  // $5 (Opus 5) + $1 (Haiku 4.5). A single blended rate cannot produce this.
  assert.equal(day.agents['claude-code']!.costUSD, 6);
  assert.equal(day.agents['claude-code']!.uncachedInput, 2_000_000, 'tokens still sum across models');
  fs.rmSync(ws.dir, { recursive: true, force: true });
});

test('Claude: unknown model → costUSD null, never a fallback rate', async () => {
  const ws = makeWorkspace(
    [
      claudeLine({
        ts: '2026-07-23T12:00:00Z', requestId: 'r', msgId: 'm',
        model: 'claude-not-a-real-model-9', input: 1_000_000, output: 1_000_000,
      }),
    ],
    []
  );
  const result = await computeDailyUsage(7, ws);
  const day = findDay(result, '2026-07-23')!;
  assert.equal(day.agents['claude-code']!.costUSD, null, 'must not fall back to any default price');
  assert.equal(day.agents['claude-code']!.output, 1_000_000, 'tokens are still reported');
  assert.equal(result.pricing.pricedCalls, 0);
  assert.equal(result.pricing.totalCalls, 1);
  assert.deepEqual(result.pricing.unpricedModels, ['claude-not-a-real-model-9']);
  fs.rmSync(ws.dir, { recursive: true, force: true });
});

test('Claude: a row with no model field counts as unpriced, not as a default model', async () => {
  const ws = makeWorkspace(
    ['{"type":"assistant","timestamp":"2026-07-23T12:00:00Z","requestId":"r","message":{"id":"m","usage":{"input_tokens":1000000,"output_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}'],
    []
  );
  const result = await computeDailyUsage(7, ws);
  assert.equal(findDay(result, '2026-07-23')!.agents['claude-code']!.costUSD, null);
  assert.deepEqual(result.pricing.unpricedModels, ['(unknown)']);
  fs.rmSync(ws.dir, { recursive: true, force: true });
});

test('Claude: a day that is only partly priceable reports no cost at all', async () => {
  const ws = makeWorkspace(
    [
      claudeLine({ ts: '2026-07-23T12:00:00Z', requestId: 'r1', msgId: 'm1', model: 'claude-opus-5', input: 1_000_000, output: 0 }),
      claudeLine({ ts: '2026-07-23T12:01:00Z', requestId: 'r2', msgId: 'm2', model: 'mystery-model', input: 1_000_000, output: 0 }),
    ],
    []
  );
  const result = await computeDailyUsage(7, ws);
  const day = findDay(result, '2026-07-23')!;
  // Reporting the $5 priced share would be a confident-looking under-report:
  // the UI cannot tell a partial total from a complete one.
  assert.equal(day.agents['claude-code']!.costUSD, null);
  assert.equal(day.agents['claude-code']!.uncachedInput, 2_000_000, 'tokens are still reported in full');
  assert.equal(result.pricing.pricedCalls, 1, 'coverage names the size of the gap');
  assert.equal(result.pricing.totalCalls, 2);
  assert.deepEqual(result.pricing.unpricedModels, ['mystery-model']);
  fs.rmSync(ws.dir, { recursive: true, force: true });
});

test('Claude: 1h cache writes bill at 2x input, not the 5m 1.25x rate', async () => {
  const ws = makeWorkspace(
    [
      claudeLine({
        ts: '2026-07-23T12:00:00Z', requestId: 'r', msgId: 'm',
        model: 'claude-opus-5', input: 0, output: 0,
        cacheWrite: 1_000_000, cacheWrite1h: 1_000_000,
      }),
    ],
    []
  );
  const day = findDay(await computeDailyUsage(7, ws), '2026-07-23')!;
  // 1M @ $6.25 (5m) + 1M @ $10.00 (1h) = $16.25. Charging both at 5m gives $12.50.
  assert.equal(day.agents['claude-code']!.costUSD, 16.25);
  assert.equal(day.agents['claude-code']!.cacheWrite, 2_000_000, 'display total still sums both TTLs');
  fs.rmSync(ws.dir, { recursive: true, force: true });
});

test('Claude: cache writes with no TTL breakdown fall back to the cheaper 5m rate', async () => {
  const ws = makeWorkspace(
    [
      claudeLine({
        ts: '2026-07-23T12:00:00Z', requestId: 'r', msgId: 'm',
        model: 'claude-opus-5', input: 0, output: 0,
        cacheWrite: 1_000_000, noCacheBreakdown: true,
      }),
    ],
    []
  );
  const day = findDay(await computeDailyUsage(7, ws), '2026-07-23')!;
  // An unknown TTL under-reports rather than inflates: $6.25, not $10.00.
  assert.equal(day.agents['claude-code']!.costUSD, 6.25);
  fs.rmSync(ws.dir, { recursive: true, force: true });
});

test('Claude: <synthetic> rows are excluded from cost and from coverage counts', async () => {
  const ws = makeWorkspace(
    [
      claudeLine({ ts: '2026-07-23T12:00:00Z', requestId: 'r1', msgId: 'm1', model: 'claude-opus-5', input: 1_000_000, output: 0 }),
      claudeLine({ ts: '2026-07-23T12:01:00Z', requestId: 'r2', msgId: 'm2', model: '<synthetic>', input: 9_000_000, output: 9_000_000 }),
    ],
    []
  );
  const result = await computeDailyUsage(7, ws);
  const day = findDay(result, '2026-07-23')!;
  assert.equal(day.agents['claude-code']!.costUSD, 5, 'synthetic tokens were never billed');
  assert.equal(day.agents['claude-code']!.uncachedInput, 1_000_000, 'synthetic tokens excluded from totals too');
  assert.equal(result.pricing.totalCalls, 1, 'and never counted as an unpriced gap');
  assert.deepEqual(result.pricing.unpricedModels, []);
  fs.rmSync(ws.dir, { recursive: true, force: true });
});

test('pricing coverage reports the table date', async () => {
  const ws = makeWorkspace([], []);
  const result = await computeDailyUsage(7, ws);
  assert.match(result.pricing.asOf, /^\d{4}-\d{2}-\d{2}$/);
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
