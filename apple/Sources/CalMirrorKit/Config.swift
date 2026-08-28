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

/// How much of the source event's NOTES crosses into the copy.
/// - `none`: no notes at all — the historical default
/// - `tags`: only the `#tags`, on one line; the note prose is dropped. Lets a
///   mirror carry selection tags across without leaking what the note says.
/// - `full`: the whole note, with tags stripped unless `copyNotesTags` is set
public enum NotesMode: String, Codable, Sendable { case none, tags, full }

/// Per-mirror field projection: how much of each source event crosses into the
/// copy. An absent `projection` block decodes to `Projection()` — the historical
/// behavior (real title + location, no notes/alarms, source availability).
public struct Projection: Codable, Equatable, Sendable {
    public enum TitleMode: String, Codable, Sendable { case copy, redact }
    public enum Availability: String, Codable, Sendable { case source, busy }

    public var title: TitleMode
    public var titleText: String        // shown when title == .redact
    /// Prepended to the copy's title, with a single space. Applies to whatever
    /// title the copy ends up with — real or redacted — so a redacting mirror
    /// can still say which mirror a block came from ("[Work] Busy").
    public var titlePrefix: String
    public var location: Bool
    public var notes: NotesMode
    public var alarms: Bool
    public var availability: Availability
    public var custom: Bool             // UI: user explicitly chose "Custom" (persisted so it sticks)

    public init(title: TitleMode = .copy, titleText: String = "Busy",
                titlePrefix: String = "",
                location: Bool = true, notes: NotesMode = .none, alarms: Bool = false,
                availability: Availability = .source, custom: Bool = false) {
        self.title = title; self.titleText = titleText; self.titlePrefix = titlePrefix
        self.location = location; self.notes = notes; self.alarms = alarms
        self.availability = availability; self.custom = custom
    }

    /// The copy's title, given the source title this projection resolved to.
    /// Single place so the engine and the UI preview can never disagree.
    public func prefixed(_ base: String) -> String {
        let p = titlePrefix.trimmingCharacters(in: .whitespaces)
        return p.isEmpty ? base : "\(p) \(base)"
    }

