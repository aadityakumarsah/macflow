import AppKit
import ImageIO

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

    /// These three supplied PNGs have an all-zero alpha channel. They are
    /// kept in the bundle, but cannot be presented as usable artwork.
    var isUsable: Bool { self != .bloom && self != .bloomTwo && self != .bloomSeven }
    static let usablePresets: [Self] = [.classic, .gallery, .studio, .horizon, .flowers, .portrait, .blush, .garden]
    static let emptyFiles: [Self] = [.bloom, .bloomTwo, .bloomSeven]

    private static let thumbnailCache: NSCache<NSString, CGImageBox> = {
        let cache = NSCache<NSString, CGImageBox>()
        cache.countLimit = 8
        return cache
    }()

    /// ImageIO decodes only the small thumbnail, and only when its tile opens.
    var thumbnail: CGImage? {
        let key = rawValue as NSString
        if let cached = Self.thumbnailCache.object(forKey: key) { return cached.image }
        guard let url,
              let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 320,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }
        Self.thumbnailCache.setObject(CGImageBox(image), forKey: key)
        return image
    }

    static func asset(for reference: String) -> Self? {
        guard reference.hasPrefix("builtin:") else { return nil }
        let name = String(reference.dropFirst("builtin:".count)).replacingOccurrences(of: ".png", with: "")
        return Self(rawValue: name)
    }

    static func url(for reference: String) -> URL? {
        asset(for: reference)?.url
    }
}

private final class CGImageBox {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}
