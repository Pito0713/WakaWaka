/**
 * shell-split.ts — the lexical half of Bash classification.
 *
 * Splitting a command chain correctly is a parsing problem in its own right,
 * separate from deciding what the pieces mean. Everything here answers "where
 * does one command end and the next begin", and every rule exists because a
 * naive split produced a wrong answer on real data: quoted separators, escaped
 * separators, line continuations, heredoc bodies, and `2>&1`.
 */

// ── Heredocs ──────────────────────────────────────────────────────────────────

const HEREDOC_START = /<<-?\s*(['"]?)([A-Za-z_][A-Za-z0-9_]*)\1/g;

/**
 * Removes heredoc bodies, keeping the line that opens them.
 *
 * A heredoc body is data, not commands. Left in place, `python3 <<'PY' … PY`
 * lets arbitrary script text be read as a shell chain — a body containing the
 * words `npm test` would score the call as `verify`.
 */
export function stripHeredocBodies(command: string): string {
  const lines = command.split('\n');
  const kept: string[] = [];
  let pending: string[] = [];

  for (const line of lines) {
    if (pending.length > 0) {
      if (line.trim() === pending[0]) pending.shift(); // closing delimiter
      continue; // body lines are data — drop them
    }
    kept.push(line);
    HEREDOC_START.lastIndex = 0;
    for (const match of line.matchAll(HEREDOC_START)) pending.push(match[2]);
  }
  return kept.join('\n');
}

// ── Chain splitting ───────────────────────────────────────────────────────────

/**
 * Splits on `&&`, `||`, `;`, `|`, `&` and newlines at the top level only.
 *
 * Quotes, `$(…)`, backticks and backslash escapes are all opaque, so neither
 * `grep "a || b"` nor `echo foo\;pytest` splits. Missing the escape case would
 * let any quoted data string containing `\;pytest` fake a verify segment.
 */
export function splitSegments(command: string): string[] {
  // A backslash-newline is a line continuation, not a command boundary.
  const source = stripHeredocBodies(command).replace(/\\\n/g, ' ');
  const segments: string[] = [];
  let current = '';
  let quote: '"' | "'" | null = null;
  let depth = 0;

  for (let i = 0; i < source.length; i++) {
    const ch = source[i];

    // Backslash escapes the next character everywhere except inside '…',
    // where the shell treats it literally.
    if (ch === '\\' && quote !== "'" && i + 1 < source.length) {
      current += ch + source[i + 1];
      i++;
      continue;
    }
    if (quote) {
      current += ch;
      if (ch === quote) quote = null;
      continue;
    }
    if (ch === '"' || ch === "'") { quote = ch; current += ch; continue; }
    if (ch === '`') { depth = depth === 0 ? 1 : 0; current += ch; continue; }
    if (ch === '$' && source[i + 1] === '(') { depth++; current += '$('; i++; continue; }
    if (ch === '(') { depth++; current += ch; continue; }
    if (ch === ')') { depth = Math.max(0, depth - 1); current += ch; continue; }

    if (depth === 0) {
      const two = source.slice(i, i + 2);
      if (two === '&&' || two === '||') { segments.push(current); current = ''; i++; continue; }
      // `2>&1` and `>&2` duplicate a descriptor — the `&` is not a separator.
      if (ch === '&' && current.trimEnd().endsWith('>')) { current += ch; continue; }
      if (ch === ';' || ch === '|' || ch === '&' || ch === '\n') { segments.push(current); current = ''; continue; }
    }
    current += ch;
  }
  segments.push(current);
  return segments.map((s) => s.trim()).filter(Boolean);
}

/** Whitespace split that keeps quoted runs together and drops the quote marks. */
export function tokenize(segment: string): string[] {
  const tokens: string[] = [];
  let current = '';
  let quote: '"' | "'" | null = null;

  for (let i = 0; i < segment.length; i++) {
    const ch = segment[i];
    if (ch === '\\' && quote !== "'" && i + 1 < segment.length) {
      current += segment[i + 1];
      i++;
      continue;
    }
    if (quote) {
      if (ch === quote) quote = null;
      else current += ch;
      continue;
    }
    if (ch === '"' || ch === "'") { quote = ch; continue; }
    if (/\s/.test(ch)) { if (current) { tokens.push(current); current = ''; } continue; }
    current += ch;
  }
  if (current) tokens.push(current);
  return tokens;
}

/** Redirect targets that discard output instead of writing anything. */
const NULL_SINKS = new Set(['/dev/null', '/dev/stdout', '/dev/stderr']);

/**
 * True when the segment redirects output into a real file.
 *
 * Three things that look like writes but are not: `2>&1` and `>&2` duplicate a
 * descriptor, and `2>/dev/null` discards output. That last one is the common
 * case by a wide margin — treating it as a write reclassified 28% of all real
 * Bash calls on this machine, nearly all of them plain `ls`/`cat` reads.
 */
export function writesViaRedirect(segment: string): boolean {
  let quote: '"' | "'" | null = null;
  for (let i = 0; i < segment.length; i++) {
    const ch = segment[i];
    if (ch === '\\' && quote !== "'" && i + 1 < segment.length) { i++; continue; }
    if (quote) { if (ch === quote) quote = null; continue; }
    if (ch === '"' || ch === "'") { quote = ch; continue; }
    if (ch !== '>') continue;

    const rest = segment.slice(i + 1).replace(/^>/, '').trimStart();
    if (rest.startsWith('&')) continue; // descriptor duplication
    const target = rest.split(/[\s;|&]/, 1)[0].replace(/^['"]|['"]$/g, '');
    if (!NULL_SINKS.has(target)) return true;
  }
  return false;
}
