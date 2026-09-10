// Which page the URL names. Pure — no JSON imports, no DOM — so the tests can
// load it under plain Node.

/** The bundled example's slug; what a file:// open shows. */
export const DEFAULT_SLUG = 'x7f2k9';

/**
 * The slug from the URL. `askwhen.me/x7f2k9` — one path segment, nothing else.
 *
 * On a customer's own hostname — `ask.example.com`, `matt.askwhen.me` — the
 * root is the page and there is no slug in the path. The answer is then the
 * sentinel `host`: `/p/host.json` is the service's "the page for whichever
 * name this arrived on", and four characters cannot collide with a real slug,
 * which has at least six. The submission still goes to `/v1/pages/{slug}/…`,
 * using the slug the dump carries.
 *
 * Opened from the filesystem there is no service to ask, so the example slug
 * shows a real page rather than the 404.
 */
export function slugFromLocation(loc = globalThis.location) {
  const segment = (loc?.pathname ?? '').split('/').filter(Boolean).pop();
  if (segment && /^[a-z0-9]{4,32}$/i.test(segment)) return segment;
  const query = new URLSearchParams(loc?.search ?? '').get('p');
  if (query && /^[a-z0-9]{4,32}$/i.test(query)) return query;
  if (loc?.protocol === 'http:' || loc?.protocol === 'https:') return 'host';
  return DEFAULT_SLUG;
}
