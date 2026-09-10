// Where a policy dump comes from.
//
// This is a seam, and it is the only place in the web app that will ever know.
// On the site it is a same-origin fetch of `/p/{slug}.json` (service.js). Opened
// from the filesystem — the gallery, a design review, `dist/index.html` on a
// laptop — there is no service to ask, so the dumps bundled at build time
// answer instead. Nothing above this file changes either way: the components
// take a parsed dump and have no opinion about how it arrived.

import example from '../../schema/policy-dump.example.json';
import { fetchDump } from './service.js';
import { DEFAULT_SLUG, slugFromLocation } from './slug.js';
import denverDst from '../test/fixtures/dst-america-denver.json';
import aucklandDst from '../test/fixtures/dst-pacific-auckland.json';

const BUNDLED = new Map(
  [example, denverDst, aucklandDst].map((dump) => [dump.slug, dump]),
);

export { DEFAULT_SLUG, slugFromLocation };

// The constant in slug.js is a copy of the example's slug, kept out of that
// file so it stays importable without a JSON loader. This is the check.
if (example.slug !== DEFAULT_SLUG) {
  throw new Error(`slug.js DEFAULT_SLUG is ${DEFAULT_SLUG}; the example is ${example.slug}`);
}

/** Every slug the filesystem fallback can render. */
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
export async function loadDump(slug, loc = globalThis.location) {
  if (loc?.protocol === 'file:') return BUNDLED.get(slug) ?? null;
  return fetchDump(slug);
}
