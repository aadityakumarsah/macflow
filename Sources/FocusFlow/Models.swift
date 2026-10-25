import Foundation
import CoreGraphics

enum SegmentKind: String, Codable, CaseIterable, Identifiable {
    case zoom, speed, blur, camera, pan, spotlight, callout, pixelate, outline, typing
    var id: String { rawValue }
    /// `.spotlight` is deliberately absent: dimming everything but a patch
    /// looked worse than it helped. Existing projects still decode and render
    /// theirs; it simply cannot be added any more.
    static let availableCases: [SegmentKind] = [.zoom, .typing, .outline, .callout, .blur, .pixelate]
    var title: String { rawValue.capitalized }
    var symbol: String {
        switch self { case .zoom: "plus.magnifyingglass"; case .speed: "bolt.fill"; case .blur: "drop.fill"; case .camera: "video.fill"; case .pan: "arrow.left.and.right"; case .spotlight: "flashlight.on.fill"; case .callout: "text.bubble"; case .pixelate: "square.grid.3x3.fill"; case .outline: "square.dashed.inset.filled"; case .typing: "text.cursor" }
    }
    var detail: String {
        switch self {
        case .zoom: "Move closer to a detail"
        case .pan: "Glide across the frame"
        case .typing: "Follow the typing"
        case .spotlight: "Dim everything around a detail"
        case .outline: "Draw an accent frame"
        case .callout: "Add a short text label"
        case .blur: "Soften private information"
        case .pixelate: "Hide details in crisp blocks"
        case .speed: "Change playback pace"
        case .camera: "Show the camera track"
        }
    }
}

struct EditSegment: Identifiable, Codable, Equatable {
    var id = UUID()
    var kind: SegmentKind
    var start: Double
    var duration: Double
    var intensity: Double
    var x: Double
    var y: Double

    var width: Double? = nil
    var height: Double? = nil
    var followsCursor: Bool? = nil
    var transition: Double? = nil
    var curve: MotionCurve? = nil
    var endX: Double? = nil
    var endY: Double? = nil
    /// For `.typing`: the share of the segment the slide takes. A run of
    /// typing is followed by a hold, and the caret stops advancing with the
    /// last keypress, so the travel finishes here and the frame is still for
    /// the remainder. Nil travels across the whole segment.
    var travelFraction: Double? = nil
    /// For `.typing`: how far the caret travels before the frame moves, in
    /// frame widths, and how long the frame then takes to catch up. Nil, or
    /// zero, slides continuously with the caret.
    var followBand: Double? = nil
    var followSettle: Double? = nil
    var text: String? = nil
    /// Selection edits anchor the camera at the drag start and follow the
    /// growing selected range using the separately recorded pointer samples.
    var tracksSelection: Bool? = nil
    var selectionStartTime: Double? = nil
    var selectionEndTime: Double? = nil
    var spotlightOpacity: Double? = nil
    var spotlightFeather: Double? = nil
    var end: Double { start + duration }
    var regionWidth: Double { width ?? 0.3 }
    var regionHeight: Double { height ?? 0.2 }
}

enum CanvasRatio: String, CaseIterable, Identifiable, Codable {
    case source = "Source", landscape = "16:9", portrait = "9:16", square = "1:1", classic = "4:3"
    case custom = "Custom"
    var id: String { rawValue }

    /// The ratio's own proportions. `.custom` has none of its own — it reads
    /// them from the project — so it falls back to the source shape here.
    var size: CGSize {
        switch self {
        case .source, .landscape, .custom: CGSize(width: 1920, height: 1080)
        case .portrait: CGSize(width: 1080, height: 1920)
        case .square: CGSize(width: 1080, height: 1080)
        case .classic: CGSize(width: 1440, height: 1080)
        }
    }

    func size(for sourceSize: CGSize) -> CGSize {
        size(for: sourceSize, custom: nil)
    }

    /// `custom` is the chosen width:height, used only by the custom case.
    func size(for sourceSize: CGSize, custom: CGSize?) -> CGSize {
        let limit: CGFloat = 1920

        if self == .custom {
            guard let custom, custom.width > 0, custom.height > 0 else { return size }
            // Fit the ratio inside the limit on its longer side, so a very
            // wide or very tall choice stays a sane number of pixels.
            let aspect = custom.width / custom.height
            let width = aspect >= 1 ? limit : limit * aspect
            let height = aspect >= 1 ? limit / aspect : limit
            return CanvasRatio.even(CGSize(width: width, height: height))
        }

        guard self == .source, sourceSize.width > 0, sourceSize.height > 0 else { return size }
        let scale = min(1, limit / max(sourceSize.width, sourceSize.height))
        return CanvasRatio.even(CGSize(width: sourceSize.width * scale, height: sourceSize.height * scale))
    }

