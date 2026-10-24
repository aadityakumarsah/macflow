import Foundation

enum BuiltInBackground: String, CaseIterable, Identifiable {
    case bloom = "bg"
    case bloomTwo = "bg2"
    case classic = "bg3"
    case gallery = "bg4"
    case studio = "bg5"
    case horizon = "bg6"
    case bloomSeven = "bg7"
    case flowers = "bg8"
    case portrait = "bg9"
    case blush = "bg10"
    case garden = "bg11"

    var id: String { rawValue }
    var title: String { "\(rawValue).png" }
    var reference: String { "builtin:\(rawValue).png" }
    var url: URL? { Bundle.module.url(forResource: rawValue, withExtension: "png", subdirectory: "Backgrounds") }

    static func url(for reference: String) -> URL? {
        guard reference.hasPrefix("builtin:") else { return nil }
        let name = String(reference.dropFirst("builtin:".count)).replacingOccurrences(of: ".png", with: "")
        return Self(rawValue: name)?.url
    }
}
