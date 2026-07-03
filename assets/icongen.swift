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

    // White refresh glyph, centered.
    let glyphPt = rect.width * 0.5
    let conf = NSImage.SymbolConfiguration(pointSize: glyphPt, weight: .semibold)
        .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
    if let base = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: nil),
       let sym = base.withSymbolConfiguration(conf) {
        let gs = sym.size
        sym.draw(in: NSRect(x: rect.midX - gs.width/2, y: rect.midY - gs.height/2,
                            width: gs.width, height: gs.height))
    }
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
