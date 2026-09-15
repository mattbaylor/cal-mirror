package api

// Tier is what a product id buys (decisions.md: $20 page / $35 subdomain /
// $70 custom domain; one page at $20, several from $35).
type Tier struct {
	Product   string
	Pages     int
	Subdomain bool
	Custom    bool
}

var tiers = map[string]Tier{
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
