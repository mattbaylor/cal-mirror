import { LitElement, html, css, nothing } from 'lit';
import { tokens, base } from '../styles.js';
import './slot-button.js';
import {
  dayHeading,
  dayKey,
  groupByDay,
  relativeDayName,
  startOfLocalDay,
  weekDayKeys,
  weekStartKey,
} from '../format.js';

/**
 * A week of offers, in the requester's own timezone.
 *
 * A week at a time rather than the whole horizon: 45 days of pills is a wall,
 * and the design asks for one question on screen at a time. Every day in the
 * week is listed, including the empty ones — a day with nothing offered says
 * "nothing offered", never disappears. Absence of a slot is not evidence of a
 * meeting, and a page that quietly omits days invites the opposite reading.
 */
export class AvailabilityWeek extends LitElement {
  static properties = {
    slots: { type: Array },
    zone: { type: String },
    ownerZone: { type: String },
    ownerName: { type: String },
    locale: { type: String },
    now: { type: Object },
    selected: { type: String },
    held: { type: Array },
    _weekStart: { state: true },
  };

  constructor() {
    super();
    this.slots = [];
    this.held = [];
    this._weekStart = null;
  }

  static styles = [
    tokens,
    base,
    css`
      .nav {
        display: flex;
        align-items: baseline;
        justify-content: space-between;
        gap: 12px;
        margin-bottom: 18px;
      }

      .range {
        font-size: 14px;
        color: var(--mut);
      }

      .steps {
        display: flex;
        gap: 8px;
      }

      .steps button {
        font: inherit;
        font-size: 14px;
        color: var(--tx);
        background: var(--card);
        border: 1px solid var(--line);
        border-radius: 999px;
        padding: 7px 14px;
        cursor: pointer;
        min-height: 40px;
      }

      .steps button:hover:not(:disabled) {
        border-color: var(--accent);
      }

      .steps button:disabled {
        opacity: 0.4;
        cursor: default;
      }

      .day {
        padding: 16px 0;
        border-top: 1px solid var(--line);
      }

      .day:first-of-type {
        border-top: none;
      }

      h3 {
        font-size: 13px;
        font-weight: 700;
        text-transform: uppercase;
        letter-spacing: 0.6px;
        color: var(--mut);
        margin: 0 0 10px;
      }

      h3 .rel {
        color: var(--accent);
      }

      .slots {
        display: flex;
        flex-wrap: wrap;
        gap: 8px;
      }

      .empty {
        color: var(--dim);
        font-size: 14.5px;
      }

      .none {
        color: var(--mut);
        font-size: 15px;
        padding: 28px 0;
      }
    `,
  ];

  /** Local day-keys that have at least one offer, in order. */
  get #daysWithSlots() {
    const zone = this.zone;
    return [...new Set(this.slots.map((s) => dayKey(new Date(s.s), zone)))].sort();
  }

  get #weekStart() {
    if (this._weekStart) return this._weekStart;
    const first = this.#daysWithSlots[0];
    const anchor = first || dayKey(this.now ?? new Date(), this.zone);
    return weekStartKey(anchor, this.zone);
  }

  #weekBounds() {
    const days = this.#daysWithSlots;
    if (!days.length) return { first: null, last: null };
    return {
      first: weekStartKey(days[0], this.zone),
      last: weekStartKey(days[days.length - 1], this.zone),
    };
  }

  #step(direction) {
    const keys = weekDayKeys(this.#weekStart, this.zone);
    const pivot = direction > 0 ? keys[6] : keys[0];
    const anchor = startOfLocalDay(pivot, this.zone).getTime() + direction * 36 * 3600000;
    this._weekStart = weekStartKey(dayKey(new Date(anchor), this.zone), this.zone);
  }

  render() {
    if (!this.slots.length) {
      return html`<p class="none">
        No times are being offered at the moment. That is all this page knows — it says
        nothing about how busy the week is.
      </p>`;
    }

    const now = this.now ?? new Date();
    const locale = this.locale;
    const grouped = new Map(
      groupByDay(this.slots, this.zone, { locale, ownerZone: this.ownerZone }).map((d) => [d.key, d]),
    );
    // Days already gone are not offers, and a page that opens on two lines of
    // "no times offered" from last week buries the thing it exists to show.
    const today = dayKey(now, this.zone);
    const keys = weekDayKeys(this.#weekStart, this.zone).filter((key) => key >= today);
    const { first, last } = this.#weekBounds();
    const held = new Set(this.held ?? []);

    return html`
      <div class="nav">
        <span class="range">${this.#rangeLabel(keys, locale)}</span>
        <div class="steps">
          <button
            type="button"
            ?disabled=${!first || this.#weekStart <= first}
            @click=${() => this.#step(-1)}
          >
            <span aria-hidden="true">&larr;</span>
            <span class="sr-only">Previous week</span>
          </button>
          <button
            type="button"
            ?disabled=${!last || this.#weekStart >= last}
            @click=${() => this.#step(1)}
          >
            <span aria-hidden="true">&rarr;</span>
            <span class="sr-only">Next week</span>
          </button>
        </div>
      </div>

      ${keys.length
        ? keys.map((key) => this.#renderDay(key, grouped.get(key), now, locale, held))
        : html`<p class="none">Nothing left this week.</p>`}
    `;
  }

  #rangeLabel(keys, locale) {
    if (!keys.length) return '';
    const from = startOfLocalDay(keys[0], this.zone);
    const to = startOfLocalDay(keys[keys.length - 1], this.zone);
    // formatRange, not two formats joined by a dash. Hand-assembling this puts
    // the month on whichever side English happens to want it, and gets every
    // other locale — and the month boundary — wrong.
    return new Intl.DateTimeFormat(locale, {
      timeZone: this.zone,
      month: 'long',
      day: 'numeric',
    }).formatRange(from, to);
  }

  #renderDay(key, day, now, locale, held) {
    const midnight = startOfLocalDay(key, this.zone);
    const heading = dayHeading(midnight, this.zone, locale);
    const relative = relativeDayName(midnight, this.zone, now);

    return html`
      <section class="day">
        <h3>
          ${relative ? html`<span class="rel">${relative}</span> &middot; ` : nothing}${heading}
        </h3>
        ${day
          ? html`<div class="slots">
              ${day.entries.map(
                (entry) => html`
                  <slot-button
                    .time=${entry.time}
                    .endTime=${entry.endTime}
                    .ownerTime=${entry.ownerTime}
                    .ownerName=${this.ownerName}
                    .dayLabel=${heading}
                    ?selected=${this.selected === entry.slot.s}
                    ?held=${held.has(entry.slot.s)}
                    @slot-picked=${() => this.#pick(entry)}
                  ></slot-button>
                `,
              )}
            </div>`
          : html`<p class="empty">No times offered.</p>`}
      </section>
    `;
  }

  #pick(entry) {
    this.dispatchEvent(
      new CustomEvent('slot-chosen', { detail: entry, bubbles: true, composed: true }),
    );
  }
}

customElements.define('availability-week', AvailabilityWeek);
