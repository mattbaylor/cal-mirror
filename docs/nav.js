// The site's header, as one element: <cm-nav current="compare"></cm-nav>.
//
// Every page used to carry its own copy of the nav markup and CSS, and the
// three page widths made the same markup lay out three ways. This renders one
// bar on the site's shared column, outside the page's content, so it is
// identical everywhere, and carries the Mac / iPhone switch from platform.js.
// Colors and type come from site.css's tokens, which cross the shadow root.
//
// Links are absolute from the directory nav.js lives in, so the same element
// works at the root and under vs/, blog/ and de/. `current` names the link to
// mark.
//
// Translations. A language is a directory under the root holding the same file
// names — /de/index.html, /de/blog/on-call-rotas.html — so a page's counterpart
// in another language is a path transform, and nothing has to be registered.
// `lang` picks the labels and the link set. There is no per-page opt-in and no
// "(EN)" fallback: every page exists in every language, which docs/i18n-check.py
// enforces, so the switcher can always point at the same path under another
// language's directory.
//
// To add a language: one LANGS row, one NAV block, and the whole site under
// /<code>/. The check will tell you exactly which pages are missing.

const ROOT = new URL(".", import.meta.url);

// One row per language: code, the name in that language, the flag, and the
// directory under the root ("" for English, which lives at the root). Adding a
// language is this row plus a NAV block plus the pages — nothing else.
const LANGS = [
  { code: "en", name: "English", flag: "\u{1F1FA}\u{1F1F8}", dir: ""    },
  { code: "de", name: "Deutsch", flag: "\u{1F1E9}\u{1F1EA}", dir: "de/" },
];

// Per language: the links, and the label the brand carries. Paths are relative
// to the site root, so a language may point at an untranslated English page —
// marked (EN) in the label, rather than pretending or 404ing.
const NAV = {
  en: {
    home: "",
    links: [
      ["askwhen",   "askwhen.html",   "AskWhen.me"],
      ["blog",      "blog/",          "Blog"],
      ["compare",   "vs/",            "Compare"],
      ["changelog", "changelog.html", "Release notes"],
      ["privacy",   "privacy.html",   "Privacy"],
    ],
    switcher: "Language",
  },
  de: {
    home: "de/",
    links: [
      ["askwhen",   "de/askwhen.html",   "AskWhen.me"],
      ["blog",      "de/blog/",          "Blog"],
      ["compare",   "de/vs/",            "Vergleich"],
      ["changelog", "de/changelog.html", "Versionshinweise"],
      ["privacy",   "de/privacy.html",   "Datenschutz"],
    ],
    switcher: "Sprache",
  },
};

const STYLE = `
  :host{display:block;position:sticky;top:0;z-index:10;
    background:color-mix(in srgb, var(--paper) 82%, transparent);
    -webkit-backdrop-filter:saturate(180%) blur(14px);backdrop-filter:saturate(180%) blur(14px);
    border-bottom:1px solid var(--rule)}
  .bar{max-width:66rem;margin:0 auto;padding:.8rem clamp(18px,5vw,56px);display:flex;align-items:center;
    justify-content:space-between;gap:.8rem 1.6rem;flex-wrap:wrap;font-size:16px;line-height:1.5}
  cm-platform{order:3;flex-basis:100%;display:flex;justify-content:center}
  @media (min-width:900px){ cm-platform{order:0;flex-basis:auto} }
  .brand{display:inline-flex;align-items:center;gap:.6rem;font-weight:600;letter-spacing:-.01em;text-decoration:none;color:var(--ink)}
  .brand img{width:30px;height:30px;border-radius:8px;display:block}
  .links{display:flex;align-items:center;gap:.2rem 1.6rem;flex-wrap:wrap}
  .links a{text-decoration:none;color:var(--muted);font-weight:500}
  .links a:hover{color:var(--ink)}
  .links a[aria-current]{color:var(--ink)}
  /* The language switcher: a button that opens a list. It has to hold a dozen
     languages as well as two, so it is a menu rather than a row of links. */
  .lang{position:relative}
  .lang > button{display:inline-flex;align-items:center;gap:.4rem;font:600 14px/1 "Figtree",-apple-system,sans-serif;
    color:var(--muted);background:var(--soft);border:0;border-radius:10px;padding:.5em .7em;cursor:pointer;
    transition:color .15s}
  .lang > button:hover{color:var(--ink)}
  .lang > button .flag{font-size:15px;line-height:1}
  .lang > button svg{width:11px;height:11px;stroke:currentColor;stroke-width:2;fill:none;stroke-linecap:round;stroke-linejoin:round}
  .lang[data-open] > button{color:var(--ink)}
  .menu{position:absolute;top:calc(100% + .45rem);right:0;min-width:11rem;margin:0;padding:.3rem;list-style:none;
    background:var(--paper);border:1px solid var(--rule);border-radius:12px;
    box-shadow:0 12px 30px rgba(15,26,43,.14);display:none;z-index:20}
  .lang[data-open] .menu{display:block}
  .menu a{display:flex;align-items:center;gap:.55rem;padding:.5rem .6rem;border-radius:8px;
    text-decoration:none;color:var(--ink);font-size:15px;font-weight:500;white-space:nowrap}
  .menu a:hover{background:var(--soft)}
  .menu a[aria-current]{font-weight:600}
  .menu .flag{font-size:16px;line-height:1}
  .menu .tick{margin-left:auto;color:var(--link)}
  .menu .home{margin-left:auto;font-size:12.5px;color:var(--muted);font-weight:400}
  a:focus-visible{outline:2px solid var(--link);outline-offset:3px;border-radius:4px}
`;

