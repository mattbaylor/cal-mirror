// Command askwhen is the service.
//
// It exists now, ahead of the endpoints it will eventually carry, because
// everything else was blocked behind it: the Dockerfile cannot build without a
// `cmd/`, so the image could not be built, so provisioning a host to run it
// would have produced an empty box.
//
// What it serves today is what has been built and tested: the policy dump with a
// conditional GET, and the on-demand TLS authorisation gate. The request
// lifecycle is step 3 and is deliberately absent — `GET /c/{confirm_token}` in
// particular must not be written until the mutating-GET question is answered,
// because a link already sitting in an inbox cannot be changed.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/mattbaylor/cal-mirror/askwhen/service/internal/api"
	"github.com/mattbaylor/cal-mirror/askwhen/service/internal/domainverify"
	"github.com/mattbaylor/cal-mirror/askwhen/service/internal/httpcache"
	"github.com/mattbaylor/cal-mirror/askwhen/service/internal/mail"
	"github.com/mattbaylor/cal-mirror/askwhen/service/internal/store"
	"github.com/mattbaylor/cal-mirror/askwhen/service/internal/tlsauth"
)

func main() {
	healthcheck := flag.Bool("healthcheck", false,
		"probe a running instance and exit non-zero if it is unwell; this is what compose.yml calls")
	flag.Parse()

	log := slog.New(slog.NewJSONHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelInfo}))

	if *healthcheck {
		// The binary answers its own health check because the runtime image is
		// distroless: there is no shell and no curl, and adding either to get a
		// health check would undo the reason for choosing it.
		if err := probe(envOr("AW_LISTEN", ":8080")); err != nil {
			fmt.Fprintln(os.Stderr, "unhealthy:", err)
			os.Exit(1)
		}
		return
	}

	if err := run(log); err != nil {
		log.Error("fatal", "err", err)
		os.Exit(1)
	}
}

type config struct {
	listen       string
	dbPath       string
	schemaPath   string
	zone         string
	tlsSecret    string
	pepper       []byte
	origin       string
	trustedProxy string
	postalURL    string
	postalKey    string
	mailFrom     string
	// The built web app: index.html and app.js. /web in the image.
	webDir string
	// Where a custom domain is supposed to point: the CNAME target, and the
	// edge's public address for an apex that cannot carry a CNAME.
	edgeTarget string
	edgeIPs    []string
}

func loadConfig() (config, error) {
	c := config{
		listen:     envOr("AW_LISTEN", ":8080"),
		dbPath:     envOr("AW_DB", "/data/askwhen.db"),
		schemaPath: envOr("AW_SCHEMA", "/schema.sql"),
		zone:       envOr("AW_ZONE", "askwhen.me"),
		origin:     envOr("AW_ORIGIN", "https://askwhen.me"),
		// The one proxy whose X-Forwarded-For is believed. edge.md: trust it
		// from 172.16.1.4 and nowhere else, or the per-IP limit either counts
		// the proxy or lets a requester pick their own bucket.
		trustedProxy: envOr("AW_TRUSTED_PROXY", "172.16.1.4"),
		webDir:       envOr("AW_WEB", "/web"),
		edgeTarget:   envOr("AW_EDGE_TARGET", "edge.askwhen.me"),
		edgeIPs:      strings.Fields(strings.ReplaceAll(envOr("AW_EDGE_IPS", "64.111.22.170"), ",", " ")),
	}

	// Read from a file rather than an environment variable so the value does not
	// appear in `docker inspect`. compose.yml mounts it as a secret.
	secret, err := readSecret("AW_TLS_AUTH_SECRET_FILE", "AW_TLS_AUTH_SECRET")
	if err != nil {
		return c, err
	}
	c.tlsSecret = secret

	// The pepper is what makes a stolen database useless for publishing to
	// somebody's page or confirming somebody's request. Without it the service
	// can still serve, so this is a warning rather than a refusal to start —
	// but every write path checks and refuses.
	pepper, err := readSecret("AW_PEPPER_FILE", "AW_PEPPER")
	if err != nil {
		return c, err
	}
	c.pepper = []byte(pepper)

	// Postal, by API rather than SMTP. The key is a server credential held in
	// Infisical as postal_api_key and mounted as a file, like the others.
	c.postalURL = envOr("AW_POSTAL_URL", "https://dlvr.rehosted.us")
	c.mailFrom = envOr("AW_MAIL_FROM", "askwhen.me <no-reply@askwhen.me>")
	key, err := readSecret("AW_POSTAL_API_KEY_FILE", "AW_POSTAL_API_KEY")
	if err != nil {
		return c, err
	}
	c.postalKey = key

	// Not fatal, and deliberately so: the service is useful without custom
	// domains, and refusing to start would take the whole product down over a
	// tier feature. tlsauth already refuses everything when the secret is empty,
	// so the failure is contained and visible rather than silent.
	return c, nil
}

