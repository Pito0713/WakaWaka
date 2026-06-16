import { test } from 'node:test';
import assert from 'node:assert/strict';
import * as path from 'path';
import * as os from 'os';
import * as fs from 'fs';
import { fileURLToPath } from 'url';
import { calculateUsage, estimateCost, type UsageSnapshot, type PricingTable } from './usage-calculator.js';

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

const PRICING: PricingTable = {
  model: 'claude-sonnet-4-6',
  inputPerMTok: 3.0,
  outputPerMTok: 15.0,
  cacheReadPerMTok: 0.3,
  cacheCreationPerMTok: 3.75,
};

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

test('estimateCost: formula correct', () => {
  const usage: UsageSnapshot = {
    cumulativeInput: 1_000_000,
    cumulativeOutput: 1_000_000,
    cumulativeCacheRead: 1_000_000,
    cumulativeCacheCreation: 1_000_000,
    lastTurnDelta: null,
  };
  const cost = estimateCost(usage, PRICING);
  // 3.0 + 15.0 + 0.3 + 3.75 = 22.05
  assert.equal(cost, 22.05);
});
