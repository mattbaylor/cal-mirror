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

// Per-event control tags. Since v1.2 these live in the SOURCE event's NOTES,
// not the title. A tag is `#` followed by every non-whitespace character up to
// the next space/newline — any ASCII is allowed inside, so `#ref-cal`, `#skip_2`,
// etc. are each a single tag. A tag is only recognized where the `#` begins the
// notes or follows whitespace (so `a#b` is not a tag). An event may carry several.
public let TAG_SKIP = "#nomirror"       // don't mirror this event at all
public let TAG_PRIVATE = "#private"     // force full redaction, even on a copy mirror
public let TAG_PUBLIC = "#public"       // force full copy, even on a redacting mirror

/// The tags parsed out of one event's notes, plus the control-tag verdicts.
public struct NoteTags: Equatable, Sendable {
    /// Every tag token exactly as written — the leading `#` and any `+`/`-` included.
    public let tokens: [String]
    private let lowered: Set<String>    // lowercased tokens, for membership tests
    public let skip: Bool               // #nomirror present
    public let forcePrivate: Bool       // #private present
    public let forcePublic: Bool        // #public present

    init(_ tokens: [String]) {
        self.tokens = tokens
        let low = Set(tokens.map { $0.lowercased() })
        lowered = low
        skip = low.contains(TAG_SKIP)
        forcePrivate = low.contains(TAG_PRIVATE)
        forcePublic = low.contains(TAG_PUBLIC)
    }

    /// True if any of `wanted` matches a tag on this event (case-insensitive,
    /// whole-token). Config tags are normalized — trimmed, and given a leading `#`
    /// if omitted. The `+`/`-` prefix is significant: `#ref` does NOT match a
    /// `#+ref` token, and vice-versa (the modifier is part of the tag's identity).
    public func matchesAny(_ wanted: [String]) -> Bool {
        for w in wanted {
            var s = w.trimmingCharacters(in: .whitespaces).lowercased()
            if s.isEmpty { continue }
            if !s.hasPrefix("#") { s = "#" + s }
            if lowered.contains(s) { return true }
        }
        return false
    }
}

/// Parse the control/selection tags out of an event's notes. A tag starts at a
/// `#` that begins the notes or follows whitespace, and runs to the next
/// whitespace; a bare `#` (no character after it) is ignored.
public func scanNoteTags(_ notes: String?) -> NoteTags {
    guard let notes, !notes.isEmpty else { return NoteTags([]) }
    let ch = Array(notes)
    var tokens: [String] = []
    var i = 0, boundary = true          // start-of-notes counts as a boundary
    while i < ch.count {
        if ch[i] == "#" && boundary {
            var j = i + 1
            while j < ch.count && !ch[j].isWhitespace { j += 1 }
            if j > i + 1 { tokens.append(String(ch[i..<j])) }   // require ≥1 char after '#'
            i = j
            boundary = false            // the char before position j was non-whitespace
            continue
        }
        boundary = ch[i].isWhitespace
        i += 1
    }
    return NoteTags(tokens)
}

/// Rebuild an event's notes for a copy. Control tags (`#nomirror`/`#private`/
/// `#public`) are always removed. Every other tag is removed unless the mirror's
/// `copyNotesTags` is on — with a per-tag override: a `#-…` tag is always removed,
/// a `#+…` tag is always kept (verbatim, `+` included). Lines that shed no tag are
/// preserved byte-for-byte; only a line that actually loses a tag is rebuilt (its
/// inter-word spacing collapses to single spaces). Returns nil when nothing remains.
public func renderCopiedNotes(_ notes: String?, copyNotesTags: Bool) -> String? {
    guard let notes, !notes.isEmpty else { return notes }
    func isTag(_ f: String) -> Bool { f.count >= 2 && f.hasPrefix("#") }
    func keep(_ token: String) -> Bool {
        let low = token.lowercased()
        if low == TAG_SKIP || low == TAG_PRIVATE || low == TAG_PUBLIC { return false }
        let c = token[token.index(token.startIndex, offsetBy: 1)]   // safe: isTag ⇒ count ≥ 2
        if c == "-" { return false }
        if c == "+" { return true }
        return copyNotesTags
    }
    var strippedAny = false
    let lines = notes.components(separatedBy: "\n").map { line -> String in
        let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard fields.contains(where: { isTag($0) && !keep($0) }) else { return line }
        strippedAny = true
        return fields.filter { !isTag($0) || keep($0) }.joined(separator: " ")
    }
    guard strippedAny else { return notes }             // idempotent: untouched when nothing stripped
    var out = lines.joined(separator: "\n")
    while let last = out.last, last == "\n" || last == " " || last == "\t" { out.removeLast() }
    return out.isEmpty ? nil : out
}

/// Per-mirror event selection by notes tag. A mirror runs in ONE mode — include
/// or reject, never both (a single `mode` makes "both" unrepresentable). Absent,
/// or with an empty `tags` list, it selects nothing away — every event is eligible.
public struct TagFilter: Codable, Equatable, Sendable {
    public enum Mode: String, Codable, Sendable { case include, reject }
    public var mode: Mode
    public var tags: [String]
    public init(mode: Mode, tags: [String]) { self.mode = mode; self.tags = tags }

    // Lenient: a missing/unrecognized `mode` THROWS, so the enclosing optional
    // decodes to nil — i.e. no filter (copy everything), never a half-set filter.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = try c.decode(Mode.self, forKey: .mode)
        tags = (try? c.decode([String].self, forKey: .tags)) ?? []
    }

    /// Whether this filter actually constrains anything (has ≥1 tag).
    public var isActive: Bool { !tags.isEmpty }

    /// The copy(true)/skip(false) verdict for an event's parsed notes tags.
    public func admits(_ nt: NoteTags) -> Bool {
        guard isActive else { return true }
        let hit = nt.matchesAny(tags)
        return mode == .include ? hit : !hit
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
    public var projection: Projection
    /// Notes-tag selection: which source events this mirror copies. nil = copy all.
    public var tagFilter: TagFilter?
    /// When notes are projected, echo the source's non-control `#tags` into the
    /// copy? Default false = strip them. Per-tag `#+`/`#-` overrides this.
    public var copyNotesTags: Bool
    /// Optional pre-rename tag scheme this mirror should also adopt (migration).
    public var legacyScheme: String?

    public init(id: String, name: String, source: CalRef, dest: CalRef,
                enabled: Bool = true, showHeartbeat: Bool = true,
                windowPastDays: Double = 30, windowFutureDays: Double = 365,
                projection: Projection = Projection(),
                tagFilter: TagFilter? = nil, copyNotesTags: Bool = false,
                legacyScheme: String? = nil) {
        self.id = id; self.name = name; self.source = source; self.dest = dest
        self.enabled = enabled; self.showHeartbeat = showHeartbeat
        self.windowPastDays = windowPastDays; self.windowFutureDays = windowFutureDays
        self.projection = projection
        self.tagFilter = tagFilter; self.copyNotesTags = copyNotesTags
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
        // Absent OR malformed (e.g. unknown mode) → nil, i.e. no filter (copy all).
        tagFilter = try? c.decode(TagFilter.self, forKey: .tagFilter)
        copyNotesTags = (try? c.decode(Bool.self, forKey: .copyNotesTags)) ?? false
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
