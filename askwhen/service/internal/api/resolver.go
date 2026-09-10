package api

import (
	"context"
	"net"
)

// systemResolver is net.DefaultResolver behind the slice of it domainverify
// needs. A distroless image has no /etc/resolv.conf surprises: Go's pure
// resolver reads the one Docker writes.
type systemResolver struct{}

func (systemResolver) LookupCNAME(ctx context.Context, host string) (string, error) {
	return net.DefaultResolver.LookupCNAME(ctx, host)
}

func (systemResolver) LookupHost(ctx context.Context, host string) ([]string, error) {
	return net.DefaultResolver.LookupHost(ctx, host)
}
