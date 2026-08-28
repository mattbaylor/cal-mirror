// The menu-bar icon: the app icon's face, redrawn for 18pt.
//
// The full-size icon (assets/icongen.swift) is a gradient tile with SF Symbol
// calendars and a white arrow. None of that survives the shrink — the gradient
// goes muddy and the symbols turn to mush — so this is a redrawn cousin at
// menu-bar weight: heavier strokes, no symbol glyphs, and the tile reduced to
// an outline. It is a template image, so macOS tints it for light/dark and
// inverts it while the menu is open.
//
// The tile is identical in every state, so the icon never shifts in the bar
// when state changes; only what sits inside it swaps.
#if os(macOS)
import AppKit

/// Everything the menu-bar icon can show.
///
/// The first three are health and are drawn as faces. `paused` is a face too —
/// it is a state you chose, not a failure. `unconfigured` is deliberately not a
/// face: with no mirrors set up there is nothing to have an expression about,
/// so it shows an add affordance instead.
enum MenuBarState { case ok, degraded, failing, paused, unconfigured }

func menuBarImage(_ state: MenuBarState) -> NSImage {
    // Drawn through a handler rather than baked to a bitmap, so it re-renders at
    // whatever scale the display needs instead of being resampled.
    let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
        guard let cg = NSGraphicsContext.current?.cgContext else { return false }
        drawIcon(cg, size: rect.width, state)
        return true
    }
    img.isTemplate = true
    img.accessibilityDescription = {
        switch state {
        case .ok:           return "All mirrors syncing"
        case .degraded:     return "Mirrors out of date"
        case .failing:      return "Mirror sync failing"
        case .paused:       return "Syncing paused"
        case .unconfigured: return "No mirrors configured"
        }
    }()
    return img
}

// MARK: - Geometry
//
// Drawn in an 18-unit square with a top-left origin, then scaled to whatever
// size the display asks for. Contents are drawn at natural size and then scaled
// and recentered to sit inside the tile.

private let TILE = CGRect(x: 0.8, y: 0.8, width: 16.4, height: 16.4)
private let TILE_WIDTH: CGFloat = 1.05
private let TILE_RADIUS: CGFloat = 3.7      // matches the app icon's 0.2237 ratio
private let FACE_SCALE: CGFloat = 0.92
private let EYES = [CGPoint(x: 5.0, y: 6.4), CGPoint(x: 13.0, y: 6.4)]

/// Vertical center of each state's drawn content. The mouths hang to different
/// depths — the frown plus arrowhead reaches lower than the smile — so each
/// state needs its own center to sit optically level inside the shared tile.
private func contentCenterY(_ s: MenuBarState) -> CGFloat {
    switch s {
    case .ok:           return 9.63
    case .degraded:     return 9.08
    case .failing:      return 10.02
    case .paused:       return 9.13
    case .unconfigured: return 9.00
    }
}

