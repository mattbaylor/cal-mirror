// The claim that matters most, checked against the artifact rather than the
// intent: this page talks to nobody.
//
// Step 2 is "done when it ... makes no network request of any kind", and a
// README cannot enforce that. Grepping the built bundle can. It runs on every
// build, so the first line that reaches for the network fails here rather than
// in a privacy policy.

import { readFileSync, readdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { join } from 'node:path';

const dist = fileURLToPath(new URL('../dist', import.meta.url));

// Every way a page can start a request. `import(` is here because a dynamic
// import of a chunk is a network fetch wearing different clothes.
const FORBIDDEN = [
  [/\bfetch\s*\(/, 'fetch()'],
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
