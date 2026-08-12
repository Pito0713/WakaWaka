import { test } from 'node:test';
import assert from 'node:assert/strict';
import * as path from 'path';
import * as os from 'os';
import * as fs from 'fs';
import { computePhaseUsage, type PhaseUsageResult, type Segment } from './phase-usage.js';
import { classifyCall, loadToolPhases, extractInvocations } from './phase-classify.js';

const NOW = new Date('2026-07-24T12:00:00Z');
const TABLE = loadToolPhases();

interface LineSpec {
  ts?: string;
  requestId?: string;
  msgId?: string;
  model?: string;
  output?: number;
  input?: number;
  cacheRead?: number;
  cacheWrite?: number;
  sidechain?: boolean;
  sessionId?: string;
  /** Tool invocations; `Bash` entries carry their command as the second item. */
  tools?: (string | [string, string])[];
  /** Emit a plain-string content (a reply with no tool blocks). */
  text?: string;
}

function line(o: LineSpec): string {
  const content: unknown = o.text !== undefined
    ? [{ type: 'text', text: o.text }]
    : (o.tools ?? []).map((t) =>
        Array.isArray(t)
          ? { type: 'tool_use', name: t[0], input: { command: t[1] } }
          : { type: 'tool_use', name: t, input: {} });
  return JSON.stringify({
    type: 'assistant',
    timestamp: o.ts ?? '2026-07-23T12:00:00Z',
    requestId: o.requestId,
    sessionId: o.sessionId ?? 'sess-1',
    cwd: '/workspace/my-project',
    isSidechain: o.sidechain ?? false,
    message: {
      id: o.msgId,
      model: o.model ?? 'claude-opus-5',
      content,
      usage: {
        input_tokens: o.input ?? 0,
        output_tokens: o.output ?? 0,
        cache_read_input_tokens: o.cacheRead ?? 0,
        cache_creation_input_tokens: o.cacheWrite ?? 0,
      },
    },
  });
}

function workspace(lines: string[]): { claudeDir: string; now: Date; dir: string } {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'phase-usage-test-'));
  const proj = path.join(dir, 'projects', 'proj');
  fs.mkdirSync(proj, { recursive: true });
  fs.writeFileSync(path.join(proj, 'a.jsonl'), lines.join('\n') + '\n');
  return { claudeDir: path.join(dir, 'projects'), now: NOW, dir };
}

async function run(lines: string[]): Promise<PhaseUsageResult> {
  const ws = workspace(lines);
  try {
    return await computePhaseUsage(7, ws);
  } finally {
    fs.rmSync(ws.dir, { recursive: true, force: true });
  }
}

/** The load-bearing invariant: buckets must reconstruct the segment total. */
function assertConserved(segment: Segment) {
  const fields = ['calls', 'output', 'uncachedInput', 'cacheRead', 'cacheWrite'] as const;
  for (const field of fields) {
    const summed = (['understand', 'develop', 'verify', 'reply', 'other'] as const)
      .reduce((sum, phase) => sum + segment.phases[phase][field], 0);
    assert.equal(summed, segment.total[field], `${field} must sum to the segment total`);
  }
  for (const phase of ['understand', 'develop', 'verify', 'reply', 'other'] as const) {
    const bucket = segment.phases[phase];
    assert.equal(bucket.direct.calls + bucket.sidechain.calls, bucket.calls, `${phase} direct+sidechain calls`);
    assert.equal(bucket.direct.output + bucket.sidechain.output, bucket.output, `${phase} direct+sidechain output`);
  }
}

// ── §11-1..3 Attribution ─────────────────────────────────────────────────────

