# askwhen.me — web app

The Lit application. One codebase, N pages: a slug selects a policy dump, and the
dump is the only thing that differs between two request pages.

Design: `../design/architecture.md` §5, and "How it should feel" beneath it.
Vocabulary: `../design/glossary.md` — it is a **request** page, never a booking
page, and the copy here should never drift back.

## Running it

```
npm install
npm run check     # types from the schema, tsc, build, tests, the no-network assertion
npm run build     # dist/index.html + dist/app.js + the contact sheet
```

`dist/index.html` opens straight from the filesystem. There is no dev server
because there is nothing to serve: the page makes no requests, so `file://` is a
faithful reproduction rather than a degraded one.

`dist/gallery.html` is the contact sheet — every state at 390 pt, three
timezones side by side, a fall-back week, and the freshness stoplight at all
three levels, with time pinned so the sheet does not change under you. It is a
design-review surface, not part of the product.

## Bundler — esbuild

The open question in this file is answered. esbuild, one dependency, no config
file, one output file per entry point. That last part is the reason: "no
third-party requests" is checkable by reading the artifact, and `test/no-network.mjs`
does exactly that on every build. A bundler that emits a graph of chunks would
turn dynamic `import()` into a network request the grep could not see.

`docs/` at the repo root stays hand-written and build-step-free. The two do not
meet.

## TypeScript

Since 10 September 2026 (Matt: "I was expecting TypeScript"). Strict, and
checked rather than merely stripped: `npm run typecheck` runs `tsc --noEmit`
over `src/` and `test/`, and `check` runs it before anything else, so a type
error fails CI rather than shipping as a runtime surprise. esbuild does the
emitting; Node runs the tests directly with its own type stripping, so there
is still no test runner and no build step in front of them.

**The dump's type is generated from the schema**, not written by hand:
`gen-types.mjs` turns `schema/policy-dump.schema.json` into
`src/generated/policy-dump.ts`. That is the part worth more than a language
preference. A hand-written type beside the schema is a second copy that can
quietly disagree — and the disagreement would be silent, because both would
compile. Generated, a field added to the schema fails to type-check here until
the code handles it, and a field the code reaches for that the schema does not
have is a compile error. The output is committed so editors see it; CI
regenerates and diffs, so it cannot go stale.

`useDefineForClassFields` is off in `tsconfig.json`: Lit's reactive
properties are accessors on the prototype, and with define semantics a class
field would shadow them. One setting, rather than `declare` on forty fields.

## Layout

```
src/format.ts                    every timezone question, pure and exhaustively tested
src/generated/policy-dump.ts     the dump's type, from the schema — DO NOT EDIT
src/slug.ts                      which page the URL names; pure
src/dump.ts                      where a dump comes from — fetch on the site, bundled on file://
src/service.ts                   the two same-origin calls, and the only file that makes them
src/styles.ts                    shared tokens; the palette the marketing site uses
src/components/                  request-page, availability-week, slot-button,
                                 request-form, request-state
src/main.ts                      the entry point: slug in, page out
src/gallery.ts                   the contact sheet
gen-types.mjs                    schema → src/generated
test/format.test.ts              the three-timezone and DST claims
test/service.test.ts             the service contract, against a stand-in for it
test/no-network.mjs              the privacy claim, asserted against the built bundle
```

## What step 2 does and does not do

**Does.** Renders a dump. Groups slots into local days in the requester's own
zone, shows the owner's time beside each one when the zones differ, pages a week
at a time, shows the freshness stoplight, walks the whole flow — pick a time,
say who you are, confirm your email — and shows every end state.

**Does not.** Talk to anyone but the host it came from. Since 10 Sept 2026 the
page makes exactly two calls, both same-origin — `GET /p/{slug}.json` for the
dump and `POST /v1/pages/{slug}/requests` to submit — and `test/no-network.mjs`
now asserts that shape against the built bundle: every `fetch(` must target a
same-origin path literal, every other way to start a request is still
forbidden, and no absolute URL may appear at all. Opened from the filesystem
there is no service to ask, so the bundled dumps answer instead; that is what
keeps the gallery and a `file://` review working.

## Carried forward to step 3

- `loadDump()` in `src/dump.js` becomes a same-origin fetch of `/p/{slug}.json`.
  Nothing above it changes; the components take a parsed dump and have no
  opinion about how it arrived.
- Held slots are modelled (`availability-week` takes a `held` array and renders
  those slots struck through and disabled) but nothing populates it, because
  holds live in the service.
- `request-form` emits `trapped: true` when the honeypot is filled. Step 2
  accepts and drops it so the page looks identical either way; step 3 decides
  what the service does with it.
- The example dump's `meeting.location` is `null`. The page treats absent and
  explicit-null identically, per the note carried forward from step 1.