    /// H.264 rejects odd dimensions.
    static func even(_ size: CGSize) -> CGSize {
        CGSize(width: max(2, (size.width / 2).rounded() * 2),
               height: max(2, (size.height / 2).rounded() * 2))
    }
}

enum BackgroundStyle: String, CaseIterable, Identifiable, Codable {
    case aurora, sunset, ocean, graphite, cream, none
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

/// A plain sRGB triple so custom colours survive a project round trip without
/// depending on AppKit or SwiftUI types in the document format.
struct RGBColor: Codable, Equatable, Hashable {
    var r: Double, g: Double, b: Double

    static let forest = RGBColor(r: 0.10, g: 0.47, b: 0.31)
    static let ink = RGBColor(r: 0.04, g: 0.16, b: 0.20)
}

enum BackgroundKind: String, CaseIterable, Identifiable, Codable {
    case preset, solid, gradient, image, blur
    var id: String { rawValue }
    var title: String {
        switch self {
        case .preset: "Presets"
        case .solid: "Colour"
        case .gradient: "Gradient"
        case .image: "Image"
        case .blur: "Blurred video"
        }
    }
}

/// Background options layered on top of `BackgroundStyle`.
///
/// `BackgroundStyle` stays the stored preset so existing projects keep
/// decoding; `kind` decides whether that preset is what actually gets drawn.
struct CustomBackground: Codable, Equatable {
    var kind: BackgroundKind = .preset
    var top = RGBColor.forest
    var bottom = RGBColor.ink
    /// Gradient direction in degrees, 0 = left to right, 90 = bottom to top.
    var angle: Double = 135
    var imagePath: String?
    /// Fill the canvas and crop, rather than fitting the whole image inside it.
    var imageFills = true
    var blurRadius: Double = 48
    /// Darkens an image or blurred backdrop so the recording stays dominant.
    var dim: Double = 0.18
}

enum ExportFormat: String, CaseIterable, Identifiable, Codable {
    case mp4 = "MP4", mov = "MOV"
    var id: String { rawValue }
    var fileExtension: String { self == .mp4 ? "mp4" : "mov" }
}

enum ExportResolution: String, CaseIterable, Identifiable, Codable {
    case source = "Source", p720 = "720p", p1080 = "1080p", p1440 = "1440p", p2160 = "4K"
    var id: String { rawValue }

    /// The longest edge to render at, or nil to keep the canvas as composed.
    var longestEdge: CGFloat? {
        switch self {
        case .source: nil
        case .p720: 1280
        case .p1080: 1920
        case .p1440: 2560
        case .p2160: 3840
        }
    }
}

enum ExportFrameRate: Int, CaseIterable, Identifiable, Codable {
    case fps30 = 30, fps60 = 60
    var id: Int { rawValue }
    var title: String { "\(rawValue) fps" }
}

struct ExportOptions: Codable, Equatable {
    var format: ExportFormat = .mp4
    var resolution: ExportResolution = .source
    var frameRate: ExportFrameRate = .fps30

