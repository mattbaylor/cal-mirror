import { css } from 'lit';

// One palette, shared by every component. The token names match the marketing
// site so the two read as a family, but the default here is light: this page is
// opened cold by a stranger from a link, and light is the friendlier arrival.
export const tokens = css`
  :host {
    --bg: #f6f8fc;
    --bg2: #eef2f9;
    --card: #ffffff;
    --card2: #f3f6fb;
    --line: #e2e8f2;
    --tx: #0d1220;
    --mut: #4a5568;
    --dim: #78889d;
    --accent: #3aa0ff;
    --accent2: #28c8b6;
    --good: #2ecc71;
    --warn: #d99a20;
    --bad: #c0392b;
    --radius: 16px;
    --shadow: 0 12px 40px rgba(30, 50, 90, 0.1);
    --font: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif;
  }

  @media (prefers-color-scheme: dark) {
    :host {
      --bg: #0b0e14;
      --bg2: #0f1420;
      --card: #151b28;
      --card2: #1b2333;
      --line: #232c3d;
      --tx: #e6edf3;
      --mut: #93a1b5;
      --dim: #6b7a90;
      --warn: #e0a93a;
      --bad: #ff6b5a;
      --shadow: 0 12px 40px rgba(0, 0, 0, 0.35);
    }
  }
`;

// Focus is never removed, only restyled. Half the people who open this are on a
// phone in a corridor; the other half may be on a keyboard the whole way.
export const base = css`
  *,
  *::before,
  *::after {
    box-sizing: border-box;
  }

  :host {
    display: block;
    font: 16px/1.6 var(--font);
    color: var(--tx);
    -webkit-font-smoothing: antialiased;
  }

  :focus-visible {
    outline: 2px solid var(--accent);
    outline-offset: 2px;
    border-radius: 6px;
  }

  .sr-only {
    position: absolute;
    width: 1px;
    height: 1px;
    padding: 0;
    margin: -1px;
    overflow: hidden;
    clip: rect(0 0 0 0);
    clip-path: inset(50%);
    white-space: nowrap;
    border: 0;
  }

  @media (prefers-reduced-motion: reduce) {
    * {
      animation: none !important;
      transition: none !important;
    }
  }
`;
