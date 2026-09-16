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