// Where this page sits under the root, with any language directory removed:
// "de/blog/on-call-rotas.html" -> "blog/on-call-rotas.html".
function barePath() {
  let rel = location.pathname.startsWith(ROOT.pathname)
    ? location.pathname.slice(ROOT.pathname.length) : "";
  for (const l of LANGS) {
    if (!l.dir) continue;
    if (rel === l.dir.slice(0, -1) || rel.startsWith(l.dir)) { rel = rel.slice(l.dir.length); break; }
  }
  return rel;
}

class CMNav extends HTMLElement {
  connectedCallback() {
    const current = this.getAttribute("current");
    const lang = NAV[this.getAttribute("lang")] ? this.getAttribute("lang") : "en";
    const strings = NAV[lang];
    const shadow = this.attachShadow({ mode: "open" });

    const style = document.createElement("style");
    style.textContent = STYLE;

    const bar = document.createElement("nav");
    bar.className = "bar";
    bar.setAttribute("aria-label", "Site");

    const brand = document.createElement("a");
    brand.className = "brand";
    brand.href = new URL(strings.home, ROOT).href;
    const icon = document.createElement("img");
    icon.src = new URL("icon.png", ROOT).href;
    icon.alt = "Calendar Mirror";
    brand.append(icon, " Calendar Mirror");

    const links = document.createElement("div");
    links.className = "links";
    for (const [key, path, label] of strings.links) {
      const a = document.createElement("a");
      a.href = new URL(path, ROOT).href;
      a.textContent = label;
      if (key === current) a.setAttribute("aria-current", "page");
      links.append(a);
    }

    // The switcher. Every page exists in every language — docs/i18n-check.py
    // fails the build otherwise — so the counterpart is always the same path
    // under another language's directory, and there is nothing to qualify.
    const bare = barePath();
    const wrap = document.createElement("div");
    wrap.className = "lang";

    const here = LANGS.find(l => l.code === lang) || LANGS[0];
    const toggle = document.createElement("button");
    toggle.type = "button";
    toggle.setAttribute("aria-haspopup", "true");
    toggle.setAttribute("aria-expanded", "false");
    toggle.setAttribute("aria-label", strings.switcher);
    toggle.innerHTML = `<span class="flag" aria-hidden="true">${here.flag}</span>` +
      `<span>${here.code.toUpperCase()}</span>` +
      `<svg viewBox="0 0 12 12" aria-hidden="true"><path d="M2.5 4.5 6 8l3.5-3.5"/></svg>`;

    const menu = document.createElement("ul");
    menu.className = "menu";
    for (const l of LANGS) {
      const li = document.createElement("li");
      const a = document.createElement("a");
      a.href = new URL(l.dir + bare, ROOT).href;
      a.hreflang = l.code;
      a.innerHTML = `<span class="flag" aria-hidden="true">${l.flag}</span><span>${l.name}</span>` +
        (l.code === lang ? `<span class="tick" aria-hidden="true">&#10003;</span>` : "");
      if (l.code === lang) a.setAttribute("aria-current", "true");
      li.append(a);
      menu.append(li);
    }

    const setOpen = (open) => {
      if (open) wrap.setAttribute("data-open", ""); else wrap.removeAttribute("data-open");
      toggle.setAttribute("aria-expanded", String(open));
    };
    toggle.addEventListener("click", (e) => {
      e.stopPropagation();
      setOpen(!wrap.hasAttribute("data-open"));
    });
    document.addEventListener("click", () => setOpen(false));
    shadow.addEventListener("keydown", (e) => { if (e.key === "Escape") { setOpen(false); toggle.focus(); } });

    wrap.append(toggle, menu);
    links.append(wrap);

    bar.append(brand, links);
    shadow.append(style, bar);

    // Mac or iPhone (platform.js) — only where the page actually has something
    // that differs between them. A blog post, a comparison, the privacy page or
    // the release notes read the same on both, and a switch that changes
    // nothing is furniture. Decided by looking for .mac-only / .ios-only rather
    // than by an attribute each page has to remember, so a new page gets this
    // right without being told.
    const addPlatform = () => {
      if (!document.querySelector(".mac-only, .ios-only")) return;
      bar.insertBefore(document.createElement("cm-platform"), links);
    };
    if (document.readyState === "loading") {
      document.addEventListener("DOMContentLoaded", addPlatform, { once: true });
    } else {
      addPlatform();
    }
  }
}

customElements.define("cm-nav", CMNav);
