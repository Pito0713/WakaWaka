/**
 * agent-registry.mjs — shared state for the "active agents" panel.
 *
 * Each live agent session owns one file under `~/.wakawaka/state/`:
 *
 *     agent_<kind>_<sessionId>.json
 *
 * Lifecycle hooks (SessionStart / UserPromptSubmit / Stop / SessionEnd) create,
 * update and delete it; `pretooluse.mjs` piggybacks a heartbeat on the call it
 * was already making, so the highest-frequency event costs no extra process.
 *
 * Two design rules the rest of the feature depends on:
 *
 *   1. **Metadata only.** Never write prompt text, tool input or tool output.
 *      `skill` holds a name, `lastTool` holds a tool name. This is what makes
 *      the privacy claim in the plan's §8 true, and it is the reason this
 *      approach replaced the earlier one that read transcript tails.
 *   2. **Every write is atomic** (temp file + rename), so WakaWaka polling the
 *      same directory once a second can never read half a JSON document.
 *
 * Liveness is decided by pid rather than by recency, because a crashed agent
 * leaves a file behind that looks identical to a live idle one. `pidStartedAt`
 * guards against pid reuse: a recycled pid has a different start time.
 */

import * as fs from 'node:fs';
import * as os from 'node:os';
import * as path from 'node:path';
import { spawnSync } from 'node:child_process';

/** Bump only for a breaking field change; readers refuse what they don't know. */
export const SCHEMA_VERSION = 1;

const STATE_DIR = process.env.WAKAWAKA_STATE_DIR
  ?? path.join(os.homedir(), '.wakawaka', 'state');

/**
 * True when this process was spawned by WakaWaka itself.
 *
 * `ParserRunner` shells out to `claude -p "/usage"` every ten minutes. Without
 * this guard that call registers as an agent session, and the panel blinks a
 * phantom Claude row on a timer.
 */
export function isInternalInvocation(env = process.env) {
  return env.WAKAWAKA_INTERNAL === '1';
}

/**
 * Session ids reach us from hook payloads, so they are untrusted input that
 * ends up in a filename. Anything that could escape the state directory or
 * collide with another file is rejected outright rather than sanitised — a
 * silently rewritten id would split one session across two registry files.
 */
export function isValidSessionId(sessionId) {
  return typeof sessionId === 'string'
    && sessionId.length > 0
    && sessionId.length <= 128
    && /^[A-Za-z0-9._-]+$/.test(sessionId)
    && sessionId !== '.'
    && sessionId !== '..';
}

const VALID_KINDS = new Set(['claude-code', 'codex']);

export function registryPath(kind, sessionId) {
  if (!VALID_KINDS.has(kind)) return null;
  if (!isValidSessionId(sessionId)) return null;
  return path.join(STATE_DIR, `agent_${kind}_${sessionId}.json`);
}

export function readEntry(kind, sessionId) {
  const file = registryPath(kind, sessionId);
  if (!file) return null;
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch {
    return null; // absent, unreadable, or half-written — treat as no entry
  }
}

/**
 * Writes the entry atomically: a temp file in the same directory, then
 * `rename`, which is atomic within a filesystem. The temp name carries the pid
 * so two hooks writing concurrently cannot collide on it.
 */
export function writeEntry(entry) {
  const file = registryPath(entry.kind, entry.sessionId);
  if (!file) return false;
  const temp = `${file}.${process.pid}.tmp`;
  try {
    fs.mkdirSync(STATE_DIR, { recursive: true, mode: 0o700 });
    fs.writeFileSync(temp, JSON.stringify(entry), { encoding: 'utf8', mode: 0o600 });
    fs.renameSync(temp, file);
    return true;
  } catch {
    try { fs.unlinkSync(temp); } catch { /* nothing to clean up */ }
    return false;
  }
}

export function deleteEntry(kind, sessionId) {
  const file = registryPath(kind, sessionId);
  if (!file) return false;
  try {
    fs.unlinkSync(file);
    return true;
  } catch {
    return false; // already gone
  }
}

/**
 * Read-modify-write of an existing entry.
 *
 * Returns false when there is no entry: only `SessionStart` creates one, so a
 * later event arriving without it means the session began before the hooks
 * were installed. Recreating it here would produce a row with no pid and no
 * start time, which the liveness check could never clear.
 */
