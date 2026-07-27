import * as path from 'node:path';

const CRITICAL_PATTERNS = [
  /\bdd\b[^|&;\n]*\bof=\/dev\/(sd[a-z]+|nvme[0-9]+n[0-9]+|disk[0-9]+)/,
  /\b(mkfs|newfs)\b/,
  /:\(\)\s*\{[^}]*:\s*\|\s*:&/,
  />\s*\/dev\/(sd[a-z]+|nvme[0-9]+n[0-9]+|disk[0-9]+)(\s|$)/,
  /\bsudo\s+rm\b/,
];

const SHELL_EXECUTABLES = new Set(['sh', 'bash', 'dash', 'zsh', 'fish', 'csh', 'sush']);
const ENVIRONMENT_NO_ARGUMENT_OPTIONS = new Set(['-i', '--ignore-environment']);
const ENVIRONMENT_OPERAND_OPTIONS = new Set(['-u', '--unset', '-C', '--chdir']);

const HIGH_PATTERNS = [
  /\bsudo\b/,
  /\bgit\s+push\b[^|&;\n]*(--force|-f)\b/,
  /\bgit\s+reset\s+--hard\b/,
  /\bgit\s+clean\b[^|&;\n]*-[a-zA-Z]*f/,
  /\bchmod\b/,
  /\bchown\b/,
  /\bkill\b|\bpkill\b|\bkillall\b/,
  /\bnpm\s+(install|i)\s+(-g|--global)\b/,
  /\bpip3?\s+install\b(?!\s+--user)/,
  /\brsync\b[^|&;\n]*--delete\b/,
  /\bssh\s+/,
  /\bdrop\s+(database|table|schema)\b/i,
  /\btruncate\s+(table\s+)?\w/i,
];

function stripWrappingQuotes(token) {
  if (token.length < 2) return token;
  const hasDoubleQuotes = token.startsWith('"') && token.endsWith('"');
  const hasSingleQuotes = token.startsWith("'") && token.endsWith("'");
  return hasDoubleQuotes || hasSingleQuotes ? token.slice(1, -1) : token;
}

function isCatastrophicRmTarget(rawTarget) {
  const target = stripWrappingQuotes(rawTarget);
  if (target === '~' || target.startsWith('~/')) return true;
  if (target === '$HOME' || target.startsWith('$HOME/')) return true;
  if (target === '${HOME}' || target.startsWith('${HOME}/')) return true;
  const normalizedTarget = path.posix.normalize(target);
  if (target.startsWith('/') && normalizedTarget === '/') return true;
  return /^\/+(?:[*?]|\[)/.test(normalizedTarget);
}

function assessRmRisk(command) {
  const tokens = command.split(/\s+/);
  const rmIndex = tokens.findIndex((token) =>
    path.posix.basename(stripWrappingQuotes(token)) === 'rm');
  if (rmIndex < 0) return null;
  const argumentsList = tokens.slice(rmIndex + 1).map(stripWrappingQuotes);
  const hasRecursive = argumentsList.some((argument) =>
    argument === '--recursive' || /^-[^-]*r/.test(argument));
  const hasForce = argumentsList.some((argument) =>
    argument === '--force' || /^-[^-]*f/.test(argument));
  if (!hasRecursive || !hasForce) return null;
  return argumentsList.some(isCatastrophicRmTarget) ? 'critical' : 'high';
}

function tokenizeShellSegment(segment) {
  const tokens = [];
  let currentToken = '';
  let activeQuote = null;
  let isEscaped = false;
  for (const character of segment.trim()) {
    if (isEscaped) {
      currentToken += character;
      isEscaped = false;
    } else if (character === '\\' && activeQuote !== "'") {
      isEscaped = true;
    } else if (activeQuote && character === activeQuote) {
      activeQuote = null;
    } else if (!activeQuote && (character === '"' || character === "'")) {
      activeQuote = character;
    } else if (!activeQuote && /\s/.test(character)) {
      if (currentToken) tokens.push(currentToken);
      currentToken = '';
    } else {
      currentToken += character;
    }
  }
  if (isEscaped) currentToken += '\\';
  if (currentToken) tokens.push(currentToken);
  return tokens;
}

function getEnvironmentExecutable(tokens) {
  let tokenIndex = 1;
  while (tokenIndex < tokens.length) {
    const token = tokens[tokenIndex];
    if (token === '--') return tokens[tokenIndex + 1] ?? null;
    if (ENVIRONMENT_NO_ARGUMENT_OPTIONS.has(token)
        || /^--(?:unset|chdir)=/.test(token)
        || /^[a-zA-Z_][a-zA-Z0-9_]*=/.test(token)) {
      tokenIndex += 1;
      continue;
    }
    if (ENVIRONMENT_OPERAND_OPTIONS.has(token)) {
      tokenIndex += 2;
      continue;
    }
    return token;
  }
  return null;
}

function isShellExecutable(token) {
  if (!token) return false;
  return SHELL_EXECUTABLES.has(path.posix.basename(token));
}

function isDownloaderPipedToShell(command) {
  const downloaderPipe = /\b(?:curl|wget|fetch)\b[^|&;\n]*\|/.exec(command);
  if (!downloaderPipe) return false;
  const remainingCommand = command.slice(downloaderPipe.index + downloaderPipe[0].length);
  const firstPipeSegment = remainingCommand.split(/[|&;\n]/, 1)[0];
  const tokens = tokenizeShellSegment(firstPipeSegment);
  if (tokens.length === 0) return false;
  const firstExecutable = path.posix.basename(tokens[0]) === 'env'
    ? getEnvironmentExecutable(tokens)
    : tokens[0];
  return isShellExecutable(firstExecutable);
}

export function assessBashRisk(command) {
  const normalizedCommand = typeof command === 'string' ? command.trim() : '';
  const rmRisk = assessRmRisk(normalizedCommand);
  if (rmRisk) return rmRisk;
  if (isDownloaderPipedToShell(normalizedCommand)) return 'critical';
  if (CRITICAL_PATTERNS.some((pattern) => pattern.test(normalizedCommand))) return 'critical';
  if (HIGH_PATTERNS.some((pattern) => pattern.test(normalizedCommand))) return 'high';
  return 'medium';
}

export function getBashPrefix(command) {
  if (typeof command !== 'string') return null;
  return command.trim().split(/\s+/)[0] || null;
}

export function hasUnsafeShellSyntax(command) {
  return typeof command !== 'string'
    || /[|&;><\n]/.test(command)
    || /\$\(|`/.test(command)
    || (getBashPrefix(command) === 'rg'
      && /(?:^|\s)--pre(?:-glob)?(?:=|\s|$)/.test(command));
}

export function isSimpleShellCommand(command) {
  return !hasUnsafeShellSyntax(command);
}

export function sanitizeIdentifier(identifier) {
  return String(identifier).replace(/[^a-zA-Z0-9_-]/g, '_');
}

export async function readStdin() {
  const chunks = [];
  for await (const chunk of process.stdin) chunks.push(chunk);
  return Buffer.concat(chunks).toString('utf8').trim();
}
