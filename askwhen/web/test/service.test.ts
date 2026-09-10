// The two calls, against a stand-in for the service. What is asserted is the
// contract the Go side actually implements (internal/api/requests.go and the
// dump route), not a guess at it: paths, method, body shape, and how each
// status the service can return becomes a state the page has.

import { test, beforeEach, afterEach } from 'node:test';
import assert from 'node:assert/strict';

import { fetchDump, submitRequest } from '../src/service.ts';

// What service.ts actually passes: a plain headers object and a string body.
type Init = { method?: string; headers: Record<string, string>; body: string; cache?: string };
type Call = { url: string; init: Init };
type Answer = { ok: boolean; status: number; headers: Map<string, string>; json: () => Promise<unknown> };

let calls: Call[] = [];
const realFetch = globalThis.fetch;

function answer(status: number, body: unknown, headers: Record<string, string> = {}): Answer {
  return {
    ok: status >= 200 && status < 300,
    status,
    headers: new Map(Object.entries(headers)),
    json: async () => {
      if (typeof body !== 'string') return body;
      return JSON.parse(body) as unknown;
    },
  };
}

beforeEach(() => {
  calls = [];
});
afterEach(() => {
  globalThis.fetch = realFetch;
});

function stub(...answers: (Answer | Error)[]) {
  // The stand-in answers with the four fields service.ts reads; it is not a
  // whole Response and does not pretend to be.
  globalThis.fetch = (async (url: string, init: Partial<Init> = {}) => {
    calls.push({ url, init: { headers: {}, body: '', ...init } });
    const a = answers.shift();
    if (a instanceof Error) throw a;
    return a;
  }) as unknown as typeof fetch;
}

test('fetchDump asks for /p/{slug}.json on this origin and returns the document', async () => {
  stub(answer(200, { v: 1, slug: 'x7f2k9', slots: [] }));
  const dump = await fetchDump('x7f2k9');
  assert.equal(calls[0].url, '/p/x7f2k9.json');
  assert.equal(calls[0].init.headers.accept, 'application/json');
  assert.deepEqual(dump, { v: 1, slug: 'x7f2k9', slots: [] });
});

test('fetchDump: 404, 5xx and no network are all "no page here" — §4c', async () => {
  stub(answer(404, ''));
  assert.equal(await fetchDump('zzzzzz'), null);
  stub(answer(503, ''));
  assert.equal(await fetchDump('x7f2k9'), null);
  stub(new TypeError('Failed to fetch'));
  assert.equal(await fetchDump('x7f2k9'), null);
});

test('submitRequest posts the fields the service reads, by their wire names', async () => {
  stub(answer(202, { ok: true, message: 'Check your email.' }));
  const r = await submitRequest('x7f2k9', {
    slot: '2026-09-12T16:00:00Z',
    name: 'Ada',
    email: 'ada@example.com',
    note: 'hi',
    trapped: false,
  });
  assert.deepEqual(r, { ok: true });
  assert.equal(calls[0].url, '/v1/pages/x7f2k9/requests');
  assert.equal(calls[0].init.method, 'POST');
  assert.equal(calls[0].init.headers['content-type'], 'application/json');
  assert.deepEqual(JSON.parse(calls[0].init.body), {
    slot: '2026-09-12T16:00:00Z',
    name: 'Ada',
    email: 'ada@example.com',
    note: 'hi',
    trapped: false,
  });
});

test('a trapped submission goes up like any other; the service drops it', async () => {
  stub(answer(202, { ok: true }));
  await submitRequest('x7f2k9', { slot: 's', name: 'n', email: 'e', trapped: true });
  assert.equal(JSON.parse(calls[0].init.body).trapped, true);
});

test('every status the service returns becomes a reason the page has a state for', async () => {
  const body = { slot: 's', name: 'n', email: 'e' };
  stub(answer(409, { ok: false, reason: 'held', message: 'Someone just asked.' }));
  assert.deepEqual(await submitRequest('x7f2k9', body), { ok: false, reason: 'held' });
  stub(answer(409, { ok: false, reason: 'slot', message: 'Not offered.' }));
  assert.deepEqual(await submitRequest('x7f2k9', body), { ok: false, reason: 'slot' });
  stub(answer(429, { ok: false, reason: 'rate' }));
  assert.deepEqual(await submitRequest('x7f2k9', body), { ok: false, reason: 'rate' });
  stub(answer(404, ''));
  assert.deepEqual(await submitRequest('x7f2k9', body), { ok: false, reason: 'gone' });
  stub(answer(400, { ok: false, reason: 'email', message: 'Bad address.' }));
  assert.deepEqual(await submitRequest('x7f2k9', body), { ok: false, reason: 'failed' });
  stub(answer(503, 'not json'));
  assert.deepEqual(await submitRequest('x7f2k9', body), { ok: false, reason: 'failed' });
  stub(new TypeError('Failed to fetch'));
  assert.deepEqual(await submitRequest('x7f2k9', body), { ok: false, reason: 'failed' });
});

test('slugFromLocation: a path slug, a query slug, the host sentinel, or the example on file://', async () => {
  const { slugFromLocation, DEFAULT_SLUG } = await import('../src/slug.ts');
  const at = (protocol: string, pathname: string, search = '') =>
    slugFromLocation({ protocol, pathname, search });
  assert.equal(at('https:', '/x7f2k9'), 'x7f2k9');
  assert.equal(at('https:', '/x7f2k9/'), 'x7f2k9');
  assert.equal(at('https:', '/', '?p=x7f2k9'), 'x7f2k9');
  // A customer's hostname: the root is the page, and the service resolves it by Host.
  assert.equal(at('https:', '/'), 'host');
  assert.equal(at('http:', ''), 'host');
  // From disk there is no service; show the example.
  assert.equal(at('file:', '/Users/matt/dist/index.html'), DEFAULT_SLUG);
  // Never a real slug: the service reserves it, and the length rule keeps them apart.
  assert.ok('host'.length < 6);
});
