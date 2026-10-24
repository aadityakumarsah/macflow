import Foundation
import CoreGraphics

/// Coordinates use a top-left origin throughout the UI and capture metadata.
struct ContentRegion: Codable, Equatable {
    var x: Double = 0
    var y: Double = 0
    var width: Double = 1
    var height: Double = 1
    static let full = ContentRegion()
    var bounded: ContentRegion {
        let w = min(1, max(0.05, width)), h = min(1, max(0.05, height))
        return ContentRegion(x: min(1 - w, max(0, x)), y: min(1 - h, max(0, y)), width: w, height: h)
    }
    func rect(in size: CGSize) -> CGRect {
        let r = bounded
        return CGRect(x: r.x * size.width, y: r.y * size.height, width: r.width * size.width, height: r.height * size.height)
    }
    func pixelRect(in size: CGSize) -> CGRect {
        let r = rect(in: size)
        let x = floor(r.minX / 2 + 0.000001) * 2, y = floor(r.minY / 2 + 0.000001) * 2
        return CGRect(x: x, y: y, width: max(2, min(size.width - x, floor(r.width / 2 + 0.000001) * 2)), height: max(2, min(size.height - y, floor(r.height / 2 + 0.000001) * 2)))
    }
    static func selection(from a: CGPoint, to b: CGPoint) -> ContentRegion {
        ContentRegion(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y)).bounded
    }
}

enum WindowChrome: String, Codable, CaseIterable, Identifiable {
    case none = "None", light = "macOS Light", dark = "macOS Dark"
    var id: String { rawValue }
}
struct FrameAppearance: Codable, Equatable {
    var chrome: WindowChrome = .light
    var title: String = ""
    var barHeight: Double = 52
    var trafficLights = true
    var lightSize: Double = 15
    var crop: ContentRegion = .full
}
enum MotionCurve: String, Codable, CaseIterable, Identifiable {
    case smooth = "Silky", snappy = "Snappy", linear = "Linear"
    var id: String { rawValue }
    func value(_ input: Double) -> Double {
        let t = min(1, max(0, input))
        switch self {
        case .smooth: return t * t * t * (t * (t * 6 - 15) + 10)
        case .snappy: return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
        case .linear: return t
        }
    }
}
enum EntranceStyle: String, Codable, CaseIterable, Identifiable {
    case none = "None", rise = "Slide up", slide = "Slide from left", scale = "Gentle scale"
    var id: String { rawValue }
}
struct MotionAppearance: Codable, Equatable {
    var entrance: EntranceStyle = .none
    var duration: Double = 0.8
    var fadeOut = false
}
enum PointerStyle: String, Codable, CaseIterable, Identifiable {
    case macOS = "macOS", light = "Pearl", dark = "Obsidian", accent = "Accent"
    var id: String { rawValue }
}
enum EffectAccent: String, Codable, CaseIterable, Identifiable {
    case mint = "Mint", blue = "Blue", violet = "Violet", amber = "Amber"
    var id: String { rawValue }
    var rgb: (Double, Double, Double) {
        switch self { case .mint: (0.12, 0.78, 0.52); case .blue: (0.17, 0.55, 1); case .violet: (0.59, 0.36, 1); case .amber: (1, 0.64, 0.15) }
    }
    var cgColor: CGColor { let c = rgb; return CGColor(red: c.0, green: c.1, blue: c.2, alpha: 1) }
}
enum ClickStyle: String, Codable, CaseIterable, Identifiable {
    case ripple = "Ripple", pulse = "Soft pulse", press = "Press"
    var id: String { rawValue }
}
enum PointerShape: String, Codable, CaseIterable, Identifiable {
    case automatic = "Automatic", arrow = "Arrow", text = "Text (I-beam)"
    var id: String { rawValue }
}
struct CursorAppearance: Codable, Equatable {
    var style: PointerStyle = .macOS
    var accent: EffectAccent = .blue
    var clickStyle: ClickStyle = .ripple
    var sway = false
    var shape: PointerShape? = .automatic
}

struct FrameLayout {
    let outer: CGRect
    let content: CGRect
    let header: CGRect
    static func make(canvas: CGRect, sourceSize: CGSize, padding: Double, frame: FrameAppearance) -> FrameLayout {
        let area = canvas.insetBy(dx: min(canvas.width, canvas.height) * padding / 100, dy: min(canvas.width, canvas.height) * padding / 100)
        let aspect = max(0.01, sourceSize.width / max(1, sourceSize.height))
        let headerRatio = frame.chrome == .none ? 0 : min(100, max(24, frame.barHeight)) / 1920
        let width = min(area.width, area.height / (1 / aspect + headerRatio))
        let height = width / aspect, bar = width * headerRatio
        let outer = CGRect(x: area.midX - width / 2, y: area.midY - (height + bar) / 2, width: width, height: height + bar)
        return FrameLayout(outer: outer, content: CGRect(x: outer.minX, y: outer.minY, width: width, height: height), header: CGRect(x: outer.minX, y: outer.minY + height, width: width, height: bar))
    }
}
