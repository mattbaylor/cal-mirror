import { LitElement, html, css } from 'lit';
import { tokens, base } from '../styles.js';

/**
 * One offerable interval.
 *
 * A slot is an *offer*, not free time — it has already been through the owner's
 * policy — so the button says a time and commits to nothing else. The visible
 * label is short; the accessible name is the whole sentence, because a screen
 * reader user arriving at "10:00 AM" in a list of forty has no other context.
 */
export class SlotButton extends LitElement {
  static properties = {
    time: { type: String },
    endTime: { type: String },
    ownerTime: { type: String },
    ownerName: { type: String },
    dayLabel: { type: String },
    selected: { type: Boolean, reflect: true },
    disabled: { type: Boolean, reflect: true },
    held: { type: Boolean, reflect: true },
  };

  static styles = [
    tokens,
    base,
    css`
      :host {
        display: contents;
      }

      button {
        font: inherit;
        color: var(--tx);
        background: var(--card);
        border: 1px solid var(--line);
        border-radius: 999px;
        padding: 10px 18px;
        cursor: pointer;
        text-align: left;
        line-height: 1.25;
        transition: border-color 0.12s ease, background 0.12s ease;
        min-height: 44px;
      }

      button:hover:not(:disabled) {
        border-color: var(--accent);
      }

      button[aria-pressed='true'] {
        border-color: var(--accent);
        background: var(--accent);
        color: #06121f;
        font-weight: 600;
      }

      button:disabled {
        cursor: default;
        opacity: 0.55;
        text-decoration: line-through;
        text-decoration-thickness: 1px;
      }

      .owner {
        display: block;
        font-size: 12.5px;
        color: var(--mut);
        margin-top: 2px;
      }

      button[aria-pressed='true'] .owner {
        color: rgba(6, 18, 31, 0.75);
      }
    `,
  ];

  render() {
    const label = this.held
      ? `${this.dayLabel} at ${this.time} — just asked for, no longer available`
      : `Ask for ${this.dayLabel} at ${this.time}${this.endTime ? ` until ${this.endTime}` : ''}`;

    return html`
      <button
        type="button"
        aria-pressed=${this.selected ? 'true' : 'false'}
        ?disabled=${this.disabled || this.held}
        aria-label=${label}
        @click=${this.#pick}
      >
        <span aria-hidden="true">${this.time}</span>
        ${this.ownerTime
          ? html`<span class="owner" aria-hidden="true"
              >${this.ownerTime} for ${this.ownerName || 'them'}</span
            >`
          : null}
      </button>
    `;
  }

  #pick() {
    this.dispatchEvent(new CustomEvent('slot-picked', { bubbles: true, composed: true }));
  }
}

customElements.define('slot-button', SlotButton);
