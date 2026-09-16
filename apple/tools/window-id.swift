// Print the CGWindowID of the on-screen window with this owner and title.
//   swift window-id.swift <owner name> <window title>
import CoreGraphics
import Foundation

let args = CommandLine.arguments
guard args.count == 3 else { fputs("usage: window-id <owner> <title>\n", stderr); exit(2) }
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
for w in list {
    guard (w[kCGWindowOwnerName as String] as? String) == args[1],
          (w[kCGWindowName as String] as? String) == args[2],
          let id = w[kCGWindowNumber as String] as? Int else { continue }
    print(id); exit(0)
}
exit(1)
