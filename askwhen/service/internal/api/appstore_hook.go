package api

import (
	"io"
	"log/slog"
	"net/http"
	"time"

	"github.com/mattbaylor/cal-mirror/askwhen/service/internal/appstore"
	"github.com/mattbaylor/cal-mirror/askwhen/service/internal/store"
)

// AppStoreHook receives App Store Server Notifications V2: Apple's word, as
// a subscription renews, changes tier, lapses or is refunded.
//
// Two of these are mounted — /hooks/appstore for Production and
// /hooks/appstore-sandbox for Sandbox — because Apple wants two URLs and
// because a sandbox notification must never touch a production entitlement.
// Each refuses the other's environment.
//
// The signature is the whole authentication (appstore.Verifier, pinned to
// Apple's root). Refusals are 404s. Everything Apple sends is acknowledged
// with 200 once verified, whether or not it changed anything — Apple retries
// anything else for days, and a notification the service does not act on is
// not an error.
//
// What it does with them:
//
//   - every notification with a transaction: record Apple's latest expiry
//     and product (upsert); if the subscription is live again, end any grace.
//   - EXPIRED, GRACE_PERIOD_EXPIRED: start the 7-day grace on the pages
//     (decisions.md, "Lapse — 7-day grace, then delete").
//   - REFUND, REVOKE: record the revocation; grace ends now. They have their
//     money back; the page goes at the next sweep.
//
// Nothing is deleted here. The sweeper deletes pages whose grace has run
// out, on its own clock, which is the one place deletion happens.
type AppStoreHook struct {
	Store  *store.Store
	Verify interface {
		DecodeNotification(body []byte) (appstore.Notification, error)
	}
	// Environment this endpoint serves: "Production" or "Sandbox".
	Environment string
	// Grace is the lapse window. 7 days.
	Grace  time.Duration
	Logger *slog.Logger
}

func (h *AppStoreHook) ServeHTTP(w http.ResponseWriter, r *http.Request) {
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
	n, err := h.Verify.DecodeNotification(body)
	if err != nil {
		h.Logger.Warn("appstore hook: refused", "why", err.Error())
		http.NotFound(w, r)
		return
	}
	if n.Data.Environment != h.Environment {
		// A sandbox notification at the production URL, or the reverse.
		// Genuine, and wrong door; 200 so Apple stops retrying it here.
		h.Logger.Warn("appstore hook: wrong environment", "got", n.Data.Environment, "type", n.NotificationType)
		w.WriteHeader(http.StatusOK)
		return
	}
	if n.NotificationType == "TEST" || n.Transaction.OriginalTransactionID == "" {
		h.Logger.Info("appstore hook", "type", n.NotificationType, "subtype", n.Subtype)
		w.WriteHeader(http.StatusOK)
		return
	}

	tx := n.Transaction
	now := time.Now()
	ent := store.Entitlement{Hash: tx.Hash(), ProductID: tx.ProductID, Environment: tx.Environment, ExpiresAt: tx.Expires()}
	if tx.RevocationDate != 0 {
		ent.RevokedAt = time.UnixMilli(tx.RevocationDate).UTC()
	}
	switch n.NotificationType {
	case "REFUND", "REVOKE":
		if ent.RevokedAt.IsZero() {
			ent.RevokedAt = now
		}
	}
	if err := h.Store.UpsertEntitlement(r.Context(), ent); err != nil {
		h.Logger.Error("appstore hook: upsert", "err", err)
		http.Error(w, "unavailable", http.StatusServiceUnavailable)
		return
	}

	var lapsed, reinstated int64
	switch {
	case !ent.RevokedAt.IsZero():
		lapsed, err = h.Store.Lapse(r.Context(), ent.Hash, now)
	case n.NotificationType == "EXPIRED" || n.NotificationType == "GRACE_PERIOD_EXPIRED":
		lapsed, err = h.Store.Lapse(r.Context(), ent.Hash, now.Add(h.Grace))
	case ent.Live(now):
		reinstated, err = h.Store.Reinstate(r.Context(), ent.Hash)
	}
	if err != nil {
		h.Logger.Error("appstore hook: lapse/reinstate", "err", err)
		http.Error(w, "unavailable", http.StatusServiceUnavailable)
		return
	}
	h.Logger.Info("appstore hook", "type", n.NotificationType, "subtype", n.Subtype,
		"product", tx.ProductID, "expires", ent.ExpiresAt.Format(time.RFC3339),
		"pages_lapsed", lapsed, "pages_reinstated", reinstated)
	w.WriteHeader(http.StatusOK)
}
