package api

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"strings"
	"time"

	"github.com/mattbaylor/cal-mirror/askwhen/service/internal/domainverify"
	"github.com/mattbaylor/cal-mirror/askwhen/service/internal/store"
	"github.com/mattbaylor/cal-mirror/askwhen/service/internal/tlsauth"
)

// Domains is the owner's side of §7: claiming a hostname for a page and
// finding out whether it works yet. Two tiers, one table:
//
//   - a *subdomain* is one label under our zone — matt.askwhen.me. We own the
//     DNS (a wildcard A record points every label at the edge), so claiming it
//     is the whole job and the gate issues on first handshake.
//   - a *custom* domain is anyone else's name — ask.example.com. The customer
//     CNAMEs it at edge.askwhen.me (or points an apex at the edge's address),
//     and nothing is issued until that has been observed: an ACME order for a
//     name that does not resolve to us fails, and failed orders spend the rate
//     limit that also renews the other sites on that proxy.
//
// Entitlement is not checked here. Tiers are a StoreKit question the service
// cannot yet ask (create takes only a hash), so today any page may claim; the
// cap below is what bounds the exposure until that lands.
type Domains struct {
	Owner *Owner
	// Zone is our own — "askwhen.me". Names under it are subdomains; the apex
	// and the labels in Reserved are nobody's.
	Zone string
	// Verify describes where a custom domain is supposed to point.
	Verify domainverify.Config
	// Resolver answers DNS; nil means the system's.
	Resolver domainverify.Resolver
	Logger   *slog.Logger
}

// MaxDomainsPerPage bounds what one write token can put in the table, and so
// what one token can make the gate say yes to. Three is a subdomain, a custom
// domain and one mistake.
const MaxDomainsPerPage = 3

// Labels under the zone that are ours, or would be confusing, or are mail's.
// Kept short on purpose: the point is not to police taste but to keep a
// customer from claiming the CNAME target everybody else's setup depends on.
var reservedLabels = map[string]bool{
	"www": true, "edge": true, "api": true, "mail": true, "mx": true, "psrp": true,
	"admin": true, "app": true, "static": true, "cdn": true, "status": true, "help": true,
}

type domainView struct {
	Host     string `json:"host"`
	Kind     string `json:"kind"`
	Verified bool   `json:"verified"`
	// Check is the live DNS answer for an unverified custom domain, so the
	// owner's device can say what to fix. Absent once verified, and for
	// subdomains, which have nothing to check.
	Check  string `json:"check,omitempty"`
	Advice string `json:"advice,omitempty"`
	// Point is what to tell the customer: the CNAME target.
	Point string `json:"point,omitempty"`
}

// Claim answers PUT /v1/pages/{slug}/domains/{host}.
func (d *Domains) Claim(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	slug := r.PathValue("slug")
	if !validSlug(slug) {
		http.NotFound(w, r)
		return
	}
	if !d.Owner.authenticate(w, r, slug) {
		return
	}
	host, kind, why := d.classify(r.PathValue("host"))
	if why != "" {
		http.Error(w, why, http.StatusBadRequest)
		return
	}

	existing, err := d.Owner.Store.Domains(r.Context(), slug)
	if err != nil {
		d.fail(w, "domains", err)
		return
	}
	already := false
	for _, e := range existing {
		if e.Host == host {
			already = true
		}
	}
	if !already && len(existing) >= MaxDomainsPerPage {
		http.Error(w, "this page already has the most hostnames it may have", http.StatusConflict)
		return
	}

	err = d.Owner.Store.ClaimDomain(r.Context(), host, slug, kind)
	switch {
	case errors.Is(err, store.ErrDomainTaken):
		// Somebody else's, and which somebody is not this owner's business.
		http.Error(w, "that hostname is not available", http.StatusConflict)
		return
	case errors.Is(err, store.ErrNoPage):
		http.NotFound(w, r)
		return
	case err != nil:
		d.fail(w, "claim domain", err)
		return
	}
	if !already {
		d.Logger.Info("domain: claimed", "host", host, "kind", kind, "slug", slug)
	}

	view := d.view(r.Context(), store.Domain{Host: host, Slug: slug, Kind: kind}, true)
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	if already {
		w.WriteHeader(http.StatusOK)
	} else {
		w.WriteHeader(http.StatusCreated)
	}
	json.NewEncoder(w).Encode(view)
}

