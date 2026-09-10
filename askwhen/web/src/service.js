// The only two calls this page ever makes, and the only file that makes them.
//
// Both go to the page's own origin and nowhere else — the no-network check
// in test/no-network.mjs reads the built bundle and refuses any fetch whose
// target is not a same-origin path literal, so this cannot quietly grow a
// third-party call. The service enforces the same thing from the other side
// with connect-src 'self'.
//
// `fetch` is called by name with a literal path, on purpose: the no-network
// check reads the bundle, and an alias would hide the target from it. Tests
// stand in for the service by replacing `globalThis.fetch`, which is also why
// nothing here touches `window` or `document`.

/**
 * The page's policy dump, or null.
 *
 * Null is not an error path — architecture §4c is explicit that a missing
 * page is the common case and must never say *why*. Lapsed, deleted, expired,
 * never-existed and, here, "the server could not be reached" all look the
 * same: there is no page to show. A transient failure is the one of those a
 * reload fixes, and the requester will try that anyway.
 */
export async function fetchDump(slug) {
  try {
    const res = await fetch(`/p/${slug}.json`, {
      headers: { accept: 'application/json' },
      cache: 'no-cache',
    });
    if (!res.ok) return null;
    return await res.json();
  } catch {
    return null;
  }
}

/**
 * Submit a request. Resolves to one of:
 *   { ok: true }                          — accepted; a confirmation email is on its way
 *   { ok: false, reason: 'held' }         — somebody just asked for that time
 *   { ok: false, reason: 'slot' }         — that time is no longer on offer
 *   { ok: false, reason: 'rate' }         — too many from here; try later
 *   { ok: false, reason: 'gone' }         — the page is not there any more
 *   { ok: false, reason: 'failed' }       — anything else, including no network
 *
 * Never throws: the page has a state for every one of these, and an exception
 * would leave it on the form with a disabled button.
 */
export async function submitRequest(slug, { slot, name, email, note, trapped }) {
  try {
    const res = await fetch(`/v1/pages/${slug}/requests`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', accept: 'application/json' },
      body: JSON.stringify({ slot, name, email, note: note ?? '', trapped: Boolean(trapped) }),
    });
    if (res.status === 202) return { ok: true };
    if (res.status === 404) return { ok: false, reason: 'gone' };
    if (res.status === 429) return { ok: false, reason: 'rate' };
    let body = null;
    try {
      body = await res.json();
    } catch {
      /* not JSON; fall through */
    }
    const reason = body?.reason;
    if (res.status === 409 && (reason === 'held' || reason === 'slot')) return { ok: false, reason };
    return { ok: false, reason: 'failed' };
  } catch {
    return { ok: false, reason: 'failed' };
  }
}
