// Generates the cal-mirror app icon: a blue→teal gradient with the white
// refresh glyph used throughout the brand. Produces a full-bleed 1024 master
// (for iOS) and a rounded macOS .iconset.
//
//   swiftc assets/icongen.swift -o /tmp/icongen && /tmp/icongen assets
//   iconutil -c icns assets/AppIcon.iconset -o assets/AppIcon.icns
import AppKit

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."

func render(_ px: Int, rounded: Bool) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: px, height: px)
    NSGraphicsContext.saveGraphicsState()
    let gctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = gctx
    let cg = gctx.cgContext
    let S = CGFloat(px)

    let margin: CGFloat = rounded ? S * 0.085 : 0
    let rect = CGRect(x: margin, y: margin, width: S - 2*margin, height: S - 2*margin)
    let radius: CGFloat = rounded ? rect.width * 0.2237 : 0

    cg.saveGState()
    cg.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
    cg.clip()
    let colors = [NSColor(srgbRed: 0.227, green: 0.627, blue: 1.0, alpha: 1).cgColor,
                  NSColor(srgbRed: 0.157, green: 0.784, blue: 0.714, alpha: 1).cgColor] as CFArray
    let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
    cg.drawLinearGradient(grad, start: CGPoint(x: rect.minX, y: rect.maxY),
                          end: CGPoint(x: rect.maxX, y: rect.minY), options: [])
    cg.restoreGState()

    // Two calendars with a single one-way curved arrow (source → copy).
    func drawSymbol(_ name: String, center: CGPoint, pointSize: CGFloat) {
        let conf = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil),
              let sym = base.withSymbolConfiguration(conf) else { return }
        let s = sym.size
        sym.draw(in: NSRect(x: center.x - s.width/2, y: center.y - s.height/2, width: s.width, height: s.height))
    }

    let R = rect
    let calPt = R.width * 0.30
    drawSymbol("calendar", center: CGPoint(x: R.minX + R.width * 0.29, y: R.minY + R.height * 0.40), pointSize: calPt)
    drawSymbol("calendar", center: CGPoint(x: R.minX + R.width * 0.71, y: R.minY + R.height * 0.40), pointSize: calPt)

    // Curved one-way arrow arcing from the left calendar to the right one.
    let start = CGPoint(x: R.minX + R.width * 0.35, y: R.minY + R.height * 0.60)
    let end   = CGPoint(x: R.minX + R.width * 0.65, y: R.minY + R.height * 0.60)
    let ctrl  = CGPoint(x: R.midX,                  y: R.minY + R.height * 0.84)
    cg.setStrokeColor(NSColor.white.cgColor)
    cg.setLineWidth(R.width * 0.045)
    cg.setLineCap(.round)
    let arc = CGMutablePath(); arc.move(to: start); arc.addQuadCurve(to: end, control: ctrl)
    cg.addPath(arc); cg.strokePath()

    // Arrowhead at the end, along the curve's tangent (into the right calendar).
    let dx = end.x - ctrl.x, dy = end.y - ctrl.y
    let len = max(hypot(dx, dy), 0.0001); let ux = dx / len, uy = dy / len
    let ah = R.width * 0.095
    let tip = CGPoint(x: end.x + ux * ah * 0.2, y: end.y + uy * ah * 0.2)
    let backX = end.x - ux * ah, backY = end.y - uy * ah
    let w = ah * 0.5
    let head = CGMutablePath()
    head.move(to: tip)
    head.addLine(to: CGPoint(x: backX + -uy * w, y: backY + ux * w))
    head.addLine(to: CGPoint(x: backX - -uy * w, y: backY - ux * w))
    head.closeSubpath()
    cg.setFillColor(NSColor.white.cgColor); cg.addPath(head); cg.fillPath()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

func write(_ data: Data, _ path: String) {
    try! data.write(to: URL(fileURLWithPath: path))
    print("  wrote \(path)")
}

let fm = FileManager.default
let iconset = "\(outDir)/AppIcon.iconset"
try? fm.createDirectory(atPath: iconset, withIntermediateDirectories: true)

// Full-bleed master for iOS (system masks the corners).
write(render(1024, rounded: false), "\(outDir)/AppIcon-ios-1024.png")

// Rounded macOS iconset.
let map: [(Int, [String])] = [
    (16, ["icon_16x16"]), (32, ["icon_16x16@2x", "icon_32x32"]),
    (64, ["icon_32x32@2x"]), (128, ["icon_128x128"]),
    (256, ["icon_128x128@2x", "icon_256x256"]), (512, ["icon_256x256@2x", "icon_512x512"]),
    (1024, ["icon_512x512@2x"]),
]
for (px, names) in map {
    let data = render(px, rounded: true)
    for n in names { write(data, "\(iconset)/\(n).png") }
}
print("done.")
