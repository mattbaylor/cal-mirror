package api

import "time"

// Tier is what a product id buys (decisions.md: one page free to anyone who
// bought Calendar Mirror; $20 subdomain / $35 custom domain, several pages).
type Tier struct {
	Product   string
	Pages     int
	Subdomain bool
	Custom    bool
}

// FreeProduct is the free tier's product id. It is not an App Store product:
// nothing is bought, the owner presents the app transaction for Calendar
// Mirror instead, and the service records it under this id.
const FreeProduct = "me.askwhen.free"

// FreeIdle is how long a free page lasts without the owner publishing or
// resolving a request (decisions.md: 90 days, then the usual 7-day grace).
const FreeIdle = 90 * 24 * time.Hour

var tiers = map[string]Tier{
	FreeProduct: {Product: FreeProduct, Pages: 1},
	// Retired: the free tier replaced it and it never had a subscriber. Still
	// honoured until App Store Connect stops selling it, so the service can
	// deploy ahead of the app; delete the line once it is off sale.
	"me.askwhen.page.annual":      {Product: "me.askwhen.page.annual", Pages: 1},
	"me.askwhen.subdomain.annual": {Product: "me.askwhen.subdomain.annual", Pages: 5, Subdomain: true},
	"me.askwhen.domain.annual":    {Product: "me.askwhen.domain.annual", Pages: 5, Subdomain: true, Custom: true},
}

// TierFor is the tier a product id buys; ok is false for a product we do not
// sell, which a genuine Apple transaction for our bundle cannot carry but a
// future product added in App Store Connect before the service knew it could.
func TierFor(productID string) (Tier, bool) {
	t, ok := tiers[productID]
	return t, ok
}
