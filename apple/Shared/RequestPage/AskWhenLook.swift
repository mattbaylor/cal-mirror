import SwiftUI

/// AskWhen.me's own look, applied only where AskWhen.me is the thing on
/// screen: the setup flow, the explainer sheet, the request rows, the
/// conflict sheet. Everything outside keeps the system accent — Calendar
/// Mirror is blue; AskWhen.me is warm (`decisions.md`, *The AskWhen.me mark
/// and palette*, Matt, 17 September 2026).
///
/// Three colours, each with one job:
/// - `accent` — text, tint, borders, focus. Follows the appearance:
///   #C7355F light (4.8:1 on the grouped background, 5.1:1 on a card),
///   #F0689A dark (5.9:1 on a dark card).
/// - `fill` — the primary button, #FF9A3C in both modes: the gradient's
///   amber, so a submit is never the red that reads as cancel (Matt). White
///   on it is 2.1:1 and forbidden, so the label is `ink` (8.9:1). Against a
///   light surface the amber alone is 2:1, short of the 3:1 a control's
///   edge needs, so in light mode the button carries a border in the
///   accent; in dark mode amber against dark is 9:1 and it carries none.
/// The gradient itself is decoration only and appears in the mark alone.
enum AskWhenLook {
    static let accent = Color("AskWhenAccent")
    static let fill = Color("AskWhenFill")
    static let fillEdge = Color("AskWhenFillEdge")
    static let ink = Color("AskWhenInk")
    /// The mark, rendered from `assets/askwhen-mark.svg` by
    /// `assets/askwhen-markgen.swift`; never an SF Symbol.
    static let markName = "AskWhenMark"
}

/// The primary button: amber, ink label, accent edge in light mode. A style
/// of its own rather than `.borderedProminent`, whose label is white.
struct AskWhenProminentButtonStyle: ButtonStyle {
    enum Size { case large, regular }
    var size: Size = .large

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(size == .large ? .body.weight(.semibold) : .subheadline.weight(.semibold))
            .foregroundStyle(AskWhenLook.ink)
            .padding(.vertical, size == .large ? 14 : 7)
            .padding(.horizontal, size == .large ? 20 : 14)
            .frame(maxWidth: size == .large ? .infinity : nil)
            .background(AskWhenLook.fill, in: Capsule())
            .overlay(Capsule().strokeBorder(AskWhenLook.fillEdge, lineWidth: 1.5))
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(Capsule())
    }
}

extension View {
    /// The root of an AskWhen.me screen. Tints every control warm; the
    /// primary button then takes `askWhenProminent()`.
    func askWhenLook() -> some View { tint(AskWhenLook.accent) }

    /// The primary action, in AskWhen.me's amber.
    func askWhenProminent(_ size: AskWhenProminentButtonStyle.Size = .large) -> some View {
        buttonStyle(AskWhenProminentButtonStyle(size: size))
    }
}
