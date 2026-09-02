package tlsauth

import (
	"context"
	"crypto/subtle"
	"log/slog"
	"net/http"
	"sync"
	"time"
)

// Lookup is the authoritative answer: has a paying owner claimed this host, and
// has its CNAME been observed pointing at us?
//
// An interface rather than a *store.Store so the decision logic can be tested
// without a database, and so a lookup that fails is easy to simulate — which is
// the case that matters most, because getting it wrong turns the gate into a
// door.
type Lookup interface {
	AuthorizedCustomDomain(ctx context.Context, host string) (bool, error)
}

// Decision is what the handler turns into a status code. Named rather than a
// bare bool so the reason survives into the log line.
type Decision int

const (
	Deny Decision = iota
	Allow
	Malformed
	Unavailable
)

// Config for the endpoint. Zero values are safe: no secret means the handler
// refuses everything, which is the correct default for a gate.
type Config struct {
	// Zone is our own apex — "askwhen.me". Names at or under it are refused,
	// because they have their own certificates in the Caddyfile.
	Zone string

	// Secret is the shared credential the proxy must present. Required.
	//
	// It exists because the decision to run behind `caddy-dc` moved this
	// endpoint off the compose network: it is now reachable from another host,
	// so "only Caddy can reach it" stopped being true and had to be replaced
	// with something that is.
	//
	// It travels in the **query string**, because that is the only channel
	// Caddy offers. Verified against caddy's ondemand.go: the ask request is a
	// plain `GET`, it sets no headers, and it builds the URL with
	//
	//	qs := askURL.Query(); qs.Set("domain", name); askURL.RawQuery = qs.Encode()
	//
	// which preserves whatever query parameters the configured endpoint already
	// had. So `ask http://app:8080/internal/tls-authorize?key=…` arrives here as
	// `?domain=…&key=…`. A header would have been tidier and is not available.
	//
	// A secret in a URL is a real if small downgrade — it can reach a debug log.
	// The mitigations are that this endpoint is reachable only from the proxy's
	// address, that the value is long and random, and that nothing in this file
	// logs the request URL.
	Secret string

	// SecretParam is the query parameter carrying Secret. Anything but
	// "domain", which Caddy sets itself.
	SecretParam string

	// Param is the query parameter Caddy puts the hostname in. Caddy's
	// on_demand_tls `ask` appends `?domain=<name>`.
	Param string

	// DenyTTL is how long a refusal is remembered.
	//
	// Only refusals are cached, and that asymmetry is the point. A flood of
	// handshakes for random names would otherwise be one database read each, on
	// a proxy shared with unrelated sites. Caching an *allow* could keep serving
	// a domain after its owner cancelled; caching a *deny* can only make a
	// newly-verified customer wait a few seconds, and Caddy retries.
	DenyTTL time.Duration

	// DenyCacheMax bounds the cache so the flood it defends against cannot
	// become a memory exhaustion instead.
	DenyCacheMax int

	Timeout time.Duration
	Logger  *slog.Logger
}

func (c *Config) withDefaults() {
	if c.Param == "" {
		c.Param = "domain"
	}
	if c.SecretParam == "" {
		c.SecretParam = "key"
	}
	if c.DenyTTL == 0 {
		c.DenyTTL = 30 * time.Second
	}
	if c.DenyCacheMax == 0 {
		c.DenyCacheMax = 4096
	}
	if c.Timeout == 0 {
		c.Timeout = 2 * time.Second
	}
	if c.Logger == nil {
		c.Logger = slog.Default()
	}
}

// Authorizer answers Caddy's on-demand TLS `ask`.
type Authorizer struct {
	cfg    Config
	lookup Lookup

	mu    sync.Mutex
	denys map[string]time.Time
}

func New(lookup Lookup, cfg Config) *Authorizer {
	cfg.withDefaults()
	return &Authorizer{cfg: cfg, lookup: lookup, denys: make(map[string]time.Time)}
}

