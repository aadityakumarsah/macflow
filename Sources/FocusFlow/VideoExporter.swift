import AppKit
import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreText

struct ExportSettings {
    let background: BackgroundStyle
    let canvasSize: CGSize
    let padding: Double
    let cornerRadius: Double
    let shadow: Double
    var segments: [EditSegment]
    var pointerSamples: [PointerSample]
    var clicks: [RecordedClick]
    let keystrokes: [KeystrokeEvent]
    let cursorSize: Double
    let clickEffects: Bool
    let showKeystrokes: Bool
    let cameraURL: URL?
    let showCamera: Bool
    let cameraSize: Double
    var cameraHeightScale: Double = 1
    var cameraSubjectScale: Double = 1
    let cameraX: Double
    let cameraY: Double
    let cameraCornerRadius: Double
    let cameraShape: CameraShape
    var showCursor = true
    var smoothCursor = true
    var cursorShadow = true
    var cameraMirrored = false
    var trimStart: Double = 0
    var trimEnd: Double = .greatestFiniteMagnitude
    var playbackRate: Double = 1
    var muted = false
    var musicURL: URL? = nil
    var musicVolume: Double = 0.35
    var cameraTimeOffset: Double = 0
    var frame = FrameAppearance(chrome: .none)
    var motion = MotionAppearance()
    var cursor = CursorAppearance()
    var cursorPointScale: Double = 1
    var customBackground = CustomBackground()
    var exportOptions = ExportOptions()
}

enum ExportError: LocalizedError {
    case unavailable, failed(String)
    var errorDescription: String? {
        switch self {
        case .unavailable: "This video cannot be exported."
        case .failed(let reason): "Export failed: \(reason)"
        }
    }
}