func run(log *slog.Logger) error {
	cfg, err := loadConfig()
	if err != nil {
		return err
	}
	if cfg.tlsSecret == "" {
		log.Warn("no TLS authorisation secret configured; custom-domain certificates will all be refused")
	}
	if len(cfg.pepper) == 0 {
		log.Warn("no pepper configured; every write path will refuse")
	}
	if cfg.postalKey == "" {
		log.Warn("no Postal API key configured; confirmation links will be logged, not sent")
	}

	ctx := context.Background()
	schema, err := os.ReadFile(cfg.schemaPath)
	if err != nil {
		return fmt.Errorf("read schema: %w", err)
	}

	st, err := store.Open(ctx, cfg.dbPath)
	if err != nil {
		return err
	}
	defer st.Close()

	if err := st.Migrate(ctx, string(schema)); err != nil {
		return err
	}
	log.Info("schema applied", "db", cfg.dbPath, "schema", cfg.schemaPath)

	// Retention as a timer. Every row carries its own death date, so the sweep
	// is two unconditional statements and there is no state whose expiry
	// somebody forgot to implement.
	sweepCtx, stopSweep := context.WithCancel(ctx)
	defer stopSweep()
	post := mailer(cfg, log)
	go api.Sweeper(sweepCtx, st, 60*time.Second, ttlConfirmed, notifier(post, log), log)

	shell, err := api.LoadShell(cfg.webDir, log)
	if err != nil {
		return fmt.Errorf("web app (AW_WEB=%s): %w", cfg.webDir, err)
	}

	// A customer who set their CNAME and went to bed should wake up verified.
	domains := domainsAPI(st, cfg, log)
	go api.DomainChecker(sweepCtx, domains, 5*time.Minute)

	srv := &http.Server{
		Addr:    cfg.listen,
		Handler: routes(st, cfg, post, shell, domains, log),

		// A request is a name, an email, a note and a slot. Nothing here should
		// take long, and an unbounded read is how a slow-loris ties up a service
		// that has no business being slow.
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       15 * time.Second,
		WriteTimeout:      30 * time.Second,
		IdleTimeout:       60 * time.Second,
	}

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, os.Interrupt, syscall.SIGTERM)

	errs := make(chan error, 1)
	go func() {
		log.Info("listening", "addr", cfg.listen, "zone", cfg.zone)
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			errs <- err
		}
	}()

	select {
	case err := <-errs:
		return err
	case <-stop:
		log.Info("shutting down")
		// SQLite has one writer, and a request cut off mid-write is how a hold
		// gets taken for a request nobody can see.
		shutCtx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
		defer cancel()
		return srv.Shutdown(shutCtx)
	}
}

// The retention numbers, in one place, because the confirm handler and the
// sweeper must agree on them: a request confirmed under one limit and swept
// under another is a request that dies early or lingers.
const (
	holdConfirmed = 24 * time.Hour
	ttlConfirmed  = 336 * time.Hour // 14 days
	ttlResolved   = 48 * time.Hour  // ceiling; the trigger in schema.sql agrees
)

// mailer is Postal when a key is configured, and otherwise something that
// logs what it would have sent so the loop can be exercised by hand on a box
// without one.
func mailer(cfg config, log *slog.Logger) *mail.Postal {
	if cfg.postalKey == "" {
		return nil
	}
	return &mail.Postal{BaseURL: cfg.postalURL, APIKey: cfg.postalKey, From: cfg.mailFrom}
}

func deliverer(p *mail.Postal, log *slog.Logger) func(context.Context, string, string) error {
	if p == nil {
		return func(ctx context.Context, to, url string) error {
			log.Info("deliver (no Postal key): confirmation link", "url", url)
			return nil
		}
	}
	return p.Confirmation
}