// Decide is the whole policy, separated from HTTP so it can be tested as what
// it is: a function from a hostname to a yes or a no.
func (a *Authorizer) Decide(ctx context.Context, raw string) (Decision, string) {
	host, err := Normalize(raw)
	if err != nil {
		return Malformed, ""
	}
	if a.cfg.Zone != "" && InZone(host, a.cfg.Zone) {
		return Deny, host
	}
	if a.denied(host) {
		return Deny, host
	}

	ctx, cancel := context.WithTimeout(ctx, a.cfg.Timeout)
	defer cancel()

	ok, err := a.lookup.AuthorizedCustomDomain(ctx, host)
	if err != nil {
		// Fail closed, and do not cache it. A database that is briefly unwell
		// must not turn into a refusal that outlives the outage, and it must
		// certainly not turn into an approval.
		return Unavailable, host
	}
	if !ok {
		a.deny(host)
		return Deny, host
	}
	return Allow, host
}

// ServeHTTP implements the endpoint Caddy calls.
//
// Caddy reads only the status code: 2xx issues, anything else refuses. The
// bodies here are for whoever is reading logs at three in the morning.
func (a *Authorizer) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	// Constant-time, and an empty configured secret can never match, so a
	// misconfigured deployment refuses everything rather than allowing it.
	//
	// The query parameter is what Caddy can actually send. The header is
	// accepted too, for curl and for any caller that is not Caddy.
	q := r.URL.Query()
	if a.cfg.Secret == "" || !(match(q.Get(a.cfg.SecretParam), a.cfg.Secret) ||
		match(r.Header.Get("X-AskWhen-TLS-Auth"), a.cfg.Secret)) {
		// 404, not 401. A prober who finds this endpoint should not be told
		// they found it; there is nothing here to authenticate *to*.
		a.cfg.Logger.Warn("tls-authorize: rejected unauthenticated caller",
			"remote", r.RemoteAddr)
		http.NotFound(w, r)
		return
	}

	raw := q.Get(a.cfg.Param)
	decision, host := a.Decide(r.Context(), raw)

	switch decision {
	case Allow:
		a.cfg.Logger.Info("tls-authorize: allow", "host", host)
		w.WriteHeader(http.StatusOK)
	case Malformed:
		a.cfg.Logger.Warn("tls-authorize: malformed host", "raw", clip(raw))
		http.Error(w, "bad host", http.StatusBadRequest)
	case Unavailable:
		// 503 rather than 500 so the log distinguishes "we could not tell" from
		// "we decided no". Caddy refuses either way and will ask again.
		a.cfg.Logger.Error("tls-authorize: lookup unavailable", "host", host)
		http.Error(w, "unavailable", http.StatusServiceUnavailable)
	default:
		a.cfg.Logger.Info("tls-authorize: deny", "host", host)
		http.NotFound(w, r)
	}
}

func (a *Authorizer) denied(host string) bool {
	a.mu.Lock()
	defer a.mu.Unlock()
	until, ok := a.denys[host]
	if !ok {
		return false
	}
	if time.Now().After(until) {
		delete(a.denys, host)
		return false
	}
	return true
}

func (a *Authorizer) deny(host string) {
	a.mu.Lock()
	defer a.mu.Unlock()
	if len(a.denys) >= a.cfg.DenyCacheMax {
		// Drop everything rather than evict cleverly. The cache is an
		// optimisation whose worst case is one extra database read; an LRU here
		// would be more code than the thing it protects.
		clear(a.denys)
	}
	a.denys[host] = time.Now().Add(a.cfg.DenyTTL)
}

func match(presented, want string) bool {
	return subtle.ConstantTimeCompare([]byte(presented), []byte(want)) == 1
}

func clip(s string) string {
	const max = 120
	if len(s) > max {
		return s[:max] + "…"
	}
	return s
}
