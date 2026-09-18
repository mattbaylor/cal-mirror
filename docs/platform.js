// Mac or iPhone: one switch that turns every screenshot and demo on a page.
//
// The apps are the same on both, but a reader has one in front of them. The
// choice lands on <html data-platform="mac|ios">, and site.css hides .mac-only
// or .ios-only accordingly. It is decided synchronously here, before the page
// paints, so nothing flashes; the reader's last choice is remembered in
// localStorage when that is allowed, and a touch screen defaults to iPhone.
//
// <cm-platform></cm-platform> renders the switch. Loaded as a classic script
// in <head>, on purpose: a module would run after first paint.

(function () {
  const KEY = "cm-platform";
  let saved = new URLSearchParams(location.search).get("platform");   // ?platform=ios, for a link
  if (saved !== "mac" && saved !== "ios") { try { saved = localStorage.getItem(KEY); } catch (e) {} }
  const initial = saved === "mac" || saved === "ios" ? saved
    : (matchMedia("(pointer: coarse)").matches ? "ios" : "mac");
  document.documentElement.dataset.platform = initial;

  const STYLE = `
    :host{display:inline-flex}
    .seg{display:inline-flex;gap:.2rem;padding:.2rem;border-radius:12px;background:var(--soft, #F3F7FB)}
    button{display:inline-flex;align-items:center;gap:.45em;font:600 14px/1 "Figtree",-apple-system,sans-serif;color:var(--muted,#5B6B7F);
      background:transparent;border:0;border-radius:9px;padding:.5em .9em;cursor:pointer;white-space:nowrap;transition:background .15s,color .15s}
    svg{width:18px;height:18px;fill:none;stroke:currentColor;stroke-width:1.6;stroke-linecap:round;stroke-linejoin:round}
    button[aria-pressed="true"]{background:var(--paper,#fff);color:var(--ink,#0F1A2B);box-shadow:0 1px 3px rgba(15,26,43,.15)}
    button:focus-visible{outline:2px solid var(--link,#1B78D1);outline-offset:2px}
    @media (prefers-color-scheme: dark){ button[aria-pressed="true"]{box-shadow:none} }
  `;

  class CMPlatform extends HTMLElement {
    connectedCallback() {
      const shadow = this.attachShadow({ mode: "open" });
      const style = document.createElement("style"); style.textContent = STYLE;
      const seg = document.createElement("div"); seg.className = "seg";
      seg.setAttribute("role", "group"); seg.setAttribute("aria-label", "Show it on");
      const ICON = {
        mac: '<svg viewBox="0 0 24 24" aria-hidden="true"><rect x="4" y="5" width="16" height="11" rx="1.5"/><path d="M2 18.5h20"/></svg>',
        ios: '<svg viewBox="0 0 24 24" aria-hidden="true"><rect x="7" y="2.5" width="10" height="19" rx="2.2"/><path d="M10.5 5h3"/></svg>',
      };
      for (const [key, label] of [["mac", "Mac"], ["ios", "iPhone & iPad"]]) {
        const b = document.createElement("button"); b.type = "button"; b.dataset.key = key;
        b.innerHTML = ICON[key]; b.append(label);
        b.addEventListener("click", () => set(key));
        seg.append(b);
      }
      shadow.append(style, seg);
      this._buttons = seg.querySelectorAll("button");
      this.reflect();
      document.addEventListener("cm-platform", () => this.reflect());
    }
    reflect() {
      const now = document.documentElement.dataset.platform;
      for (const b of this._buttons) b.setAttribute("aria-pressed", String(b.dataset.key === now));
    }
  }
  function set(key) {
    document.documentElement.dataset.platform = key;
    try { localStorage.setItem(KEY, key); } catch (e) {}
    document.dispatchEvent(new CustomEvent("cm-platform", { detail: key }));
  }
  customElements.define("cm-platform", CMPlatform);
})();
