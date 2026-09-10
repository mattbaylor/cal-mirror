// The design-review contact sheet. Not part of the product — it is the surface
// that makes every state visible at once, at true size, so a page can be looked
// at rather than reasoned about.
//
// Its one job that the request page cannot do for itself: stand the same dump
// in three timezones side by side, at the same instant, and let the difference
// be read directly.

import './components/request-page.ts';
import type { PageState, RequestPage } from './components/request-page.ts';
import type { PolicyDump } from './generated/policy-dump.ts';
import exampleJson from '../../schema/policy-dump.example.json' with { type: 'json' };
import denverJson from '../test/fixtures/dst-america-denver.json' with { type: 'json' };

const example = exampleJson as PolicyDump;
const denverDst = denverJson as PolicyDump;

const NOW = new Date('2026-09-01T18:30:00Z');

const ZONES: [string, string, string][] = [
  ['America/Denver', 'en-US', "The owner's own zone — no second time is shown"],
  ['Asia/Kolkata', 'en-US', 'Half-hour offset; the 2pm slot lands at 1:30 the next morning'],
  ['Pacific/Auckland', 'en-NZ', 'A day ahead throughout, and a 24-hour locale'],
];

const aged = (dump: PolicyDump, hours: number): PolicyDump => ({
  ...dump,
  generated: new Date(NOW.getTime() - hours * 3600000).toISOString(),
  expires: new Date(NOW.getTime() + 12 * 3600000).toISOString(),
});

const fresh = (dump: PolicyDump) => aged(dump, 2);

function frame(title: string, note: string, build: () => HTMLElement) {
  const wrap = document.createElement('section');
  wrap.className = 'cell';
  const h = document.createElement('h2');
  h.textContent = title;
  const p = document.createElement('p');
  p.textContent = note;
  const box = document.createElement('div');
  box.className = 'device';
  box.appendChild(build());
  wrap.append(h, p, box);
  return wrap;
}

interface Stance {
  zone?: string;
  locale?: string;
  state?: PageState;
  chosen?: boolean;
}

function page(dump: PolicyDump | null, { zone, locale, state, chosen }: Stance = {}) {
  const el = document.createElement('request-page') as RequestPage;
  el.dump = dump;
  el.now = NOW;
  if (zone) el.zone = zone;
  if (locale) el.locale = locale;
  const first = dump?.slots[0];
  if (state) {
    el.state = state;
    el._email = 'alex@example.com';
    if (chosen !== false && first) {
      el._chosen = {
        slot: first,
        start: new Date(first.s),
        end: new Date(first.e),
        time: '10:00 AM',
        endTime: '10:30 AM',
        ownerTime: null,
      };
    }
  }
  return el;
}

const grid = document.getElementById('sheet');
if (!grid) throw new Error('gallery.html has no #sheet');
const add = (...nodes: HTMLElement[]) => grid.append(...nodes);

add(
  ...ZONES.map(([zone, locale, note]) =>
    frame(zone, note, () => page(fresh(example), { zone, locale })),
  ),
);

add(
  frame('Fall back — America/Denver', 'The hour that happens twice, qualified MDT and MST', () =>
    page(
      { ...denverDst, generated: '2026-11-01T04:00:00Z', expires: '2026-11-02T04:00:00Z' },
      { zone: 'America/Denver', locale: 'en-US' },
    ),
  ),
);

add(
  frame('Freshness — amber', 'Between 6 and 24 hours old', () =>
    page(aged(example, 12), { zone: 'America/Denver', locale: 'en-US' }),
  ),
  frame('Freshness — red', 'Over a day old, and saying so', () =>
    page(aged(example, 40), { zone: 'America/Denver', locale: 'en-US' }),
  ),
);

add(
  frame('Step 2 — who is asking', 'Two fields, no account', () =>
    page(fresh(example), { zone: 'America/Denver', locale: 'en-US', state: 'form' }),
  ),
  frame('Step 3 — confirm your email', 'Held 15 minutes; nothing has been sent yet', () =>
    page(fresh(example), {
      zone: 'America/Denver',
      locale: 'en-US',
      state: 'confirm-your-email',
    }),
  ),
);

add(
  frame('Accepted', 'The only state where anything reaches a calendar', () =>
    page(fresh(example), { zone: 'America/Denver', locale: 'en-US', state: 'accepted' }),
  ),
  frame('Declined', 'Nothing written, slot released', () =>
    page(fresh(example), { zone: 'America/Denver', locale: 'en-US', state: 'declined' }),
  ),
);

add(
  frame('Held by someone else', 'Two people asked for the same time; the first is confirming', () =>
    page(fresh(example), { zone: 'America/Denver', locale: 'en-US', state: 'held' }),
  ),
  frame('Did not go through', 'The submission failed before it was recorded', () =>
    page(fresh(example), { zone: 'America/Denver', locale: 'en-US', state: 'failed' }),
  ),
);

add(
  frame('Expired dump', 'Lapse and expiry share one voice, and never say which', () =>
    page({ ...example, expires: '2026-08-31T00:00:00Z' }, { zone: 'America/Denver' }),
  ),
  frame('No page there', 'The only page a stranger sees cold', () => page(null)),
  frame('One slot just asked for', 'Held renders as taken, not as gone (§4b)', () =>
    page({ ...fresh(example), held: example.slots.slice(0, 1).map((s) => s.s) }, { zone: 'America/Denver' }),
  ),
  frame('Nothing offered', 'Absence of a slot is not evidence of a meeting', () =>
    page({ ...fresh(example), slots: [] }, { zone: 'America/Denver' }),
  ),
);
