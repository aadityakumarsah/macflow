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
    /// An animated backdrop and a progress line across the frame. Off by
    /// default: it is decoration applied to every recording, and a plain one
    /// should not arrive already dressed up.
    var ambientGraphics: Bool? = false
    var automaticMotionBlur: Bool? = true
    /// Restrained on purpose. A camera blur is drawn from the frame that is
    /// already there, so every bit of it is detail removed: at the strength
    /// this once defaulted to, a zoom across a page of text smeared the text
    /// for the length of the move, which reads as a worse recording rather
    /// than as a nicer move. It is here to take the hard edge off a moving
    /// frame, not to be seen.
    var motionBlurStrength: Double? = 0.35

    /// Blur from the content itself moving — scrolling, mostly.
    ///
    /// Separate from the blur above, which is driven by the camera moves
    /// FocusFlow applies. A scroll moves the page while the viewport stays
    /// put, so that one never sees it, and scrolling strobes instead.
    var scrollBlur: Bool? = true
    /// How much of the neighbouring frames is mixed in: a shutter angle in
    /// all but name.
    var scrollBlurStrength: Double? = 0.32
    /// Blend two neighbours rather than one. Smoother on fast scrolls, and
    /// twice the work per frame.
    var scrollBlurLong: Bool? = false
}
enum PointerStyle: String, Codable, CaseIterable, Identifiable {
    case macOS = "macOS", light = "Pearl", dark = "Obsidian", accent = "Accent"
    /// Not arrows at all: a ring around where the pointer is, and a filled
    /// dot. A recording watched at a quarter of its size loses an arrow
    /// among the pixels; a ring reads at any size, and neither of them
    /// hides the thing being pointed at.
    case ring = "Ring", dot = "Dot"
    case custom = "Your own"
    var id: String { rawValue }
    /// Drawn from the accent colour rather than from a fixed palette.
    var isMark: Bool { self == .ring || self == .dot }
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

    /// A comet of the accent colour behind a pointer that is moving, and
    /// nothing at all behind one that is still. It is the clearest way to
    /// show that the pointer crossed the screen rather than teleporting,
    /// which is what a cut-down frame rate makes a fast move look like.
    var trail: Bool? = false
    var trailLength: Double? = 0.5
    var trailOpacity: Double? = 0.3

    /// The pointer swells a little while it travels and settles when it
    /// arrives, so the eye is carried along with it.
    var swell: Bool? = false
    var swellAmount: Double? = 0.3

    /// Your own artwork, used in place of every drawn pointer. The image's
    /// top-left corner is the point it points at, which is where every
    /// cursor file puts its hotspot unless it says otherwise.
    var customImagePath: String?

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

/// Following the caret while someone types.
struct TypingFollowSettings: Codable, Equatable {
    var enabled: Bool = true
    /// How close the frame gets to the line being written. Closer magnifies
    /// the travel as well as the text, so this is also how fast the follow
    /// appears to move.
    var zoom: Double = 1.75
    /// How far the frame travels per keypress, as a fraction of the width.
    /// A caret advances by roughly one character, and this is the stand-in
    /// for a character width — the recording does not report one.
    var advancePerKey: Double = 0.011
    /// The furthest it will travel from where typing began.
    var maxTravel: Double = 0.42
    /// How far the caret may wander before the frame moves at all, as a share
    /// of what is on screen. Holding still and then catching up is how a
    /// camera follows anything — Apple's own Zoom moves the screen image only
    /// once the focus item is near an edge, and every follow camera worth the
    /// name has a dead zone. A frame that creeps along with every keystroke
    /// reads as drift, and it makes an estimated caret position look wrong in
    /// a way a still frame does not. Zero follows continuously.
    var deadZone: Double = 0.26
    /// How long the frame takes to catch up once the caret has left the zone.
    ///
    /// A smaller band crossed more slowly: a wide band caught up in half a
    /// second is a whip across most of what is on screen, and the words
    /// being written arrive after it rather than travelling with it. Past
    /// the time the caret itself takes to cross a band this stops being a
    /// catch-up at all and becomes a glide that never quite finishes,
    /// which is the gentlest the follow can be.
    var catchUp: Double = 1.2
    /// Seconds of stillness that ends a run of typing.
    var gap: Double = 1.1
    /// How long the frame holds after the last keypress before releasing.
    var hold: Double = 0.7
    var curve: MotionCurve = .smooth
}

/// Focusing on text as it is selected.
///
/// A drag across text with the I-beam is the clearest statement of intent
/// a recording contains: this, here, is what I am talking about. The camera
/// follows the selection as it grows rather than jumping to where it ended
/// up, and the range itself is washed in the accent colour so it is legible
/// even where the application's own selection colour is faint.
struct SelectionFocusSettings: Codable, Equatable {
    var enabled: Bool = true
    /// How close the frame gets. Capped by the size of the selection, so a
    /// long drag across a paragraph pulls back rather than cropping it.
    var zoom: Double = 1.8
    /// Keeps following the range as it grows, rather than settling on the
    /// middle of where it finished.
    var tracks: Bool = true
    var highlight: Bool = true
    var highlightOpacity: Double = 0.22
    /// How long the frame stays after the drag ends.
    var hold: Double = 0.9
}

/// A move of the frame itself through space, rather than of the camera within
/// the recording.
enum CameraMove: String, Codable, CaseIterable, Identifiable {
    case none = "None"
    case glide = "Glide across"
    case unfold = "Unfold"
    case pullBack = "Pull back"

