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
	"github.com/mattbaylor/cal-mirror/askwhen/service/internal/httpcache"
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
	listen     string
	dbPath     string
	schemaPath string
	zone       string
	tlsSecret  string
	pepper     []byte
}

func loadConfig() (config, error) {
	c := config{
		listen:     envOr("AW_LISTEN", ":8080"),
		dbPath:     envOr("AW_DB", "/data/askwhen.db"),
		schemaPath: envOr("AW_SCHEMA", "/schema.sql"),
		zone:       envOr("AW_ZONE", "askwhen.me"),
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

	srv := &http.Server{
		Addr:    cfg.listen,
		Handler: routes(st, cfg, log),

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

func routes(st *store.Store, cfg config, log *slog.Logger) http.Handler {
	mux := http.NewServeMux()

	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Cache-Control", "no-store")
		w.WriteHeader(http.StatusOK)
		fmt.Fprintln(w, "ok")
	})

	mux.Handle("GET /internal/tls-authorize", tlsauth.New(st, tlsauth.Config{
		Zone:   cfg.zone,
		Secret: cfg.tlsSecret,
		Logger: log,
	}))

	// `{slug}.json` is not a legal ServeMux pattern — a wildcard has to be a
	// whole path segment — so the suffix is stripped here rather than the public
	// URL being reshaped around a routing library's limitation.
	mux.HandleFunc("GET /p/{file}", func(w http.ResponseWriter, r *http.Request) {
		serveDump(w, r, st, log)
	})

	// Double opt-in. GET renders, POST confirms — see internal/api/confirm.go
	// for why that split is not decoration.
	confirm := &api.Confirm{
		Store:         st,
		Pepper:        cfg.pepper,
		HoldConfirmed: 24 * time.Hour,
		TTLConfirmed:  336 * time.Hour,
		Logger:        log,
	}
	mux.Handle("/c/{token}", confirm)

	return mux
}

// serveDump answers the request every visitor makes, and answers it cheaply the
// second time.
func serveDump(w http.ResponseWriter, r *http.Request, st *store.Store, log *slog.Logger) {
	file := r.PathValue("file")
	slug, ok := strings.CutSuffix(file, ".json")
	if !ok || !validSlug(slug) {
		// §4c: never distinguish never-existed from lapsed, deleted or expired.
		http.NotFound(w, r)
		return
	}

	etag, err := st.DumpETag(r.Context(), slug)
	if errors.Is(err, store.ErrNoPage) {
		http.NotFound(w, r)
		return
	}
	if err != nil {
		log.Error("dump etag", "err", err)
		http.Error(w, "unavailable", http.StatusServiceUnavailable)
		return
	}

	// The whole point of storing the validator: a returning visitor is answered
	// without the document ever being read.
	if httpcache.Serve(w, r, etag) {
		return
	}

	dump, etag2, err := st.Dump(r.Context(), slug)
	if errors.Is(err, store.ErrNoPage) {
		http.NotFound(w, r)
		return
	}
	if err != nil {
		log.Error("dump", "err", err)
		http.Error(w, "unavailable", http.StatusServiceUnavailable)
		return
	}
	// A publish can land between the two reads. Serving the new bytes under the
	// old validator would leave every cache holding a document it thinks is
	// current and is not.
	w.Header().Set("ETag", etag2)
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	// §8: noindex by default. The page opts in per slug; the dump never does.
	w.Header().Set("X-Robots-Tag", "noindex")
	fmt.Fprint(w, dump)
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