private func drawIcon(_ cg: CGContext, size: CGFloat, _ state: MenuBarState) {
    let k = size / 18.0
    cg.saveGState()
    defer { cg.restoreGState() }
    cg.translateBy(x: 0, y: size); cg.scaleBy(x: k, y: -k)   // top-left origin
    cg.setLineCap(.round); cg.setLineJoin(.round)
    cg.setStrokeColor(NSColor.black.cgColor); cg.setFillColor(NSColor.black.cgColor)

    cg.setLineWidth(TILE_WIDTH)
    cg.addPath(CGPath(roundedRect: TILE, cornerWidth: TILE_RADIUS, cornerHeight: TILE_RADIUS, transform: nil))
    cg.strokePath()

    cg.translateBy(x: 9, y: 9)
    cg.scaleBy(x: FACE_SCALE, y: FACE_SCALE)
    cg.translateBy(x: -9, y: -contentCenterY(state))
    let wb = 1.0 / FACE_SCALE   // hold stroke weight constant through the scale

    // Nothing configured: no face, just an add affordance. A face here would be
    // expressing an opinion about mirrors that do not exist yet.
    if case .unconfigured = state {
        let arm: CGFloat = 4.6
        cg.setLineWidth(2.2 * wb)
        cg.move(to: CGPoint(x: 9 - arm, y: 9)); cg.addLine(to: CGPoint(x: 9 + arm, y: 9))
        cg.move(to: CGPoint(x: 9, y: 9 - arm)); cg.addLine(to: CGPoint(x: 9, y: 9 + arm))
        cg.strokePath()
        return
    }

    // ---- Eyes ----
    for c in EYES {
        switch state {
        case .ok:
            // A calendar: rounded rect with a solid header band. No grid dots or
            // binding nubs — below about 6pt they turn into noise.
            let r = CGRect(x: c.x - 2.5, y: c.y - 2.3, width: 5.0, height: 4.6)
            let p = CGPath(roundedRect: r, cornerWidth: 1.0, cornerHeight: 1.0, transform: nil)
            cg.saveGState(); cg.addPath(p); cg.clip()
            cg.fill(CGRect(x: r.minX, y: r.minY, width: r.width, height: 1.5))
            cg.restoreGState()
            cg.setLineWidth(1.1 * wb); cg.addPath(p); cg.strokePath()
        case .degraded:
            // Solid warning triangle. Filled, not outlined: at menu-bar size the
            // interior counter of an outline collapses. Stroking the same path
            // rounds the corners.
            let p = CGMutablePath()
            p.move(to: CGPoint(x: c.x, y: c.y - 2.6))
            p.addLine(to: CGPoint(x: c.x + 2.9, y: c.y + 2.4))
            p.addLine(to: CGPoint(x: c.x - 2.9, y: c.y + 2.4))
            p.closeSubpath()
            cg.addPath(p); cg.fillPath()
            cg.setLineWidth(0.9 * wb); cg.addPath(p); cg.strokePath()
        case .failing:
            cg.setLineWidth(1.7 * wb)
            let e: CGFloat = 2.3
            cg.move(to: CGPoint(x: c.x - e, y: c.y - e)); cg.addLine(to: CGPoint(x: c.x + e, y: c.y + e))
            cg.move(to: CGPoint(x: c.x + e, y: c.y - e)); cg.addLine(to: CGPoint(x: c.x - e, y: c.y + e))
            cg.strokePath()
        case .paused:
            cg.setLineWidth(1.5 * wb)
            cg.move(to: CGPoint(x: c.x - 2.3, y: c.y)); cg.addLine(to: CGPoint(x: c.x + 2.3, y: c.y))
            cg.strokePath()
        case .unconfigured:
            break   // handled above
        }
    }

    // ---- Mouth ----
    // The arrowhead is the brand's one-way sync arrow: a tongue hanging off the
    // curved mouths, in line with the straight one. Paused has no arrow at all,
    // because nothing is flowing.
    func tongue(at p: CGPoint) {
        let half: CGFloat = 1.45, len: CGFloat = 2.8, topY = p.y - 0.4
        let t = CGMutablePath()
        t.move(to: CGPoint(x: p.x - half, y: topY))
        t.addLine(to: CGPoint(x: p.x + half, y: topY))
        t.addLine(to: CGPoint(x: p.x, y: topY + len))
        t.closeSubpath()
        cg.addPath(t); cg.fillPath()
    }
    func curve(_ y: CGFloat, control: CGFloat) {
        let p0 = CGPoint(x: 4.4, y: y), p2 = CGPoint(x: 13.6, y: y)
        let arc = CGMutablePath(); arc.move(to: p0)
        arc.addQuadCurve(to: p2, control: CGPoint(x: 9, y: control))
        cg.addPath(arc); cg.strokePath()
        tongue(at: p2)
    }

    cg.setLineWidth(1.5 * wb)
    switch state {
    case .ok:      curve(12.4, control: 17.4)   // smile
    case .failing: curve(14.4, control: 9.6)    // frown
    case .paused:
        cg.move(to: CGPoint(x: 4.4, y: 12.9)); cg.addLine(to: CGPoint(x: 13.6, y: 12.9))
        cg.strokePath()
    case .degraded:
        let y: CGFloat = 12.9
        cg.move(to: CGPoint(x: 3.9, y: y)); cg.addLine(to: CGPoint(x: 11.6, y: y)); cg.strokePath()
        let head = CGMutablePath()
        head.move(to: CGPoint(x: 14.3, y: y))
        head.addLine(to: CGPoint(x: 11.3, y: y - 1.9))
        head.addLine(to: CGPoint(x: 11.3, y: y + 1.9))
        head.closeSubpath()
        cg.addPath(head); cg.fillPath()
    case .unconfigured:
        break   // handled above
    }
}
#endif
