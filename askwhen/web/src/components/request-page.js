import { LitElement, html, css, nothing } from 'lit';
import { tokens, base } from '../styles.js';
import './availability-week.js';
import './request-form.js';
import './request-state.js';
import { dayHeading, freshness, isExpired, requesterZone, upcoming } from '../format.js';

const STEPS = ['Pick a time', 'Say who you are', 'Confirm your email', 'They answer'];

/**
 * The whole request page.
 *
 * One application, N pages: a slug selects a dump, and the dump is the only
 * difference between two of these. Everything visible is derived from the dump
 * plus the browser's own idea of where and when it is.
 *
 * `zone`, `locale` and `now` are settable so the gallery can stand this page in
 * three timezones at once and the tests can stand it anywhere in time. Left
 * alone they resolve to the requester's real ones, which is the only thing that
 * happens in production.
 */
export class RequestPage extends LitElement {
  static properties = {
    dump: { type: Object },
    zone: { type: String },
    locale: { type: String },
    now: { type: Object },
    state: { type: String, reflect: true },
    _chosen: { state: true },
    _email: { state: true },
  };

  constructor() {
    super();
    this.state = 'picking';
    this._chosen = null;
    this._email = '';
  }

  static styles = [
    tokens,
    base,
    css`
      :host {
        display: block;
        background: var(--bg);
        min-height: 100%;
      }

      .wrap {
        max-width: 660px;
        margin: 0 auto;
        padding: 44px 20px 96px;
      }

      header {
        margin-bottom: 26px;
      }

      h1 {
        font-size: 30px;
        letter-spacing: -0.6px;
        line-height: 1.2;
        margin: 0 0 6px;
      }

      .blurb {
        color: var(--mut);
        margin: 0;
      }

      .shape {
        color: var(--dim);
        font-size: 14px;
        margin: 10px 0 0;
      }

      .fresh {
        display: flex;
        align-items: flex-start;
        gap: 9px;
        font-size: 13.5px;
        color: var(--mut);
        margin: 20px 0 0;
        padding: 11px 14px;
        background: var(--card2);
        border: 1px solid var(--line);
        border-radius: 12px;
      }

      .dot {
        width: 9px;
        height: 9px;
        border-radius: 50%;
        flex: none;
        margin-top: 6px;
      }

      .dot.green {
        background: var(--good);
      }
      .dot.amber {
        background: var(--warn);
      }
      .dot.red {
        background: var(--bad);
      }

      ol.path {
        display: flex;
        flex-wrap: wrap;
        gap: 6px 14px;
        list-style: none;
        margin: 26px 0 30px;
        padding: 0;
        font-size: 13px;
        color: var(--dim);
      }

      ol.path li {
        display: flex;
        align-items: center;
        gap: 7px;
      }

      ol.path .n {
        display: grid;
        place-items: center;
        width: 20px;
        height: 20px;
        border-radius: 50%;
        border: 1px solid var(--line);
        font-size: 11px;
        flex: none;
      }

      ol.path li[aria-current] {
        color: var(--tx);
        font-weight: 600;
      }

      ol.path li[aria-current] .n {
        background: var(--accent);
        border-color: var(--accent);
        color: #06121f;
      }

      ol.path li.done .n {
        background: var(--card2);
      }

      h2.lede {
        font-size: 19px;
        letter-spacing: -0.2px;
        margin: 0 0 4px;
      }

      .zone {
        color: var(--dim);
        font-size: 13.5px;
        margin: 0 0 22px;
      }

      .chosen {
        background: var(--card);
        border: 1px solid var(--line);
        border-radius: 12px;
        padding: 14px 16px;
        margin-bottom: 22px;
      }

      .chosen .when {
        font-weight: 600;
      }

      .chosen .sub {
        color: var(--mut);
        font-size: 13.5px;
        margin-top: 3px;
      }

      footer {
        margin-top: 44px;
        padding-top: 18px;
        border-top: 1px solid var(--line);
        color: var(--dim);
        font-size: 13px;
      }

      footer p {
        margin: 0 0 8px;
      }

      .missing {
        text-align: center;
        padding: 70px 0;
      }

      .missing h1 {
        font-size: 26px;
      }

      @media (max-width: 420px) {
        .wrap {
          padding: 30px 16px 72px;
        }
        h1 {
          font-size: 25px;
        }
      }
    `,
  ];