enum VideoExporter {
    static func composition(source: URL, settings: ExportSettings) async throws -> (AVMutableComposition, AVMutableVideoComposition, AVAudioMix?) {
        let asset = AVURLAsset(url: source)
        let duration = try await asset.load(.duration)
        guard let video = try await asset.loadTracks(withMediaType: .video).first else { throw ExportError.unavailable }
        let edit = AVMutableComposition()
        guard let screen = edit.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw ExportError.unavailable }
        let videoTimeRange = try await video.load(.timeRange)
        let videoEnd = CMTimeMinimum(duration, videoTimeRange.end)
        guard videoEnd > .zero else { throw ExportError.unavailable }
        try screen.insertTimeRange(CMTimeRange(start: .zero, duration: videoEnd), of: video, at: .zero)
        // Chrome may finish writing its audio after its last video frame. A
        // composition that runs into that gap asks the compositor for a frame
        // that does not exist, aborting the entire export. Extend a short
        // piece of the last video instead, preserving the spoken audio tail.
        if duration > videoEnd {
            let finalPiece = CMTimeMinimum(CMTime(seconds: 0.1, preferredTimescale: 600), videoEnd)
            try screen.insertTimeRange(CMTimeRange(start: videoEnd - finalPiece, duration: finalPiece), of: video, at: videoEnd)
            screen.scaleTimeRange(CMTimeRange(start: videoEnd, duration: finalPiece), toDuration: duration - videoEnd)
        }
        let screenTransform = try await video.load(.preferredTransform)
        if !settings.muted {
            for audio in try await asset.loadTracks(withMediaType: .audio) {
                if let track = edit.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                    let range = try await audio.load(.timeRange)
                    // Trim audio to match video duration to avoid gaps
                    let audioDuration = CMTimeMinimum(range.duration, videoEnd)
                    try track.insertTimeRange(CMTimeRange(start: range.start, duration: audioDuration), of: audio, at: range.start)
                }
            }
        }
        var musicMix: AVAudioMix?
        if let musicURL = settings.musicURL, FileManager.default.fileExists(atPath: musicURL.path) {
            let musicAsset = AVURLAsset(url: musicURL)
            guard let sourceAudio = try await musicAsset.loadTracks(withMediaType: .audio).first,
                  let track = edit.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw ExportError.failed("The selected music file has no playable audio.")
            }
            let range = try await sourceAudio.load(.timeRange)
            guard range.duration > .zero else { throw ExportError.failed("The selected music file has no playable audio.") }
            var at = CMTime.zero
            while at < duration {
                let length = CMTimeMinimum(range.duration, duration - at)
                try track.insertTimeRange(CMTimeRange(start: range.start, duration: length), of: sourceAudio, at: at)
                at = at + length
            }
            let parameters = AVMutableAudioMixInputParameters(track: track)
            parameters.setVolume(Float(min(1, max(0, settings.musicVolume))), at: .zero)
            let mix = AVMutableAudioMix()
            mix.inputParameters = [parameters]
            musicMix = mix
        }
        var cameraID = kCMPersistentTrackID_Invalid
        var cameraTransform = CGAffineTransform.identity
        if let url = settings.cameraURL {
            let camera = AVURLAsset(url: url)
            if let source = try await camera.loadTracks(withMediaType: .video).first,
               let track = edit.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) {
                let sourceStart = CMTime(seconds: max(0, settings.cameraTimeOffset), preferredTimescale: 600)
                let targetStart = CMTime(seconds: max(0, -settings.cameraTimeOffset), preferredTimescale: 600)
                let length = CMTimeMinimum(duration - targetStart, try await camera.load(.duration) - sourceStart)
                if length > .zero {
                    try track.insertTimeRange(CMTimeRange(start: sourceStart, duration: length), of: source, at: targetStart)
                    cameraID = track.trackID
                }
                cameraTransform = try await source.load(.preferredTransform)
            }
        }
        let rate = max(0.25, min(3, settings.playbackRate))
        edit.scaleTimeRange(CMTimeRange(start: .zero, duration: duration), toDuration: CMTimeMultiplyByFloat64(duration, multiplier: 1 / rate))
        let composition = AVMutableVideoComposition()
        composition.renderSize = settings.canvasSize
        composition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(settings.exportOptions.frameRate.rawValue))
        composition.customVideoCompositorClass = FocusFlowCompositor.self
        composition.instructions = [CompositionInstruction(timeRange: CMTimeRange(start: .zero, duration: edit.duration), settings: settings, screenTrackID: screen.trackID, cameraTrackID: cameraID, screenTransform: screenTransform, cameraTransform: cameraTransform)]
        return (edit, composition, musicMix)
    }

    static func export(source: URL, destination: URL, settings: ExportSettings, progress: @escaping (Double) -> Void) async throws {
        guard source.standardizedFileURL != destination.standardizedFileURL,
              settings.cameraURL?.standardizedFileURL != destination.standardizedFileURL else {
            throw ExportError.failed("Choose a different filename to preserve your original recording.")
        }
        let (asset, composition, musicMix) = try await composition(source: source, settings: settings)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else { throw ExportError.unavailable }
        let options = settings.exportOptions
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".focusflow-export-\(UUID().uuidString).\(options.format.fileExtension)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        session.outputURL = temporary
        // Resolution is carried by the composition's renderSize, which the
        // highest-quality preset passes through untouched; the smaller presets
        // impose their own dimensions and would fight it.
        session.outputFileType = options.format == .mp4 ? .mp4 : .mov
        session.videoComposition = composition
        session.audioMix = musicMix
        session.shouldOptimizeForNetworkUse = true
        let start = max(0, settings.trimStart / settings.playbackRate)
        let end = min(asset.duration.seconds, settings.trimEnd / settings.playbackRate)
        guard end > start else { throw ExportError.failed("The trim range is empty.") }
        session.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600), duration: CMTime(seconds: end - start, preferredTimescale: 600))
        let poll = Task {
            while !Task.isCancelled {
                progress(Double(session.progress))
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
        await session.export()
        poll.cancel()
        guard session.status == .completed else { throw ExportError.failed(session.error?.localizedDescription ?? "Unknown error") }
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
        } else { try FileManager.default.moveItem(at: temporary, to: destination) }
        progress(1)
    }
}

final class CompositionInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    let timeRange: CMTimeRange
    let enablePostProcessing = true
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = CMPersistentTrackID(kCMPersistentTrackID_Invalid)
    let settings: ExportSettings
    let screenTrackID: CMPersistentTrackID
    let cameraTrackID: CMPersistentTrackID
    let screenTransform: CGAffineTransform
    let cameraTransform: CGAffineTransform
    init(timeRange: CMTimeRange, settings: ExportSettings, screenTrackID: CMPersistentTrackID, cameraTrackID: CMPersistentTrackID, screenTransform: CGAffineTransform = .identity, cameraTransform: CGAffineTransform = .identity) {
        self.timeRange = timeRange
        self.settings = settings
        self.screenTrackID = screenTrackID
        self.screenTransform = screenTransform
        self.cameraTransform = cameraTransform
        self.cameraTrackID = cameraTrackID
        var ids: [NSValue] = [NSNumber(value: screenTrackID)]
        if cameraTrackID != kCMPersistentTrackID_Invalid { ids.append(NSNumber(value: cameraTrackID)) }
        self.requiredSourceTrackIDs = ids
    }
}