    var id: String { rawValue }

    var detail: String {
        switch self {
        case .none: "The frame sits square to the viewer."
        case .glide: "Tilts into perspective and travels across the detail."
        case .unfold: "Opens out of a tilt until it is square to you."
        case .pullBack: "Starts close and withdraws to show the whole picture."
        }
    }
}

/// How the frame is softened once it is standing in space.
enum FrameBlur: String, Codable, CaseIterable, Identifiable {
    case none = "None"
    case depth = "Depth of field"
    case radial = "Radial"
    case directional = "Directional"
    case tiltShift = "Tilt shift"
    var id: String { rawValue }
    var detail: String {
        switch self {
        case .none: "No softening."
        case .depth: "Sharp where the frame is nearest, soft where it recedes."
        case .radial: "Softens outwards from the middle, as though rushing forward."
        case .directional: "Smears along one angle, like a camera whipping past."
        case .tiltShift: "A sharp band across the frame, soft above and below."
        }
    }
}

/// Where the frame stands in space: one thing, so it can be animated from
/// one to another rather than being six sliders that each go their own way.
struct FramePose: Codable, Equatable {
    var pitch: Double = 0
    var yaw: Double = 0
    var roll: Double = 0
    var panX: Double = 0
    var panY: Double = 0
    var zoom: Double = 1

    static let neutral = FramePose()
    /// Extra motion inside the moving window, kept small so the content and
    /// its surrounding frame read as one object with a little depth.
    static let contentParallax = 0.28
    var isNeutral: Bool { self == .neutral }

    /// The same pose seen from the other side. A move that travels sweeps
    /// from here to the pose itself, so one set of sliders describes a
    /// journey rather than a place.
    var mirrored: FramePose {
        FramePose(pitch: -pitch, yaw: -yaw, roll: -roll, panX: -panX, panY: -panY, zoom: 2 - zoom)
    }

    func blended(to other: FramePose, _ amount: Double) -> FramePose {
        let t = max(0, min(1, amount))
        func mix(_ a: Double, _ b: Double) -> Double { a + (b - a) * t }
        return FramePose(pitch: mix(pitch, other.pitch), yaw: mix(yaw, other.yaw), roll: mix(roll, other.roll),
                         panX: mix(panX, other.panX), panY: mix(panY, other.panY), zoom: mix(zoom, other.zoom))
    }
    /// Inside what the renderer and the sliders will accept.
    var clamped: FramePose {
        FramePose(pitch: max(-1, min(1, pitch)), yaw: max(-1, min(1, yaw)), roll: max(-1, min(1, roll)),
                  panX: max(-1, min(1, panX)), panY: max(-1, min(1, panY)), zoom: max(0.6, min(1.8, zoom)))
    }

    /// Rounded to a step, which is what holding Shift while dragging does:
    /// a lean that is exactly a quarter turn rather than nearly one.
    func snapped(to step: Double = 0.05) -> FramePose {
        guard step > 0.0001 else { return self }
        func snap(_ value: Double) -> Double { (value / step).rounded() * step }
        return FramePose(pitch: snap(pitch), yaw: snap(yaw), roll: snap(roll),
                         panX: snap(panX), panY: snap(panY), zoom: snap(zoom))
    }