// logNotifier stands in for Postal on a keyless box. It logs the outcome and
// not the address: the address is the one thing in the row that is somebody's.
type logNotifier struct{ log *slog.Logger }

func (l logNotifier) Accepted(_ context.Context, _ string, ev mail.Event) (string, error) {
	l.log.Info("notify (no Postal key): accepted", "uid", ev.UID, "when", ev.When())
	return "", nil
}
func (l logNotifier) Declined(_ context.Context, _ string, ev mail.Event) error {
	l.log.Info("notify (no Postal key): declined", "uid", ev.UID, "when", ev.When())
	return nil
}
func (l logNotifier) NoResponse(_ context.Context, _ string, ev mail.Event) error {
	l.log.Info("notify (no Postal key): no response", "uid", ev.UID, "when", ev.When())
	return nil
}

func notifier(p *mail.Postal, log *slog.Logger) api.Notifier {
	if p == nil {
		return logNotifier{log}
	}
	return p
}

func domainsAPI(st *store.Store, cfg config, log *slog.Logger) *api.Domains {
	return &api.Domains{
		Owner:  &api.Owner{Store: st, Pepper: cfg.pepper, Logger: log},
		Zone:   cfg.zone,
		Verify: domainverify.Config{Target: cfg.edgeTarget, EdgeIPs: cfg.edgeIPs},
		Logger: log,
	}
}

func routes(st *store.Store, cfg config, post *mail.Postal, shell *api.Shell, domains *api.Domains, log *slog.Logger) http.Handler {
	mux := http.NewServeMux()

	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Cache-Control", "no-store")
		w.WriteHeader(http.StatusOK)
		fmt.Fprintln(w, "ok")
	})

	// The bare domain is nobody's page. Send whoever lands there to the product
	// site (Matt, 10 Sept 2026). 301 as asked, but with a one-day cache rather
	// than a browser's default forever, so a landing page here later — "what is
	// this link I was sent?" — does not fight a redirect cached in 2026.
	//
	// On a customer's own hostname — ask.example.com, matt.askwhen.me — the
	// root *is* the page: the shell is served and fetches /p/host.json, which
	// resolves by Host. No redirect there; that would send a stranger holding
	// a customer's link to our marketing site.
	mux.HandleFunc("GET /{$}", func(w http.ResponseWriter, r *http.Request) {
		host := hostOf(r)
		if host == cfg.zone || host == "www."+cfg.zone || host == "" {
			w.Header().Set("Cache-Control", "public, max-age=86400")
			http.Redirect(w, r, "https://calendarmirror.com/", http.StatusMovedPermanently)
			return
		}
		if _, err := st.SlugForHost(r.Context(), host); err != nil {
			// Unknown host, or the database is unwell. One answer: the edge
			// would not have issued a certificate for a host we do not know,
			// so this is somebody poking the internal port by name.
			http.NotFound(w, r)
			return
		}
		shell.Root(w, r)
	})

	// The request page itself: one document and one script for every slug.
	// The page fetches its own dump, so no lookup happens here (see api.Shell).
	// "GET /app.js" is a literal and beats the wildcard; a slug cannot contain
	// a dot anyway.
	mux.HandleFunc("GET /{slug}", shell.Page)
	mux.HandleFunc("GET /app.js", shell.Script)

	// The gate is reachable from the edge and nothing else (edge.md, "three
	// things that are not optional", 1). The secret in the query string is
	// defence in depth; this is the perimeter.
	mux.Handle("GET /internal/tls-authorize", internalOnly(cfg.trustedProxy, tlsauth.New(st, tlsauth.Config{
		Zone:   cfg.zone,
		Secret: cfg.tlsSecret,
		Logger: log,
	})))

	// `{slug}.json` is not a legal ServeMux pattern — a wildcard has to be a
	// whole path segment — so the suffix is stripped here rather than the public
	// URL being reshaped around a routing library's limitation.
	mux.HandleFunc("GET /p/{file}", func(w http.ResponseWriter, r *http.Request) {
		serveDump(w, r, st, log)
	})

	// The owner's hostnames. Claiming is cheap; what it buys is a row the
	// on-demand TLS gate will say yes to (custom, once verified) and a Host
	// the root route will serve.
	// Postal's report on the .ics mail. Public — dlvr calls it through the
	// edge — and authenticated by the signature alone (mail.Verifier, keyed
	// from the instance's own JWKS). Not under /internal, which the perimeter
	// check would refuse.
	mux.Handle("POST /hooks/postal", &api.PostalHook{
		Store:  st,
		Verify: &mail.Verifier{BaseURL: cfg.postalURL},
		Notify: notifier(post, log),
		Logger: log,
	})

	mux.HandleFunc("GET /v1/pages/{slug}/domains", domains.List)
	mux.HandleFunc("PUT /v1/pages/{slug}/domains/{host}", domains.Claim)
	mux.HandleFunc("DELETE /v1/pages/{slug}/domains/{host}", domains.Release)

	// Double opt-in. GET renders, POST confirms — see internal/api/confirm.go
	// for why that split is not decoration.
	confirm := &api.Confirm{
		Store:         st,
		Pepper:        cfg.pepper,
		HoldConfirmed: holdConfirmed,
		TTLConfirmed:  ttlConfirmed,
		Logger:        log,
	}
	mux.Handle("/c/{token}", confirm)

	// A stranger asking for a time. The one write a stranger can cause, and the
	// only endpoint the per-IP limit applies to — page views stay pure reads.
	mux.Handle("POST /v1/pages/{slug}/requests", &api.Requests{
		Store:          st,
		Pepper:         cfg.pepper,
		Origin:         cfg.origin,
		HoldInitial:    15 * time.Minute,
		TTLUnconfirmed: time.Hour,
		RatePerIP:      10,
		RateWindow:     time.Hour,
		TrustedProxy:   cfg.trustedProxy,
		Deliver:        deliverer(post, log),
		Logger:         log,
	})

	// The owner's side. Every route here needs the page's write token — the one
	// credential the service ever issues, and the one it stores only as a hash.
	owner := &api.Owner{
		Store:       st,
		Pepper:      cfg.pepper,
		DumpTTL:     24 * time.Hour,
		TTLResolved: ttlResolved,
		Notify:      notifier(post, log),
		Logger:      log,
	}
	mux.HandleFunc("POST /v1/pages", owner.Create)
	mux.HandleFunc("PUT /v1/pages/{slug}", owner.Publish)
	mux.HandleFunc("DELETE /v1/pages/{slug}", owner.Delete)
	mux.HandleFunc("GET /v1/pages/{slug}/queue", owner.Queue)
	mux.HandleFunc("POST /v1/requests/{id}/resolve", owner.Resolve)

	return mux
}