final class FocusFlowCompositor: NSObject, AVVideoCompositing {
    private let context = CIContext(options: [.cacheIntermediates: false])
    var sourcePixelBufferAttributes: [String: Any]? = [
        kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_32BGRA, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
    ]
    var requiredPixelBufferAttributesForRenderContext: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
    ]
    private var renderContext: AVVideoCompositionRenderContext?

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) { renderContext = newRenderContext }
    func cancelAllPendingVideoCompositionRequests() { context.clearCaches() }

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        autoreleasepool {
            guard let instruction = request.videoCompositionInstruction as? CompositionInstruction,
                  let sourceBuffer = request.sourceFrame(byTrackID: instruction.screenTrackID),
                  let outputBuffer = renderContext?.newPixelBuffer() else {
                request.finish(with: ExportError.unavailable); return
            }
            let settings = instruction.settings
            let canvas = CGRect(origin: .zero, size: settings.canvasSize)
            let time = request.compositionTime.seconds * settings.playbackRate
            let source = normalized(CIImage(cvPixelBuffer: sourceBuffer).transformed(by: instruction.screenTransform))
            let camera = (instruction.cameraTrackID == kCMPersistentTrackID_Invalid ? nil : request.sourceFrame(byTrackID: instruction.cameraTrackID)).map {
                normalized(CIImage(cvPixelBuffer: $0).transformed(by: instruction.cameraTransform))
            }
            let result = renderFrame(source: source, camera: camera, time: time, settings: settings)
            context.render(result, to: outputBuffer, bounds: canvas, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
            request.finish(withComposedVideoFrame: outputBuffer)
        }
    }

    private func normalized(_ image: CIImage) -> CIImage {
        image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
    }

    /// One rendering path for playback, export, and image checks.
    func renderFrame(source original: CIImage, camera: CIImage? = nil, time: Double, settings: ExportSettings) -> CIImage {
        let canvas = CGRect(origin: .zero, size: settings.canvasSize)
        var source = normalized(original)
        for blur in settings.segments where blur.kind == .blur && time >= blur.start && time <= blur.end {
            let w = source.extent.width * blur.regionWidth, h = source.extent.height * blur.regionHeight
            let region = CGRect(x: source.extent.width * blur.x - w / 2, y: source.extent.height * (1 - blur.y) - h / 2, width: w, height: h).intersection(source.extent)
            let hidden = source.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: max(8, blur.intensity * 16)]).cropped(to: region)
            source = hidden.composited(over: source)
        }
        for pixelate in settings.segments where pixelate.kind == .pixelate {
            let strength = MotionEngine.envelope(pixelate, time: time)
            guard strength > 0 else { continue }
            let w = source.extent.width * pixelate.regionWidth, h = source.extent.height * pixelate.regionHeight
            let region = CGRect(x: source.extent.width * pixelate.x - w / 2, y: source.extent.height * (1 - pixelate.y) - h / 2, width: w, height: h).intersection(source.extent)
            guard !region.isEmpty else { continue }
            let blocks = source.clampedToExtent().applyingFilter("CIPixellate", parameters: [
                kCIInputScaleKey: max(10, source.extent.width / 1920 * pixelate.intensity * 24),
                kCIInputCenterKey: CIVector(x: region.midX, y: region.midY)
            ]).cropped(to: region)
            source = opacity(blocks, strength).composited(over: source)
        }
        for spot in settings.segments where spot.kind == .spotlight {
            let strength = MotionEngine.envelope(spot, time: time)
            guard strength > 0 else { continue }
            let w = source.extent.width * spot.regionWidth, h = source.extent.height * spot.regionHeight
            let region = CGRect(x: source.extent.width * spot.x - w / 2, y: source.extent.height * (1 - spot.y) - h / 2, width: w, height: h)
            let mask = CIFilter.roundedRectangleGenerator()
            mask.extent = region
            mask.radius = Float(min(w, h) * 0.18); mask.color = .white
            let feather = max(12, source.extent.width / 1920 * 24)
            let dimmed = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: strength * min(0.9, spot.intensity * 0.25))).cropped(to: source.extent).composited(over: source)
            let softMask = mask.outputImage!.cropped(to: region.insetBy(dx: -feather * 4, dy: -feather * 4))
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: feather])
            source = source.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: dimmed, kCIInputMaskImageKey: softMask])
            let borderWidth = max(2, source.extent.width / 1920 * 3)
            let outer = CIFilter.roundedRectangleGenerator()
            outer.extent = region.insetBy(dx: -borderWidth, dy: -borderWidth)
            outer.radius = Float(min(w, h) * 0.18 + borderWidth)
            outer.color = .white
            let inner = CIFilter.roundedRectangleGenerator()
            inner.extent = region.insetBy(dx: borderWidth, dy: borderWidth)
            inner.radius = Float(max(1, min(w, h) * 0.18 - borderWidth))
            inner.color = .white
            let ring = outer.outputImage!.cropped(to: region.insetBy(dx: -feather * 4, dy: -feather * 4))
                .applyingFilter("CISourceOutCompositing", parameters: [kCIInputBackgroundImageKey: inner.outputImage!.cropped(to: region.insetBy(dx: -feather * 4, dy: -feather * 4))])
            let ink = CIImage(color: CIColor(cgColor: settings.cursor.accentColor.copy(alpha: strength * 0.48) ?? settings.cursor.accentColor)).cropped(to: ring.extent)
            let clear = CIImage(color: .clear).cropped(to: ring.extent)
            let glow = ink.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: clear, kCIInputMaskImageKey: ring.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: feather * 0.65])])
            let edge = opacity(ink.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: clear, kCIInputMaskImageKey: ring]), 0.5)
            source = edge.composited(over: glow.composited(over: source))
        }
        source = applyInteractionEffects(to: source, at: time, target: source.extent, settings: settings)
        for outline in settings.segments where outline.kind == .outline {
            let strength = MotionEngine.envelope(outline, time: time)
            guard strength > 0 else { continue }
            let w = source.extent.width * outline.regionWidth, h = source.extent.height * outline.regionHeight
            let region = CGRect(x: source.extent.width * outline.x - w / 2, y: source.extent.height * (1 - outline.y) - h / 2, width: w, height: h).intersection(source.extent)
            guard !region.isEmpty else { continue }
            let line = min(region.width / 4, region.height / 4, max(3, source.extent.width / 1920 * outline.intensity * 6))
            let ink = CIImage(color: CIColor(cgColor: settings.cursor.accentColor.copy(alpha: strength) ?? settings.cursor.accentColor))
            let edges = [
                CGRect(x: region.minX, y: region.minY, width: region.width, height: line),
                CGRect(x: region.minX, y: region.maxY - line, width: region.width, height: line),
                CGRect(x: region.minX, y: region.minY, width: line, height: region.height),
                CGRect(x: region.maxX - line, y: region.minY, width: line, height: region.height)
            ]
            for edge in edges { source = ink.cropped(to: edge).composited(over: source) }
        }
        for label in settings.segments where label.kind == .callout {
            let strength = MotionEngine.envelope(label, time: time)
            guard strength > 0, let badge = RenderAssets.callout(text: label.text ?? "Look here", unit: source.extent.width / 1920 * min(3, max(0.5, label.intensity)), accent: settings.cursor.accentColor, key: settings.cursor.accentKey) else { continue }
            let x = min(source.extent.width - badge.extent.width, max(0, source.extent.width * label.x - badge.extent.width / 2))
            let y = min(source.extent.height - badge.extent.height, max(0, source.extent.height * (1 - label.y) - badge.extent.height / 2))
            source = opacity(badge, strength).transformed(by: CGAffineTransform(translationX: x, y: y - (1 - strength) * 16)).composited(over: source)
        }
        let selection = settings.frame.crop.rect(in: source.extent.size)
        let contentCrop = CGRect(x: selection.minX, y: source.extent.height - selection.maxY, width: selection.width, height: selection.height)
        source = normalized(source.cropped(to: contentCrop))
        let sourceSize = source.extent.size
        let viewport = MotionEngine.viewport(at: time, segments: settings.segments, samples: settings.pointerSamples, crop: settings.frame.crop)
        let zoomCrop = CGRect(x: viewport.minX * sourceSize.width, y: (1 - viewport.maxY) * sourceSize.height, width: viewport.width * sourceSize.width, height: viewport.height * sourceSize.height)
        source = normalized(source.cropped(to: zoomCrop))
        let layout = FrameLayout.make(canvas: canvas, sourceSize: sourceSize, padding: settings.padding, frame: settings.frame)
        source = source.transformed(by: CGAffineTransform(scaleX: layout.content.width / source.extent.width, y: layout.content.height / source.extent.height))
            .transformed(by: CGAffineTransform(translationX: layout.content.minX, y: layout.content.minY)).cropped(to: layout.content)
        if settings.motion.automaticMotionBlur != false {
            let frameStep = 1 / Double(settings.exportOptions.frameRate.rawValue)
            let previous = MotionEngine.viewport(at: max(0, time - frameStep), segments: settings.segments, samples: settings.pointerSamples, crop: settings.frame.crop)
            let next = MotionEngine.viewport(at: time + frameStep, segments: settings.segments, samples: settings.pointerSamples, crop: settings.frame.crop)
            let dx = (next.midX - previous.midX) / max(0.01, viewport.width) * layout.content.width
            let dy = (next.midY - previous.midY) / max(0.01, viewport.height) * layout.content.height
            let zoomMotion = abs(next.width - previous.width) / max(0.01, viewport.width) * layout.content.width * 0.12
            let radius = min(12, (hypot(dx, dy) * 0.16 + zoomMotion) * max(0, min(1, settings.motion.motionBlurStrength ?? 0.55)))
            if radius > 0.6 {
                source = source.clampedToExtent().applyingFilter("CIMotionBlur", parameters: [kCIInputRadiusKey: radius, kCIInputAngleKey: atan2(-dy, dx)]).cropped(to: layout.content)
            }
        }
        if let header = RenderAssets.header(settings.frame, rect: layout.header) { source = header.composited(over: source) }
        let rounded = CIFilter.roundedRectangleGenerator()
        rounded.extent = layout.outer; rounded.radius = Float(settings.cornerRadius); rounded.color = .white
        let mask = rounded.outputImage!.cropped(to: canvas)
        let clear = CIImage(color: .clear).cropped(to: canvas)
        source = source.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: clear, kCIInputMaskImageKey: mask])
        if settings.shadow > 0 {
            let shade = mask.applyingFilter("CIColorMatrix", parameters: ["inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0.35)])
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: settings.shadow])
                .transformed(by: CGAffineTransform(translationX: 0, y: -settings.shadow / 3))
            source = source.composited(over: shade)
        }
        let motion = settings.motion
        let progress = MotionCurve.smooth.value((time - settings.trimStart) / max(0.1, motion.duration))
        if motion.entrance != .none {
            var transform = CGAffineTransform.identity
            if motion.entrance == .rise { transform = CGAffineTransform(translationX: 0, y: -(1 - progress) * canvas.height * 0.12) }
            if motion.entrance == .slide { transform = CGAffineTransform(translationX: -(1 - progress) * canvas.width * 0.16, y: 0) }
            if motion.entrance == .scale {
                let scale = 0.9 + progress * 0.1
                transform = CGAffineTransform(translationX: canvas.midX, y: canvas.midY).scaledBy(x: scale, y: scale).translatedBy(x: -canvas.midX, y: -canvas.midY)
            }
            source = opacity(source.transformed(by: transform), progress)
        }
        if motion.fadeOut { source = opacity(source, MotionCurve.smooth.value((settings.trimEnd - time) / max(0.1, motion.duration))) }
        let backdrop = makeBackground(settings: settings, source: original, extent: canvas)
        var result = source.composited(over: settings.motion.ambientGraphics == false ? backdrop : animatedBackdrop(backdrop, canvas: canvas, time: time, settings: settings)).cropped(to: canvas)
        if settings.motion.ambientGraphics != false {
            let progress = max(0, min(1, (time - settings.trimStart) / max(0.01, settings.trimEnd - settings.trimStart)))
            let line = CGRect(x: canvas.minX, y: canvas.minY, width: canvas.width * progress, height: max(3, canvas.height / 400))
            let accent = CIImage(color: CIColor(cgColor: settings.cursor.accentColor))
            result = accent.cropped(to: line).composited(over: result).cropped(to: canvas)
        }
        if settings.showKeystrokes, let key = settings.keystrokes.last(where: { time >= $0.time && time - $0.time < 1.25 }), let badge = keyBadge(key.text, canvas: canvas) {
            result = badge.composited(over: result)
        }
        if settings.showCamera, var camera {
            if settings.cameraMirrored { camera = normalized(camera.transformed(by: CGAffineTransform(scaleX: -1, y: 1))) }
            result = applyCamera(camera, over: result, settings: settings, canvas: canvas)
        }
        return result.cropped(to: canvas)
    }

    private func opacity(_ image: CIImage, _ alpha: Double) -> CIImage {
        image.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: max(0, min(1, alpha)))])
    }

    private func animatedBackdrop(_ base: CIImage, canvas: CGRect, time: Double, settings: ExportSettings) -> CIImage {
        let phase = time * 0.38
        let centre = CGPoint(x: canvas.width * (0.48 + 0.27 * sin(phase)), y: canvas.height * (0.5 + 0.24 * cos(phase * 0.8)))
        let glow = CIFilter.radialGradient()
        glow.center = centre
        glow.radius0 = 0
        glow.radius1 = Float(max(canvas.width, canvas.height) * 0.72)
        glow.color0 = CIColor(cgColor: settings.cursor.accentColor.copy(alpha: 0.16) ?? settings.cursor.accentColor)
        glow.color1 = .clear
        return (glow.outputImage?.cropped(to: canvas) ?? CIImage(color: .clear).cropped(to: canvas)).composited(over: base)
    }

    private func applyCamera(_ cameraImage: CIImage, over background: CIImage, settings: ExportSettings, canvas: CGRect) -> CIImage {
        let base = max(72, min(canvas.width, canvas.height) * settings.cameraSize)
        let height = settings.cameraShape == .circle ? base : base * min(1.7, max(0.65, settings.cameraHeightScale))
        let width = settings.cameraShape == .circle ? height : base * 1.45
        let x = min(canvas.maxX - width, max(canvas.minX, canvas.minX + settings.cameraX * canvas.width - width / 2))
        let y = min(canvas.maxY - height, max(canvas.minY, canvas.minY + (1 - settings.cameraY) * canvas.height - height / 2))
        let target = CGRect(x: x, y: y, width: width, height: height)
        let scale = max(target.width / cameraImage.extent.width, target.height / cameraImage.extent.height)
            * min(3, max(1, settings.cameraSubjectScale))
        var camera = cameraImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        camera = camera.transformed(by: CGAffineTransform(translationX: target.midX - camera.extent.midX, y: target.midY - camera.extent.midY)).cropped(to: target)

        let rounded = CIFilter.roundedRectangleGenerator()
        rounded.extent = target
        rounded.radius = Float(settings.cameraShape == .circle ? height / 2 : min(height / 2, settings.cameraCornerRadius))
        rounded.color = .white
        let transparent = CIImage(color: .clear).cropped(to: canvas)
        let clipped = camera.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: transparent,
            kCIInputMaskImageKey: rounded.outputImage?.cropped(to: canvas) ?? CIImage(color: .white).cropped(to: target)
        ])
        return clipped.composited(over: background).cropped(to: canvas)
    }

    private func applyInteractionEffects(to image: CIImage, at time: Double, target: CGRect, settings: ExportSettings) -> CIImage {
        var result = image
        let click = settings.clicks.last(where: { time >= $0.time && time - $0.time < 0.8 })
        if settings.clickEffects, let click,
           let ring = RenderAssets.click(accent: settings.cursor.accentColor, key: settings.cursor.accentKey, style: settings.cursor.clickStyle) {
            let progress = (time - click.time) / 0.8
            let unit = target.width / 1920
            let clickScale = max(0.2, settings.cursor.clickScale ?? 1.4)
            let baseSize = max(90, settings.cursorSize * 32) * unit * clickScale
            let center = CGPoint(x: click.x * target.width, y: (1 - click.y) * target.height)
            if let flash = RenderAssets.highlight(accent: settings.cursor.accentColor, key: settings.cursor.accentKey) {
                let size = baseSize * (1.1 + progress * 1.3)
                let placed = flash.transformed(by: CGAffineTransform(scaleX: size / flash.extent.width, y: size / flash.extent.height))
                    .transformed(by: CGAffineTransform(translationX: center.x - size / 2, y: center.y - size / 2))
                result = opacity(placed, 0.34 * pow(1 - progress, 2)).composited(over: result)
            }
            for delay in [0.0, 0.16] {
                let phase = (progress - delay) / (1 - delay)
                guard phase >= 0 else { continue }
                let diameter = baseSize * (0.45 + 1.35 * (1 - pow(1 - phase, 3)))
                let placed = ring.transformed(by: CGAffineTransform(scaleX: diameter / ring.extent.width, y: diameter / ring.extent.height))
                    .transformed(by: CGAffineTransform(translationX: center.x - diameter / 2, y: center.y - diameter / 2))
                result = opacity(placed, 0.95 * pow(1 - phase, 1.5)).composited(over: result)
            }
        }
        // Drawn before the pointer so the pointer sits on top of it.
        if settings.showCursor, settings.cursor.highlight == true,
           let pointer = CursorMotion.sample(at: time, samples: settings.pointerSamples, smoothed: settings.smoothCursor),
           let glow = RenderAssets.highlight(accent: settings.cursor.accentColor, key: settings.cursor.accentKey) {
            let unit = target.width / 1920
            let size = 120 * unit * max(0.4, settings.cursor.highlightSize ?? 3.4) * settings.cursorSize
            let x = pointer.x * target.width - size / 2
            let y = (1 - pointer.y) * target.height - size / 2
            let placed = glow
                .transformed(by: CGAffineTransform(scaleX: size / glow.extent.width, y: size / glow.extent.height))
                .transformed(by: CGAffineTransform(translationX: x, y: y))
            result = opacity(placed, max(0, min(1, settings.cursor.highlightOpacity ?? 0.22))).composited(over: result)
        }
        if settings.showCursor, let pointer = CursorMotion.sample(at: time, samples: settings.pointerSamples, smoothed: settings.smoothCursor), let cursor = RenderAssets.cursor(settings.cursor, shape: settings.cursor.shape == nil || settings.cursor.shape == .automatic ? pointer.shape ?? .arrow : settings.cursor.shape!) {
            let resolvedShape = settings.cursor.shape == nil || settings.cursor.shape == .automatic ? pointer.shape ?? .arrow : settings.cursor.shape!
            let isText = resolvedShape == .text
            let isSystem = settings.cursor.style == .macOS || isText
            // The I-beam is a thin glyph and reads much smaller than the arrow
            // at the same scale, so it carries its own multiplier.
            let shapeScale = settings.cursorSize * (isText ? max(0.1, settings.cursor.textScale) : 1)
            var scale = isSystem ? settings.cursorPointScale * shapeScale : target.width / 1920 * shapeScale / 3
            if settings.clickEffects, let click {
                let age = (time - click.time) / 0.42
                if age < 1 { scale *= 1 - 0.22 * exp(-age * 10) + 0.15 * sin(age * .pi) }
            }
            var angle = 0.0
            if settings.cursor.sway,
               let before = CursorMotion.sample(at: time - 0.05, samples: settings.pointerSamples, smoothed: true),
               let after = CursorMotion.sample(at: time + 0.05, samples: settings.pointerSamples, smoothed: true) {
                angle = max(-0.14, min(0.14, -(after.x - before.x) * 2))
            }
            let transform = CGAffineTransform(translationX: pointer.x * target.width, y: (1 - pointer.y) * target.height).rotated(by: angle).scaledBy(x: scale, y: scale)
            var placed = cursor.transformed(by: transform)
            // Fades the pointer without touching its highlight or clicks.
            let pointerOpacity = max(0, min(1, settings.cursor.opacity ?? 1))
            if pointerOpacity < 1 { placed = opacity(placed, pointerOpacity) }
            if settings.cursorShadow {
                let shadow = opacity(placed.applyingFilter("CIColorMatrix", parameters: ["inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0)]), 0.45)
                    .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: target.width / 1920 * 3])
                    .transformed(by: CGAffineTransform(translationX: 0, y: -target.width / 1920 * 3))
                result = shadow.composited(over: result)
            }
            result = placed.composited(over: result)
        }
        return result.cropped(to: image.extent)
    }

    private func keyBadge(_ text: String, canvas: CGRect) -> CIImage? {
        let width = max(90, min(300, CGFloat(text.count) * 24 + 36)), height: CGFloat = 54
        guard let context = CGContext(data: nil, width: Int(width), height: Int(height), bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: 0.03, alpha: 0.82))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 23, weight: .bold), .foregroundColor: NSColor.white]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        let lineBounds = CTLineGetBoundsWithOptions(line, [])
        context.textPosition = CGPoint(x: (width - lineBounds.width) / 2, y: (height - lineBounds.height) / 2)
        CTLineDraw(line, context)
        guard let cgImage = context.makeImage() else { return nil }
        let badge = CIImage(cgImage: cgImage)
        return badge.transformed(by: CGAffineTransform(translationX: canvas.midX - width / 2, y: canvas.minY + 42))
    }

    private func presetColors(_ style: BackgroundStyle) -> (CIColor, CIColor) {
        switch style {
        case .aurora: (CIColor(red: 0.35, green: 0.12, blue: 0.82), CIColor(red: 1, green: 0.38, blue: 0.20))
        case .sunset: (CIColor(red: 1, green: 0.19, blue: 0.13), CIColor(red: 0.43, green: 0.09, blue: 0.72))
        case .ocean: (CIColor(red: 0.02, green: 0.72, blue: 0.80), CIColor(red: 0.06, green: 0.12, blue: 0.42))
        case .graphite: (CIColor(red: 0.18, green: 0.23, blue: 0.31), CIColor(red: 0.03, green: 0.05, blue: 0.09))
        case .cream: (CIColor(red: 1, green: 0.96, blue: 0.87), CIColor(red: 0.98, green: 0.72, blue: 0.28))
        case .none: (.black, .black)
        }
    }

    private func gradient(_ from: CIColor, _ to: CIColor, angle: Double, extent: CGRect) -> CIImage {
        // Run the gradient across the canvas along `angle`, measured from the
        // centre so the full sweep stays inside the frame at any aspect.
        let radians: CGFloat = CGFloat(angle) * .pi / 180
        let dx: CGFloat = cos(radians)
        let dy: CGFloat = sin(radians)
        let span: CGFloat = abs(dx) * extent.width + abs(dy) * extent.height
        let reach: CGFloat = span / 2
        let midX: CGFloat = extent.midX
        let midY: CGFloat = extent.midY
        let filter = CIFilter.linearGradient()
        filter.point0 = CGPoint(x: midX - dx * reach, y: midY - dy * reach)
        filter.point1 = CGPoint(x: midX + dx * reach, y: midY + dy * reach)
        filter.color0 = from
        filter.color1 = to
        return filter.outputImage?.cropped(to: extent) ?? CIImage(color: from).cropped(to: extent)
    }

    /// Scales an image to cover (or fit inside) the canvas and centres it.
    private func lay(_ image: CIImage, in extent: CGRect, fills: Bool) -> CIImage {
        let size = image.extent.size
        guard size.width > 0, size.height > 0 else { return CIImage(color: .black).cropped(to: extent) }
        let sx = extent.width / size.width, sy = extent.height / size.height
        let scale = fills ? max(sx, sy) : min(sx, sy)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let centred = scaled.transformed(by: CGAffineTransform(
            translationX: extent.midX - scaled.extent.midX,
            y: extent.midY - scaled.extent.midY))
        // `fit` leaves bars, so put something behind them rather than alpha.
        return centred.cropped(to: extent).composited(over: CIImage(color: .black).cropped(to: extent))
    }

    private func dimmed(_ image: CIImage, by amount: Double, extent: CGRect) -> CIImage {
        guard amount > 0 else { return image }
        let veil = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: min(0.9, amount))).cropped(to: extent)
        return veil.composited(over: image)
    }

    private func makeBackground(settings: ExportSettings, source: CIImage, extent: CGRect) -> CIImage {
        let custom = settings.customBackground
        switch custom.kind {
        case .preset:
            if let path = custom.imagePath, BuiltInBackground.url(for: path) != nil,
               let image = VideoExporter.backgroundImage(at: path) {
                return dimmed(lay(image, in: extent, fills: custom.imageFills), by: custom.dim, extent: extent)
            }
            let colors = presetColors(settings.background)
            return gradient(colors.0, colors.1, angle: 135, extent: extent)

        case .solid:
            return CIImage(color: CIColor(red: custom.top.r, green: custom.top.g, blue: custom.top.b)).cropped(to: extent)

        case .gradient:
            return gradient(CIColor(red: custom.top.r, green: custom.top.g, blue: custom.top.b),
                            CIColor(red: custom.bottom.r, green: custom.bottom.g, blue: custom.bottom.b),
                            angle: custom.angle, extent: extent)

        case .image:
            guard let path = custom.imagePath, let image = VideoExporter.backgroundImage(at: path) else {
                // Missing file: fall back to the gradient rather than a black
                // frame, so a moved image does not look like a broken render.
                return gradient(CIColor(red: custom.top.r, green: custom.top.g, blue: custom.top.b),
                                CIColor(red: custom.bottom.r, green: custom.bottom.g, blue: custom.bottom.b),
                                angle: custom.angle, extent: extent)
            }
            return dimmed(lay(image, in: extent, fills: custom.imageFills), by: custom.dim, extent: extent)

        case .blur:
            let filled = lay(normalized(source), in: extent, fills: true)
            // Clamp first, or the blur samples transparent edges and vignettes.
            let blurred = filled.clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: max(1, custom.blurRadius)])
                .cropped(to: extent)
            return dimmed(blurred, by: custom.dim, extent: extent)
        }
    }
}

extension VideoExporter {
    /// Decoding a background image per frame is far too slow for playback, so
    /// the last one stays cached. Keyed by path and modification date so an
    /// edited file is picked up without restarting the app.
    private static let imageCacheLock = NSLock()
    nonisolated(unsafe) private static var imageCacheKey = ""
    nonisolated(unsafe) private static var imageCacheValue: CIImage?

    static func backgroundImage(at path: String) -> CIImage? {
        let resolved = BuiltInBackground.url(for: path) ?? (path.hasPrefix("builtin:") ? nil : URL(fileURLWithPath: path))
        guard let resolved else { return nil }
        let stamp = (try? FileManager.default.attributesOfItem(atPath: resolved.path)[.modificationDate] as? Date)??.timeIntervalSince1970 ?? 0
        let key = "\(resolved.path)|\(stamp)"
        imageCacheLock.lock()
        defer { imageCacheLock.unlock() }
        if key == imageCacheKey { return imageCacheValue }
        let image = CIImage(contentsOf: resolved)
        imageCacheKey = key
        imageCacheValue = image
        return image
    }
}
