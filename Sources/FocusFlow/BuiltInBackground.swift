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
    /// These ship as JPEG: as PNG the eleven of them were 15MB of the disk
    /// image, which every update had to carry. They are opaque backdrops, so
    /// there is no alpha to lose. PNG is still accepted so a project saved
    /// against an older build keeps resolving.
    var url: URL? {
        Bundle.module.url(forResource: rawValue, withExtension: "jpg", subdirectory: "Backgrounds")
            ?? Bundle.module.url(forResource: rawValue, withExtension: "png", subdirectory: "Backgrounds")
    }

    static let usablePresets: [Self] = allCases

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
        var name = String(reference.dropFirst("builtin:".count))
        for suffix in [".png", ".jpg", ".jpeg"] where name.hasSuffix(suffix) {
            name = String(name.dropLast(suffix.count))
        }
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