test('same (requestId,msgId) written three times counts once, with the last usage', async () => {
  const result = await run([
    line({ requestId: 'r1', msgId: 'm1', ts: '2026-07-23T12:00:00Z', output: 100, tools: ['Read'] }),
    line({ requestId: 'r1', msgId: 'm1', ts: '2026-07-23T12:00:01Z', output: 150, tools: ['Read'] }),
    line({ requestId: 'r1', msgId: 'm1', ts: '2026-07-23T12:00:02Z', output: 200, tools: ['Read'] }),
  ]);
  const segment = result.segments[0];
  assert.equal(segment.total.calls, 1, 'one API call, not three');
  assert.equal(segment.total.output, 200, 'last write wins, not first (100) or sum (450)');
  assertConserved(segment);
});

test('tool content is the union across writes, not just the first record', async () => {
  // The first streaming write has no tool blocks yet. Taking only that record
  // would classify this call as `reply` — the failure the plan calls out.
  const result = await run([
    line({ requestId: 'r1', msgId: 'm1', ts: '2026-07-23T12:00:00Z', output: 10, text: 'thinking' }),
    line({ requestId: 'r1', msgId: 'm1', ts: '2026-07-23T12:00:01Z', output: 90, tools: ['Edit'] }),
  ]);
  const segment = result.segments[0];
  assert.equal(segment.phases.develop.calls, 1, 'the Edit from the later write must count');
  assert.equal(segment.phases.reply.calls, 0);
  assertConserved(segment);
});

test('out-of-order timestamps still resolve to the newest usage', async () => {
  const result = await run([
    line({ requestId: 'r1', msgId: 'm1', ts: '2026-07-23T12:00:05Z', output: 200, tools: ['Read'] }),
    line({ requestId: 'r1', msgId: 'm1', ts: '2026-07-23T12:00:01Z', output: 50, tools: ['Read'] }),
  ]);
  assert.equal(result.segments[0].total.output, 200);
});

test('records missing requestId/msgId are never merged together', async () => {
  const result = await run([
    line({ output: 10, tools: ['Read'] }),
    line({ output: 20, tools: ['Read'] }),
  ]);
  const segment = result.segments[0];
  assert.equal(segment.total.calls, 2);
  assert.equal(segment.total.output, 30);
});

// ── §11-4..5 Conservation and exclusion ──────────────────────────────────────

test('five buckets sum to the segment total across a mixed workload', async () => {
  const result = await run([
    line({ requestId: 'a', msgId: 'a', output: 10, cacheRead: 5, cacheWrite: 1, tools: ['Read'] }),
    line({ requestId: 'b', msgId: 'b', output: 20, cacheRead: 6, cacheWrite: 2, tools: ['Edit'] }),
    line({ requestId: 'c', msgId: 'c', output: 30, cacheRead: 7, cacheWrite: 3, tools: [['Bash', 'pytest']] }),
    line({ requestId: 'd', msgId: 'd', output: 40, cacheRead: 8, cacheWrite: 4, text: 'here you go' }),
    line({ requestId: 'e', msgId: 'e', output: 50, cacheRead: 9, cacheWrite: 5, tools: ['MysteryTool'] }),
  ]);
  const segment = result.segments[0];
  assert.equal(segment.total.calls, 5);
  assert.equal(segment.total.output, 150);
  assertConserved(segment);
  assert.equal(segment.phases.understand.calls, 1);
  assert.equal(segment.phases.develop.calls, 1);
  assert.equal(segment.phases.verify.calls, 1);
  assert.equal(segment.phases.reply.calls, 1);
  assert.equal(segment.phases.other.calls, 1);
});

test('<synthetic> rows and rows without usage are excluded from every bucket', async () => {
  const result = await run([
    line({ requestId: 'a', msgId: 'a', output: 10, tools: ['Read'] }),
    line({ requestId: 's', msgId: 's', model: '<synthetic>', output: 9999, tools: ['Read'] }),
    JSON.stringify({ type: 'assistant', timestamp: '2026-07-23T12:00:00Z', message: { model: 'claude-opus-5', content: [] } }),
  ]);
  const segment = result.segments[0];
  assert.equal(segment.total.output, 10, 'synthetic tokens never entered a bucket');
  assert.equal(result.diagnostics.excluded.synthetic, 1);
  assert.equal(result.diagnostics.excluded.noUsage, 1);
  assertConserved(segment);
});