    /// Towards neutral, which is how a pose fades in and out.
    func weighted(_ amount: Double) -> FramePose { FramePose.neutral.blended(to: self, amount) }
    func setting(_ change: (inout FramePose) -> Void) -> FramePose {
        var copy = self; change(&copy); return copy
    }
    /// Two poses at once are both departures from square, so they add.
    func added(_ other: FramePose) -> FramePose {
        FramePose(pitch: pitch + other.pitch, yaw: yaw + other.yaw, roll: roll + other.roll,
                  panX: panX + other.panX, panY: panY + other.panY, zoom: zoom * other.zoom)
    }
}

/// How far each edge of the frame is pulled in because it is leaning away
/// from the viewer, as a fraction of the frame.
///
/// A playing move and the pose the frame is placed in both lean the same
/// corners, so they are added together before anything is drawn.
struct FrameLean: Equatable {
    var left: Double = 0
    var right: Double = 0
    var top: Double = 0
    var bottom: Double = 0
    static let none = FrameLean()
    /// The deepest lean of any edge, which is what decides whether there is
    /// enough depth to be worth softening along.
    var depth: Double { max(max(left, right), max(top, bottom)) }
}

/// The four corners a frame's rectangle lands on once it is standing in
/// space, running bottom-left, bottom-right, top-right, top-left — the
/// order `CIPerspectiveTransform` takes them in.
struct FrameQuad: Equatable {
    var bottomLeft: CGPoint
    var bottomRight: CGPoint
    var topRight: CGPoint
    var topLeft: CGPoint

    var corners: [CGPoint] { [bottomLeft, bottomRight, topRight, topLeft] }

    static func rect(_ rect: CGRect) -> FrameQuad {
        FrameQuad(bottomLeft: CGPoint(x: rect.minX, y: rect.minY),
                  bottomRight: CGPoint(x: rect.maxX, y: rect.minY),
                  topRight: CGPoint(x: rect.maxX, y: rect.maxY),
                  topLeft: CGPoint(x: rect.minX, y: rect.maxY))
    }

    func applying(_ transform: CGAffineTransform) -> FrameQuad {
        FrameQuad(bottomLeft: bottomLeft.applying(transform),
                  bottomRight: bottomRight.applying(transform),
                  topRight: topRight.applying(transform),
                  topLeft: topLeft.applying(transform))
    }

    /// The same quad with y measured downwards from the top, which is what
    /// a view draws in and an image does not.
    func flipped(in height: CGFloat) -> FrameQuad {
        func flip(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x, y: height - point.y) }
        return FrameQuad(bottomLeft: flip(bottomLeft), bottomRight: flip(bottomRight),
                         topRight: flip(topRight), topLeft: flip(topLeft))
    }
}

/// The projective map that carries a rectangle onto a quad.
///
/// This is the map `CIPerspectiveTransform` applies, written out so that
/// anything drawn over the preview — the 3D handles, most of all — can put
/// a point exactly where the render will put it, rather than somewhere
/// close that drifts as the frame leans further.
struct ProjectiveMap {
    private let a, b, c, d, e, f, g, h: Double
    /// The rectangle the map reads its coordinates in.
    private let source: CGRect

    /// Maps the unit square, (0,0) at the bottom left, onto `quad`.
    init(unitSquareTo quad: FrameQuad) {
        self.init(CGRect(x: 0, y: 0, width: 1, height: 1), to: quad)
    }

    /// Maps `rect` onto `quad`, which is how the renderer uses it: the whole
    /// canvas is warped, and a point inside it travels with the warp.
    init(_ rect: CGRect, to quad: FrameQuad) {
        source = rect
        let (x0, y0) = (Double(quad.bottomLeft.x), Double(quad.bottomLeft.y))
        let (x1, y1) = (Double(quad.bottomRight.x), Double(quad.bottomRight.y))
        let (x2, y2) = (Double(quad.topRight.x), Double(quad.topRight.y))
        let (x3, y3) = (Double(quad.topLeft.x), Double(quad.topLeft.y))
        let sx = x0 - x1 + x2 - x3, sy = y0 - y1 + y2 - y3
        let dx1 = x1 - x2, dx2 = x3 - x2, dy1 = y1 - y2, dy2 = y3 - y2
        let denominator = dx1 * dy2 - dx2 * dy1
        // A parallelogram has no vanishing point, so the map is affine.
        if abs(sx) < 1e-9 && abs(sy) < 1e-9 || abs(denominator) < 1e-9 {
            g = 0; h = 0
        } else {
            g = (sx * dy2 - dx2 * sy) / denominator
            h = (dx1 * sy - sx * dy1) / denominator
        }
        a = x1 - x0 + g * x1; b = x3 - x0 + h * x3; c = x0
        d = y1 - y0 + g * y1; e = y3 - y0 + h * y3; f = y0
    }

