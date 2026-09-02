// Where a policy dump comes from.
//
// This is a seam, and it is the only place in the web app that will ever know.
// In step 2 there is no service, so every dump the app can show is bundled at
// build time — which is what makes "no network request of any kind" a property
// of the build rather than a promise in a README.
//
// Step 3 replaces the body of `loadDump` with a same-origin fetch of
// `/p/{slug}.json`. Nothing above it changes: the components take a parsed dump
// and have no opinion about how it arrived.

import example from '../../schema/policy-dump.example.json';
import denverDst from '../test/fixtures/dst-america-denver.json';
import aucklandDst from '../test/fixtures/dst-pacific-auckland.json';

const BUNDLED = new Map(
  [example, denverDst, aucklandDst].map((dump) => [dump.slug, dump]),
);

export const DEFAULT_SLUG = example.slug;

/** Every slug this build can render. Step 3 makes this list meaningless. */
export function bundledSlugs() {
  return [...BUNDLED.keys()];
}

/**
 * A dump, or null if there is no page there.
 *
 * Null is not an error path — architecture §4c is explicit that a missing page
 * is the common case and must never say *why* it is missing. Lapsed, deleted,
 * expired and never-existed all look identical from out here, deliberately.
 */
export async function loadDump(slug) {
  return BUNDLED.get(slug) ?? null;
}

/**
 * The slug from the URL. `askwhen.me/x7f2k9` — one path segment, nothing else.
 *
 * Falls back to the example so opening the built file directly, with no path at
 * all, shows a real page rather than the 404.
 */
export function slugFromLocation(loc = globalThis.location) {
  const segment = (loc?.pathname ?? '').split('/').filter(Boolean).pop();
  if (segment && /^[a-z0-9]{4,32}$/i.test(segment)) return segment;
  const query = new URLSearchParams(loc?.search ?? '').get('p');
  if (query && /^[a-z0-9]{4,32}$/i.test(query)) return query;
  return DEFAULT_SLUG;
}