    // Fully lenient decoding: any bad/absent field falls back to its default,
    // and a malformed value never throws (which would nuke the whole config).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = (try? c.decode(TitleMode.self, forKey: .title)) ?? .copy
        titleText = ((try? c.decode(String.self, forKey: .titleText)).flatMap { $0.isEmpty ? nil : $0 }) ?? "Busy"
        titlePrefix = (try? c.decode(String.self, forKey: .titlePrefix)) ?? ""
        location = (try? c.decode(Bool.self, forKey: .location)) ?? true
        // `notes` was a Bool before tags-only mode existed. Accept both: a
        // string is the current form, a legacy `true` means the whole note.
        if let mode = try? c.decode(NotesMode.self, forKey: .notes) { notes = mode }
        else if let legacy = try? c.decode(Bool.self, forKey: .notes) { notes = legacy ? .full : .none }
        else { notes = .none }
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

/// Build a TAGS-ONLY note for a copy: the event's tags, in source order, on one
/// line, and nothing else — the prose never crosses over. Control tags
/// (`#nomirror`/`#private`/`#public`) and `#-…` tags are dropped; `#+…` is kept
/// verbatim. `copyNotesTags` has no say here: choosing this mode IS the choice
/// to carry tags. Returns nil when no tag survives, so the copy gets no notes.
public func renderTagsOnly(_ notes: String?) -> String? {
    let kept = scanNoteTags(notes).tokens.filter { token in
        let low = token.lowercased()
        if low == TAG_SKIP || low == TAG_PRIVATE || low == TAG_PUBLIC { return false }
        return token[token.index(token.startIndex, offsetBy: 1)] != "-"   // scanNoteTags ⇒ count ≥ 2
    }
    return kept.isEmpty ? nil : kept.joined(separator: " ")
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
    /// Property-based selection — declined, canceled, all-day, time of day, etc.
    /// All-default (the absent case) selects nothing away.
    public var filters: EventFilters
    /// When notes are projected, echo the source's non-control `#tags` into the
    /// copy? Default false = strip them. Per-tag `#+`/`#-` overrides this.
    public var copyNotesTags: Bool
    /// Optional pre-rename tag scheme this mirror should also adopt (migration).
    public var legacyScheme: String?

    public init(id: String, name: String, source: CalRef, dest: CalRef,
                enabled: Bool = true, showHeartbeat: Bool = true,
                windowPastDays: Double = 30, windowFutureDays: Double = 365,
                projection: Projection = Projection(),
                tagFilter: TagFilter? = nil, filters: EventFilters = EventFilters(),
                copyNotesTags: Bool = false,
                legacyScheme: String? = nil) {
        self.id = id; self.name = name; self.source = source; self.dest = dest
        self.enabled = enabled; self.showHeartbeat = showHeartbeat
        self.windowPastDays = windowPastDays; self.windowFutureDays = windowFutureDays
        self.projection = projection
        self.tagFilter = tagFilter; self.filters = filters
        self.copyNotesTags = copyNotesTags
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
        // Absent → all-default, which selects nothing away (historical behavior).
        filters = (try? c.decode(EventFilters.self, forKey: .filters)) ?? EventFilters()
        copyNotesTags = (try? c.decode(Bool.self, forKey: .copyNotesTags)) ?? false
        legacyScheme = try c.decodeIfPresent(String.self, forKey: .legacyScheme)
    }

    // Declared explicitly: supplying BOTH init(from:) and encode(to:) stops the
    // compiler synthesizing these.
    enum CodingKeys: String, CodingKey {
        case id, name, source, dest, enabled, showHeartbeat
        case windowPastDays, windowFutureDays, projection
        case tagFilter, filters, copyNotesTags, legacyScheme
    }

    // config.json is meant to be hand-editable, so a block that isn't doing
    // anything doesn't get written: an inactive `filters` or `tagFilter`, and a
    // false `copyNotesTags`, are all absent rather than spelled out as defaults.
    // Decoding treats absent and all-default identically, so this is lossless.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(source, forKey: .source)
        try c.encode(dest, forKey: .dest)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(showHeartbeat, forKey: .showHeartbeat)
        try c.encode(windowPastDays, forKey: .windowPastDays)
        try c.encode(windowFutureDays, forKey: .windowFutureDays)
        try c.encode(projection, forKey: .projection)
        if let tagFilter, tagFilter.isActive { try c.encode(tagFilter, forKey: .tagFilter) }
        if filters.isActive { try c.encode(filters, forKey: .filters) }
        if copyNotesTags { try c.encode(copyNotesTags, forKey: .copyNotesTags) }
        try c.encodeIfPresent(legacyScheme, forKey: .legacyScheme)
    }
}

/// Top-level configuration: global settings plus the list of mirror pairs.
public struct Config: Codable, Equatable, Sendable {
    public var paused: Bool
    public var intervalSeconds: Int
    /// Sync as calendars change, rather than only on the schedule.
    ///
    /// Global, not per-mirror, and that is a property of the platform rather
    /// than a simplification: `EKEventStoreChanged` reports that the store
    /// changed, never *which* calendar. A per-mirror switch would be a promise
    /// the API can't keep. The UI still presents it per mirror — turning it on
    /// anywhere turns it on everywhere — and says so.
    public var realtime: Bool
    public var mirrors: [Mirror]

    /// The floor realtime pins the schedule to. Once changes drive the cycles,
    /// the interval is only a backstop for missed notifications, and it stops
    /// being worth configuring.
    public static let realtimeFloorSeconds = 300

    /// Note the asymmetry with `init(from:)` below, which is deliberate: a
    /// config constructed fresh — a new install — gets realtime ON, while a
    /// config decoded from a file that predates the key keeps it OFF. Upgrading
    /// never silently changes how an existing setup syncs.
    public init(paused: Bool = false, intervalSeconds: Int = 900,
                realtime: Bool = true, mirrors: [Mirror] = []) {
        self.paused = paused; self.intervalSeconds = intervalSeconds
        self.realtime = realtime; self.mirrors = mirrors
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        paused = try c.decodeIfPresent(Bool.self, forKey: .paused) ?? false
        intervalSeconds = try c.decodeIfPresent(Int.self, forKey: .intervalSeconds) ?? 900
        realtime = try c.decodeIfPresent(Bool.self, forKey: .realtime) ?? false
        mirrors = try c.decodeIfPresent([Mirror].self, forKey: .mirrors) ?? []
    }

    /// What the scheduler should use as its floor, given the mode.
    public var effectiveIntervalSeconds: Int {
        realtime ? Config.realtimeFloorSeconds : intervalSeconds
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