    func callAsFunction(_ point: CGPoint) -> CGPoint {
        let u = source.width > 0 ? Double((point.x - source.minX) / source.width) : 0
        let v = source.height > 0 ? Double((point.y - source.minY) / source.height) : 0
        let w = g * u + h * v + 1
        guard abs(w) > 1e-9 else { return point }
        return CGPoint(x: (a * u + b * v + c) / w, y: (d * u + e * v + f) / w)
    }

    func quad(of rect: CGRect) -> FrameQuad {
        FrameQuad(bottomLeft: self(CGPoint(x: rect.minX, y: rect.minY)),
                  bottomRight: self(CGPoint(x: rect.maxX, y: rect.minY)),
                  topRight: self(CGPoint(x: rect.maxX, y: rect.maxY)),
                  topLeft: self(CGPoint(x: rect.minX, y: rect.maxY)))
    }
}

extension FramePose {
    /// How far each edge is pulled in by this pose, plus whatever a playing
    /// move is already asking for.
    func lean(adding move: FrameLean = .none) -> FrameLean {
        let yaw = max(-1, min(1, self.yaw)), pitch = max(-1, min(1, self.pitch))
        return FrameLean(left: move.left + max(0, -yaw) * 0.26,
                         right: move.right + max(0, yaw) * 0.26,
                         top: move.top + max(0, pitch) * 0.2,
                         bottom: move.bottom + max(0, -pitch) * 0.2)
    }

    /// Where the corners of `frame` go once it is leaning. An edge that
    /// recedes is pulled in and, being further away, is also shorter than
    /// the edge facing the viewer.
    func quad(in frame: CGRect, lean: FrameLean) -> FrameQuad {
        let yaw = max(-1, min(1, self.yaw)), pitch = max(-1, min(1, self.pitch))
        let dxRight = frame.width * lean.right
        let dxLeft = frame.width * lean.left
        let dyTop = frame.height * lean.top
        let dyBottom = frame.height * lean.bottom
        let squashRight = frame.height * max(0, yaw) * 0.12
        let squashLeft = frame.height * max(0, -yaw) * 0.12
        let squashTop = frame.width * max(0, pitch) * 0.12
        let squashBottom = frame.width * max(0, -pitch) * 0.12
        return FrameQuad(
            bottomLeft: CGPoint(x: frame.minX + dxLeft + squashBottom, y: frame.minY + dyBottom + squashLeft),
            bottomRight: CGPoint(x: frame.maxX - dxRight - squashBottom, y: frame.minY + dyBottom + squashRight),
            topRight: CGPoint(x: frame.maxX - dxRight * 0.35 - squashTop, y: frame.maxY - dyTop - squashRight),
            topLeft: CGPoint(x: frame.minX + dxLeft * 0.35 + squashTop, y: frame.maxY - dyTop - squashLeft))
    }

    /// Roll, slide and push in — the rest of standing the frame somewhere.
    /// `scale` and `shiftX` are whatever a playing move contributes.
    func transform(about centre: CGPoint, frame: CGRect, scale: Double = 1, shiftX: Double = 0) -> CGAffineTransform {
        let zoom = max(0.2, min(3, self.zoom))
        let roll = max(-1, min(1, self.roll)) * .pi / 5
        let dx = shiftX + panX * Double(frame.width) * 0.5
        let dy = panY * Double(frame.height) * 0.5
        guard scale * zoom != 1 || dx != 0 || dy != 0 || roll != 0 else { return .identity }
        return CGAffineTransform(translationX: centre.x + dx, y: centre.y + dy)
            .rotated(by: roll)
            .scaledBy(x: scale * zoom, y: scale * zoom)
            .translatedBy(x: -centre.x, y: -centre.y)
    }