// Release answers DELETE /v1/pages/{slug}/domains/{host}.
func (d *Domains) Release(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	slug := r.PathValue("slug")
	if !validSlug(slug) {
		http.NotFound(w, r)
		return
	}
	if !d.Owner.authenticate(w, r, slug) {
		return
	}
	host, err := tlsauth.Normalize(r.PathValue("host"))
	if err != nil {
		http.NotFound(w, r)
		return
	}
	ok, err := d.Owner.Store.ReleaseDomain(r.Context(), host, slug)
	if err != nil {
		d.fail(w, "release domain", err)
		return
	}
	if !ok {
		http.NotFound(w, r)
		return
	}
	d.Logger.Info("domain: released", "host", host, "slug", slug)
	w.WriteHeader(http.StatusNoContent)
}

// List answers GET /v1/pages/{slug}/domains, checking DNS for anything still
// unverified so the owner's "is it working yet?" gets a current answer — and
// marking it verified the moment it is.
func (d *Domains) List(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "private, no-store")
	slug := r.PathValue("slug")
	if !validSlug(slug) {
		http.NotFound(w, r)
		return
	}
	if !d.Owner.authenticate(w, r, slug) {
		return
	}
	domains, err := d.Owner.Store.Domains(r.Context(), slug)
	if err != nil {
		d.fail(w, "domains", err)
		return
	}
	views := make([]domainView, 0, len(domains))
	for _, dom := range domains {
		views = append(views, d.view(r.Context(), dom, true))
	}
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	json.NewEncoder(w).Encode(map[string]any{"domains": views, "point": d.Verify.Target})
}

// classify normalises a host and decides which tier it is, or says why not.
func (d *Domains) classify(raw string) (host, kind, why string) {
	host, err := tlsauth.Normalize(raw)
	if err != nil {
		return "", "", "not a usable hostname: " + err.Error()
	}
	if !tlsauth.InZone(host, d.Zone) {
		if host == strings.TrimPrefix(d.Verify.Target, ".") {
			return "", "", "that is the name to point at, not one to claim"
		}
		return host, "custom", ""
	}
	label, ok := strings.CutSuffix(host, "."+d.Zone)
	if !ok || label == "" {
		return "", "", "the zone itself is not claimable"
	}
	if strings.Contains(label, ".") {
		return "", "", "one label only: something.askwhen.me"
	}
	if reservedLabels[label] || len(label) < 2 {
		return "", "", "that label is reserved"
	}
	return host, "subdomain", ""
}

// view builds what the owner sees, checking DNS for an unverified custom
// domain when asked and recording a pass.
func (d *Domains) view(ctx context.Context, dom store.Domain, check bool) domainView {
	v := domainView{Host: dom.Host, Kind: dom.Kind, Verified: dom.VerifiedAt != "" || dom.Kind == "subdomain"}
	if dom.Kind != "custom" || v.Verified || !check {
		return v
	}
	v.Point = d.Verify.Target
	res, err := domainverify.Check(ctx, d.resolver(), dom.Host, d.Verify)
	v.Check = string(res)
	switch res {
	case domainverify.Verified:
		if err := d.Owner.Store.MarkDomainVerified(ctx, dom.Host); err != nil {
			d.Logger.Error("domain: mark verified", "host", dom.Host, "err", err)
		} else {
			d.Logger.Info("domain: verified", "host", dom.Host)
			v.Verified = true
			v.Check, v.Point = "", ""
		}
	case domainverify.NotFound:
		v.Advice = "No record found. Create a CNAME for " + dom.Host + " pointing at " + d.Verify.Target + "."
	case domainverify.PointsElsewhere:
		v.Advice = dom.Host + " resolves, but not to us. Check the record points at " + d.Verify.Target + "."
	case domainverify.Unresolvable:
		v.Advice = "DNS did not answer. This is not a problem with your record; it will be checked again."
		if err != nil {
			d.Logger.Warn("domain: check", "host", dom.Host, "err", err)
		}
	}
	return v
}

func (d *Domains) resolver() domainverify.Resolver {
	if d.Resolver != nil {
		return d.Resolver
	}
	return &systemResolver{}
}

func (d *Domains) fail(w http.ResponseWriter, what string, err error) {
	d.Logger.Error("domain: "+what, "err", err)
	http.Error(w, "unavailable", http.StatusServiceUnavailable)
}

// DomainChecker walks the unverified custom domains on a timer and marks the
// ones that have come to point at us. The owner's GET does the same on demand;
// this is for the customer who set the record and went to bed. Nothing here
// ever *un*-verifies: see store.MarkDomainVerified for why.
func DomainChecker(ctx context.Context, d *Domains, every time.Duration) {
	t := time.NewTicker(every)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			pending, err := d.Owner.Store.UnverifiedCustomDomains(ctx)
			if err != nil {
				d.Logger.Error("domain checker", "err", err)
				continue
			}
			for _, dom := range pending {
				d.view(ctx, dom, true)
			}
		}
	}
}
