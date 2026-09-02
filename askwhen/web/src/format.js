// Everything the page knows about time, in one pure module.
//
// The wire is UTC and only UTC — architecture §3 "Timezones". The browser is
// what localises, and it is the only thing that knows where the requester is.
// That confines the whole timezone problem to this file, where it can be tested
// against real DST boundaries instead of reasoned about.
//
// Nothing here touches the DOM, the network, or `new Date()` without being
// handed one. Every function that needs "now" takes it as an argument, so a
// test can stand anywhere in time.

/** The zone the requester is in, unless a caller pins one (tests, gallery). */
export function requesterZone(explicit) {
  if (explicit) return explicit;
  try {
    return Intl.DateTimeFormat().resolvedOptions().timeZone || 'UTC';
  } catch {
    return 'UTC';
  }
}

function partsOf(date, zone, options) {
  const fmt = new Intl.DateTimeFormat('en-US', { timeZone: zone, ...options });
  const out = {};
  for (const part of fmt.formatToParts(date)) out[part.type] = part.value;
  return out;
}

/**
 * The calendar day an instant falls on, in `zone`, as YYYY-MM-DD.
 *
 * This is the only correct way to ask the question. Reading UTC fields and
 * adjusting by a fixed offset is wrong twice a year, and wrong permanently for
 * the half-hour and three-quarter-hour zones.
 */
export function dayKey(date, zone) {
  const p = partsOf(date, zone, { year: 'numeric', month: '2-digit', day: '2-digit' });
  return `${p.year}-${p.month}-${p.day}`;
}

/** "9:00 AM" or "09:00", whichever the requester's locale actually uses. */
export function timeLabel(date, zone, locale) {
  return new Intl.DateTimeFormat(locale, {
    timeZone: zone,
    hour: 'numeric',
    minute: '2-digit',
  }).format(date);
}

/** "MDT", "GMT+5:30", "NZST" — the short zone name for this instant. */
export function zoneLabel(date, zone, locale) {
  const p = partsOf(date, zone, { timeZoneName: 'short' });
  if (p.timeZoneName) return p.timeZoneName;
  return new Intl.DateTimeFormat(locale, { timeZone: zone, timeZoneName: 'short' })
    .formatToParts(date)
    .filter((x) => x.type === 'timeZoneName')
    .map((x) => x.value)
    .join('');
}

/** "Wednesday, September 2" — the requester's locale decides the shape. */
export function dayHeading(date, zone, locale) {
  return new Intl.DateTimeFormat(locale, {
    timeZone: zone,
    weekday: 'long',
    month: 'long',
    day: 'numeric',
  }).format(date);
}

/** "Today", "Tomorrow", or null. Relative to `now`, in the requester's zone. */
export function relativeDayName(date, zone, now) {
  const key = dayKey(date, zone);
  if (key === dayKey(now, zone)) return 'Today';
  const tomorrow = new Date(now.getTime() + 86400000);
  if (key === dayKey(tomorrow, zone)) return 'Tomorrow';
  return null;
}

/**
 * Local midnight for a YYYY-MM-DD key in `zone`, as a UTC instant.
 *
 * Binary search rather than arithmetic. An offset-based guess has to be right
 * about DST to compute the thing that tells you about DST, and the days it gets
 * wrong are exactly the days worth testing.
 */
export function startOfLocalDay(key, zone) {
  const [y, m, d] = key.split('-').map(Number);
  let lo = Date.UTC(y, m - 1, d) - 18 * 3600000;
  let hi = Date.UTC(y, m - 1, d) + 18 * 3600000;
  while (hi - lo > 60000) {
    const mid = lo + Math.floor((hi - lo) / 2 / 60000) * 60000;
    if (dayKey(new Date(mid), zone) < key) lo = mid + 60000;
    else hi = mid;
  }
  return new Date(hi);
}

