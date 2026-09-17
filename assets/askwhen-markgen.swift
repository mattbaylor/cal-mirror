// Rasterises the AskWhen.me mark from its master, assets/askwhen-mark.svg.
//
// The mark is Matt's (decisions.md, 17 Sept 2026): the Calendar Mirror face
// with a "?" grid on the left calendar and a check knocked out of the smile's
// end, on the warm gradient. This file never redraws it — AppKit renders the
// SVG as-is — it only produces the sizes each surface consumes, the way
// icongen.swift does for the app icon: a full-bleed square, and a rounded
// variant at the 0.2237 corner ratio where the mark sits on a surface as a
// tile. At 32px and below the check knockout disappears; that is accepted.
//
//   swiftc assets/askwhen-markgen.swift -o /tmp/markgen && /tmp/markgen
//
// Writes:
//   askwhen/web/static/favicon-16.png, favicon-32.png    square
//   askwhen/web/static/apple-touch-icon.png (180)        square; iOS rounds it
//   askwhen/web/static/og.png (1024)                     square
//   docs/img/askwhen-mark.png (256)                      rounded, for the site
//   apple/Shared/AskWhen.xcassets/AskWhenMark.imageset/   56 @1x/@2x/@3x, rounded
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let master = NSImage(contentsOf: root.appendingPathComponent("assets/askwhen-mark.svg"))!

func render(_ px: Int, rounded: Bool) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: px, height: px)
    NSGraphicsContext.saveGraphicsState()
    let gctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = gctx
    gctx.imageInterpolation = .high
    let S = CGFloat(px)
    let rect = CGRect(x: 0, y: 0, width: S, height: S)
    if rounded {
        let radius = S * 0.2237
        gctx.cgContext.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        gctx.cgContext.clip()
    }
    master.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

func write(_ data: Data, _ rel: String) {
    let url = root.appendingPathComponent(rel)
    try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! data.write(to: url)
    print("wrote \(rel)")
}

write(render(16, rounded: false), "askwhen/web/static/favicon-16.png")
write(render(32, rounded: false), "askwhen/web/static/favicon-32.png")
write(render(180, rounded: false), "askwhen/web/static/apple-touch-icon.png")
write(render(1024, rounded: false), "askwhen/web/static/og.png")
write(render(256, rounded: true), "docs/img/askwhen-mark.png")
for (scale, px) in [(1, 56), (2, 112), (3, 168)] {
    write(render(px, rounded: true), "apple/Shared/AskWhen.xcassets/AskWhenMark.imageset/mark@\(scale)x.png")
}
