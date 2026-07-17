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

/// Per-mirror field projection: how much of each source event crosses into the
/// copy. An absent `projection` block decodes to `Projection()` — the historical
/// behavior (real title + location, no notes/alarms, source availability).
public struct Projection: Codable, Equatable, Sendable {
    public enum TitleMode: String, Codable, Sendable { case copy, redact }
    public enum Availability: String, Codable, Sendable { case source, busy }

    public var title: TitleMode
    public var titleText: String        // shown when title == .redact
    public var location: Bool
    public var notes: Bool
    public var alarms: Bool
    public var availability: Availability
    public var custom: Bool             // UI: user explicitly chose "Custom" (persisted so it sticks)

    public init(title: TitleMode = .copy, titleText: String = "Busy",
                location: Bool = true, notes: Bool = false, alarms: Bool = false,
                availability: Availability = .source, custom: Bool = false) {
        self.title = title; self.titleText = titleText
        self.location = location; self.notes = notes; self.alarms = alarms
        self.availability = availability; self.custom = custom
    }

    // Fully lenient decoding: any bad/absent field falls back to its default,
    // and a malformed value never throws (which would nuke the whole config).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = (try? c.decode(TitleMode.self, forKey: .title)) ?? .copy
        titleText = ((try? c.decode(String.self, forKey: .titleText)).flatMap { $0.isEmpty ? nil : $0 }) ?? "Busy"
        location = (try? c.decode(Bool.self, forKey: .location)) ?? true
        notes = (try? c.decode(Bool.self, forKey: .notes)) ?? false
        alarms = (try? c.decode(Bool.self, forKey: .alarms)) ?? false
        availability = (try? c.decode(Availability.self, forKey: .availability)) ?? .source
        custom = (try? c.decode(Bool.self, forKey: .custom)) ?? false
    }
}

/// Per-event override tags typed into the SOURCE event's title. Fixed strings,
/// matched case-insensitively, stripped from the copied title so they don't leak.
public let TAG_SKIP = "#nomirror"       // don't mirror this event at all
public let TAG_PRIVATE = "#private"     // force full redaction, even on a copy mirror
public let TAG_PUBLIC = "#public"       // force full copy, even on a redacting mirror

/// Scan a source title for the fixed control tags. `clean` is the title with
/// every tag removed and surrounding whitespace collapsed — what we copy so the
/// tag never leaks. When no tag is present, `clean` is the original title untouched.
public func scanTags(_ title: String) -> (skip: Bool, forcePrivate: Bool, forcePublic: Bool, clean: String) {
    var skip = false, priv = false, pub = false, found = false
    var t = title
    for (tok, kind) in [(TAG_SKIP, 0), (TAG_PRIVATE, 1), (TAG_PUBLIC, 2)] {
        while let r = t.range(of: tok, options: .caseInsensitive) {
            found = true
            switch kind { case 0: skip = true; case 1: priv = true; default: pub = true }
            t.removeSubrange(r)
        }
    }
    guard found else { return (skip, priv, pub, title) }
    let clean = t.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).joined(separator: " ")
    return (skip, priv, pub, clean)
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
    public var projection: Projection
    /// Optional pre-rename tag scheme this mirror should also adopt (migration).
    public var legacyScheme: String?

    public init(id: String, name: String, source: CalRef, dest: CalRef,
                enabled: Bool = true, showHeartbeat: Bool = true,
                windowPastDays: Double = 30, windowFutureDays: Double = 365,
                projection: Projection = Projection(),
                legacyScheme: String? = nil) {
        self.id = id; self.name = name; self.source = source; self.dest = dest
        self.enabled = enabled; self.showHeartbeat = showHeartbeat
        self.windowPastDays = windowPastDays; self.windowFutureDays = windowFutureDays
        self.projection = projection
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
        projection = (try? c.decode(Projection.self, forKey: .projection)) ?? Projection()
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
