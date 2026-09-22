#!/usr/bin/env python3
"""Write docs/sitemap.xml from the pages in docs/.

    python3 infra/site/sitemap.py

Every published page in every language is listed. A page marked `noindex` is
not published, so it is skipped — that rule replaced a hardcoded skip list when
coming.html was deleted, and it means a draft page excludes itself.

No `lastmod`. It used to carry the date of the last commit touching each page,
which meant every page edit had to run this script in the same change or the
dates lied. It is a hint crawlers may ignore, and a wrong one is worse than
none.

The blog and the language directories come in through one recursive walk, so a
new section or a new language needs no edit here. docs/i18n-check.py fails the
build if this file misses a page.
"""
import glob, os, sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..")
DOCS = os.path.join(ROOT, "docs")
SITE = "https://calendarmirror.com"

def url_for(rel):
    rel = rel.replace(os.sep, "/")
    if rel == "index.html":
        return SITE + "/"
    if rel.endswith("/index.html"):
        return SITE + "/" + rel[: -len("index.html")]
    return SITE + "/" + rel

def main():
    urls = []
    for p in sorted(glob.glob(os.path.join(DOCS, "**", "*.html"), recursive=True)):
        if 'name="robots" content="noindex"' in open(p).read():
            continue
        urls.append(url_for(os.path.relpath(p, DOCS)))
    lines = ['<?xml version="1.0" encoding="UTF-8"?>',
             '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">']
    for u in sorted(set(urls)):
        lines.extend(["  <url>", f"    <loc>{u}</loc>", "  </url>"])
    lines.append("</urlset>")
    out = "\n".join(lines) + "\n"
    dest = os.path.join(DOCS, "sitemap.xml")
    open(dest, "w").write(out)
    print(f"wrote {os.path.relpath(dest, ROOT)} with {out.count('<url>')} pages")
    return 0

if __name__ == "__main__":
    sys.exit(main())
