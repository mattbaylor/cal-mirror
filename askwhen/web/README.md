# askwhen.me — web app

The Lit application. One codebase, N pages: a slug selects a policy dump, and the
dump is the only thing that differs between two booking pages.

Components and acceptance criteria: `../README.md` step 2.

Nothing here yet. **Start against a static dump on disk** — `../schema/policy-dump.example.json`
— with no service and no network. The whole surface is provable that way, and it
keeps the "no external requests" property honest from the first commit rather
than bolted on later.

Not yet decided: bundler. Whatever it is, `docs/` stays hand-written and
build-step-free; the two must not meet.