/** The Monday-based week key a day belongs to, as its own YYYY-MM-DD. */
export function weekStartKey(key, zone, weekStartsOn = 1) {
  const midnight = startOfLocalDay(key, zone);
  const p = partsOf(midnight, zone, { weekday: 'short' });
  const order = { Sun: 0, Mon: 1, Tue: 2, Wed: 3, Thu: 4, Fri: 5, Sat: 6 };
  const back = (order[p.weekday] - weekStartsOn + 7) % 7;
  // Step whole local days backwards. Subtracting 86400000 repeatedly would
  // drift across a DST change; re-deriving the key each step cannot.
  let cursor = key;
  for (let i = 0; i < back; i++) {
    cursor = dayKey(new Date(startOfLocalDay(cursor, zone).getTime() - 12 * 3600000), zone);
  }
  return cursor;
}

/** The seven day-keys of the week starting at `startKey`. */
export function weekDayKeys(startKey, zone) {
  const keys = [startKey];
  for (let i = 1; i < 7; i++) {
    const prev = startOfLocalDay(keys[i - 1], zone);
    keys.push(dayKey(new Date(prev.getTime() + 36 * 3600000), zone));
  }
  return keys;
}

/**
 * Group slots into local days, labelled and disambiguated.
 *
 * The disambiguation is the reason this is not a one-line reduce. On the day a
 * clock falls back, two distinct slots an hour apart render to the identical
 * local label — 1:30 am twice — and a requester picking one has no way to know
 * which. On such a day every time is qualified with the zone in force at that
 * instant: "1:30 AM MDT" and "1:30 AM MST".
 */
export function groupByDay(slots, zone, { locale, ownerZone } = {}) {
  const byKey = new Map();

  for (const slot of slots) {
    const start = new Date(slot.s);
    const end = new Date(slot.e);
    if (Number.isNaN(start.getTime()) || Number.isNaN(end.getTime())) continue;
    const key = dayKey(start, zone);
    if (!byKey.has(key)) byKey.set(key, []);
    byKey.get(key).push({
      slot,
      start,
      end,
      time: timeLabel(start, zone, locale),
      endTime: timeLabel(end, zone, locale),
      ownerTime: ownerZone && ownerZone !== zone ? timeLabel(start, ownerZone, locale) : null,
    });
  }

  const days = [];
  for (const key of [...byKey.keys()].sort()) {
    // Chronological, by instant. Sorting on the local wall clock looks
    // equivalent and is not: in the fold, 1:30 comes before 1:00 an hour later,
    // and a wall-clock sort interleaves the two passes through the hour.
    const entries = byKey.get(key).sort((a, b) => a.start - b.start);

    const seen = new Map();
    for (const e of entries) seen.set(e.time, (seen.get(e.time) || 0) + 1);
    const repeatedHour = [...seen.values()].some((n) => n > 1);

    if (repeatedHour) {
      // Qualify every time on the day, not only the colliding ones. A list
      // reading "1:00 AM MDT, 1:30 AM MDT, 1:00 AM MST, 2:00 AM" makes the
      // unqualified entry look like an oversight; the requester should not be
      // left working out which two of six needed the extra word.
      for (const e of entries) {
        e.zone = zoneLabel(e.start, zone, locale);
        e.time = `${e.time} ${e.zone}`;
      }
    }

    days.push({ key, midnight: startOfLocalDay(key, zone), entries, repeatedHour });
  }
  return days;
}

/**
 * Freshness, per architecture §4a. Shown, never hidden: a red light is the page
 * being straight, and the alternative is quietly serving week-old availability.
 */
export function freshness(generatedISO, now) {
  const generated = new Date(generatedISO);
  if (Number.isNaN(generated.getTime())) {
    return { level: 'red', text: 'Not updated recently. Times shown may be out of date.' };
  }
  const hours = (now.getTime() - generated.getTime()) / 3600000;
  if (hours < 6) return { level: 'green', text: 'Updated in the last few hours.', hours };
  if (hours < 24) return { level: 'amber', text: 'Updated yesterday — some times may have gone.', hours };
  return { level: 'red', text: 'Not updated recently. Times shown may be out of date.', hours };
}

/** A dump past its own `expires` is not availability any more. */
export function isExpired(dump, now) {
  const expires = new Date(dump?.expires);
  if (Number.isNaN(expires.getTime())) return false;
  return expires.getTime() <= now.getTime();
}

/** Slots that have not already started. A snapshot can outlive its own times. */
export function upcoming(slots, now) {
  return slots.filter((s) => new Date(s.s).getTime() > now.getTime());
}
