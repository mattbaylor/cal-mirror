// The claim that matters most, checked against the artifact rather than the
// intent: this page talks to nobody but the host it came from.
//
// Step 2 was "makes no network request of any kind", and this file enforced
// that literally. Step 3 gave the page two calls to make — the dump and the
// submission — so the claim is now the one that was always meant: nothing
// leaves for a third party. A README cannot enforce that. Grepping the built
// bundle can: every `fetch(` must target a same-origin path literal, every
// other way to start a request is still forbidden, and no absolute URL may
// appear at all. It runs on every build, so the first line that reaches for
// somebody else's server fails here rather than in a privacy policy.

import { readFileSync, readdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { join } from 'node:path';

const dist = fileURLToPath(new URL('../dist', import.meta.url));

// Every way a page can start a request. `import(` is here because a dynamic
// import of a chunk is a network fetch wearing different clothes.
const FORBIDDEN = [
  [/XMLHttpRequest/, 'XMLHttpRequest'],
  [/\bWebSocket\b/, 'WebSocket'],
  [/EventSource/, 'EventSource'],
  [/sendBeacon/, 'navigator.sendBeacon()'],
  [/\bimport\s*\(/, 'dynamic import()'],
  [/navigator\.serviceWorker/, 'service worker registration'],
];

// Any absolute URL in a script or markup is a request waiting to happen. The
// two exceptions are namespaces, which are identifiers and never fetched.
const URL_PATTERN = /(?:https?:)?\/\/[a-z0-9.-]+\.[a-z]{2,}/gi;
const NAMESPACES = new Set(['http://www.w3.org', '//www.w3.org']);

const problems = [];

for (const file of readdirSync(dist)) {
  if (!/\.(js|html|css)$/.test(file)) continue;
  const source = readFileSync(join(dist, file), 'utf8');

  for (const [pattern, label] of FORBIDDEN) {
    if (pattern.test(source)) problems.push(`${file}: uses ${label}`);
  }

  // fetch() is allowed exactly one shape: a path literal on this origin as
  // its first argument — `fetch("/p/...")`, `fetch(\`/v1/...\`)`. A variable, a
  // computed string or anything starting other than "/" is a request whose
  // destination this check cannot read, and so is refused.
  for (const call of source.match(/\bfetch\s*\([^)]{0,40}/g) ?? []) {
    if (!/^fetch\s*\(\s*["'`]\/(?!\/)/.test(call)) {
      problems.push(`${file}: fetch whose target is not a same-origin path literal: ${call}`);
    }
  }

  for (const match of source.match(URL_PATTERN) ?? []) {
    const origin = match.replace(/(\/\/[^/]+).*/, '$1');
    if (NAMESPACES.has(match) || NAMESPACES.has(origin)) continue;
    problems.push(`${file}: references ${match}`);
  }

  if (/\.(js|css|woff2?|ttf)['"]\s*\)/.test(source) && /url\(/.test(source)) {
    problems.push(`${file}: loads an external asset through url()`);
  }
}

// The markup must not pull anything in either, including a font.
for (const file of readdirSync(dist).filter((f) => f.endsWith('.html'))) {
  const source = readFileSync(join(dist, file), 'utf8');
  for (const attr of source.match(/\b(?:src|href)\s*=\s*"([^"]*)"/gi) ?? []) {
    const value = attr.replace(/.*"([^"]*)"$/, '$1');
    if (/^\.?\//.test(value) || value.startsWith('#') || value === '') continue;
    problems.push(`${file}: <… ${attr}> points off-origin`);
  }
}

if (problems.length) {
  console.error('The built page reaches outside itself:\n  ' + problems.join('\n  '));
  process.exit(1);
}

console.log(`no-network: clean (${readdirSync(dist).join(', ')})`);
