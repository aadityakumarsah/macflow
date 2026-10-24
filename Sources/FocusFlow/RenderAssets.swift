import AppKit
import CoreImage
import CoreText

/// Immutable bitmaps are cached; playback does not rebuild AppKit symbols every frame.
enum RenderAssets {
    private static let cache: NSCache<NSString, CIImage> = {
        let cache = NSCache<NSString, CIImage>(); cache.countLimit = 80; return cache
    }()
    private static func bitmap(key: String, width: Int, height: Int, draw: (CGContext) -> Void) -> CIImage? {
        if let image = cache.object(forKey: key as NSString) { return image }
        guard let context = CGContext(data: nil, width: max(1, width), height: max(1, height), bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        draw(context)
        guard let cgImage = context.makeImage() else { return nil }
        let image = CIImage(cgImage: cgImage); cache.setObject(image, forKey: key as NSString); return image
    }
    static func cursor(_ appearance: CursorAppearance, shape: PointerShape = .arrow) -> CIImage? {
        if appearance.style == .macOS || shape == .text {
            let key = "system-cursor-\(shape)" as NSString
            if let image = cache.object(forKey: key) { return image }
            let native = shape == .text ? NSCursor.iBeam : NSCursor.arrow
            var rect = CGRect(origin: .zero, size: native.image.size)
            guard let cgImage = native.image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
            let image = CIImage(cgImage: cgImage)
                .transformed(by: CGAffineTransform(scaleX: native.image.size.width / CGFloat(cgImage.width), y: native.image.size.height / CGFloat(cgImage.height)))
                .transformed(by: CGAffineTransform(translationX: -native.hotSpot.x, y: native.hotSpot.y - native.image.size.height))
            cache.setObject(image, forKey: key); return image
        }
        let image = bitmap(key: "cursor-\(appearance.style)-\(appearance.accent)", width: 120, height: 150) { context in
            context.translateBy(x: 12, y: 138); context.scaleBy(x: 3, y: -3)
            let path = CGMutablePath()
            path.move(to: .zero)
            path.addLine(to: CGPoint(x: 1.5, y: 31))
            path.addQuadCurve(to: CGPoint(x: 4.5, y: 32), control: CGPoint(x: 1.7, y: 34))
            path.addLine(to: CGPoint(x: 11, y: 25.3)); path.addLine(to: CGPoint(x: 17, y: 38))
            path.addQuadCurve(to: CGPoint(x: 19.5, y: 39), control: CGPoint(x: 17.8, y: 40))
            path.addLine(to: CGPoint(x: 23, y: 37.2)); path.addQuadCurve(to: CGPoint(x: 24, y: 34.8), control: CGPoint(x: 25, y: 36.5))
            path.addLine(to: CGPoint(x: 18, y: 22.3)); path.addLine(to: CGPoint(x: 27.5, y: 21.5))
            path.addQuadCurve(to: CGPoint(x: 28.5, y: 18.4), control: CGPoint(x: 31, y: 21.2))
            path.addLine(to: CGPoint(x: 2.7, y: -1)); path.addQuadCurve(to: .zero, control: CGPoint(x: 0, y: -3)); path.closeSubpath()
            let fill: CGColor = appearance.style == .light ? CGColor(gray: 0.98, alpha: 1) : appearance.style == .dark ? CGColor(gray: 0.08, alpha: 1) : appearance.accent.cgColor
            context.setFillColor(fill)
            context.setStrokeColor(CGColor(gray: appearance.style == .light ? 0.16 : 1, alpha: 0.95))
            context.setLineWidth(1.3); context.setLineJoin(.round); context.addPath(path); context.drawPath(using: .fillStroke)
        }
        // The tip is exactly (0,0), independent of the transparent antialiasing margin.
        return image?.transformed(by: CGAffineTransform(translationX: -12, y: -138))
    }
    static func click(accent: EffectAccent, style: ClickStyle) -> CIImage? {
        bitmap(key: "click-\(accent)-\(style)", width: 160, height: 160) { context in
            let rect = CGRect(x: 6, y: 6, width: 148, height: 148)
            context.setFillColor(accent.cgColor.copy(alpha: style == .pulse ? 0.2 : 0.08)!)
            context.fillEllipse(in: rect)
            if style == .ripple { context.setStrokeColor(accent.cgColor.copy(alpha: 0.9)!); context.setLineWidth(5); context.strokeEllipse(in: rect) }
        }
    }
    static func header(_ frame: FrameAppearance, rect: CGRect) -> CIImage? {
        guard rect.height > 0 else { return nil }
        let w = Int(ceil(rect.width)), h = Int(ceil(rect.height))
        return bitmap(key: "header-\(w)-\(h)-\(frame.chrome)-\(frame.title)-\(frame.trafficLights)-\(frame.lightSize)", width: w, height: h) { context in
            let dark = frame.chrome == .dark
            context.setFillColor(CGColor(gray: dark ? 0.13 : 0.965, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: w, height: h))
            context.setFillColor(CGColor(gray: dark ? 0 : 0.6, alpha: 0.25)); context.fill(CGRect(x: 0, y: 0, width: w, height: 1))
            let unit = rect.width / 1920, diameter = min(rect.height * 0.56, frame.lightSize * unit)
            let left = max(diameter, 24 * unit)
            if frame.trafficLights {
                let colors = [CGColor(red: 1, green: 0.37, blue: 0.34, alpha: 1), CGColor(red: 1, green: 0.74, blue: 0.18, alpha: 1), CGColor(red: 0.16, green: 0.79, blue: 0.25, alpha: 1)]
                for i in 0..<3 {
                    let circle = CGRect(x: left + CGFloat(i) * diameter * 1.6, y: (rect.height - diameter) / 2, width: diameter, height: diameter)
                    context.setFillColor(colors[i]); context.fillEllipse(in: circle)
                    context.setStrokeColor(CGColor(gray: 0, alpha: 0.1)); context.setLineWidth(0.6); context.strokeEllipse(in: circle)
                }
            }
            let title = String(frame.title.prefix(160))
            let font = CTFontCreateWithName(".AppleSystemUIFont" as CFString, min(rect.height * 0.4, 20 * unit), nil)
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: CGColor(gray: dark ? 0.84 : 0.36, alpha: 1)]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: title, attributes: attributes))
            let bound = CTLineGetBoundsWithOptions(line, [])
            context.saveGState(); context.clip(to: CGRect(x: rect.width * 0.22, y: 0, width: rect.width * 0.56, height: rect.height))
            context.textPosition = CGPoint(x: (rect.width - bound.width) / 2, y: (rect.height - bound.height) / 2 - bound.minY)
            CTLineDraw(line, context); context.restoreGState()
        }?.transformed(by: CGAffineTransform(translationX: rect.minX, y: rect.minY))
    }
    static func callout(text: String, unit: Double, accent: EffectAccent) -> CIImage? {
        let text = String(text.prefix(80))
        let font = CTFontCreateWithName(".AppleSystemUIFont" as CFString, 26 * unit, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: CGColor(gray: 1, alpha: 1)]))
        let bounds = CTLineGetBoundsWithOptions(line, [])
        let w = min(1000 * unit, max(100 * unit, bounds.width + 42 * unit)), h = 62 * unit
        return bitmap(key: "label-\(text)-\(unit)-\(accent)", width: Int(ceil(w)), height: Int(ceil(h))) { context in
            context.setFillColor(CGColor(gray: 0.07, alpha: 0.94))
            context.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: w, height: h), cornerWidth: 16 * unit, cornerHeight: 16 * unit, transform: nil)); context.fillPath()
            context.setFillColor(accent.cgColor); context.fill(CGRect(x: 0, y: 12 * unit, width: 4 * unit, height: h - 24 * unit))
            context.textPosition = CGPoint(x: max(16 * unit, (w - bounds.width) / 2), y: (h - bounds.height) / 2 - bounds.minY)
            CTLineDraw(line, context)
        }
    }
}
