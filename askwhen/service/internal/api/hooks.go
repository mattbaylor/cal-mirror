package api

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"time"

	"github.com/mattbaylor/cal-mirror/askwhen/service/internal/mail"
	"github.com/mattbaylor/cal-mirror/askwhen/service/internal/store"
)

// PostalHook receives Postal's report on the .ics mail: delivered, or not.
//
// Delivered is the moment §10's "purged once delivery confirms" refers to —
// the request has done its job and is due for the next sweep, hours before
// the 48-hour ceiling. Not delivered earns exactly one resend, and after
// that the ceiling is the answer. Every other event Postal can send is
// acknowledged and ignored: the service tracks only what it sent at accept,
// and a report on anything else is not its business.
//
// The endpoint is public — Postal calls it from dlvr, through the edge — so
// the signature is the whole of the authentication (mail.Verifier). Nothing
// here is answered differently for an unsigned, mis-signed or unknown-key
// request than for a path that does not exist.
type PostalHook struct {
	Store  *store.Store
	Verify interface {
		Verify(ctx context.Context, kid, sig64 string, body []byte) error
	}
	Notify Notifier
	Logger *slog.Logger
}

func (h *PostalHook) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	if r.Method != http.MethodPost || h.Verify == nil {
		http.NotFound(w, r)
		return
	}
	body, err := io.ReadAll(io.LimitReader(r.Body, 256<<10))
	if err != nil {
		http.NotFound(w, r)
		return
	}
	if err := h.Verify.Verify(r.Context(), r.Header.Get("X-Postal-Signature-KID"),
		r.Header.Get("X-Postal-Signature-256"), body); err != nil {
		// Logged at the level that gets read: a bad signature on a public
		// endpoint is either misconfiguration or somebody probing, and both
		// are worth a line. The response gives them nothing.
		h.Logger.Warn("postal hook: refused", "why", err.Error())
		http.NotFound(w, r)
		return
	}

	var hook mail.Webhook
	if err := json.Unmarshal(body, &hook); err != nil {
		http.Error(w, "malformed", http.StatusBadRequest)
		return
	}
	msgID := hook.MessageID()
	if msgID == "" {
		w.WriteHeader(http.StatusOK)
		return
	}

	switch hook.Event {
	case "MessageSent":
		ok, err := h.Store.MarkDelivered(r.Context(), msgID, time.Now())
		if err != nil {
			h.Logger.Error("postal hook: mark delivered", "err", err)
			http.Error(w, "unavailable", http.StatusServiceUnavailable)
			return
		}
		if ok {
			h.Logger.Info("postal hook: delivered; request due for purge")
		}
	case "MessageDeliveryFailed", "MessageBounced":
		again, err := h.Store.FailDelivery(r.Context(), msgID)
		if err != nil {
			h.Logger.Error("postal hook: fail delivery", "err", err)
			http.Error(w, "unavailable", http.StatusServiceUnavailable)
			return
		}
		if again != nil && h.Notify != nil && again.Email != "" {
			// The one resend. If this one fails too the ceiling purges the
			// address, and the requester's own mail server is the thing that
			// needs fixing — not something a third try would change.
			id, err := h.Notify.Accepted(r.Context(), again.Email, eventFor(*again))
			switch {
			case err != nil:
				h.Logger.Error("postal hook: resend failed", "id", again.ID, "err", err)
			case id != "":
				if err := h.Store.RecordDelivery(r.Context(), id, again.ID, 2); err != nil && !errors.Is(err, store.ErrNoPage) {
					h.Logger.Error("postal hook: record resend", "id", again.ID, "err", err)
				}
				h.Logger.Info("postal hook: resent once", "id", again.ID, "event", hook.Event)
			}
		}
	default:
		// MessageDelayed, MessageHeld, MessageLoaded, MessageLinkClicked,
		// DomainDNSError: acknowledged, not acted on. Delayed is not failed;
		// Postal keeps trying and reports the outcome later.
	}
	w.WriteHeader(http.StatusOK)
}