  get #zone() {
    return requesterZone(this.zone);
  }

  get #now() {
    return this.now ?? new Date();
  }

  render() {
    if (!this.dump) return this.#renderMissing();

    const dump = this.dump;
    const now = this.#now;
    const name = dump.display?.name || 'this person';

    if (isExpired(dump, now)) {
      return this.#shell(
        dump,
        html`<request-state state="unavailable" .ownerName=${name}></request-state>`,
        null,
      );
    }

    const live = upcoming(dump.slots ?? [], now);

    switch (this.state) {
      case 'form':
        return this.#shell(dump, this.#renderForm(name), 1);
      case 'confirm-your-email':
      case 'submitted':
      case 'accepted':
      case 'declined':
      case 'expired':
        return this.#shell(dump, this.#renderState(name), this.state === 'confirm-your-email' ? 2 : 3);
      default:
        return this.#shell(dump, this.#renderPicking(dump, live, name), 0);
    }
  }

  #shell(dump, body, step) {
    const now = this.#now;
    const fresh = freshness(dump.generated, now);
    const name = dump.display?.name || 'this person';
    const minutes = dump.meeting?.minutes;

    return html`
      <div class="wrap">
        <header>
          <h1>Ask ${name} for a time</h1>
          ${dump.display?.blurb ? html`<p class="blurb">${dump.display.blurb}</p>` : nothing}
          ${minutes
            ? html`<p class="shape">
                ${minutes} minutes${dump.meeting?.location ? ` · ${dump.meeting.location}` : ''}
              </p>`
            : nothing}
          <p class="fresh">
            <span class="dot ${fresh.level}" aria-hidden="true"></span>
            <span>${fresh.text} Times here are an offer, not a reservation — ${name} confirms every one.</span>
          </p>
        </header>

        ${step === null ? nothing : this.#renderPath(step, name)} ${body}

        <footer>
          <p>
            This page holds nothing but the times ${name} chose to offer. It has no calendar, no
            account, and no third-party script — no fonts, no analytics, nothing that phones
            anywhere.
          </p>
          <p>askwhen.me</p>
        </footer>
      </div>
    `;
  }

  #renderPath(current, name) {
    const labels = [...STEPS];
    labels[3] = `${name} answers`;
    return html`
      <ol class="path">
        ${labels.map(
          (label, i) => html`
            <li
              class=${i < current ? 'done' : ''}
              aria-current=${i === current ? 'step' : nothing}
            >
              <span class="n" aria-hidden="true">${i < current ? '✓' : i + 1}</span>${label}
            </li>
          `,
        )}
      </ol>
    `;
  }

  #renderPicking(dump, live, name) {
    const zone = this.#zone;
    return html`
      <h2 class="lede">Pick a time that suits you</h2>
      <p class="zone">
        Shown in your own time zone, ${zone.replace(/_/g, ' ')}.${dump.display?.tz &&
        dump.display.tz !== zone
          ? ` ${name} is in ${dump.display.tz.replace(/_/g, ' ')}.`
          : ''}
      </p>
      <availability-week
        .slots=${live}
        .zone=${zone}
        .ownerZone=${dump.display?.tz}
        .ownerName=${name}
        .locale=${this.locale}
        .now=${this.#now}
        .selected=${this._chosen?.slot.s}
        @slot-chosen=${this.#chooseSlot}
      ></availability-week>
    `;
  }

  #renderForm(name) {
    const chosen = this._chosen;
    const heading = dayHeading(chosen.start, this.#zone, this.locale);
    return html`
      <h2 class="lede">Tell ${name} who is asking</h2>
      <p class="zone">Two fields. There is no account, and there never will be.</p>
      <div class="chosen">
        <div class="when">${heading} at ${chosen.time}</div>
        <div class="sub">
          ${this.dump.meeting?.minutes} minutes${chosen.ownerTime
            ? ` · ${chosen.ownerTime} where ${name} is`
            : ''}
        </div>
      </div>
      <request-form
        .ownerName=${name}
        @request-submitted=${this.#submit}
        @request-cancelled=${this.#restart}
      ></request-form>
    `;
  }

  #renderState(name) {
    const chosen = this._chosen;
    return html`
      <request-state
        .state=${this.state}
        .ownerName=${name}
        .email=${this._email}
        .dayLabel=${chosen ? dayHeading(chosen.start, this.#zone, this.locale) : ''}
        .time=${chosen?.time ?? ''}
        ?canRetry=${this.state === 'declined' || this.state === 'expired'}
        @request-restart=${this.#restart}
      ></request-state>
    `;
  }

  #renderMissing() {
    return html`
      <div class="wrap missing">
        <h1>There is no page here</h1>
        <p class="blurb">
          This link may be wrong, or the page it pointed at is no longer taking requests.
        </p>
        <footer style="margin-top:34px">
          <p>
            askwhen.me is a request page whose server never learns whose calendar it is. Availability
            is worked out on the owner's own device; nothing else ever leaves it.
          </p>
        </footer>
      </div>
    `;
  }

  #chooseSlot(event) {
    this._chosen = event.detail;
    this.state = 'form';
    this.#announce();
  }

  #submit(event) {
    // Step 2 has no service. A trapped submission is accepted here and dropped,
    // so the page looks identical either way; step 3 is where it stops going
    // anywhere at all.
    this._email = event.detail.email;
    this.state = 'confirm-your-email';
    this.#announce();
    this.dispatchEvent(
      new CustomEvent('request-ready', {
        detail: { ...event.detail, slot: this._chosen?.slot },
        bubbles: true,
        composed: true,
      }),
    );
  }

  #restart() {
    this.state = 'picking';
    this._chosen = null;
    this.#announce();
  }

  /** Move focus to the top of the new step. A shell that swaps its middle
   *  without doing this leaves a keyboard user where the old content was. */
  #announce() {
    this.updateComplete.then(() => {
      const target = this.renderRoot.querySelector('h2.lede, request-state');
      if (target && 'focus' in target) {
        target.setAttribute('tabindex', '-1');
        target.focus({ preventScroll: false });
      }
    });
  }
}

customElements.define('request-page', RequestPage);
