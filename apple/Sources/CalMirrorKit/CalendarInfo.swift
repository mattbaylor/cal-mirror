import Foundation

/// A calendar as the app lists it: what the engine reads from EventKit, what
/// a fixture invents, and what the request page's inference walks. Pure, in
/// its own file, because the menu-bar UI compiles the Kit without
/// `MirrorEngine.swift` (it never touches EventKit) and still needs the type.
public struct CalendarInfo: Identifiable, Hashable, Sendable {
    public let title: String
    public let account: String
    public let identifier: String
    public let writable: Bool
    public var id: String { identifier }
    public var label: String { "\(title) — \(account)" }

    /// Public so a fixture outside the Kit can describe a calendar that does
    /// not exist — the synthetic Mac in `MacFixture` builds its list this way
    /// rather than asking EventKit.
    public init(title: String, account: String, identifier: String, writable: Bool) {
        self.title = title; self.account = account
        self.identifier = identifier; self.writable = writable
    }
}

extension CalRef {
    /// A reference to `c` that carries its identifier.
    public init(_ c: CalendarInfo) {
        self.init(title: c.title, account: c.account, identifier: c.identifier)
    }

    /// The calendar this reference names, among `calendars`. The identifier
    /// wins when it still resolves, so a renamed calendar keeps its mirrors.
    /// Without one, or once EventKit has reissued it, the name decides as it
    /// always did: title and account, then title alone, first match in the
    /// order given.
    public func resolve(in calendars: [CalendarInfo]) -> CalendarInfo? {
        if let id = identifier, let c = calendars.first(where: { $0.identifier == id }) { return c }
        if let a = account, let c = calendars.first(where: { $0.title == title && $0.account == a }) { return c }
        return calendars.first { $0.title == title }
    }

    /// Whether this reference names `c`. The comparison the pickers make, so
    /// a reference saved before identifiers existed still shows as selected.
    public func refers(to c: CalendarInfo, among calendars: [CalendarInfo]) -> Bool {
        resolve(in: calendars)?.identifier == c.identifier
    }

    /// This reference with its identifier filled in, and its title and account
    /// brought up to date with the calendar that identifier names. A reference
    /// without one is pinned only when its name fits exactly one calendar:
    /// pinning a guess would make the wrong pick permanent. An identifier that
    /// no longer resolves is left alone, name and all, so the name can still
    /// find the calendar.
    public func pinned(in calendars: [CalendarInfo]) -> CalRef {
        if let id = identifier {
            guard let c = calendars.first(where: { $0.identifier == id }) else { return self }
            return CalRef(c)
        }
        // The same order `resolve` tries: the account narrows when it can.
        var candidates = calendars.filter { $0.title == title }
        if let a = account {
            let inAccount = candidates.filter { $0.account == a }
            if !inAccount.isEmpty { candidates = inAccount }
        }
        return candidates.count == 1 ? CalRef(candidates[0]) : self
    }
}

extension Config {
    /// Every calendar reference in the config, pinned (`CalRef.pinned(in:)`).
    /// Called with a fresh calendar list; the caller saves when the result
    /// differs. An empty list — no access yet — changes nothing.
    public func pinningCalendars(_ calendars: [CalendarInfo]) -> Config {
        guard !calendars.isEmpty else { return self }
        var c = self
        for i in c.mirrors.indices {
            c.mirrors[i].source = c.mirrors[i].source.pinned(in: calendars)
            c.mirrors[i].dest = c.mirrors[i].dest.pinned(in: calendars)
        }
        if var page = c.requestPage {
            page.blocking = page.blocking.map { $0.pinned(in: calendars) }
            page.requestCalendar = page.requestCalendar?.pinned(in: calendars)
            c.requestPage = page
        }
        return c
    }
}