    /// Scales a composed canvas to the chosen resolution, keeping its aspect
    /// and even dimensions (H.264 rejects odd ones).
    func canvas(from size: CGSize) -> CGSize {
        guard let edge = resolution.longestEdge, size.width > 0, size.height > 0 else { return size }
        let scale = edge / max(size.width, size.height)
        return CGSize(width: max(2, (size.width * scale / 2).rounded() * 2),
                      height: max(2, (size.height * scale / 2).rounded() * 2))
    }
}

enum CameraShape: String, CaseIterable, Identifiable, Codable {
    case roundedRectangle = "Rounded"
    case circle = "Circle"
    var id: String { rawValue }
}

struct ProjectDocument: Codable {
    var videoPath: String
    var segments: [EditSegment]
    var background: BackgroundStyle
    var ratio: CanvasRatio
    var padding: Double
    var cornerRadius: Double
    var shadow: Double
    var cursorSize: Double
    var clickEffects: Bool
    var showCursor: Bool? = true
    var smoothCursor: Bool? = true
    var cursorShadow: Bool? = true
    var showKeystrokes: Bool? = false
    var showCamera: Bool? = true
    var cameraSize: Double? = 0.24
    var cameraHeightScale: Double? = nil
    var cameraSubjectScale: Double? = nil
    var cameraX: Double? = 0.82
    var cameraY: Double? = 0.78
    var cameraCornerRadius: Double? = 14
    var cameraShape: CameraShape? = .roundedRectangle
    var cameraMirrored: Bool? = false
    var trimStart: Double? = 0
    var trimEnd: Double? = nil
    var playbackRate: Double? = 1
    var muted: Bool? = false
    var musicPath: String? = nil
    var musicVolume: Double? = nil
    var metadata: RecordingMetadata? = nil
    var frameAppearance: FrameAppearance? = nil
    var motionAppearance: MotionAppearance? = nil
    var cursorAppearance: CursorAppearance? = nil
    var customBackground: CustomBackground? = nil
    var exportOptions: ExportOptions? = nil
    var grade: GradeSettings? = nil
    var cameraMove: CameraMoveSettings? = nil
    var typingFollow: TypingFollowSettings? = nil
    var sounds: SoundSettings? = nil
    var customRatioWidth: Double? = nil
    var customRatioHeight: Double? = nil
}

/// When a key was pressed, and nothing else.
///
/// Typing cannot be followed without knowing that it is happening, but what
/// was typed is none of the app's business — so only the instant is kept. No
/// character, no key code, nothing that could reconstruct the text.
struct TypingEvent: Codable, Equatable {
    var time: Double
}

/// When the wheel turned, and nothing else — the same bargain as a keypress.
/// Enough to lay a sound under a scroll and to know a scroll happened.
struct ScrollEvent: Codable, Equatable {
    var time: Double
}

struct RecordedClick: Codable {
    var time: Double
    var x: Double
    var y: Double
}

struct PointerSample: Codable {
    var time: Double
    var x: Double
    var y: Double
    var shape: PointerShape? = nil
    var pressed: Bool? = nil
}

struct KeystrokeEvent: Codable {
    var time: Double
    var text: String
}

struct CameraPresentation: Codable {
    var x: Double
    var y: Double
    var size: Double
    var shape: CameraShape
    var mirrored: Bool
}

struct RecordingMetadata: Codable {
    var clicks: [RecordedClick]
    var pointerSamples: [PointerSample]
    var keystrokes: [KeystrokeEvent]
    var sourceWidth: Double
    var sourceHeight: Double
    var sourceName: String
    var cameraFileName: String?
    var cameraTimeOffset: Double? = nil
    var cameraPresentation: CameraPresentation? = nil
    var sourcePointWidth: Double? = nil
    var sourcePointHeight: Double? = nil
    var embeddedCursor: Bool? = nil
    var typingEvents: [TypingEvent]? = nil
    var scrollEvents: [ScrollEvent]? = nil

    static let empty = RecordingMetadata(clicks: [], pointerSamples: [], keystrokes: [], sourceWidth: 0, sourceHeight: 0, sourceName: "", cameraFileName: nil)

    init(clicks: [RecordedClick], pointerSamples: [PointerSample], keystrokes: [KeystrokeEvent], sourceWidth: Double, sourceHeight: Double, sourceName: String, cameraFileName: String? = nil, cameraTimeOffset: Double? = nil, cameraPresentation: CameraPresentation? = nil, sourcePointWidth: Double? = nil, sourcePointHeight: Double? = nil) {
        self.clicks = clicks
        self.pointerSamples = pointerSamples
        self.keystrokes = keystrokes
        self.sourceWidth = sourceWidth
        self.sourceHeight = sourceHeight
        self.sourceName = sourceName
        self.cameraFileName = cameraFileName
        self.cameraTimeOffset = cameraTimeOffset
        self.cameraPresentation = cameraPresentation
        self.sourcePointWidth = sourcePointWidth; self.sourcePointHeight = sourcePointHeight
    }

    enum CodingKeys: String, CodingKey { case clicks, pointerSamples, keystrokes, sourceWidth, sourceHeight, sourceName, cameraFileName, cameraTimeOffset, cameraPresentation, sourcePointWidth, sourcePointHeight, embeddedCursor, typingEvents, scrollEvents }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        clicks = try values.decodeIfPresent([RecordedClick].self, forKey: .clicks) ?? []
        pointerSamples = try values.decodeIfPresent([PointerSample].self, forKey: .pointerSamples) ?? []
        keystrokes = try values.decodeIfPresent([KeystrokeEvent].self, forKey: .keystrokes) ?? []
        sourceWidth = try values.decodeIfPresent(Double.self, forKey: .sourceWidth) ?? 0
        sourceHeight = try values.decodeIfPresent(Double.self, forKey: .sourceHeight) ?? 0
        sourceName = try values.decodeIfPresent(String.self, forKey: .sourceName) ?? ""
        cameraFileName = try values.decodeIfPresent(String.self, forKey: .cameraFileName)
        cameraTimeOffset = try values.decodeIfPresent(Double.self, forKey: .cameraTimeOffset)
        cameraPresentation = try values.decodeIfPresent(CameraPresentation.self, forKey: .cameraPresentation)
        sourcePointWidth = try values.decodeIfPresent(Double.self, forKey: .sourcePointWidth)
        sourcePointHeight = try values.decodeIfPresent(Double.self, forKey: .sourcePointHeight)
        embeddedCursor = try values.decodeIfPresent(Bool.self, forKey: .embeddedCursor)
        typingEvents = try values.decodeIfPresent([TypingEvent].self, forKey: .typingEvents)
        scrollEvents = try values.decodeIfPresent([ScrollEvent].self, forKey: .scrollEvents)
    }
}