    /// The whole of standing in space, in one map: lean, roll, slide, push.
    func projection(of frame: CGRect, canvas: CGRect, lean: FrameLean,
                    scale: Double = 1, shiftX: Double = 0) -> FrameQuad {
        let leaned = quad(in: frame, lean: lean)
        let transform = self.transform(about: CGPoint(x: canvas.midX, y: canvas.midY),
                                       frame: frame, scale: scale, shiftX: shiftX)
        return transform.isIdentity ? leaned : leaned.applying(transform)
    }
}

struct CameraMoveSettings: Codable, Equatable {
    var move: CameraMove = .none

    // Where the frame stands, whether or not a move is playing. These are the
    // frame in three dimensions: lean it back, turn it, roll it, slide it,
    // push in. All zero, and the frame is square to the viewer as before.
    /// Leans the top away (positive) or the bottom (negative).
    var pitch: Double = 0
    /// Turns the right edge away (positive) or the left (negative).
    var yaw: Double = 0
    /// Rolls the frame, a fifth of a turn either way at the extremes.
    var roll: Double = 0
    var panX: Double = 0
    var panY: Double = 0
    /// Pushes in or pulls back, 1 being where the frame sits by itself.
    var zoom: Double = 1

    /// None, unless it is asked for. Depth of field used to be the
    /// default, so the first lean anyone tried softened the whole picture
    /// — the thing they had just leaned in order to see better.
    var blur: FrameBlur = .none
    /// Directional blur only: the angle it smears along, in degrees.
    var blurAngle: Double = 0
    /// Tilt shift only: where the sharp band sits, and how wide it is.
    var blurFocus: Double = 0.5
    var blurBand: Double = 0.3
    /// How far the frame leans, 0 flat and 1 steep.
    var tilt: Double = 0.55
    /// How far it travels or withdraws.
    var amount: Double = 0.5
    /// Depth of field: the receding edge softens by this much.
    var focusBlur: Double = 0
    /// Seconds the move takes when it plays once.
    var duration: Double = 2.6
    var curve: MotionCurve = .smooth
    /// Spreads the move across the whole clip rather than playing once.
    ///
    /// On by default. Playing once from the start of the trim meant that
    /// anywhere past `duration` the frame was untouched, so choosing a move
    /// and looking at the middle of a recording showed nothing at all.
    var holds: Bool = true

    /// Takes the softness of the warp back out of the picture.
    ///
    /// Standing the frame in space resamples every pixel of it, and a
    /// resample is a small low-pass filter: text that was sharp comes out
    /// of a lean very slightly woolly even with every blur switched off.
    /// A touch of luminance sharpening, scaled by how far the frame is
    /// actually leaning, puts the edges back. Optional, because it is
    /// still a filter and someone may want the frame exactly as warped.
    var crisp: Bool? = true

    var isPlaced: Bool {
        pitch != 0 || yaw != 0 || roll != 0 || panX != 0 || panY != 0 || zoom != 1
    }
    /// Blur that does not need a lean to justify it, unlike depth of field.
    var hasStandaloneBlur: Bool {
        focusBlur > 0.01 && (blur == .radial || blur == .directional || blur == .tiltShift)
    }
    var isActive: Bool { move != .none || isPlaced || hasStandaloneBlur }

