#!/usr/bin/env python3
"""Write docs/sitemap.xml from the pages in docs/, dated from git.

Every public page is listed; coming.html is not, because nothing links to it
and it is marked noindex. lastmod is the last commit that touched the page,
so regenerate it in the same change as any page edit:

    python3 infra/site/sitemap.py

(The page's own commit is not known until it exists, so lastmod trails by
one change. Crawlers treat it as a hint; a day off is fine, a year is not.)
"""
import glob, os, subprocess, sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..")
DOCS = os.path.join(ROOT, "docs")
SITE = "https://calendarmirror.com"
SKIP = {"coming.html"}

def lastmod(path):
    out = subprocess.run(["git", "-C", ROOT, "log", "-1", "--format=%cs", "--", path],
                         capture_output=True, text=True).stdout.strip()
    return out or None

def url_for(rel):
    if rel == "index.html": return SITE + "/"
    if rel.endswith("/index.html"): return SITE + "/" + rel[:-len("index.html")]
    return SITE + "/" + rel

def main():
    pages = sorted(glob.glob(os.path.join(DOCS, "*.html")) + glob.glob(os.path.join(DOCS, "vs", "*.html")))
    lines = ['<?xml version="1.0" encoding="UTF-8"?>',
             '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">']
    for p in pages:
        rel = os.path.relpath(p, DOCS)
        if os.path.basename(rel) in SKIP: continue
        mod = lastmod(p)
        lines.append("  <url>")
        lines.append(f"    <loc>{url_for(rel)}</loc>")
        if mod: lines.append(f"    <lastmod>{mod}</lastmod>")
        lines.append("  </url>")
    lines.append("</urlset>")
    out = "\n".join(lines) + "\n"
    dest = os.path.join(DOCS, "sitemap.xml")
    open(dest, "w").write(out); print(f"wrote {dest} with {out.count('<url>')} pages"); return 0

if __name__ == "__main__":
    sys.exit(main())