test('a streamed <synthetic> call is excluded once, not once per write', async () => {
  const result = await run([
    line({ requestId: 's', msgId: 's', ts: '2026-07-23T12:00:00Z', model: '<synthetic>', output: 1 }),
    line({ requestId: 's', msgId: 's', ts: '2026-07-23T12:00:01Z', model: '<synthetic>', output: 2 }),
  ]);
  assert.equal(result.diagnostics.excluded.synthetic, 1);
});

// ── §11-6..7 Classification and priority ─────────────────────────────────────

test('mixed tools follow develop > verify > understand > other', () => {
  assert.equal(classifyCall([{ name: 'Read' }, { name: 'Edit' }], TABLE).phase, 'develop');
  assert.equal(classifyCall([{ name: 'Read' }, { name: 'Bash', command: 'pytest' }], TABLE).phase, 'verify');
  assert.equal(classifyCall([{ name: 'Read' }, { name: 'Mystery' }], TABLE).phase, 'understand');
});

test('a mixed call is reported in mixedCalls with its tool combination', async () => {
  const result = await run([
    line({ requestId: 'a', msgId: 'a', output: 10, tools: ['Read', 'Edit'] }),
  ]);
  assert.deepEqual(result.diagnostics.mixedCalls, [{ combo: 'Edit+Read', calls: 1 }]);
});

test('a single-tool call is not reported as mixed', async () => {
  const result = await run([line({ requestId: 'a', msgId: 'a', output: 10, tools: ['Read'] })]);
  assert.deepEqual(result.diagnostics.mixedCalls, []);
});

test('a response with no tool_use is reply, not other', async () => {
  const result = await run([line({ requestId: 'a', msgId: 'a', output: 40, text: 'the answer is 42' })]);
  const segment = result.segments[0];
  assert.equal(segment.phases.reply.output, 40);
  assert.equal(segment.phases.other.output, 0, 'plain answers must not pollute the unclassified bucket');
});

// ── §11-8..11 Bash routed through the shell classifier ───────────────────────

test('Bash phase comes from the parsed command, not the tool name', async () => {
  const result = await run([
    line({ requestId: 'a', msgId: 'a', output: 10, tools: [['Bash', 'cd app && npm test']] }),
    line({ requestId: 'b', msgId: 'b', output: 20, tools: [['Bash', 'rg TODO src']] }),
    line({ requestId: 'c', msgId: 'c', output: 30, tools: [['Bash', 'npm run dev']] }),
  ]);
  const segment = result.segments[0];
  assert.equal(segment.phases.verify.output, 10);
  assert.equal(segment.phases.understand.output, 20);
  assert.equal(segment.phases.other.output, 30);
});

test('an unjudgeable Bash command is listed in unknownBash by head token', async () => {
  const result = await run([
    line({ requestId: 'a', msgId: 'a', output: 30, tools: [['Bash', 'frobnicate --all']] }),
  ]);
  assert.deepEqual(result.diagnostics.unknownBash, [{ head: 'frobnicate', calls: 1, output: 30 }]);
});

// ── §11-12 MCP and unknown tools ─────────────────────────────────────────────

test('an unmapped tool lands in other and is named in unclassifiedTools', async () => {
  const result = await run([
    line({ requestId: 'a', msgId: 'a', output: 50, tools: ['SomeNewTool'] }),
  ]);
  assert.equal(result.segments[0].phases.other.output, 50);
  assert.deepEqual(result.diagnostics.unclassifiedTools, [{ name: 'SomeNewTool', calls: 1, output: 50 }]);
});

test('a mapped MCP prefix lands in other WITHOUT being called unclassified', async () => {
  const result = await run([
    line({ requestId: 'a', msgId: 'a', output: 50, tools: ['mcp__claude-in-chrome__navigate'] }),
  ]);
  assert.equal(result.segments[0].phases.other.output, 50);
  assert.deepEqual(result.diagnostics.unclassifiedTools, [], 'the table has an opinion, so it is not a gap');
});

