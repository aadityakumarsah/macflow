import AppKit
import Foundation
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let destination = root.appendingPathComponent("Sources/FocusFlow/BrowserRecorder")
var metrics: [String: [String: CGFloat]] = [:]
for (name, cursor) in [("arrow", NSCursor.arrow), ("text", NSCursor.iBeam)] {
    var bounds = CGRect(origin: .zero, size: cursor.image.size)
    let image = cursor.image.cgImage(forProposedRect: &bounds, context: nil, hints: nil)!
    let bitmap = NSBitmapImageRep(cgImage: image)
    try bitmap.representation(using: .png, properties: [:])!.write(to: destination.appendingPathComponent("cursor-\(name).png"))
    metrics[name] = ["width": cursor.image.size.width, "height": cursor.image.size.height, "hotX": cursor.hotSpot.x, "hotY": cursor.hotSpot.y]
}
try JSONSerialization.data(withJSONObject: metrics, options: [.prettyPrinted, .sortedKeys]).write(to: destination.appendingPathComponent("cursor-metrics.json"))
