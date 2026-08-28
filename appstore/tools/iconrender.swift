import AppKit
// Render each menu-bar state to a PNG using the shipping renderer, so the
// output cannot drift from what the app actually draws. menuBarImage() is
// backed by a draw handler, so it re-renders at whatever size we ask for.
let states: [(String, MenuBarState)] = [
    ("ok", .ok), ("degraded", .degraded), ("failing", .failing),
    ("paused", .paused), ("unconfigured", .unconfigured)
]
let outDir = CommandLine.arguments[1]
let S = 256
for (name, st) in states {
    let src = menuBarImage(st)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: S, pixelsHigh: S,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor.black.setFill(); NSColor.black.setStroke()
    src.draw(in: NSRect(x: 0, y: 0, width: S, height: S),
             from: .zero, operation: .sourceOver, fraction: 1.0)
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!
        .write(to: URL(fileURLWithPath: "\(outDir)/menubar-\(name).png"))
    print("wrote menubar-\(name).png")
}
