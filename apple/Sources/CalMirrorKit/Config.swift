import Foundation

/// A reference to a calendar by human-readable title (+ optional account name).
/// Matching falls back to title-only when `account` is nil.
public struct CalRef: Codable, Equatable, Hashable, Sendable {
    public var title: String
    public var account: String?
    public init(title: String, account: String? = nil) {
        self.title = title
        self.account = account
    }
}

/// One source → destination mirror pair.
public struct Mirror: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var source: CalRef
    public var dest: CalRef
    public var enabled: Bool
    public var showHeartbeat: Bool
    public var windowPastDays: Double
    public var windowFutureDays: Double
    /// Optional pre-rename tag scheme this mirror should also adopt (migration).
    public var legacyScheme: String?

    public init(id: String, name: String, source: CalRef, dest: CalRef,
                enabled: Bool = true, showHeartbeat: Bool = true,
                windowPastDays: Double = 30, windowFutureDays: Double = 365,
                legacyScheme: String? = nil) {
        self.id = id; self.name = name; self.source = source; self.dest = dest
        self.enabled = enabled; self.showHeartbeat = showHeartbeat
        self.windowPastDays = windowPastDays; self.windowFutureDays = windowFutureDays
        self.legacyScheme = legacyScheme
    }

    // Lenient decoding: tolerate missing optional fields.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? id
        source = try c.decode(CalRef.self, forKey: .source)
        dest = try c.decode(CalRef.self, forKey: .dest)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        showHeartbeat = try c.decodeIfPresent(Bool.self, forKey: .showHeartbeat) ?? true
        windowPastDays = try c.decodeIfPresent(Double.self, forKey: .windowPastDays) ?? 30
        windowFutureDays = try c.decodeIfPresent(Double.self, forKey: .windowFutureDays) ?? 365
        legacyScheme = try c.decodeIfPresent(String.self, forKey: .legacyScheme)
    }
}

/// Top-level configuration: global settings plus the list of mirror pairs.
public struct Config: Codable, Equatable, Sendable {
    public var paused: Bool
    public var intervalSeconds: Int
    public var mirrors: [Mirror]

    public init(paused: Bool = false, intervalSeconds: Int = 900, mirrors: [Mirror] = []) {
        self.paused = paused; self.intervalSeconds = intervalSeconds; self.mirrors = mirrors
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        paused = try c.decodeIfPresent(Bool.self, forKey: .paused) ?? false
        intervalSeconds = try c.decodeIfPresent(Int.self, forKey: .intervalSeconds) ?? 900
        mirrors = try c.decodeIfPresent([Mirror].self, forKey: .mirrors) ?? []
    }

    public static let empty = Config()
}

/// JSON load/save for a `Config` at a file URL. The platform decides the URL
/// (macOS: ~/.local/cal-mirror/config.json; iOS: the app container).
public enum ConfigStore {
    public static func load(from url: URL) -> Config {
        guard let data = try? Data(contentsOf: url),
              let cfg = try? JSONDecoder().decode(Config.self, from: data) else { return .empty }
        return cfg
    }

    public static func save(_ config: Config, to url: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try enc.encode(config).write(to: url, options: .atomic)
    }
}
