# askwhen.me — web app

The Lit application. One codebase, N pages: a slug selects a policy dump, and the
dump is the only thing that differs between two request pages.

Design: `../design/architecture.md` §5, and "How it should feel" beneath it.
Vocabulary: `../design/glossary.md` — it is a **request** page, never a booking
page, and the copy here should never drift back.

## Running it

```
npm install
npm run check     # build, then the tests, then the no-network assertion
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

## Layout

```
src/format.js            every timezone question, pure and exhaustively tested
src/dump.js              where a dump comes from — the seam step 3 replaces
src/styles.js            shared tokens; the palette the marketing site uses
src/components/          request-page, availability-week, slot-button,
                         request-form, request-state
src/main.js              the entry point: slug in, page out
src/gallery.js           the contact sheet
test/format.test.mjs     the three-timezone and DST claims
test/no-network.mjs      the privacy claim, asserted against the built bundle
```

## What step 2 does and does not do

**Does.** Renders a dump. Groups slots into local days in the requester's own
zone, shows the owner's time beside each one when the zones differ, pages a week
at a time, shows the freshness stoplight, walks the whole flow — pick a time,
say who you are, confirm your email — and shows every end state.

**Does not.** Touch the network, in any way, at all. There is no service yet, so
the dump is bundled at build time and a submitted request goes nowhere. That is
not a stub standing in for a fetch: it is the property being kept honest from the
first commit, and `npm run check` fails if a later change breaks it.

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