    /// Written out by hand so that a field added later does not stop a
    /// project saved before it from opening. A missing key is the default,
    /// not a failure.
    /// The move's own settings, since writing an initialiser of any kind
    /// takes the one Swift would have written away. Where the frame stands
    /// and how it is blurred are set afterwards, as the inspector does.
    init(move: CameraMove = .none, tilt: Double = 0.55, amount: Double = 0.5,
         focusBlur: Double = 0, duration: Double = 2.6,
         curve: MotionCurve = .smooth, holds: Bool = true, blur: FrameBlur = .none) {
        self.move = move
        self.tilt = tilt
        self.amount = amount
        self.focusBlur = focusBlur
        self.duration = duration
        self.curve = curve
        self.holds = holds
        self.blur = blur
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        move = try values.decodeIfPresent(CameraMove.self, forKey: .move) ?? .none
        pitch = try values.decodeIfPresent(Double.self, forKey: .pitch) ?? 0
        yaw = try values.decodeIfPresent(Double.self, forKey: .yaw) ?? 0
        roll = try values.decodeIfPresent(Double.self, forKey: .roll) ?? 0
        panX = try values.decodeIfPresent(Double.self, forKey: .panX) ?? 0
        panY = try values.decodeIfPresent(Double.self, forKey: .panY) ?? 0
        zoom = try values.decodeIfPresent(Double.self, forKey: .zoom) ?? 1
        blurAngle = try values.decodeIfPresent(Double.self, forKey: .blurAngle) ?? 0
        blurFocus = try values.decodeIfPresent(Double.self, forKey: .blurFocus) ?? 0.5
        blurBand = try values.decodeIfPresent(Double.self, forKey: .blurBand) ?? 0.3
        tilt = try values.decodeIfPresent(Double.self, forKey: .tilt) ?? 0.55
        amount = try values.decodeIfPresent(Double.self, forKey: .amount) ?? 0.5
        focusBlur = try values.decodeIfPresent(Double.self, forKey: .focusBlur) ?? 0
        // Before there was a choice of blur there was only depth of field,
        // and `focusBlur` was how much of it. A project from then carries
        // no `blur` key at all, so the only way to keep the look it was
        // saved with is to read one back in for it.
        blur = try values.decodeIfPresent(FrameBlur.self, forKey: .blur) ?? (focusBlur > 0.01 ? .depth : .none)
        duration = try values.decodeIfPresent(Double.self, forKey: .duration) ?? 2.6
        curve = try values.decodeIfPresent(MotionCurve.self, forKey: .curve) ?? .smooth
        holds = try values.decodeIfPresent(Bool.self, forKey: .holds) ?? true
        crisp = try values.decodeIfPresent(Bool.self, forKey: .crisp)
    }

    /// Poses worth having one key away: square, turned either way, leaning
    /// back, and a three-quarter hero angle.
    static let quickPoses: [(name: String, key: String, pose: FramePose)] = [
        ("Square", "0", .neutral),
        ("Left", "1", FramePose(yaw: -0.45, zoom: 0.97)),
        ("Right", "2", FramePose(yaw: 0.45, zoom: 0.97)),
        ("Lean back", "3", FramePose(pitch: 0.38, zoom: 0.97)),
        ("Hero", "4", FramePose(pitch: 0.22, yaw: 0.34, roll: -0.05, zoom: 1.02)),
    ]
}

extension CameraMoveSettings {
    /// Where the frame stands, as one pose. The six sliders are a pose
    /// written out flat, because they were here before poses were.
    var pose: FramePose {
        get { FramePose(pitch: pitch, yaw: yaw, roll: roll, panX: panX, panY: panY, zoom: zoom) }
        set {
            pitch = newValue.pitch; yaw = newValue.yaw; roll = newValue.roll
            panX = newValue.panX; panY = newValue.panY; zoom = newValue.zoom
        }
    }

    /// What a playing move is doing to the frame at this moment, on top of
    /// the pose. Shared by the renderer and the on-canvas handles so that
    /// the outline drawn over the preview is the frame in the preview.
    struct Performance: Equatable {
        var lean = FrameLean.none
        var shiftX: Double = 0
        var scale: Double = 1
        /// The move has played out, and is not holding: nothing of it is
        /// left. Where the frame has been placed by hand still stands —
        /// that is not a move, it is where the camera is.
        var settled = false
    }

    /// `elapsed` is seconds since the trim began, `clip` how long the whole
    /// trimmed clip is, and `width` the width of the frame being moved.
    func performance(at elapsed: Double, clip: Double, width: Double) -> Performance {
        let span = max(0.2, duration)
        let raw = holds ? min(1, elapsed / max(0.2, clip)) : min(1, elapsed / span)
        let progress = curve.value(raw)
        var result = Performance(settled: !holds && raw >= 1)
        let tilt = max(0, min(1, self.tilt)), amount = max(0, min(1, self.amount))
        switch result.settled ? .none : move {
        case .none:
            break
        case .glide:
            // Holds its lean and travels across.
            result.lean.right = tilt * 0.2
            result.shiftX = (progress - 0.5) * amount * width * 0.22
            result.scale = 1 + tilt * 0.06
        case .unfold:
            // Opens out of the lean as it plays.
            let remaining = 1 - progress
            result.lean.left = tilt * 0.26 * remaining
            result.lean.top = tilt * 0.12 * remaining
            result.scale = 1 - 0.06 * remaining
        case .pullBack:
            // Starts close, withdraws, keeping a slight lean.
            result.lean.top = tilt * 0.09
            result.scale = (1 + amount * 0.3) - amount * 0.3 * progress
        }
        return result
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
