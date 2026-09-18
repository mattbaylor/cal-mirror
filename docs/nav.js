// The site's header, as one element: <cm-nav current="compare"></cm-nav>.
//
// Every page used to carry its own copy of the nav markup and CSS, and the
// three page widths made the same markup lay out three ways. This renders one
// bar on the site's shared column, outside the page's content, so it is
// identical everywhere, and carries the Mac / iPhone switch from platform.js.
// Colors and type come from site.css's tokens, which cross the shadow root.
//
// Links are absolute from the directory nav.js lives in, so the same element
// works at the root and under vs/. `current` names the link to mark.

const ROOT = new URL(".", import.meta.url);

const LINKS = [
  ["askwhen",   "askwhen.html",   "AskWhen.me"],
  ["compare",   "vs/",            "Compare"],
  ["changelog", "changelog.html", "Release notes"],
  ["privacy",   "privacy.html",   "Privacy"],
];

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
  .links{display:flex;gap:.2rem 1.6rem;flex-wrap:wrap}
  .links a{text-decoration:none;color:var(--muted);font-weight:500}
  .links a:hover{color:var(--ink)}
  .links a[aria-current]{color:var(--ink)}
  a:focus-visible{outline:2px solid var(--link);outline-offset:3px;border-radius:4px}
`;

class CMNav extends HTMLElement {
  connectedCallback() {
    const current = this.getAttribute("current");
    const shadow = this.attachShadow({ mode: "open" });

    const style = document.createElement("style");
    style.textContent = STYLE;

    const bar = document.createElement("nav");
    bar.className = "bar";
    bar.setAttribute("aria-label", "Site");

    const brand = document.createElement("a");
    brand.className = "brand";
    brand.href = ROOT.href;
    const icon = document.createElement("img");
    icon.src = new URL("icon.png", ROOT).href;
    icon.alt = "Calendar Mirror icon";
    brand.append(icon, " Calendar Mirror");

    const links = document.createElement("div");
    links.className = "links";
    for (const [key, path, label] of LINKS) {
      const a = document.createElement("a");
      a.href = new URL(path, ROOT).href;
      a.textContent = label;
      if (key === current) a.setAttribute("aria-current", "page");
      links.append(a);
    }

    // Mac or iPhone, for every screenshot and demo below (platform.js).
    const platform = document.createElement("cm-platform");

    bar.append(brand, platform, links);
    shadow.append(style, bar);
  }
}

customElements.define("cm-nav", CMNav);
