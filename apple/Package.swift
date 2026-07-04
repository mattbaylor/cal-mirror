// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CalMirrorKit",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "CalMirrorKit", targets: ["CalMirrorKit"]),
    ],
    targets: [
        .target(name: "CalMirrorKit"),
        // Runnable self-check of the pure logic (markers, config codable).
        // `swift run cmk-check` — works with Command Line Tools, no Xcode/XCTest.
        .executableTarget(name: "cmk-check", dependencies: ["CalMirrorKit"]),
    ]
)
