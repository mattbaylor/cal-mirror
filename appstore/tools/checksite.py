#!/usr/bin/env python3
"""Hold the website to the same accuracy rules as the App Store listing.

genmeta.py polices the metadata; nothing policed the site, and notes/REVIEW.md
(D5, 16 Sept 2026) found it overselling realtime. This scans every HTML page
under site/ for the claims the listing may not make either:

  * "within seconds" / "instantly": a change notification is best-effort, and
    iOS has no realtime at all.
  * The 1.x network claim without its 2.0 qualifier: with AskWhen.me on the
    app does talk to a server, so "no network request" must be followed by
    "until you turn on AskWhen.me" (or "until the moment you turn AskWhen.me
    on") in the same paragraph.
  * "booking" in our own voice. It may describe other tools ("a booking page
    works by holding your calendar"); it may not describe ours. The heuristic:
    "askwhen.me" or "request page" within the same sentence as "booking"
    must be a contrast — "not a booking page" — or it fails.

Run from anywhere: python3 appstore/tools/checksite.py. Exits non-zero on a
hit, and CI runs it.
"""
import os, re, sys, html

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), os.pardir, os.pardir, "site")

def text_of(path):
    raw = open(path, encoding="utf-8").read()
    raw = re.sub(r"<script.*?</script>|<style.*?</style>", " ", raw, flags=re.S)
    raw = re.sub(r"<!--.*?-->", " ", raw, flags=re.S)
    raw = re.sub(r"<[^>]+>", " ", raw)
    text = html.unescape(re.sub(r"\s+", " ", raw))
    # Dots that are not sentence ends, so "askwhen.me" and "2.0" do not split
    # a sentence away from its qualifier.
    text = re.sub(r"(?i)askwhen\.me", "askwhen-me", text)
    text = re.sub(r"(\d)\.(\d)", r"\1-\2", text)
    return text

fail = False
for dirpath, _, files in os.walk(ROOT):
    for f in sorted(files):
        if not f.endswith(".html"):
            continue
        path = os.path.join(dirpath, f)
        rel = os.path.relpath(path, ROOT)
        low = text_of(path).lower()
        for phrase in ("within seconds", "instantly"):
            for m in re.finditer(r"[^.!?|]*" + phrase + r"[^.!?]*", low):
                sentence = m.group(0)
                # A contrast with a booking page ("instantly, from the form")
                # is about them. Anything about a copy, a sync or a change is us.
                if "booking" in sentence or "from the form" in sentence:
                    continue
                print("  !! %s says %r — best-effort is not that" % (rel, phrase)); fail = True
        for m in re.finditer(r"[^.!?]*no network request[^.!?]*[.!?]", low):
            sentence = m.group(0)
            if "until" not in sentence and "unless" not in sentence and "askwhen-me on" not in sentence:
                print("  !! %s: %r — the claim needs its AskWhen.me qualifier" % (rel, sentence.strip()[:90])); fail = True
        # Our voice, not theirs: "your booking page", "our booking link",
        # "AskWhen.me's booking …". A table that sets "a booking page"
        # against "an AskWhen.me request page" is the contrast the glossary
        # wants, and passes.
        for m in re.finditer(r"\b(your|our|askwhen\.me's|calendar mirror's)\s+(\w+\s+)?booking\b", low):
            print("  !! %s: %r — booking in our own voice (glossary.md)" % (rel, m.group(0))); fail = True
print("site claims: %s" % ("FAIL" if fail else "clean"))
sys.exit(1 if fail else 0)
