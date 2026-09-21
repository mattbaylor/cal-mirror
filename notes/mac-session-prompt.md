# Picking this up on the Mac

Paste the block below into a Claude Code session started **on the Mac** — the
CLI in a terminal, or a Remote Control session. It has to be the Mac itself:
a session started from the desktop app still executes in Anthropic's cloud on
Linux, which is how this work came to be written without ever being run.

---

```
You are picking up the AskWhen.me request-page UI on Matt's Mac. It was built
in a Linux container that could never run it, so everything below has been
compiled by CI and, until 15 September, seen by nobody. It has been run once
since (notes/TASKS.md, "Next", row 1); the walk below still holds for the next time.

Read, in this order: notes/STATUS.md, notes/TASKS.md ("Next"), askwhen/design/glossary.md,
and askwhen/design/decisions.md — especially the four 15 September entries
about the trial opt-in, the offer screen, the product load, and the UI being
approved as built.

Then run it:

    ./apple/tools/run-sim.sh                  # boot, build, install, launch
    SCREEN=preview ./apple/tools/run-sim.sh   # jump to one screen, seeded

The screens are apple/Shared/RequestPage/, fifteen of them, walked end to end
in apple/tools/review.html — open that first, it says what each screen is for
and what is still open on it.

What to actually look for, in order:

1. Does it run at all. Nothing in apple/Shared/RequestPage/ has been executed.
   Launch, walk from the dormant row to a live page, and note anything that
   crashes, hangs, or renders blank.
2. The four questions the review left open, which are all easier to judge
   moving than still: the policy screen's length (a sentence plus six numbered
   settings); the conflict sheet showing what landed as a time rather than a
   title; the full IANA zone picker; publisher nomination folded into the live
   page rather than given its own screen. decisions.md says what would make
   each worth reopening.
3. The offer screen. simctl launch does not use the run scheme, so run from
   Xcode instead — the scheme has apple/AskWhen.storekit attached, and the
   trial purchase then works with no network and no sandbox account. Check
   both variants: with a trial available, and with it already used.
4. The notification. Accept and Decline ride on it and are exercised by no
   test. A conflict raised from a notification action is the path most likely
   to be wrong.

Rules that will bite:
  - main is protected: branch, PR, CI green. gh has two accounts —
    `gh auth switch --user mattbaylor` before any push, PR or merge, and
    switch back to mattbaylor-edify after.
  - Never `git add -A`. Stage explicitly.
  - Copy is generated: edit apple/Shared/RequestPage/Copy.json, then run
    apple/tools/gen-request-copy.py and apple/tools/gen-review.py. CI diffs
    all three, so hand-editing Copy.swift fails the build.
  - Screenshots come from apple/tools/review-fixture.json, never the live
    config — it holds a work email, an employer, a spouse's calendar and
    children's names.
  - App Store builds come from CI, never the laptop (ITMS-90301).
  - It is a request page, never a booking page. Glossary first.
  - Matt makes every design decision. Anything you conclude goes in
    decisions.md as Proposed, never Settled.

Nothing is "blocked" as a resting state: either it is being worked, or there
is a named ask for what unblocks it.
```

---

## If you would rather not run it by hand

`.github/workflows/screenshots.yml` does the same thing on a macOS runner and
uploads the frames as an artifact — `workflow_dispatch`, or automatically on
any PR touching `apple/Shared/RequestPage/`. That is the version that lets a
Linux session see its own work.
