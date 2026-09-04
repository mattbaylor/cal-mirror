# askwhen.me — the service and the request page, in one image.
#
# One image rather than two on purpose. Architecture §4 has the service serving
# `GET /{slug}` itself, so the Lit app and the JSON it fetches are same-origin
# and the CORS problem that killed the earlier design never arises. Two
# containers would mean either a second origin or a shared volume neither of
# them owns, to save nothing: the web build produces a few hundred KB of static
# files, and they belong to the binary that serves them.
#
# Build context is `askwhen/`, not `askwhen/infra/` — see compose.yml.
#
#   docker compose -f infra/compose.yml build
#
# This builds as of 4 September 2026. `../web/` is step 2 and is done; `../service/`
# has its entry point and the two pieces built ahead of step 3 — the TLS
# authorisation gate and the conditional-GET machinery. The request lifecycle is
# not here yet, so the image runs and serves a policy dump but cannot take a
# request.

# --------------------------------------------------------------- the Lit app
FROM node:22-alpine AS web

# WORKDIR is /src/web, not /src, so that `schema/` can sit beside it exactly as
# it does in the repository. The bundle imports the example dump as
# `../../schema/policy-dump.example.json` (web/src/dump.js), and a build layout
# that does not mirror the source layout means that path resolves here and not
# there — or the reverse, which is worse because it fails only in CI.
WORKDIR /src/web
# Copy the manifests alone first so a source edit does not re-run the install.
COPY web/package.json web/package-lock.json ./
RUN npm ci

COPY web/ ./
# The dump the components are developed against (../README.md step 2: "start
# against a static dump on disk"), at the path the source expects it.
COPY schema/ /src/schema/
RUN npm run build

# The standing constraint from ../README.md: no third-party scripts, no fonts,
# no analytics on the request page. Grep the built output rather than trusting
# that nobody added one, because the whole product argument dies quietly if they
# did — and a bundler will happily inline a Google Fonts @import for you.
#
# The one permitted hit is the SVG namespace, which is an identifier and not a
# fetch. If you find yourself widening this list, that is the moment to argue
# about it, which is the point of putting it in the build rather than in a
# review checklist.
RUN if grep -rIn -E 'https?://' dist/ | grep -v 'www\.w3\.org'; then \
      echo "FAIL: the built request page references an external URL"; exit 1; \
    fi

# --------------------------------------------------------------- the service
FROM golang:1.25-alpine AS service

WORKDIR /src
COPY service/go.mod service/go.sum ./
RUN go mod download

COPY service/ ./

# CGO_ENABLED=0 is not incidental. It is what makes the runtime stage able to be
# distroless/static, and it is why the SQLite driver has to be the pure-Go one
# (modernc.org/sqlite) rather than mattn/go-sqlite3 — see README.md, "Why Go".
ENV CGO_ENABLED=0
RUN go build -trimpath -ldflags="-s -w" -o /out/askwhen ./cmd/askwhen

# An empty directory, carried into the final stage so /data exists in the image
# owned by the user that has to write to it. See the final stage.
RUN mkdir -p /out/data

# --------------------------------------------------------------- the runtime
FROM gcr.io/distroless/static-debian12:nonroot

# distroless/static carries ca-certificates (needed for SMTP submission over
# TLS to dlvr) and nothing else — no shell, no package manager, nothing to
# exploit if the request handler is ever wrong about untrusted input.
#
# It does NOT carry tzdata. The service works in UTC throughout (§3,
# "everything on the wire is UTC, and the browser localises") and only ever
# passes the owner's zone string through to the page, so it should not need a
# zone database. If it ever does, embed it with `import _ "time/tzdata"` rather
# than fattening this stage.

COPY --from=service /out/askwhen /askwhen

# /data must exist in the image, owned by nonroot, BEFORE a volume is mounted
# over it. Docker seeds a fresh named volume from whatever is at the mount point
# and inherits its ownership; if the path is absent the volume is created
# root-owned, and this container — which runs as 65532 with a read-only root
# filesystem — cannot open the database.
#
# Found by deploying it, not by reading it. The container exited immediately and
# the failure looked like a dozen other startup problems until the volume was
# inspected. Fixed here rather than with a chown in an entrypoint, because a
# shell in the runtime stage is exactly what distroless was chosen to avoid.
COPY --from=service --chown=65532:65532 /out/data /data

# The schema travels beside the binary rather than compiled into it, and it is
# the same infra/schema.sql a human reviewed in a pull request — not a copy. A
# schema that lives in two places diverges, and the copy that diverges is always
# the one carrying the constraint that was keeping the privacy claim true. The
# service reads it at startup from AW_SCHEMA, which defaults to this path.
COPY infra/schema.sql /schema.sql

# The built request page. Nothing serves it yet — that is step 3, along with the
# rest of the request lifecycle — but the web stage above still earns its place:
# it proves the page builds and greps the output for external URLs, which is
# where the product's central claim is actually enforced.
COPY --from=web /src/web/dist /web

# 8080, not 80: the process runs as an unprivileged user and Caddy is the only
# thing that ever binds a privileged port.
EXPOSE 8080
USER nonroot:nonroot

ENTRYPOINT ["/askwhen"]
