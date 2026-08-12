import { test } from 'node:test';
import assert from 'node:assert/strict';
import * as path from 'path';
import * as os from 'os';
import * as fs from 'fs';
import { fileURLToPath } from 'url';
import { calculateUsage, bucketCost } from './usage-calculator.js';
import {
  loadPricing, emptyClaudeTokens, claudeModelPricing, splitCacheCreation, type ClaudeTokens,
} from './pricing.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const FIXTURE = path.join(__dirname, 'fixtures', 'sample.jsonl');

/*
  Fixture messages (only assistant rows with usage count):
  msg1: input=100, output=50,  cacheCreation=0,   cacheRead=0
  msg2: input=200, output=80,  cacheCreation=500, cacheRead=300
  msg3: input=150, output=60,  cacheCreation=0,   cacheRead=400

  Cumulative totals:
    input:          100 + 200 + 150 = 450
    output:          50 +  80 +  60 = 190
    cacheCreation:    0 + 500 +   0 = 500
    cacheRead:        0 + 300 + 400 = 700

  lastTurnDelta (msg3 - msg2 cumulative):
    input:  (450 - 250) = 150   [cumulative after msg3 minus after msg2]
    output: (190 - 130) = 60
*/

const PRICING = loadPricing();

function tokens(o: Partial<ClaudeTokens>): ClaudeTokens {
  return { ...emptyClaudeTokens(), ...o };
}

test('calculateUsage: cumulative totals correct', async () => {
  const usage = await calculateUsage(FIXTURE);
  assert.equal(usage.cumulativeInput, 450);
  assert.equal(usage.cumulativeOutput, 190);
  assert.equal(usage.cumulativeCacheCreation, 500);
  assert.equal(usage.cumulativeCacheRead, 700);
});

test('calculateUsage: lastTurnDelta correct', async () => {
  const usage = await calculateUsage(FIXTURE);
  assert.ok(usage.lastTurnDelta !== null);
  assert.equal(usage.lastTurnDelta!.input, 150);
  assert.equal(usage.lastTurnDelta!.output, 60);
});

test('calculateUsage: user messages (no usage) are skipped', async () => {
  // Fixture has 1 user line and 3 assistant lines; totals should only reflect 3
  const usage = await calculateUsage(FIXTURE);
  assert.equal(usage.cumulativeInput, 450, 'user line must not add to total');
});

test('calculateUsage: single-message file → lastTurnDelta equals that message', async () => {
  const tmp = path.join(os.tmpdir(), 'single.jsonl');
  fs.writeFileSync(tmp, '{"type":"assistant","message":{"usage":{"input_tokens":77,"output_tokens":33,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}\n');
  const usage = await calculateUsage(tmp);
  assert.equal(usage.lastTurnDelta?.input, 77);
  assert.equal(usage.lastTurnDelta?.output, 33);
  fs.unlinkSync(tmp);
});

test('calculateUsage: empty file → all zeros, null delta', async () => {
  const tmp = path.join(os.tmpdir(), 'empty.jsonl');
  fs.writeFileSync(tmp, '');
  const usage = await calculateUsage(tmp);
  assert.equal(usage.cumulativeInput, 0);
  assert.equal(usage.lastTurnDelta, null);
  fs.unlinkSync(tmp);
});

test('bucketCost: prices each token class at the model\'s own rate', () => {
  const buckets = new Map([
    ['claude-sonnet-4-6', tokens({
      uncachedInput: 1_000_000,
      output: 1_000_000,
      cacheRead: 1_000_000,
      cacheWrite5m: 1_000_000,
    })],
  ]);
  // 3.0 + 15.0 + 0.3 + 3.75 = 22.05
  assert.equal(bucketCost(buckets, PRICING), 22.05);
});

test('bucketCost: sums models independently rather than blending a rate', () => {
  const buckets = new Map([
    ['claude-opus-5', tokens({ uncachedInput: 1_000_000 })],   // $5
    ['claude-haiku-4-5', tokens({ uncachedInput: 1_000_000 })], // $1
  ]);
  assert.equal(bucketCost(buckets, PRICING), 6);
});

test('bucketCost: 1h cache writes cost 2x input, 5m writes 1.25x', () => {
  const write5m = new Map([['claude-opus-5', tokens({ cacheWrite5m: 1_000_000 })]]);
  const write1h = new Map([['claude-opus-5', tokens({ cacheWrite1h: 1_000_000 })]]);
  assert.equal(bucketCost(write5m, PRICING), 6.25);
  assert.equal(bucketCost(write1h, PRICING), 10);
});

test('bucketCost: unknown model → null, never a fallback rate', () => {
  const buckets = new Map([['totally-made-up', tokens({ uncachedInput: 1_000_000 })]]);
  assert.equal(bucketCost(buckets, PRICING), null);
});

test('bucketCost: one unknown model nulls the whole bucket, not just its share', () => {
  const buckets = new Map([
    ['claude-opus-5', tokens({ uncachedInput: 1_000_000 })],
    ['totally-made-up', tokens({ uncachedInput: 1_000_000 })],
  ]);
  // $5 of it is known, but reporting $5 would look like a complete total.
  assert.equal(bucketCost(buckets, PRICING), null);
});

