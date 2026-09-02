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
# This will not build yet. `../web/` and `../service/` are empty by design (the
# README in each says so, and the build order in ../README.md puts them at steps
# 2 and 3). That is not a defect in this file: it is the contract those two
# directories have to satisfy, written down before they exist so that neither of
# them invents its own answer to "how does this ship".

# --------------------------------------------------------------- the Lit app
FROM node:22-alpine AS web

WORKDIR /src
# Copy the manifests alone first so a source edit does not re-run the install.
COPY web/package.json web/package-lock.json ./
RUN npm ci

COPY web/ ./
# The dump the components are developed against (../README.md step 2: "start
# against a static dump on disk"). It ships in the image so the build can be
# smoke-tested without a database.
COPY schema/policy-dump.example.json ./public/example-dump.json
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
FROM golang:1.23-alpine AS service

WORKDIR /src
COPY service/go.mod service/go.sum ./
RUN go mod download

COPY service/ ./
COPY --from=web /src/dist ./internal/webui/dist

# The schema is embedded rather than shipped beside the binary, so that the file
# a human reviewed in a pull request is literally the file `-migrate` executes.
# A schema that lives in two places diverges, and the copy that diverges is
# always the one with the constraint that was keeping the privacy claim true.
COPY infra/schema.sql ./internal/store/schema.sql

# CGO_ENABLED=0 is not incidental. It is what makes the runtime stage able to be
# distroless/static, and it is why the SQLite driver has to be the pure-Go one
# (modernc.org/sqlite) rather than mattn/go-sqlite3 — see README.md, "Why Go".
ENV CGO_ENABLED=0
RUN go build -trimpath -ldflags="-s -w" -o /out/askwhen ./cmd/askwhen

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

# 8080, not 80: the process runs as an unprivileged user and Caddy is the only
# thing that ever binds a privileged port.
EXPOSE 8080
USER nonroot:nonroot

ENTRYPOINT ["/askwhen"]