export function updateEntry(kind, sessionId, mutate) {
  const current = readEntry(kind, sessionId);
  if (!current) return false;
  const next = { ...current, ...mutate(current), heartbeatAt: new Date().toISOString() };
  return writeEntry(next);
}

/**
 * Update, registering the session first when it has no entry yet.
 *
 * `SessionStart` is the only event that opens a window's registry file, so a
 * session that was already running when the hooks were installed — or whose
 * entry was swept while its window stayed open — could never appear in the
 * panel again. No amount of refreshing helps: the reader can only show files
 * that exist, and every later hook declined to write one.
 *
 * The original objection to writing here was that the entry would have no pid
 * and no start time, leaving a row the liveness check could never retire. That
 * does not apply when it is built exactly the way `SessionStart` builds it —
 * this hook is a child of the same agent process, so the parent walk finds the
 * same pid. The cost (a handful of `ps` calls) is paid once, on the event that
 * heals the session; afterwards this is an ordinary update.
 */
export function upsertEntry(payload, mutate) {
  const kind = detectKind(payload);
  const sessionId = detectSessionId(payload);
  if (!kind || !isValidSessionId(sessionId)) return false;
  if (updateEntry(kind, sessionId, mutate)) return true;

  const created = buildEntry({
    kind,
    sessionId,
    cwd: payload.cwd ?? process.cwd(),
    gitBranch: payload.gitBranch ?? null,
    model: payload.model ?? null,
  });
  return writeEntry({ ...created, ...mutate(created) });
}

// ── Process identity ──────────────────────────────────────────────────────────

/**
 * Process start time in epoch seconds, matching what `sysctl(KERN_PROC_PID)`
 * reports on the Swift side — that comparison is the pid-reuse guard.
 *
 * `LC_ALL=C` is not optional: `ps -o lstart=` is localised, and under a
 * non-English locale the output ("三 8月/12 21:32:35 2026") does not parse,
 * which would silently write a null start time and disable the guard.
 */
export function processStartedAt(pid) {
  try {
    const r = spawnSync('ps', ['-p', String(pid), '-o', 'lstart='], {
      encoding: 'utf8',
      env: { ...process.env, LC_ALL: 'C' },
      timeout: 2000,
    });
    if (r.status !== 0) return null;
    const parsed = Date.parse(r.stdout.trim());
    return Number.isFinite(parsed) ? Math.floor(parsed / 1000) : null;
  } catch {
    return null;
  }
}

/** `comm` values that identify an agent process rather than its shell wrapper. */
const AGENT_COMMANDS = [/(^|\/)claude$/, /(^|\/)codex$/, /(^|\/)node$/];

const MAX_PARENT_HOPS = 4;

/**
 * `{ ppid, comm }` for one pid. Both fields describe `pid` itself — `ppid` is
 * who its parent is, `comm` is what `pid` is running. Naming this `parentOf`
 * and returning `{ pid, comm }` read as though both described the parent, which
 * is a mix-up that survives review because the walk still lands correctly.
 */
function procInfo(pid) {
  try {
    const r = spawnSync('ps', ['-p', String(pid), '-o', 'ppid=,comm='], {
      encoding: 'utf8',
      env: { ...process.env, LC_ALL: 'C' },
      timeout: 2000,
    });
    if (r.status !== 0) return null;
    const line = r.stdout.trim();
    const match = line.match(/^(\d+)\s+(.*)$/);
    return match ? { ppid: Number(match[1]), comm: match[2].trim() } : null;
  } catch {
    return null;
  }
}

/**
 * Finds the agent process that owns this hook.
 *
 * Hooks are launched through a shell, so `process.ppid` is often a `sh` that
 * exits moments later — recording it would make every session look dead almost
 * immediately. Walk up the parent chain looking for the agent binary, bounded
 * so an unexpected process tree cannot spin.
 *
 * Falls back to the immediate parent when no match is found: a slightly wrong
 * pid still beats no liveness signal, and the 30-minute heartbeat sweep is the
 * backstop for that case.
 */
