// The timezone tests. Step 2 is "done when it renders the example dump
// correctly in three timezones including one across a DST change", and this is
// where that claim is actually made — the components only arrange what these
// functions return.
//
// Three zones, chosen to break different things:
//   America/Denver   — DST, and a fall-back that renders one label twice
//   Asia/Kolkata     — no DST, but a :30 offset that pushes slots to another day
//   Pacific/Auckland — DST in the other hemisphere, and far enough east that
//                      every UTC afternoon is already tomorrow

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

import {
  dayKey,
  dayHeading,
  freshness,
  groupByDay,
  isExpired,
  relativeDayName,
  startOfLocalDay,
  timeLabel,
  upcoming,
  weekDayKeys,
  weekStartKey,
  zoneLabel,
} from '../src/format.js';

const read = (p) => JSON.parse(readFileSync(fileURLToPath(new URL(p, import.meta.url)), 'utf8'));

const EXAMPLE = read('../../schema/policy-dump.example.json');
const DENVER_DST = read('./fixtures/dst-america-denver.json');
const AUCKLAND_DST = read('./fixtures/dst-pacific-auckland.json');

const EN = 'en-US';
const times = (days) => days.map((d) => [d.key, d.entries.map((e) => e.time)]);

// ---------------------------------------------------------------- day keying

test('dayKey reads the calendar day in the zone, not in UTC', () => {
  const instant = new Date('2026-09-02T20:00:00Z');
  assert.equal(dayKey(instant, 'America/Denver'), '2026-09-02');
  assert.equal(dayKey(instant, 'UTC'), '2026-09-02');
  // +5:30 tips this instant into the next calendar day.
  assert.equal(dayKey(instant, 'Asia/Kolkata'), '2026-09-03');
  // +12 does the same, a whole afternoon earlier.
  assert.equal(dayKey(instant, 'Pacific/Auckland'), '2026-09-03');
});

test('slots within a day run in real order, not wall-clock order', () => {
  // The distinction only shows up in the fold, which is why it is easy to get
  // wrong: on 1 Nov the wall clock reads 1:00, 1:30, 1:00, 1:30, so ordering by
  // the clock interleaves the two passes through the hour.
  const days = groupByDay(DENVER_DST.slots, 'America/Denver', { locale: EN });
  const starts = days[1].entries.map((e) => e.start.toISOString());
  assert.deepEqual(starts, [...starts].sort());
});

test('startOfLocalDay lands on local midnight, not on a fixed offset', () => {
  assert.equal(startOfLocalDay('2026-09-02', 'America/Denver').toISOString(), '2026-09-02T06:00:00.000Z');
  assert.equal(startOfLocalDay('2026-11-02', 'America/Denver').toISOString(), '2026-11-02T07:00:00.000Z');
  assert.equal(startOfLocalDay('2026-09-03', 'Asia/Kolkata').toISOString(), '2026-09-02T18:30:00.000Z');
  assert.equal(startOfLocalDay('2026-09-28', 'Pacific/Auckland').toISOString(), '2026-09-27T11:00:00.000Z');
});

test('startOfLocalDay survives the day a clock jumps forward', () => {
  // 27 Sep 2026, 2am NZST becomes 3am NZDT. Midnight is still midnight.
  assert.equal(startOfLocalDay('2026-09-27', 'Pacific/Auckland').toISOString(), '2026-09-26T12:00:00.000Z');
  // 8 Mar 2026, 2am MST becomes 3am MDT.
  assert.equal(startOfLocalDay('2026-03-08', 'America/Denver').toISOString(), '2026-03-08T07:00:00.000Z');
});

// ------------------------------------------------- the three-timezone claim

test('the example dump groups correctly in America/Denver', () => {
  const days = groupByDay(EXAMPLE.slots, 'America/Denver', { locale: EN, ownerZone: EXAMPLE.display.tz });
  assert.deepEqual(times(days), [
    ['2026-09-02', ['10:00 AM', '10:30 AM', '2:00 PM']],
    ['2026-09-03', ['10:00 AM']],
  ]);
  // The owner is in this zone, so no second time is offered.
  assert.equal(days[0].entries[0].ownerTime, null);
});

