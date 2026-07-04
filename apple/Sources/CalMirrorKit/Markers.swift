import Foundation

/// Per-mirror tagging of destination events, encoded in each copy's `url`.
///
/// Copy marker:      `x-calmirror:<mirrorId>~<base64url occurrenceKey>`
/// Heartbeat marker: `x-calmirror-status:<mirrorId>`
///
/// The `~` delimiter is RFC-3986 *unreserved* (never percent-encoded) and is
/// absent from the base64url alphabet, so it round-trips through URL storage.
public enum Markers {
    public static let scheme = "x-calmirror"
    public static let heartbeatScheme = "x-calmirror-status"

    public static func copyURL(mirrorId: String, key: String) -> URL? {
        URL(string: "\(scheme):\(mirrorId)~\(key)")
    }

    public static func heartbeatURL(mirrorId: String) -> URL? {
        URL(string: "\(heartbeatScheme):\(mirrorId)")
    }

    /// Owning mirror id + occurrence key for a destination event's URL, or nil
    /// if untagged. Honors each mirror's optional `legacyScheme`.
    public static func owner(of url: URL?, mirrors: [Mirror]) -> (id: String, key: String)? {
        guard let url, let scheme = url.scheme else { return nil }
        let s = url.absoluteString.removingPercentEncoding ?? url.absoluteString
        guard let colon = s.firstIndex(of: ":") else { return nil }
        let opaque = String(s[s.index(after: colon)...])
        if scheme == Markers.scheme {
            // primary "~"; tolerate "|" from pre-fix builds
            guard let d = opaque.firstIndex(where: { $0 == "~" || $0 == "|" }) else { return nil }
            return (String(opaque[..<d]), String(opaque[opaque.index(after: d)...]))
        }
        if let m = mirrors.first(where: { $0.legacyScheme == scheme }) { return (m.id, opaque) }
        return nil
    }

    /// True if a URL is any mirror/heartbeat marker (used by `--purge`).
    public static func isMirrorTag(_ url: URL?) -> Bool {
        guard let sc = url?.scheme else { return false }
        return sc.hasPrefix("x-calmirror") || sc.hasPrefix("x-jhmirror")
    }
}
