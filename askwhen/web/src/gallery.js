// The design-review contact sheet. Not part of the product — it is the surface
// that makes every state visible at once, at true size, so a page can be looked
// at rather than reasoned about.
//
// Its one job that the request page cannot do for itself: stand the same dump
// in three timezones side by side, at the same instant, and let the difference
// be read directly.

import './components/request-page.js';
import example from '../../schema/policy-dump.example.json';
import denverDst from '../test/fixtures/dst-america-denver.json';

const NOW = new Date('2026-09-01T18:30:00Z');

const ZONES = [
  ['America/Denver', 'en-US', "The owner's own zone — no second time is shown"],
  ['Asia/Kolkata', 'en-US', 'Half-hour offset; the 2pm slot lands at 1:30 the next morning'],
  ['Pacific/Auckland', 'en-NZ', 'A day ahead throughout, and a 24-hour locale'],
];

const aged = (dump, hours) => ({
  ...dump,
  generated: new Date(NOW.getTime() - hours * 3600000).toISOString(),
  expires: new Date(NOW.getTime() + 12 * 3600000).toISOString(),
});

const fresh = (dump) => aged(dump, 2);

function frame(title, note, build) {
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

function page(dump, { zone, locale, state, chosen } = {}) {
  const el = document.createElement('request-page');
  el.dump = dump;
  el.now = NOW;
  if (zone) el.zone = zone;
  if (locale) el.locale = locale;
  if (state) {
    el.state = state;
    el._email = 'alex@example.com';
    if (chosen !== false) {
      el._chosen = {
        slot: dump.slots[0],
        start: new Date(dump.slots[0].s),
        end: new Date(dump.slots[0].e),
        time: '10:00 AM',
        endTime: '10:30 AM',
        ownerTime: null,
      };
    }
  }
  return el;
}

const grid = document.getElementById('sheet');
const add = (...nodes) => grid.append(...nodes);

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
  frame('Expired dump', 'Lapse and expiry share one voice, and never say which', () =>
    page({ ...example, expires: '2026-08-31T00:00:00Z' }, { zone: 'America/Denver' }),
  ),
  frame('No page there', 'The only page a stranger sees cold', () => page(null)),
  frame('Nothing offered', 'Absence of a slot is not evidence of a meeting', () =>
    page({ ...fresh(example), slots: [] }, { zone: 'America/Denver' }),
  ),
);
