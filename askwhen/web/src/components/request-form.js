import { LitElement, html, css, nothing } from 'lit';
import { tokens, base } from '../styles.js';

// Deliberately permissive. The confirmation email is what actually proves an
// address, so a stricter pattern here only rejects valid addresses — plus
// addresses, long TLDs, unicode local parts — for no gain.
const LOOKS_LIKE_EMAIL = /^[^\s@]+@[^\s@.]+\.[^\s@]+$/;

const NOTE_LIMIT = 500;

/**
 * Who is asking, and what for.
 *
 * Two required fields and one optional one. Nothing else is asked of a
 * requester, ever — no account, no phone number, no company. The note goes in
 * the event body; the owner titles the event, so nothing typed here can name
 * anything in their calendar.
 *
 * The honeypot is the whole bot defence at this stage. Proof of work is named
 * in the architecture but deferred by `design/decisions.md` — MVP is double
 * opt-in, honeypot and a per-IP limit — so there is no widget here and no
 * third-party script to load one.
 */
export class RequestForm extends LitElement {
  static properties = {
    ownerName: { type: String },
    dayLabel: { type: String },
    time: { type: String },
    minutes: { type: Number },
    busy: { type: Boolean },
    _errors: { state: true },
    _noteLength: { state: true },
  };

  constructor() {
    super();
    this._errors = {};
    this._noteLength = 0;
  }

  static styles = [
    tokens,
    base,
    css`
      form {
        display: grid;
        gap: 18px;
      }

      label {
        display: block;
        font-size: 14px;
        font-weight: 600;
        margin-bottom: 6px;
      }

      .hint {
        display: block;
        font-weight: 400;
        font-size: 13px;
        color: var(--mut);
        margin-top: 2px;
      }

      input,
      textarea {
        width: 100%;
        font: inherit;
        font-size: 16px;
        color: var(--tx);
        background: var(--card);
        border: 1px solid var(--line);
        border-radius: 10px;
        padding: 11px 13px;
        min-height: 46px;
      }

      textarea {
        min-height: 96px;
        resize: vertical;
      }

      input[aria-invalid='true'],
      textarea[aria-invalid='true'] {
        border-color: var(--bad);
      }

      .err {
        color: var(--bad);
        font-size: 13.5px;
        margin: 6px 0 0;
      }

      .count {
        font-size: 12.5px;
        color: var(--dim);
        margin: 6px 0 0;
        text-align: right;
      }

      .actions {
        display: flex;
        flex-wrap: wrap;
        gap: 12px;
        align-items: center;
      }

      button[type='submit'] {
        font: inherit;
        font-weight: 600;
        font-size: 16px;
        color: #06121f;
        background: var(--accent);
        border: 1px solid var(--accent);
        border-radius: 999px;
        padding: 12px 26px;
        cursor: pointer;
        min-height: 48px;
      }

      button[type='submit']:disabled {
        opacity: 0.6;
        cursor: default;
      }

      .back {
        font: inherit;
        font-size: 15px;
        color: var(--mut);
        background: none;
        border: none;
        padding: 12px 4px;
        cursor: pointer;
        text-decoration: underline;
        min-height: 48px;
      }

      .trap {
        position: absolute;
        left: -9999px;
        width: 1px;
        height: 1px;
        overflow: hidden;
      }
    `,
  ];

  render() {
    return html`
      <form novalidate @submit=${this.#submit}>
        <div>
          <label for="name">Your name</label>
          <input
            id="name"
            name="name"
            autocomplete="name"
            required
            aria-invalid=${this._errors.name ? 'true' : 'false'}
            aria-describedby=${this._errors.name ? 'name-err' : nothing}
          />
          ${this._errors.name ? html`<p class="err" id="name-err">${this._errors.name}</p>` : nothing}
        </div>

        <div>
          <label for="email">
            Your email
            <span class="hint"
              >${this.ownerName || 'They'} never sees it until you confirm it, and it is only used
              to send you this one reply.</span
            >
          </label>
          <input
            id="email"
            name="email"
            type="email"
            inputmode="email"
            autocomplete="email"
            required
            aria-invalid=${this._errors.email ? 'true' : 'false'}
            aria-describedby=${this._errors.email ? 'email-err' : nothing}
          />
          ${this._errors.email ? html`<p class="err" id="email-err">${this._errors.email}</p>` : nothing}
        </div>

        <div>
          <label for="note">
            What is it about?
            <span class="hint">Optional. Goes in the note, not the title.</span>
          </label>
          <textarea
            id="note"
            name="note"
            maxlength=${NOTE_LIMIT}
            aria-describedby="note-count"
            @input=${(e) => (this._noteLength = e.target.value.length)}
          ></textarea>
          <p class="count" id="note-count">${NOTE_LIMIT - this._noteLength} characters left</p>
        </div>

        <!-- Not for people. Anything that fills this in is not one. -->
        <div class="trap" aria-hidden="true">
          <label for="website">Leave this empty</label>
          <input id="website" name="website" type="text" tabindex="-1" autocomplete="off" />
        </div>

        <div class="actions">
          <button type="submit" ?disabled=${this.busy}>
            ${this.busy ? 'Sending…' : 'Send the request'}
          </button>
          <button type="button" class="back" @click=${this.#back}>Pick a different time</button>
        </div>
      </form>
    `;
  }

  #field(id) {
    return this.renderRoot.querySelector(`#${id}`);
  }

  #submit(event) {
    event.preventDefault();

    const name = this.#field('name').value.trim();
    const email = this.#field('email').value.trim();
    const note = this.#field('note').value.trim();
    const trap = this.#field('website').value;

    const errors = {};
    if (!name) errors.name = 'Please add a name, so they know who is asking.';
    if (!email) errors.email = 'Please add an email — it is how you get an answer.';
    else if (!LOOKS_LIKE_EMAIL.test(email)) errors.email = 'That does not look like an email address.';
    this._errors = errors;

    const firstBad = Object.keys(errors)[0];
    if (firstBad) {
      this.#field(firstBad).focus();
      return;
    }

    // A filled trap is silently accepted and goes nowhere. Telling a bot it was
    // caught only teaches whoever wrote it to stop filling the field.
    this.dispatchEvent(
      new CustomEvent('request-submitted', {
        detail: { name, email, note, trapped: trap.length > 0 },
        bubbles: true,
        composed: true,
      }),
    );
  }

  #back() {
    this.dispatchEvent(new CustomEvent('request-cancelled', { bubbles: true, composed: true }));
  }
}

customElements.define('request-form', RequestForm);
