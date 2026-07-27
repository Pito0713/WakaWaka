import { test } from 'node:test';
import assert from 'node:assert/strict';
import * as fs from 'node:fs';
import * as os from 'node:os';
import * as path from 'node:path';
import { spawn } from 'node:child_process';

const HOOK_PATH = new URL('./pretooluse-codex.mjs', import.meta.url).pathname;
const HOOK_CONFIG_PATH = new URL('../../.codex/hooks.json', import.meta.url).pathname;

function createHarness() {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'wakawaka-codex-hook-'));
  const stateDirectory = path.join(root, 'state');
  return {
    root,
    stateDirectory,
    environment: {
      WAKAWAKA_STATE_DIR: stateDirectory,
      WAKAWAKA_ALLOWLIST_PATH: path.join(root, 'allowlist.json'),
      WAKAWAKA_SETTINGS_PATH: path.join(root, 'settings.json'),
      WAKAWAKA_AUDIT_PATH: path.join(root, 'audit.jsonl'),
      POLL_INTERVAL_MS: '10',
      FINAL_TIMEOUT_MS: '2000',
    },
  };
}

function runHook(input, environment) {
  return runProcess(process.execPath, [HOOK_PATH], input, environment);
}

function runProcess(command, argumentsList, input, environment, workingDirectory) {
  const child = spawn(command, argumentsList, {
    env: { ...process.env, ...environment },
    stdio: ['pipe', 'pipe', 'pipe'],
    cwd: workingDirectory,
  });
  let stdout = '';
  child.stdout.on('data', (chunk) => { stdout += chunk; });
  child.stdin.end(JSON.stringify(input));
  const completed = new Promise((resolve) => {
    child.on('close', (code) => resolve({ code, output: JSON.parse(stdout) }));
  });
  return { child, completed };
}

function permission(result) {
  return result.output.hookSpecificOutput.permissionDecision;
}

