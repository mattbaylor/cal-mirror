import { LitElement, html, css, nothing } from 'lit';
import { tokens, base } from '../styles.js';

/**
 * Where a request got to.
 *
 * Every one of these is an end state for the page, so each says the same three
 * things: what happened, what happens next, and who does it. "Submitted" is
 * deliberately not congratulatory — nothing has been agreed yet, and a page
 * that celebrates at this point is making the promise the product refuses to.
 */
const STATES = {
  'confirm-your-email': {
    icon: '✉️',
    title: 'Check your email',
    body: (o) =>
      `We have sent a message to that address. Click the link in it and your request goes to ${o.ownerName} — until you do, nothing reaches them. The time is held for fifteen minutes.`,
    tone: 'wait',
  },
  submitted: {
    icon: '📤',
    title: 'Sent',
    body: (o) =>
      `${o.ownerName} will see this on their own device, and will accept or decline it. Nothing is in anyone's calendar yet.`,
    tone: 'wait',
  },
  accepted: {
    icon: '✅',
    title: 'Accepted',
    body: (o) =>
      `${o.ownerName} accepted, and has written the event into their calendar. The invitation is on its way to you by email, and you can add it now.`,
    tone: 'good',
  },
  declined: {
    icon: '🙏',
    title: 'Declined',
    body: (o) =>
      `${o.ownerName} could not make that time. Nothing was written to anyone's calendar, and the slot is free for someone else. You are welcome to ask for another.`,
    tone: 'plain',
  },
  expired: {
    icon: '⌛',
    title: 'This request ran out of time',
    body: (o) =>
      `Nobody got to it before it lapsed, so the time has been released. Asking again is the whole fix — ${o.ownerName} will see it fresh.`,
    tone: 'plain',
  },
  unavailable: {
    icon: '🌙',
    title: 'Not currently taking requests',
    body: () =>
      'This page is not accepting requests right now. It may be back — nothing here says either way.',
    tone: 'plain',
  },
};

export class RequestState extends LitElement {
  static properties = {
    state: { type: String },
    ownerName: { type: String },
    dayLabel: { type: String },
    time: { type: String },
    email: { type: String },
    canRetry: { type: Boolean },
  };

  static styles = [
    tokens,
    base,
    css`
      .panel {
        background: var(--card);
        border: 1px solid var(--line);
        border-radius: var(--radius);
        padding: 30px 26px;
        text-align: center;
      }

      .icon {
        font-size: 34px;
        line-height: 1;
        margin-bottom: 14px;
      }

      h2 {
        font-size: 22px;
        letter-spacing: -0.3px;
        margin: 0 0 10px;
      }

      p {
        color: var(--mut);
        margin: 0 auto;
        max-width: 44ch;
      }

      .when {
        margin-top: 18px;
        padding-top: 16px;
        border-top: 1px solid var(--line);
        color: var(--tx);
        font-weight: 600;
      }

      .addr {
        color: var(--tx);
        font-weight: 600;
        word-break: break-all;
      }

      button {
        font: inherit;
        font-size: 15px;
        color: var(--tx);
        background: var(--card2);
        border: 1px solid var(--line);
        border-radius: 999px;
        padding: 11px 22px;
        margin-top: 22px;
        cursor: pointer;
        min-height: 46px;
      }

      button:hover {
        border-color: var(--accent);
      }

      .good h2 {
        color: var(--good);
      }
    `,
  ];

  render() {
    const spec = STATES[this.state] ?? STATES.unavailable;
    const owner = { ownerName: this.ownerName || 'They' };

    return html`
      <div class="panel ${spec.tone}" role="status" aria-live="polite">
        <div class="icon" aria-hidden="true">${spec.icon}</div>
        <h2>${spec.title}</h2>
        <p>${spec.body(owner)}</p>
        ${this.email && this.state === 'confirm-your-email'
          ? html`<p style="margin-top:12px"><span class="addr">${this.email}</span></p>`
          : nothing}
        ${this.dayLabel && this.time
          ? html`<p class="when">${this.dayLabel} at ${this.time}</p>`
          : nothing}
        ${this.canRetry
          ? html`<button type="button" @click=${this.#again}>Ask for another time</button>`
          : nothing}
      </div>
    `;
  }

  #again() {
    this.dispatchEvent(new CustomEvent('request-restart', { bubbles: true, composed: true }));
  }
}

customElements.define('request-state', RequestState);