// ── Sidechain, cost, segments, diagnostics ───────────────────────────────────

test('sidechain work splits within its bucket rather than forming a sixth', async () => {
  const result = await run([
    line({ requestId: 'a', msgId: 'a', output: 10, tools: ['Read'] }),
    line({ requestId: 'b', msgId: 'b', output: 90, tools: ['Read'], sidechain: true }),
  ]);
  const understand = result.segments[0].phases.understand;
  assert.equal(understand.output, 100, 'the session total includes subagent work');
  assert.equal(understand.direct.output, 10);
  assert.equal(understand.sidechain.output, 90);
});

test('cost is priced per model and nulled by an unpriceable call', async () => {
  const priced = await run([
    line({ requestId: 'a', msgId: 'a', model: 'claude-opus-5', input: 1_000_000, tools: ['Read'] }),
  ]);
  assert.equal(priced.segments[0].phases.understand.costUSD, 5);
  assert.equal(priced.diagnostics.pricedCalls, 1);

  const unpriced = await run([
    line({ requestId: 'a', msgId: 'a', model: 'claude-opus-5', input: 1_000_000, tools: ['Read'] }),
    line({ requestId: 'b', msgId: 'b', model: 'made-up-model', input: 1_000_000, tools: ['Read'] }),
  ]);
  assert.equal(unpriced.segments[0].phases.understand.costUSD, null);
  assert.equal(unpriced.diagnostics.pricedCalls, 1);
  assert.equal(unpriced.diagnostics.totalCalls, 2);
});

test('calls group into one segment per session, labelled by working directory', async () => {
  const result = await run([
    line({ requestId: 'a', msgId: 'a', sessionId: 's1', output: 10, tools: ['Read'] }),
    line({ requestId: 'b', msgId: 'b', sessionId: 's2', output: 90, tools: ['Read'] }),
  ]);
  assert.equal(result.segments.length, 2);
  assert.equal(result.segments[0].id, 's2', 'ordered by output, largest first');
  assert.equal(result.segments[0].label, 'my-project');
});

test('startedAt is the segment\'s earliest call', async () => {
  const result = await run([
    line({ requestId: 'b', msgId: 'b', ts: '2026-07-23T15:00:00Z', output: 10, tools: ['Read'] }),
    line({ requestId: 'a', msgId: 'a', ts: '2026-07-23T09:00:00Z', output: 10, tools: ['Read'] }),
  ]);
  assert.equal(result.segments[0].startedAt, '2026-07-23T09:00:00Z');
});

test('unknownRate is the output share of other, and warns past 25%', async () => {
  const result = await run([
    line({ requestId: 'a', msgId: 'a', output: 70, tools: ['MysteryTool'] }),
    line({ requestId: 'b', msgId: 'b', output: 30, tools: ['Read'] }),
  ]);
  assert.equal(result.diagnostics.unknownRate, 0.7);
  assert.ok(result.warnings.some((w) => w.includes('unknownRate')), 'must flag an unusable classification rate');
});

test('a well-classified run carries no unknownRate warning', async () => {
  const result = await run([line({ requestId: 'a', msgId: 'a', output: 100, tools: ['Read'] })]);
  assert.equal(result.diagnostics.unknownRate, 0);
  assert.ok(!result.warnings.some((w) => w.includes('unknownRate')));
});

test('the report always warns against reading output as effort', async () => {
  const result = await run([line({ requestId: 'a', msgId: 'a', output: 10, tools: ['Read'] })]);
  assert.ok(result.warnings.some((w) => w.includes('output token')));
});

// ── §11-17..18 Robustness ────────────────────────────────────────────────────

test('an empty corpus yields a legal empty result', async () => {
  const result = await run([]);
  assert.deepEqual(result.segments, []);
  assert.equal(result.diagnostics.unknownRate, 0);
  assert.equal(result.granularity, 'session');
});

