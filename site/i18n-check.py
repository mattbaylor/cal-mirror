#!/usr/bin/env python3
"""Every page of calendarmirror.com exists in every language.

The site is plain static HTML with no build step, so nothing but a check stops
a new page from shipping in English only — and a half-translated site is how you
end up labelling links "(EN)" and apologising in the nav. This fails the build
instead.

It enforces, for each language directory listed in nav.js:

  * every English page has a counterpart at the same path under /<lang>/
  * no page carries a language qualifier in a link label ("(EN)", "auf Englisch"
    about a page rather than about the app)
  * every page declares <html lang> matching where it lives, and a <cm-nav>
    whose lang attribute agrees
  * every translated pair cross-links with hreflang, both ways, plus x-default
  * the sitemap lists every page in every language

Run it from anywhere:  python3 docs/i18n-check.py
"""
import re, sys
from pathlib import Path

SITE = Path(__file__).resolve().parent
BASE = "https://calendarmirror.com/"

def languages():
    """The language codes and directories, read from nav.js so there is one list."""
    nav = (SITE / "nav.js").read_text()
    rows = re.findall(r'\{\s*code:\s*"(\w+)".*?dir:\s*"([^"]*)"', nav)
    if not rows:
        sys.exit("i18n-check: could not read LANGS out of nav.js")
    return rows

def published(p: Path) -> bool:
    """A noindex page is not part of the published site, so it needs no twin."""
    return 'name="robots" content="noindex"' not in p.read_text()

def pages(prefix: Path):
    """Every published .html under prefix, excluding the language directories."""
    out = set()
    for p in prefix.rglob("*.html"):
        rel = p.relative_to(SITE)
        if any(str(rel).startswith(d) for _, d in LANGS if d):
            continue
        if not published(p):
            continue
        out.add(rel)
    return out

LANGS = languages()
problems = []

# --- 1. every page exists in every language ---------------------------------
english = pages(SITE)
for code, dirname in LANGS:
    if not dirname:
        continue
    for rel in sorted(english):
        twin = SITE / dirname / rel
        if not twin.exists():
            problems.append(f"missing {code}: {dirname}{rel}  (translate it, or delete {rel})")
    # and nothing exists only in the translation
    for p in (SITE / dirname).rglob("*.html"):
        rel = p.relative_to(SITE / dirname)
        if not published(p):
            continue
        if not (SITE / rel).exists():
            problems.append(f"missing en: {rel}  (exists as {dirname}{rel})")

# --- 2. no language qualifiers on links -------------------------------------
QUALIFIER = re.compile(r"\((?:EN|DE|auf Englisch|in English)\)\s*<", re.I)
for p in SITE.rglob("*.html"):
    text = p.read_text()
    if not published(p):
        continue
    if QUALIFIER.search(text):
        problems.append(f"{p.relative_to(SITE)}: a link label is qualified with a language")

# --- 3. lang attributes agree with the directory ----------------------------
for p in SITE.rglob("*.html"):
    if not published(p):
        continue
    rel = p.relative_to(SITE)
    want = "en"
    for code, dirname in LANGS:
        if dirname and str(rel).startswith(dirname):
            want = code
    text = p.read_text()
    m = re.search(r'<html lang="([^"]+)"', text)
    if not m or m.group(1) != want:
        problems.append(f"{rel}: <html lang> should be \"{want}\"")
    nav = re.search(r"<cm-nav([^>]*)>", text)
    if nav:
        attr = re.search(r'lang="([^"]+)"', nav.group(1))
        got = attr.group(1) if attr else "en"
        if got != want:
            problems.append(f"{rel}: <cm-nav lang> should be \"{want}\"")

# --- 4. hreflang, both ways, plus x-default ---------------------------------
def url_for(rel: Path, dirname: str) -> str:
    s = str(rel)
    if s.endswith("index.html"):
        s = s[: -len("index.html")]
    return BASE + dirname + s

for rel in sorted(english):
    for code, dirname in LANGS:
        page = SITE / dirname / rel
        if not page.exists():
            continue
        text = page.read_text()
        for other, otherdir in LANGS:
            want = f'hreflang="{other}" href="{url_for(rel, otherdir)}"'
            if want not in text:
                problems.append(f"{page.relative_to(SITE)}: missing alternate {want}")
        if f'hreflang="x-default" href="{url_for(rel, "")}"' not in text:
            problems.append(f"{page.relative_to(SITE)}: missing x-default alternate")

# --- 5. the sitemap lists everything ----------------------------------------
sitemap = (SITE / "sitemap.xml").read_text()
for rel in sorted(english):
    for code, dirname in LANGS:
        if not (SITE / dirname / rel).exists():
            continue
        loc = f"<loc>{url_for(rel, dirname)}</loc>"
        if loc not in sitemap:
            problems.append(f"sitemap.xml: missing {url_for(rel, dirname)}")

if problems:
    print(f"i18n-check: {len(problems)} problem(s)\n")
    for p in problems:
        print("  " + p)
    sys.exit(1)
print(f"i18n-check: {len(english)} pages x {len(LANGS)} languages, all present and cross-linked")
