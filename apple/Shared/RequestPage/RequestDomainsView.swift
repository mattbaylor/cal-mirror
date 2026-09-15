import SwiftUI
import CalMirrorKit

/// The address a page answers on — the slug it always has, plus whatever the
/// $35 and $70 tiers add.
///
/// **Checking is not a refresh button.** `GET /domains` makes the service
/// re-read DNS and issue the certificate the moment the record is right, so
/// the owner asking "is it working yet?" is the thing that makes it start
/// working. The copy says so, because a button that looks passive and is not
/// gets pressed once and then waited on.
///
/// **Tier is the service's to enforce.** This screen hides what the owner has
/// not bought so it does not offer a thing that will be refused, but it does
/// not treat its own opinion as authoritative — the device holds a cached
/// entitlement and the service holds the verified one. A refusal comes back
/// with the service's own words and is shown, not paraphrased.
struct RequestDomainsView: View {
    let page: RequestPageConfig
    let tier: AskWhenTier?
    let domains: [AskwhenClient.ClaimedDomain]
    let busy: Bool
    let error: String?

    let onClaim: (String) -> Void
    let onRelease: (String) -> Void
    let onCheck: () -> Void
    let onUpgrade: (AskWhenTier) -> Void

    @State private var subdomainLabel = ""
    @State private var customHost = ""

    var body: some View {
        Section(RequestCopy.Domains.section) {
            VStack(alignment: .leading, spacing: 4) {
                Text(RequestCopy.Domains.current).font(.caption).foregroundStyle(.secondary)
                Text("askwhen.me/\(page.slug)")
                    .font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                Text(RequestCopy.Domains.slugNote).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        if let error {
            Section {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        ForEach(domains, id: \.host) { domain in
            ClaimedDomainSection(domain: domain, busy: busy,
                                 onCheck: onCheck, onRelease: { onRelease(domain.host) })
        }

        // Offered only when it is not already held: a second subdomain is not
        // a thing the service grants, and an input that always fails is worse
        // than no input.
        if !hasKind("subdomain") {
            Section(RequestCopy.Domains.subdomainHeading) {
                Text(RequestCopy.Domains.subdomainBody)
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                if tier?.includesSubdomain == true {
                    HStack(spacing: 2) {
                        TextField(RequestCopy.Domains.subdomainPlaceholder, text: $subdomainLabel)
                            .textFieldStyle(.roundedBorder)
                            #if !os(macOS)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            #endif
                        Text(RequestCopy.Domains.subdomainSuffix).foregroundStyle(.secondary)
                    }
                    Button(RequestCopy.Domains.claim) {
                        onClaim(subdomainLabel + RequestCopy.Domains.subdomainSuffix)
                        subdomainLabel = ""
                    }
                    .disabled(busy || subdomainLabel.trimmingCharacters(in: .whitespaces).isEmpty)
                } else {
                    upgrade(RequestCopy.Domains.needsSubdomainTier, to: .subdomain)
                }
            }
        }

        if !hasKind("custom") {
            Section(RequestCopy.Domains.customHeading) {
                Text(RequestCopy.Domains.customBody)
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                if tier?.includesCustomDomain == true {
                    TextField(RequestCopy.Domains.customPlaceholder, text: $customHost)
                        .textFieldStyle(.roundedBorder)
                        #if !os(macOS)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        #endif
                    Button(RequestCopy.Domains.claim) {
                        onClaim(customHost)
                        customHost = ""
                    }
                    .disabled(busy || customHost.trimmingCharacters(in: .whitespaces).isEmpty)
                } else {
                    upgrade(RequestCopy.Domains.needsDomainTier, to: .domain)
                }
            }
        }
    }

    private func hasKind(_ kind: String) -> Bool { domains.contains { $0.kind == kind } }

    /// The upgrade is offered where the want appears, which is the whole
    /// argument for not selling these tiers on the offer screen.
    private func upgrade(_ reason: String, to tier: AskWhenTier) -> some View {
        Group {
            Text(reason).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(RequestCopy.Domains.upgrade) { onUpgrade(tier) }
            // Proration is Apple's and it is not obvious. Saying so stops the
            // owner assuming they are paying twice for the same year.
            Text(RequestCopy.Domains.upgradeNote)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// One claimed hostname. A subdomain is verified on arrival and has nothing to
/// say; a custom domain is the one that needs walking through, so it carries
/// the record to set and what DNS currently answers instead.
struct ClaimedDomainSection: View {
    let domain: AskwhenClient.ClaimedDomain
    let busy: Bool
    let onCheck: () -> Void
    let onRelease: () -> Void

    @State private var confirmingRelease = false

    var body: some View {
        Section {
            HStack {
                Text(domain.host)
                    .font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                Spacer()
                Label(domain.verified ? RequestCopy.Domains.verified : RequestCopy.Domains.pending,
                      systemImage: domain.verified ? "checkmark.circle.fill" : "clock")
                    .font(.caption)
                    .foregroundStyle(domain.verified ? .green : .orange)
            }

            if !domain.verified {
                if let point = domain.point {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(RequestCopy.Domains.cnameHeading)
                            .font(.caption).foregroundStyle(.secondary)
                        Text(String(format: RequestCopy.Domains.cnameFormat, domain.host, point))
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(RequestCopy.Domains.cnameNote)
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                // The service's own diagnosis, shown verbatim. It knows what
                // DNS answered and this device does not, and rewording it
                // would only make a wrong CNAME harder to spot.
                if let check = domain.check {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(RequestCopy.Domains.sawHeading)
                            .font(.caption).foregroundStyle(.secondary)
                        Text(check).font(.system(.caption, design: .monospaced))
                            .fixedSize(horizontal: false, vertical: true)
                        if let advice = domain.advice {
                            Text(advice).font(.caption).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                Button(busy ? RequestCopy.Domains.checking : RequestCopy.Domains.check, action: onCheck)
                    .disabled(busy)
                Text(RequestCopy.Domains.checkNote)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Confirmed, because links already sent to this hostname stop
            // working the moment it is released and there is no undo.
            Button(RequestCopy.Domains.release, role: .destructive) { confirmingRelease = true }
            Text(RequestCopy.Domains.releaseNote)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .confirmationDialog(RequestCopy.Domains.release, isPresented: $confirmingRelease) {
            Button(RequestCopy.Domains.release, role: .destructive, action: onRelease)
        } message: {
            Text(RequestCopy.Domains.releaseNote)
        }
    }
}