test('the example dump groups correctly in Asia/Kolkata, half-hour offset and all', () => {
  const days = groupByDay(EXAMPLE.slots, 'Asia/Kolkata', { locale: EN, ownerZone: EXAMPLE.display.tz });
  assert.deepEqual(times(days), [
    ['2026-09-02', ['9:30 PM', '10:00 PM']],
    // 20:00Z is 1:30 the next morning here, and sorts before the evening slot.
    ['2026-09-03', ['1:30 AM', '9:30 PM']],
  ]);
  assert.equal(days[1].entries[0].ownerTime, '2:00 PM');
});

test('the example dump groups correctly in Pacific/Auckland, a day ahead throughout', () => {
  const days = groupByDay(EXAMPLE.slots, 'Pacific/Auckland', { locale: EN, ownerZone: EXAMPLE.display.tz });
  assert.deepEqual(times(days), [
    ['2026-09-03', ['4:00 AM', '4:30 AM', '8:00 AM']],
    ['2026-09-04', ['4:00 AM']],
  ]);
});

test('no slot is lost or duplicated by any of the three zones', () => {
  for (const zone of ['America/Denver', 'Asia/Kolkata', 'Pacific/Auckland', 'UTC']) {
    const days = groupByDay(EXAMPLE.slots, zone, { locale: EN });
    const flat = days.flatMap((d) => d.entries.map((e) => e.slot.s));
    assert.equal(flat.length, EXAMPLE.slots.length, zone);
    assert.deepEqual([...flat].sort(), EXAMPLE.slots.map((s) => s.s).sort(), zone);
  }
});

// ----------------------------------------------------- the DST claim proper

test('fall back: the repeated hour is disambiguated rather than shown twice', () => {
  const days = groupByDay(DENVER_DST.slots, 'America/Denver', { locale: EN });
  assert.deepEqual(times(days), [
    ['2026-10-31', ['10:00 AM']],
    [
      '2026-11-01',
      // 1:00 and 1:30 each happen twice. Bare labels would be a coin flip for
      // the requester, so the zone name is appended — and only here.
      ['1:00 AM MDT', '1:30 AM MDT', '1:00 AM MST', '1:30 AM MST', '2:00 AM MST', '10:00 AM MST'],
    ],
  ]);
});

test('fall back: the ambiguous pair really are an hour apart', () => {
  const days = groupByDay(DENVER_DST.slots, 'America/Denver', { locale: EN });
  const [mdt, , mst] = days[1].entries;
  assert.equal(mdt.time, '1:00 AM MDT');
  assert.equal(mst.time, '1:00 AM MST');
  assert.equal(mst.start - mdt.start, 3600000);
});

test('fall back: the day is 25 hours long and nothing spills into the next', () => {
  const start = startOfLocalDay('2026-11-01', 'America/Denver');
  const next = startOfLocalDay('2026-11-02', 'America/Denver');
  assert.equal((next - start) / 3600000, 25);
  const days = groupByDay(DENVER_DST.slots, 'America/Denver', { locale: EN });
  assert.equal(days.length, 2);
  assert.equal(days[1].entries.length, 6);
});

test('spring forward: a 23-hour day, and no false ambiguity', () => {
  const start = startOfLocalDay('2026-09-27', 'Pacific/Auckland');
  const next = startOfLocalDay('2026-09-28', 'Pacific/Auckland');
  assert.equal((next - start) / 3600000, 23);

  const days = groupByDay(AUCKLAND_DST.slots, 'Pacific/Auckland', { locale: EN });
  assert.deepEqual(times(days), [
    ['2026-09-26', ['10:00 AM']],
    ['2026-09-27', ['1:00 AM', '3:30 AM', '9:00 AM']],
  ]);
  // Nothing collided, so nothing is labelled — the zone name is a fix for a
  // real problem, not decoration applied on any day a clock happens to move.
  for (const day of days) assert.equal(day.repeatedHour, false);
});

