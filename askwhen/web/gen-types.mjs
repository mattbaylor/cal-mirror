// The dump's TypeScript type, from the schema, so the two cannot drift.
//
// `schema/policy-dump.schema.json` is the contract for the one document that
// leaves an owner's device. Hand-written types beside it would be a second
// copy that could quietly disagree — and the disagreement would be silent,
// because both would compile. Generating from the schema means a field added
// there fails to type-check here until the code handles it, and a field the
// code reaches for that the schema does not have is a compile error.
//
// Run by `npm run types`, which `check` and `build` run first. The output is
// committed so editors see it; CI regenerates and diffs, so it cannot go stale.

import { compile } from 'json-schema-to-typescript';
import { readFile, writeFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';

const here = (p) => fileURLToPath(new URL(p, import.meta.url));
const schema = JSON.parse(await readFile(here('../schema/policy-dump.schema.json'), 'utf8'));

// The schema's title is prose ("Booking policy dump"); the type is named
// for what the code calls it.
delete schema.title;
delete schema.$id;
let ts = await compile(schema, 'PolicyDump', {
  bannerComment: `/* Generated from ../../schema/policy-dump.schema.json by gen-types.mjs. DO NOT EDIT. */`,
  additionalProperties: false,
  style: { singleQuote: true, printWidth: 100 },
});
ts += `
/** One offer, as the schema spells it: start and end, ISO-8601 UTC. */
export type Slot = PolicyDump['slots'][number];
`;
await writeFile(here('src/generated/policy-dump.ts'), ts);
console.log('types: src/generated/policy-dump.ts');
