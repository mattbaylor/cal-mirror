// The site's header, as one element: <cm-nav current="compare"></cm-nav>.
//
// Every page used to carry its own copy of the nav markup and CSS, and the
// three page widths (home 1060px, comparisons 820px, prose 720px) made the same
// markup lay out three ways. This renders one full-width bar with its own
// 1060px inner column, outside the page's content column, so it is identical
// everywhere. It is the only script on the site besides Plausible.
//
// Links are absolute from the directory nav.js lives in, so the same element
// works at the root and under vs/. `current` names the link to mark.

const ROOT = new URL(".", import.meta.url);

const LINKS = [
  ["what",      "#what",          "What it does"],
  ["filters",   "#filters",       "Which events"],
  ["how",       "#how",           "How it works"],
  ["compare",   "vs/",            "Compare"],
  ["changelog", "changelog.html", "Release notes"],
  ["coming",    "coming.html",    "What’s coming"],
  ["privacy",   "privacy.html",   "Privacy"],
];

const STYLE = `
  :host{display:block}
  .bar{max-width:1060px;margin:0 auto;padding:20px 22px 8px;display:flex;align-items:center;
    justify-content:space-between;gap:12px 24px;flex-wrap:wrap}
  .brand{display:flex;align-items:center;gap:10px;font-weight:700;letter-spacing:.2px;
    text-decoration:none;color:var(--tx)}
  .brand img{width:30px;height:30px;border-radius:8px;display:block}
  .links{display:flex;gap:18px;align-items:center;font-size:14px;color:var(--mut);flex-wrap:wrap}
  .links a{text-decoration:none;color:var(--mut)}
  .links a:hover{color:var(--tx)}
  .links a[aria-current]{color:var(--tx);font-weight:600}
  @media (max-width:860px){ .bar{flex-direction:column;align-items:flex-start;gap:14px} }
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

    bar.append(brand, links);
    shadow.append(style, bar);
  }
}

customElements.define("cm-nav", CMNav);