test('a requester elsewhere sees the transition as an ordinary hour', () => {
  // The same six Denver slots, read from Kolkata, are simply consecutive.
  const days = groupByDay(DENVER_DST.slots, 'Asia/Kolkata', { locale: EN });
  const all = days.flatMap((d) => d.entries.map((e) => e.time));
  assert.deepEqual(all, ['9:30 PM', '12:30 PM', '1:00 PM', '1:30 PM', '2:00 PM', '2:30 PM', '10:30 PM']);
  for (const day of days) assert.equal(day.repeatedHour, false);
});

test('zoneLabel names the offset actually in force at that instant', () => {
  assert.equal(zoneLabel(new Date('2026-11-01T07:30:00Z'), 'America/Denver', EN), 'MDT');
  assert.equal(zoneLabel(new Date('2026-11-01T08:30:00Z'), 'America/Denver', EN), 'MST');
});

// -------------------------------------------------------------- week paging

test('weeks start on Monday and step whole local days across a DST change', () => {
  assert.equal(weekStartKey('2026-09-02', 'America/Denver'), '2026-08-31');
  assert.equal(weekStartKey('2026-08-31', 'America/Denver'), '2026-08-31');
  assert.equal(weekStartKey('2026-09-06', 'America/Denver'), '2026-08-31');
  // The week containing the fall-back Sunday.
  assert.equal(weekStartKey('2026-11-01', 'America/Denver'), '2026-10-26');
  assert.deepEqual(weekDayKeys('2026-10-26', 'America/Denver'), [
    '2026-10-26', '2026-10-27', '2026-10-28', '2026-10-29', '2026-10-30', '2026-10-31', '2026-11-01',
  ]);
});

test('week keys stay whole days across a spring-forward too', () => {
  assert.deepEqual(weekDayKeys('2026-09-21', 'Pacific/Auckland'), [
    '2026-09-21', '2026-09-22', '2026-09-23', '2026-09-24', '2026-09-25', '2026-09-26', '2026-09-27',
  ]);
});

// ----------------------------------------------------- freshness and expiry

test('freshness is the stoplight from architecture 4a', () => {
  const generated = '2026-09-01T15:00:00Z';
  assert.equal(freshness(generated, new Date('2026-09-01T18:00:00Z')).level, 'green');
  assert.equal(freshness(generated, new Date('2026-09-01T21:30:00Z')).level, 'amber');
  assert.equal(freshness(generated, new Date('2026-09-02T16:00:00Z')).level, 'red');
  // A dump with an unreadable timestamp is old, not fresh. Fail toward honest.
  assert.equal(freshness('not a date', new Date()).level, 'red');
});

test('an expired dump is not availability', () => {
  assert.equal(isExpired(EXAMPLE, new Date('2026-09-02T14:59:00Z')), false);
  assert.equal(isExpired(EXAMPLE, new Date('2026-09-02T15:00:00Z')), true);
});

test('slots that have already started are not offered', () => {
  const left = upcoming(EXAMPLE.slots, new Date('2026-09-02T16:29:00Z'));
  assert.deepEqual(left.map((s) => s.s), ['2026-09-02T16:30:00Z', '2026-09-02T20:00:00Z', '2026-09-03T16:00:00Z']);
});

// ------------------------------------------------------------------ labels

test('day headings and relative names follow the requester, not the owner', () => {
  const instant = new Date('2026-09-02T20:00:00Z');
  assert.equal(dayHeading(instant, 'America/Denver', EN), 'Wednesday, September 2');
  assert.equal(dayHeading(instant, 'Pacific/Auckland', EN), 'Thursday, September 3');
  assert.equal(relativeDayName(instant, 'America/Denver', new Date('2026-09-02T18:00:00Z')), 'Today');
  assert.equal(relativeDayName(instant, 'America/Denver', new Date('2026-09-01T18:00:00Z')), 'Tomorrow');
  assert.equal(relativeDayName(instant, 'America/Denver', new Date('2026-08-30T18:00:00Z')), null);
});

test('time labels respect the locale, not a hardcoded 12-hour clock', () => {
  const instant = new Date('2026-09-02T20:00:00Z');
  assert.equal(timeLabel(instant, 'America/Denver', 'en-US'), '2:00 PM');
  assert.equal(timeLabel(instant, 'en-GB' && 'Europe/London', 'en-GB'), '21:00');
});
