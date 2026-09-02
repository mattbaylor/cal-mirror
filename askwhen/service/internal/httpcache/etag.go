// Package httpcache implements conditional GET for the two endpoints that carry
// almost all of this service's traffic.
//
// It exists before the endpoints do, deliberately. Device polling is O(owners)
// and usually returns nothing (design/scale.md), and the dump is fetched by
// every requester who opens a page — so both want a cheap "nothing changed".
//
// More to the point, **cache semantics cannot be retrofitted once devices
// ship.** An old client keeps polling the way it was built to poll for as long
// as somebody has not updated, and there is no way to make it stop. Everything
// else about scaling this service can be decided late. This cannot.
package httpcache

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"net/http"
	"strings"
)

// StrongETag is a content hash: the same bytes always produce the same tag, and
// different bytes never do. Used for the policy dump, where a device that
// republishes byte-identical content should not invalidate anyone's cache.
func StrongETag(body []byte) string {
	sum := sha256.Sum256(body)
	return `"` + hex.EncodeToString(sum[:]) + `"`
}

// WeakETag is derived from a version counter rather than from bytes. Used for
// the queue.
//
// Weak rather than strong because the tag promises only that the *meaning* has
// not changed. The queue's bytes are derived from a counter today, so a strong
// tag would also be true — but the moment the payload carries a server timestamp
// or reorders, a strong tag becomes a lie, and nothing would notice. Weak is
// what we can actually promise, and If-None-Match compares weakly regardless.
func WeakETag(version int64) string {
	return fmt.Sprintf(`W/"v%d"`, version)
}

// Matches reports whether an If-None-Match header matches the current tag,
// using the weak comparison RFC 9110 §13.1.2 requires for this header.
//
// Weak comparison means the weakness prefix is ignored on both sides: a client
// holding `W/"v3"` matches a current tag of `"v3"` and vice versa. Getting this
// backwards — comparing strongly — produces a cache that silently never hits,
// which looks like nothing at all until someone measures the poll traffic.
func Matches(ifNoneMatch, current string) bool {
	ifNoneMatch = strings.TrimSpace(ifNoneMatch)
	if ifNoneMatch == "" || current == "" {
		return false
	}
	// "*" matches any current representation. We only call this when one
	// exists, so it is unconditionally a match.
	if ifNoneMatch == "*" {
		return true
	}

	want := opaque(current)
	if want == "" {
		return false
	}
	for _, candidate := range strings.Split(ifNoneMatch, ",") {
		if opaque(candidate) == want {
			return true
		}
	}
	return false
}

// opaque strips surrounding whitespace and any weakness prefix, returning the
// quoted opaque tag itself. Returns "" for anything that is not a well-formed
// entity-tag, so malformed list entries are skipped rather than matched.
func opaque(tag string) string {
	tag = strings.TrimSpace(tag)
	tag = strings.TrimPrefix(tag, "W/")
	tag = strings.TrimPrefix(tag, "w/")
	if len(tag) < 2 || tag[0] != '"' || tag[len(tag)-1] != '"' {
		return ""
	}
	return tag
}

// Serve sets the validator headers and, when the client already has this
// representation, writes 304 and reports true so the caller can stop.
//
// Cache-Control is `no-cache`, which does not mean "do not cache" — it means
// "revalidate before using". That is exactly right for both endpoints: a cached
// dump that skips revalidation would show slots that have since been taken, and
// the whole design is honest about being a snapshot. Revalidation is what the
// ETag makes cheap.
func Serve(w http.ResponseWriter, r *http.Request, etag string) bool {
	h := w.Header()
	h.Set("ETag", etag)
	if h.Get("Cache-Control") == "" {
		h.Set("Cache-Control", "no-cache")
	}

	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		return false
	}
	if !Matches(r.Header.Get("If-None-Match"), etag) {
		return false
	}

	// A 304 carries no body. Content-Length and Content-Type must not describe
	// one either, and net/http will not add them if nothing is written — but a
	// caller may have set them already before deciding to revalidate.
	h.Del("Content-Length")
	h.Del("Content-Type")
	w.WriteHeader(http.StatusNotModified)
	return true
}