export function resolveAgentPid(startPid = process.ppid) {
  let pid = startPid;
  for (let hop = 0; hop < MAX_PARENT_HOPS; hop++) {
    const info = procInfo(pid);
    if (!info) break;
    // `comm` describes `pid`, so a match means this pid *is* the agent.
    if (AGENT_COMMANDS.some((re) => re.test(info.comm))) return pid;
    if (info.ppid <= 1) break;
    pid = info.ppid;
  }
  return startPid;
}

// ── Entry construction ────────────────────────────────────────────────────────

/** Replaces the home prefix with `~` so the panel and tooltips stay readable. */
export function abbreviateHome(dir) {
  if (typeof dir !== 'string' || !dir) return '';
  const home = os.homedir();
  return dir === home || dir.startsWith(`${home}/`) ? `~${dir.slice(home.length)}` : dir;
}

export function buildEntry({ kind, sessionId, cwd, gitBranch, model, pid }) {
  const now = new Date().toISOString();
  const resolvedPid = pid ?? resolveAgentPid();
  return {
    schema: SCHEMA_VERSION,
    kind,
    sessionId,
    cwd: abbreviateHome(cwd),
    gitBranch: gitBranch ?? null,
    model: model ?? null,
    pid: resolvedPid,
    pidStartedAt: processStartedAt(resolvedPid),
    state: 'idle',
    skill: null,
    skillSource: null,
    lastTool: null,
    startedAt: now,
    heartbeatAt: now,
  };
}

/** Reads one JSON object from stdin; hooks are invoked with the payload piped in. */
export async function readHookInput(stream = process.stdin) {
  const chunks = [];
  for await (const chunk of stream) chunks.push(chunk);
  try {
    return JSON.parse(Buffer.concat(chunks).toString('utf8'));
  } catch {
    return null;
  }
}

/**
 * `kind` for a payload. Claude Code and Codex share the lifecycle hooks, so the
 * agent is identified by which fields the payload carries rather than by having
 * separate scripts.
 */
export function detectKind(payload) {
  if (!payload || typeof payload !== 'object') return null;
  if (typeof payload.codex_session_id === 'string') return 'codex';
  if (typeof payload.agent === 'string' && VALID_KINDS.has(payload.agent)) return payload.agent;
  if (typeof payload.session_id === 'string') return 'claude-code';
  return null;
}

/**
 * Records a tool invocation against the session's registry entry.
 *
 * Called from `pretooluse.mjs` rather than from a hook of its own: PreToolUse
 * is by far the most frequent event, and piggybacking it means the heartbeat
 * costs no extra process spawn. Only the tool *name* is stored.
 *
 * Returns false when there is nothing to update — no entry, an internal
 * invocation, or an unusable payload. Callers must treat this as advisory:
 * the panel is cosmetic, the approval decision it rides along with is not.
 */
export function recordToolUse(payload) {
  if (isInternalInvocation()) return false;

  const kind = detectKind(payload);
  const sessionId = detectSessionId(payload);
  if (!kind || !isValidSessionId(sessionId)) return false;

  const toolName = typeof payload?.tool_name === 'string' ? payload.tool_name : null;
  // `Skill` names the skill in its input; every other tool contributes only
  // its own name. Nothing else from tool_input is read.
  const skillName = toolName === 'Skill' ? skillIdentifier(payload?.tool_input?.skill) : null;

  return updateEntry(kind, sessionId, () => (
    skillName
      ? { state: 'working', lastTool: toolName, skill: skillName, skillSource: 'tool' }
      : { state: 'working', lastTool: toolName }
  ));
}

/**
 * A skill name, or null if the value does not look like one.
 *
 * `tool_input.skill` is model-authored and unbounded. Copying it verbatim would
 * put arbitrary text — and its length — into a file this module promises holds
 * only metadata, so it is held to the same grammar as a slash command.
 */
export function skillIdentifier(value) {
  if (typeof value !== 'string') return null;
  return /^[A-Za-z0-9][A-Za-z0-9:_-]{0,63}$/.test(value) ? value : null;
}

/** The session id to key the registry on — Codex's own id, not the approval UUID. */
export function detectSessionId(payload) {
  if (!payload || typeof payload !== 'object') return null;
  const id = payload.codex_session_id ?? payload.session_id;
  return typeof id === 'string' ? id : null;
}
