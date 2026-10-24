import Foundation
import CoreGraphics

enum SegmentKind: String, Codable, CaseIterable, Identifiable {
    case zoom, speed, blur, camera, pan, spotlight, callout
    var id: String { rawValue }
    static let availableCases: [SegmentKind] = [.zoom, .pan, .blur, .spotlight, .callout]
    var title: String { rawValue.capitalized }
    var symbol: String {
        switch self { case .zoom: "plus.magnifyingglass"; case .speed: "bolt.fill"; case .blur: "drop.fill"; case .camera: "video.fill"; case .pan: "arrow.left.and.right"; case .spotlight: "flashlight.on.fill"; case .callout: "text.bubble" }
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
    var text: String? = nil
    var end: Double { start + duration }
    var regionWidth: Double { width ?? 0.3 }
    var regionHeight: Double { height ?? 0.2 }
}

enum CanvasRatio: String, CaseIterable, Identifiable, Codable {
    case source = "Source", landscape = "16:9", portrait = "9:16", square = "1:1", classic = "4:3"
    var id: String { rawValue }
    var size: CGSize {
        switch self {
        case .source: CGSize(width: 1920, height: 1080)
        case .landscape: CGSize(width: 1920, height: 1080)
        case .portrait: CGSize(width: 1080, height: 1920)
        case .square: CGSize(width: 1080, height: 1080)
        case .classic: CGSize(width: 1440, height: 1080)
        }
    }

    func size(for sourceSize: CGSize) -> CGSize {
        guard self == .source, sourceSize.width > 0, sourceSize.height > 0 else { return size }
        let limit: CGFloat = 1920
        let scale = min(1, limit / max(sourceSize.width, sourceSize.height))
        let width = max(2, (sourceSize.width * scale / 2).rounded() * 2)
        let height = max(2, (sourceSize.height * scale / 2).rounded() * 2)
        return CGSize(width: width, height: height)
    }
}

enum BackgroundStyle: String, CaseIterable, Identifiable, Codable {
    case aurora, sunset, ocean, graphite, cream, none
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
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
    var cameraX: Double? = 0.82
    var cameraY: Double? = 0.78
    var cameraCornerRadius: Double? = 14
    var cameraShape: CameraShape? = .roundedRectangle
    var cameraMirrored: Bool? = false
    var trimStart: Double? = 0
    var trimEnd: Double? = nil
    var playbackRate: Double? = 1
    var muted: Bool? = false
    var metadata: RecordingMetadata? = nil
    var frameAppearance: FrameAppearance? = nil
    var motionAppearance: MotionAppearance? = nil
    var cursorAppearance: CursorAppearance? = nil
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

    enum CodingKeys: String, CodingKey { case clicks, pointerSamples, keystrokes, sourceWidth, sourceHeight, sourceName, cameraFileName, cameraTimeOffset, cameraPresentation, sourcePointWidth, sourcePointHeight }
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
    }
}