// serveDump answers the request every visitor makes, and answers it cheaply the
// second time.
//
// What goes out is the owner's dump plus one field the service adds: `held`,
// the starts currently held by somebody's request (§4b). The validator covers
// both, so a hold appearing or lapsing is a new representation and a cache
// revalidates into it — and it is computed from the stored ETag and the hold
// index alone, so a returning visitor is still answered without the document
// being read.
func serveDump(w http.ResponseWriter, r *http.Request, st *store.Store, log *slog.Logger) {
	file := r.PathValue("file")
	slug, ok := strings.CutSuffix(file, ".json")
	if ok && slug == "host" {
		// The page for whichever hostname this arrived on. "host" is four
		// characters and a slug is at least six, so nothing can collide.
		var err error
		if slug, err = st.SlugForHost(r.Context(), hostOf(r)); err != nil {
			http.NotFound(w, r)
			return
		}
	}
	if !ok || !validSlug(slug) {
		// §4c: never distinguish never-existed from lapsed, deleted or expired.
		http.NotFound(w, r)
		return
	}

	dumpETag, err := st.DumpETag(r.Context(), slug)
	if errors.Is(err, store.ErrNoPage) {
		http.NotFound(w, r)
		return
	}
	if err != nil {
		log.Error("dump etag", "err", err)
		http.Error(w, "unavailable", http.StatusServiceUnavailable)
		return
	}
	held, err := st.HeldStarts(r.Context(), slug)
	if err != nil {
		log.Error("dump held", "err", err)
		http.Error(w, "unavailable", http.StatusServiceUnavailable)
		return
	}

	if httpcache.Serve(w, r, servedETag(dumpETag, held)) {
		return
	}

	dump, dumpETag2, err := st.Dump(r.Context(), slug)
	if errors.Is(err, store.ErrNoPage) {
		http.NotFound(w, r)
		return
	}
	if err != nil {
		log.Error("dump", "err", err)
		http.Error(w, "unavailable", http.StatusServiceUnavailable)
		return
	}
	body, err := withHeld(dump, held)
	if err != nil {
		log.Error("dump merge", "slug", slug, "err", err)
		http.Error(w, "unavailable", http.StatusServiceUnavailable)
		return
	}
	// A publish can land between the two reads. Serving the new bytes under the
	// old validator would leave every cache holding a document it thinks is
	// current and is not.
	w.Header().Set("ETag", servedETag(dumpETag2, held))
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	// §8: noindex by default. The page opts in per slug; the dump never does.
	w.Header().Set("X-Robots-Tag", "noindex")
	w.Write(body)
}

