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
    var ambientGraphics: Bool? = true
    var automaticMotionBlur: Bool? = true
    var motionBlurStrength: Double? = 0.55
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
    /// Extra scale for the I-beam only. It is a thin glyph and reads far
    /// smaller than the arrow at the same size, so it gets its own control.
    var textScale: Double = 1.5
    var style: PointerStyle = .light
    var accent: EffectAccent = .blue
    var clickStyle: ClickStyle = .ripple
    var sway = false
    var shape: PointerShape? = .automatic

    /// Any colour, rather than the four presets. Optional so projects written
    /// before it keep decoding and keep their preset.
    var customAccent: RGBColor?

    /// A soft disc that travels with the pointer. The cursor is a few dozen
    /// pixels in a frame that may be watched at a fraction of its size, and a
    /// highlight reads when the arrow alone does not.
    var highlight: Bool? = false
    var highlightSize: Double? = 3.4
    var highlightOpacity: Double? = 0.22

    /// Scales the click effect independently of the pointer.
    var clickScale: Double? = 1.4
    /// Fades the pointer itself without touching its effects.
    var opacity: Double? = 1

    /// The colour every cursor effect draws with.
    var accentRGB: (Double, Double, Double) {
        if let custom = customAccent { return (custom.r, custom.g, custom.b) }
        return accent.rgb
    }

    var accentColor: CGColor {
        let c = accentRGB
        return CGColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
    }

    /// Distinguishes cached artwork drawn with a custom colour from the preset.
    var accentKey: String {
        if let custom = customAccent {
            return String(format: "c%.3f-%.3f-%.3f", custom.r, custom.g, custom.b)
        }
        return accent.rawValue
    }
}

/// A look applied to the whole frame, before the background shows through.
enum ColorGrade: String, Codable, CaseIterable, Identifiable {
    case none = "None"
    case cinematic = "Cinematic"
    case noir = "Noir"
    case vintage = "Vintage"
    case frost = "Frost"
    case golden = "Golden"
    case midnight = "Midnight"
    case vivid = "Vivid"
    case dreamy = "Dreamy"

    var id: String { rawValue }

    /// Saturation, contrast and brightness handed to CIColorControls.
    var controls: (saturation: Double, contrast: Double, brightness: Double) {
        switch self {
        case .none: (1, 1, 0)
        case .cinematic: (0.88, 1.12, -0.02)
        case .noir: (0, 1.22, -0.01)
        case .vintage: (0.72, 0.94, 0.04)
        case .frost: (0.82, 1.06, 0.03)
        case .golden: (1.08, 1.04, 0.02)
        case .midnight: (0.78, 1.16, -0.06)
        case .vivid: (1.35, 1.08, 0)
        case .dreamy: (1.1, 0.9, 0.05)
        }
    }

    /// A wash laid over the frame, as red/green/blue plus its strength.
    var tint: (r: Double, g: Double, b: Double, amount: Double)? {
        switch self {
        case .none, .vivid: nil
        case .cinematic: (0.05, 0.12, 0.28, 0.1)
        case .noir: (0.02, 0.02, 0.04, 0.05)
        case .vintage: (0.46, 0.32, 0.12, 0.12)
        case .frost: (0.42, 0.68, 0.92, 0.11)
        case .golden: (0.95, 0.65, 0.18, 0.1)
        case .midnight: (0.06, 0.10, 0.34, 0.16)
        case .dreamy: (0.85, 0.62, 0.85, 0.09)
        }
    }

    /// A soft bloom suits a dreamy look and nothing else here.
    var bloom: Double { self == .dreamy ? 0.6 : 0 }
}

struct GradeSettings: Codable, Equatable {
    var grade: ColorGrade = .none
    /// Stops of exposure, the way a camera would express it.
    var exposure: Double = 0
    /// A multiplier on the grade's own contrast.
    var contrast: Double = 1
    /// Darkening at the edges, 0 for none.
    var vignette: Double = 0

    var isIdentity: Bool {
        grade == .none && exposure == 0 && contrast == 1 && vignette == 0
    }
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