test('a corrupt JSON line is skipped without aborting the file', async () => {
  const result = await run([
    line({ requestId: 'a', msgId: 'a', output: 10, tools: ['Read'] }),
    '{ this is not json',
    line({ requestId: 'b', msgId: 'b', output: 20, tools: ['Read'] }),
  ]);
  assert.equal(result.segments[0].total.calls, 2, 'lines after the corrupt one still count');
});

// ── Adversarial-review regressions (stage 2/3 cross-check) ───────────────────

test('a record with tool content but no usage still contributes its tools', async () => {
  // The tool_use lives on a record that carries no usage; the usage-bearing
  // record is text-only. Reading them independently classifies this as `reply`.
  const withTools = JSON.stringify({
    type: 'assistant', timestamp: '2026-07-23T12:00:00Z', requestId: 'r1', sessionId: 'sess-1',
    message: { id: 'm1', model: 'claude-opus-5', content: [{ type: 'tool_use', name: 'Edit', input: {} }] },
  });
  const result = await run([
    withTools,
    line({ requestId: 'r1', msgId: 'm1', ts: '2026-07-23T12:00:01Z', output: 100, text: 'done' }),
  ]);
  const segment = result.segments[0];
  assert.equal(segment.phases.develop.calls, 1, 'the Edit must survive its record having no usage');
  assert.equal(segment.phases.reply.calls, 0);
  assert.equal(result.diagnostics.excluded.noUsage, 0, 'that record is half of a counted call, not an exclusion');
  assertConserved(segment);
});

test('exclusions are counted per call, not per streaming record', async () => {
  const noUsage = (line_: string) => line_;
  const result = await run([
    // Two records of ONE call, neither carrying usage → one excluded call.
    noUsage(JSON.stringify({
      type: 'assistant', timestamp: '2026-07-23T12:00:00Z', requestId: 'r9', sessionId: 's',
      message: { id: 'm9', model: 'claude-opus-5', content: [] },
    })),
    noUsage(JSON.stringify({
      type: 'assistant', timestamp: '2026-07-23T12:00:01Z', requestId: 'r9', sessionId: 's',
      message: { id: 'm9', model: 'claude-opus-5', content: [] },
    })),
  ]);
  assert.equal(result.diagnostics.excluded.noUsage, 1, 'one call, not two records');
});

test('records outside the window are ignored, not counted as exclusions', async () => {
  const result = await run([
    line({ requestId: 'a', msgId: 'a', ts: '2026-07-23T12:00:00Z', output: 10, tools: ['Read'] }),
    // Well before the 7-day window, and carrying no usage.
    JSON.stringify({
      type: 'assistant', timestamp: '2020-01-01T00:00:00Z', requestId: 'old', sessionId: 's',
      message: { id: 'old', model: 'claude-opus-5', content: [] },
    }),
  ]);
  assert.equal(result.diagnostics.excluded.noUsage, 0, 'excluded must describe the reported window');
  assert.equal(result.segments[0].total.calls, 1);
});

test('equal timestamps resolve deterministically, not by traversal order', async () => {
  const lines = [
    line({ requestId: 'r', msgId: 'm', ts: '2026-07-23T12:00:00Z', output: 10, tools: ['Read'] }),
    line({ requestId: 'r', msgId: 'm', ts: '2026-07-23T12:00:00Z', output: 20, tools: ['Read'] }),
  ];
  const first = await run(lines);
  const second = await run(lines);
  assert.equal(first.segments[0].total.output, second.segments[0].total.output);
  assert.equal(first.segments[0].total.output, 20, 'later line wins the tie');
});

test('extractInvocations ignores non-tool content blocks', () => {
  assert.deepEqual(extractInvocations('plain string'), []);
  assert.deepEqual(extractInvocations([{ type: 'text', text: 'hi' }]), []);
  assert.deepEqual(extractInvocations([{ type: 'tool_use', name: 'Read', input: {} }]), [{ name: 'Read' }]);
});