// internalOnly admits a request only when it came straight from the proxy's
// own address and was not forwarded on somebody's behalf.
//
// Two checks, because one is not enough: a public request for /internal/…
// that the edge proxies through arrives from the same 172.16.1.4 as Caddy's
// own `ask`. What tells them apart is that Caddy's ask sets no headers at all
// (verified against ondemand.go), while a proxied request always carries
// X-Forwarded-For. Refuses with the same 404 as an unknown page, so the
// existence of the endpoint is not learnable from outside.
func internalOnly(proxy string, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		ip, _, err := net.SplitHostPort(r.RemoteAddr)
		if err != nil {
			ip = r.RemoteAddr
		}
		if proxy == "" || ip != proxy ||
			r.Header.Get("X-Forwarded-For") != "" || r.Header.Get("X-Forwarded-Host") != "" ||
			r.Header.Get("X-Forwarded-Proto") != "" {
			http.NotFound(w, r)
			return
		}
		next.ServeHTTP(w, r)
	})
}

// hostOf is the request's Host, lowercased, without a port, without a
// trailing dot — the spelling the domain table stores. Caddy forwards the
// customer's Host unchanged.
func hostOf(r *http.Request) string {
	h := strings.ToLower(strings.TrimSuffix(r.Host, "."))
	if i := strings.LastIndex(h, ":"); i > 0 && !strings.Contains(h[i:], "]") {
		h = h[:i]
	}
	return strings.TrimPrefix(strings.TrimSuffix(h, "]"), "[")
}

// servedETag is the validator for dump-plus-holds: strong, and different
// whenever either half is.
func servedETag(dumpETag string, held []string) string {
	return httpcache.StrongETag([]byte(dumpETag + "\n" + strings.Join(held, "\n")))
}

// withHeld adds the `held` list to the stored document. Every other value is
// carried as raw bytes, so what the owner published is what goes out; only the
// key order changes, to the sorted one, which is also what makes the output
// deterministic for the validator.
func withHeld(dump string, held []string) ([]byte, error) {
	var doc map[string]json.RawMessage
	if err := json.Unmarshal([]byte(dump), &doc); err != nil {
		return nil, err
	}
	list, err := json.Marshal(held)
	if err != nil {
		return nil, err
	}
	doc["held"] = list
	return json.Marshal(doc)
}

// validSlug mirrors the CHECK constraint in schema.sql. Applied here so a
// malformed slug never reaches the database at all.
func validSlug(s string) bool {
	if len(s) < 6 || len(s) > 32 {
		return false
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		if !(c >= 'a' && c <= 'z') && !(c >= '0' && c <= '9') {
			return false
		}
	}
	return true
}

func envOr(key, fallback string) string {
	if v := strings.TrimSpace(os.Getenv(key)); v != "" {
		return v
	}
	return fallback
}

// readSecret prefers a file, falling back to a plain variable for local runs.
func readSecret(fileKey, valueKey string) (string, error) {
	if path := os.Getenv(fileKey); path != "" {
		b, err := os.ReadFile(path)
		if err != nil {
			return "", fmt.Errorf("read %s: %w", fileKey, err)
		}
		return strings.TrimSpace(string(b)), nil
	}
	return strings.TrimSpace(os.Getenv(valueKey)), nil
}

func probe(listen string) error {
	host, port, err := net.SplitHostPort(listen)
	if err != nil {
		return fmt.Errorf("AW_LISTEN %q: %w", listen, err)
	}
	if host == "" {
		host = "127.0.0.1"
	}
	client := &http.Client{Timeout: 3 * time.Second}
	resp, err := client.Get("http://" + net.JoinHostPort(host, port) + "/healthz")
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("status %d", resp.StatusCode)
	}
	return nil
}