async function waitForFile(filePath) {
  for (let attempts = 0; attempts < 100; attempts += 1) {
    if (fs.existsSync(filePath)) return;
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  throw new Error(`Timed out waiting for ${filePath}`);
}

async function reviewAction(input, expectedRisk, decision = { decision: 'allow' }, settings) {
  const harness = createHarness();
  if (settings) fs.writeFileSync(path.join(harness.root, 'settings.json'), JSON.stringify(settings));
  const toolUseId = input.tool_use_id ?? `tool-${input.session_id}`;
  const approvalId = `codex_${toolUseId.replace(/[^a-zA-Z0-9_-]/g, '_')}`;
  const pendingPath = path.join(harness.stateDirectory, `pending_${approvalId}.json`);
  const decisionPath = path.join(harness.stateDirectory, `decision_${approvalId}.json`);
  const running = runHook({ ...input, tool_use_id: toolUseId }, harness.environment);
  await waitForFile(pendingPath);
  const pending = JSON.parse(fs.readFileSync(pendingPath, 'utf8'));
  assert.equal(pending.risk_level, expectedRisk);
  fs.writeFileSync(decisionPath, JSON.stringify(decision));
  const result = await running.completed;
  const auditExists = fs.existsSync(path.join(harness.root, 'audit.jsonl'));
  fs.rmSync(harness.root, { recursive: true });
  return { result, pending, auditExists };
}

test('safe read Bash command is auto-allowed', async () => {
  const harness = createHarness();
  const running = runHook({
    session_id: 'safe-read',
    tool_name: 'Bash',
    tool_input: { command: 'rg hooks cost-aware-approval' },
  }, harness.environment);
  const result = await running.completed;
  assert.equal(permission(result), 'allow');
  assert.equal(fs.existsSync(harness.stateDirectory), false);
  fs.rmSync(harness.root, { recursive: true });
});

test('compound command with a safe prefix still requires review', async () => {
  const { result } = await reviewAction({
    session_id: 'compound-command',
    tool_name: 'Bash',
    tool_input: { command: 'rg hooks README.md; touch marker' },
  }, 'medium', { decision: 'deny' });
  assert.equal(permission(result), 'deny');
});

for (const [testName, command] of [
  ['rg --pre with a separate argument', "rg --pre 'touch marker' needle target"],
  ['rg --pre-glob with an equals argument', "rg --pre-glob='*.txt' needle target"],
]) {
  test(`${testName} requires review`, async () => {
    const { result } = await reviewAction({
      session_id: testName.replaceAll(' ', '-'),
      tool_name: 'Bash',
      tool_input: { command },
    }, 'medium', { decision: 'deny' });
    assert.equal(permission(result), 'deny');
  });
}

test('medium Bash command can be allowed by a decision', async () => {
  const { result } = await reviewAction({
    session_id: 'bash-allow',
    tool_name: 'Bash',
    tool_input: { command: 'cp source target' },
  }, 'medium');
  assert.equal(permission(result), 'allow');
});

test('medium Bash command can be denied by a decision', async () => {
  const { result } = await reviewAction({
    session_id: 'bash-deny',
    tool_name: 'Bash',
    tool_input: { command: 'cp source target' },
  }, 'medium', { decision: 'deny', reason: 'No copy' });
  assert.equal(permission(result), 'deny');
});

test('high Bash command requires review even with auto mode enabled', async () => {
  const { result } = await reviewAction({
    session_id: 'bash-high',
    tool_name: 'Bash',
    tool_input: { command: 'sudo service restart' },
  }, 'high', { decision: 'deny' }, {
    autoMode: { codex: { enabled: true } },
  });
  assert.equal(permission(result), 'deny');
});

test('critical Bash command is denied immediately', async () => {
  const harness = createHarness();
  const running = runHook({
    session_id: 'bash-critical',
    tool_name: 'Bash',
    tool_input: { command: 'rm -rf /' },
  }, harness.environment);
  const result = await running.completed;
  assert.equal(permission(result), 'deny');
  assert.equal(fs.existsSync(harness.stateDirectory), false);
  fs.rmSync(harness.root, { recursive: true });
});

for (const command of [
  'rm -rf -- /',
  'rm -r -f /',
  'rm --recursive --force /',
  'rm -rf "/"',
  '/bin/rm -rf /*',
]) {
  test(`${command} is denied as critical`, async () => {
    const harness = createHarness();
    const running = runHook({
      session_id: 'critical-rm-variant',
      tool_use_id: command,
      tool_name: 'Bash',
      tool_input: { command },
    }, harness.environment);
    const result = await running.completed;
    assert.equal(permission(result), 'deny');
    assert.equal(fs.existsSync(harness.stateDirectory), false);
    fs.rmSync(harness.root, { recursive: true });
  });
}

test('rm -rf of a non-root target is high and bypasses auto mode', async () => {
  const { result } = await reviewAction({
    session_id: 'high-rm',
    tool_name: 'Bash',
    tool_input: { command: 'rm -rf /tmp/x' },
  }, 'high', { decision: 'deny' }, {
    autoMode: { codex: { enabled: true } },
  });
  assert.equal(permission(result), 'deny');
});

for (const command of [
  'ls $(touch marker)',
  'ls `touch marker`',
]) {
  test(`${command} requires review`, async () => {
    const { result } = await reviewAction({
      session_id: 'shell-substitution',
      tool_name: 'Bash',
      tool_input: { command },
    }, 'medium', { decision: 'deny' });
    assert.equal(permission(result), 'deny');
  });
}

test('allowlisted rg --pre still requires review', async () => {
  const harness = createHarness();
  fs.writeFileSync(path.join(harness.root, 'allowlist.json'), JSON.stringify({ bashPrefixes: ['rg'] }));
  const input = {
    session_id: 'allowlisted-rg-pre',
    tool_use_id: 'allowlisted-rg-pre-call',
    tool_name: 'Bash',
    tool_input: { command: "rg --pre 'touch marker' needle target" },
  };
  const pendingPath = path.join(harness.stateDirectory, 'pending_codex_allowlisted-rg-pre-call.json');
  const decisionPath = path.join(harness.stateDirectory, 'decision_codex_allowlisted-rg-pre-call.json');
  const running = runHook(input, harness.environment);
  await waitForFile(pendingPath);
  fs.writeFileSync(decisionPath, JSON.stringify({ decision: 'deny' }));
  assert.equal(permission(await running.completed), 'deny');
  fs.rmSync(harness.root, { recursive: true });
});

for (const command of [
  "rg --pre 'touch marker' needle target",
  'ls $(touch marker)',
]) {
  test(`auto mode does not approve ${command}`, async () => {
    const { result, auditExists } = await reviewAction({
      session_id: 'unsafe-auto-command',
      tool_name: 'Bash',
      tool_input: { command },
    }, 'medium', { decision: 'deny' }, {
      autoMode: { codex: { enabled: true } },
    });
    assert.equal(permission(result), 'deny');
    assert.equal(auditExists, false);
  });
}

test('apply_patch preserves tool input for medium review', async () => {
  const toolInput = { command: '*** Begin Patch\n*** Add File: note.txt\n+hello\n*** End Patch' };
  const { result, pending } = await reviewAction({
    session_id: 'apply-patch',
    tool_name: 'apply_patch',
    tool_input: toolInput,
  }, 'medium');
  assert.deepEqual(pending.tool_input, toolInput);
  assert.equal(permission(result), 'allow');
});

test('unknown local or MCP tool cannot be auto-approved', async () => {
  const { result, pending } = await reviewAction({
    session_id: 'unknown-mcp',
    tool_name: 'mcp__example__send',
    tool_input: { message: 'hello' },
  }, 'medium', { decision: 'deny' }, {
    autoMode: { codex: { enabled: true } },
  });
  assert.equal(pending.agent, 'codex');
  assert.equal(permission(result), 'deny');
});

test('concurrent calls in one session use independent tool-use approval ids', async () => {
  const harness = createHarness();
  const baseInput = {
    session_id: 'shared-session',
    tool_name: 'Bash',
    tool_input: { command: 'cp source target' },
  };
  const first = runHook({ ...baseInput, tool_use_id: 'call-one' }, harness.environment);
  const second = runHook({ ...baseInput, tool_use_id: 'call-two' }, harness.environment);
  const firstPending = path.join(harness.stateDirectory, 'pending_codex_call-one.json');
  const secondPending = path.join(harness.stateDirectory, 'pending_codex_call-two.json');
  await Promise.all([waitForFile(firstPending), waitForFile(secondPending)]);
  const firstContent = JSON.parse(fs.readFileSync(firstPending, 'utf8'));
  assert.equal(firstContent.codex_session_id, 'shared-session');
  assert.equal(firstContent.tool_use_id, 'call-one');
  fs.writeFileSync(path.join(harness.stateDirectory, 'decision_codex_call-one.json'),
    JSON.stringify({ decision: 'allow' }));
  fs.writeFileSync(path.join(harness.stateDirectory, 'decision_codex_call-two.json'),
    JSON.stringify({ decision: 'deny' }));
  assert.equal(permission(await first.completed), 'allow');
  assert.equal(permission(await second.completed), 'deny');
  fs.rmSync(harness.root, { recursive: true });
});

test('timeout leaves tombstone and a later call cannot consume its stale decision', async () => {
  const harness = createHarness();
  const timeoutEnvironment = { ...harness.environment, FINAL_TIMEOUT_MS: '40', POLL_INTERVAL_MS: '5' };
  const first = runHook({
    session_id: 'timeout-session',
    tool_use_id: 'timed-out-call',
    tool_name: 'Bash',
    tool_input: { command: 'cp source target' },
  }, timeoutEnvironment);
  const firstResult = await first.completed;
  assert.equal(permission(firstResult), 'deny');
  const tombstonePath = path.join(harness.stateDirectory, 'pending_codex_timed-out-call.json');
  const tombstone = JSON.parse(fs.readFileSync(tombstonePath, 'utf8'));
  assert.equal(tombstone.hookExited, true);
  fs.writeFileSync(path.join(harness.stateDirectory, 'decision_codex_timed-out-call.json'),
    JSON.stringify({ decision: 'allow' }));

  const second = runHook({
    session_id: 'timeout-session',
    tool_name: 'Bash',
    tool_input: { command: 'cp source target' },
  }, { ...harness.environment, FINAL_TIMEOUT_MS: '1000' });
  let secondPendingPath;
  for (let attempts = 0; attempts < 100; attempts += 1) {
    const candidates = fs.readdirSync(harness.stateDirectory)
      .filter((name) => name.startsWith('pending_codex_') && name !== path.basename(tombstonePath));
    if (candidates.length > 0) {
      secondPendingPath = path.join(harness.stateDirectory, candidates[0]);
      break;
    }
    await new Promise((resolve) => setTimeout(resolve, 5));
  }
  assert.ok(secondPendingPath, 'later call must get a new random approval id');
  const secondApprovalId = path.basename(secondPendingPath).replace(/^pending_/, '').replace(/\.json$/, '');
  fs.writeFileSync(path.join(harness.stateDirectory, `decision_${secondApprovalId}.json`),
    JSON.stringify({ decision: 'deny' }));
  assert.equal(permission(await second.completed), 'deny');
  fs.rmSync(harness.root, { recursive: true });
});

test('repo hook command resolves and starts the Codex adapter from a nested cwd', async () => {
  const harness = createHarness();
  const config = JSON.parse(fs.readFileSync(HOOK_CONFIG_PATH, 'utf8'));
  assert.ok(config.hooks.Stop, 'existing Stop hook must be preserved');
  const hookCommand = config.hooks.PreToolUse[0].hooks[0].command;
  const running = runProcess('/bin/sh', ['-c', hookCommand], {
    session_id: 'config-smoke',
    tool_name: 'Bash',
    tool_input: { command: 'rg hooks README.md' },
  }, harness.environment, path.dirname(HOOK_PATH));
  const result = await running.completed;
  assert.equal(result.code, 0);
  assert.equal(permission(result), 'allow');
  fs.rmSync(harness.root, { recursive: true });
});