test('pricing: a dated canonical model id resolves, not just the alias', () => {
  assert.ok(claudeModelPricing(PRICING, 'claude-haiku-4-5'), 'alias');
  assert.ok(claudeModelPricing(PRICING, 'claude-haiku-4-5-20251001'), 'canonical dated id');
});

test('pricing: introductory rates apply only until they lapse', () => {
  const intro = claudeModelPricing(PRICING, 'claude-sonnet-5', '2026-08-12')!;
  const standard = claudeModelPricing(PRICING, 'claude-sonnet-5', '2026-09-01')!;
  assert.equal(intro.inputPerMTok, 2, 'intro price in force before 2026-08-31');
  assert.equal(intro.outputPerMTok, 10);
  assert.equal(standard.inputPerMTok, 3, 'standard price from 2026-09-01');
  assert.equal(standard.outputPerMTok, 15);
});

test('pricing: a model with no scheduled change prices the same on any date', () => {
  const early = claudeModelPricing(PRICING, 'claude-opus-5', '2026-01-01')!;
  const late = claudeModelPricing(PRICING, 'claude-opus-5', '2030-01-01')!;
  assert.equal(early.inputPerMTok, late.inputPerMTok);
});

test('splitCacheCreation: the two TTL halves always sum to the billed total', () => {
  const cases = [
    { cache_creation_input_tokens: 3000, cache_creation: { ephemeral_5m_input_tokens: 1000, ephemeral_1h_input_tokens: 2000 } },
    // Breakdown claims more than the billed total — must not bill 150.
    { cache_creation_input_tokens: 100, cache_creation: { ephemeral_5m_input_tokens: 80, ephemeral_1h_input_tokens: 70 } },
    // Breakdown accounts for less than the total — remainder is charged as 5m.
    { cache_creation_input_tokens: 3000, cache_creation: { ephemeral_5m_input_tokens: 0, ephemeral_1h_input_tokens: 1000 } },
    { cache_creation_input_tokens: 500 },
  ];
  for (const usage of cases) {
    const { cacheWrite5m, cacheWrite1h } = splitCacheCreation(usage);
    const total = usage.cache_creation_input_tokens;
    assert.equal(cacheWrite5m + cacheWrite1h, total, `sum must equal total for ${JSON.stringify(usage)}`);
    assert.ok(cacheWrite5m >= 0 && cacheWrite1h >= 0, 'neither half may be negative');
  }
});

test('splitCacheCreation: corrupt negative counts clamp to zero, never negative cost', () => {
  const { cacheWrite5m, cacheWrite1h } = splitCacheCreation({ cache_creation_input_tokens: -10 });
  assert.equal(cacheWrite5m, 0);
  assert.equal(cacheWrite1h, 0);
});

test('bucketCost: empty bucket → null, not 0 (nothing measured ≠ free)', () => {
  assert.equal(bucketCost(new Map(), PRICING), null);
});

test('calculateUsage: buckets tokens under the row\'s model', async () => {
  const tmp = path.join(os.tmpdir(), `model-buckets-${process.pid}.jsonl`);
  fs.writeFileSync(
    tmp,
    '{"type":"assistant","message":{"model":"claude-opus-5","usage":{"input_tokens":1000000,"output_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}\n'
  );
  const { byModel } = await calculateUsage(tmp);
  assert.equal(byModel.cumulative.get('claude-opus-5')?.uncachedInput, 1_000_000);
  assert.equal(bucketCost(byModel.cumulative, PRICING), 5, 'priced as Opus 5, not Sonnet');
  fs.unlinkSync(tmp);
});

test('calculateUsage: <synthetic> rows are excluded entirely', async () => {
  const tmp = path.join(os.tmpdir(), `synthetic-${process.pid}.jsonl`);
  fs.writeFileSync(
    tmp,
    '{"type":"assistant","message":{"model":"<synthetic>","usage":{"input_tokens":9000000,"output_tokens":9000000,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}\n'
  );
  const usage = await calculateUsage(tmp);
  assert.equal(usage.cumulativeInput, 0, 'never-billed placeholder must not inflate totals');
  assert.equal(usage.byModel.cumulative.size, 0);
  fs.unlinkSync(tmp);
});

test('calculateUsage: splits cache creation by TTL from the breakdown block', async () => {
  const tmp = path.join(os.tmpdir(), `cache-ttl-${process.pid}.jsonl`);
  fs.writeFileSync(
    tmp,
    '{"type":"assistant","message":{"model":"claude-opus-5","usage":{"input_tokens":0,"output_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":3000,"cache_creation":{"ephemeral_5m_input_tokens":1000,"ephemeral_1h_input_tokens":2000}}}}\n'
  );
  const { byModel, cumulativeCacheCreation } = await calculateUsage(tmp);
  const bucket = byModel.cumulative.get('claude-opus-5')!;
  assert.equal(bucket.cacheWrite5m, 1000);
  assert.equal(bucket.cacheWrite1h, 2000);
  assert.equal(cumulativeCacheCreation, 3000, 'display total still collapses both TTLs');
  fs.unlinkSync(tmp);
});
