import AppKit
import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreText
import Metal

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
    var grade = GradeSettings()
    var cameraMove = CameraMoveSettings()
    var exportOptions = ExportOptions()
    var typingEvents: [TypingEvent] = []
    var scrollEvents: [ScrollEvent] = []
    var sounds = SoundSettings()
    var selectionFocus = SelectionFocusSettings()
    var captions = CaptionSettings()
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
    /// Copy only the rendering instruction for edits that do not change
    /// source tracks, timing, or audio. The old instruction stays immutable
    /// for frames already being rendered on the compositor's queue.
    static func updatingPresentation(_ previous: AVVideoComposition, settings: ExportSettings) -> AVMutableVideoComposition? {
        guard previous.instructions.count == 1,
              let old = previous.instructions.first as? CompositionInstruction,
              let updated = previous.mutableCopy() as? AVMutableVideoComposition else { return nil }
        updated.renderSize = settings.canvasSize
        updated.instructions = [CompositionInstruction(timeRange: old.timeRange, settings: settings,
            screenTrackID: old.screenTrackID, cameraTrackID: old.cameraTrackID,
            screenTransform: old.screenTransform, cameraTransform: old.cameraTransform, timeMap: old.timeMap)]
        return updated
    }

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
        var mixInputs: [AVMutableAudioMixInputParameters] = []
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
            mixInputs.append(parameters)
        }

        // Sounds for what happened: the keyboard under a run of typing, a
        // click under a click, the wheel under a scroll. The cues come from
        // the recording's own events, so they follow the edit rather than
        // being placed once and left to drift out of step with it.
        let cues = SoundTrack.cues(clicks: settings.clicks,
                                   typing: settings.typingEvents,
                                   scrolling: settings.scrollEvents,
                                   duration: duration.seconds,
                                   settings: settings.sounds)
        for kind in SoundKind.allCases {
            let kindCues = cues.filter { $0.kind == kind }
            guard !kindCues.isEmpty, let url = kind.url else { continue }
            let clipAsset = AVURLAsset(url: url)
            guard let clipAudio = try await clipAsset.loadTracks(withMediaType: .audio).first,
                  let track = edit.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            let clip = try await clipAudio.load(.timeRange)
            guard clip.duration > .zero else { continue }
            let shortest = CMTime(seconds: 0.02, preferredTimescale: 600)
            // In order, and never on top of what is already there: inserting
            // into a composition track pushes whatever follows, so two cues
            // that overlap would shove the rest of the sound out of time.
            var cursor = CMTime.zero
            for (index, cue) in kindCues.enumerated() {
                let next = index + 1 < kindCues.count ? kindCues[index + 1].start : .greatestFiniteMagnitude
                // A cue with no span of its own — a click — is the clip once.
                let span = cue.fills ? cue.end - cue.start : clip.duration.seconds
                let stop = CMTime(seconds: min(min(cue.start + span, next), duration.seconds), preferredTimescale: 600)
                var at = CMTimeMaximum(CMTime(seconds: cue.start, preferredTimescale: 600), cursor)
                while at < stop {
                    let length = CMTimeMinimum(clip.duration, stop - at)
                    guard length > shortest else { break }
                    try track.insertTimeRange(CMTimeRange(start: clip.start, duration: length), of: clipAudio, at: at)
                    at = at + length
                }
                cursor = CMTimeMaximum(cursor, at)
            }
            let parameters = AVMutableAudioMixInputParameters(track: track)
            parameters.setVolume(Float(settings.sounds.volume(kind)), at: .zero)
            mixInputs.append(parameters)
        }
        var musicMix: AVAudioMix?
        if !mixInputs.isEmpty {
            let mix = AVMutableAudioMix()
            mix.inputParameters = mixInputs
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
        let timeMap = PlaybackTimeMap(duration: duration.seconds, rate: settings.playbackRate, segments: settings.segments)
        // Work backwards so earlier source ranges retain their original coordinates.
        // Scale all tracks together: screen, camera, speech, music and sound cues.
        for span in timeMap.spans.reversed() where abs(span.rate - 1) > 0.000001 {
            edit.scaleTimeRange(CMTimeRange(start: CMTime(seconds: span.sourceStart, preferredTimescale: 60000),
                duration: CMTime(seconds: span.sourceEnd - span.sourceStart, preferredTimescale: 60000)),
                toDuration: CMTime(seconds: span.outputEnd - span.outputStart, preferredTimescale: 60000))
        }
        let composition = AVMutableVideoComposition()
        composition.renderSize = settings.canvasSize
        composition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(settings.exportOptions.frameRate.rawValue))
        composition.customVideoCompositorClass = FocusFlowCompositor.self
        composition.instructions = [CompositionInstruction(timeRange: CMTimeRange(start: .zero, duration: edit.duration), settings: settings, screenTrackID: screen.trackID, cameraTrackID: cameraID, screenTransform: screenTransform, cameraTransform: cameraTransform, timeMap: timeMap)]
        return (edit, composition, musicMix)
    }

    /// How the file is encoded.
    ///
    /// `AVAssetExportSession` picks this from a preset and offers no way to
    /// say "no worse than what was recorded": the highest-quality preset
    /// still re-encodes a crisp screen recording at a rate of its own
    /// choosing, and text came back softer than the capture it was made
    /// from. So the rate is worked out here, from the recording itself,
    /// and floored at what the canvas needs.
    static func videoSettings(canvas: CGSize, frameRate: Int, source: CGSize, sourceDataRate: Double) -> [String: Any] {
        let pixels = Double(canvas.width) * Double(canvas.height)
        let sourcePixels = Double(source.width) * Double(source.height)
        // Bits per pixel per frame. Screen content is flat colour and hard
        // edges, and edges are the first thing a mean bitrate destroys, so
        // this is generous by the standards of camera footage.
        let needed = pixels * Double(frameRate) * 0.17
        // What the recording was carrying. Scaled down if the canvas is
        // smaller than the capture, never up: a wastefully encoded source
        // should not make a wastefully encoded export.
        let matched = sourcePixels > 0 ? sourceDataRate * min(1, pixels / sourcePixels) * 1.25 : 0
        // Past about this much H.264 is spending bits on a picture nobody
        // could tell from the one before it. A source encoded more
        // wastefully than that — ProRes, or a capture full of sensor noise
        // — is matched up to here and no further.
        let transparent = pixels * Double(frameRate) * 0.6
        let bitrate = min(max(needed, min(matched, transparent)), 240_000_000)
        return [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(canvas.width),
            AVVideoHeightKey: Int(canvas.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: Int(bitrate),
                AVVideoExpectedSourceFrameRateKey: frameRate,
                AVVideoMaxKeyFrameIntervalKey: frameRate * 2,
                AVVideoAllowFrameReorderingKey: true,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ]
    }

    static func export(source: URL, destination: URL, settings: ExportSettings, progress: @escaping (Double) -> Void) async throws {
        guard source.standardizedFileURL != destination.standardizedFileURL,
              settings.cameraURL?.standardizedFileURL != destination.standardizedFileURL else {
            throw ExportError.failed("Choose a different filename to preserve your original recording.")
        }
        let (asset, composition, musicMix) = try await composition(source: source, settings: settings)
        let options = settings.exportOptions
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".focusflow-export-\(UUID().uuidString).\(options.format.fileExtension)")
        defer { try? FileManager.default.removeItem(at: temporary) }

        guard let timing = (composition.instructions.first as? CompositionInstruction)?.timeMap else { throw ExportError.unavailable }
        let start = timing.outputTime(for: settings.trimStart)
        let end = min(asset.duration.seconds, timing.outputTime(for: settings.trimEnd))
        guard end > start else { throw ExportError.failed("The trim range is empty.") }
        let range = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                duration: CMTime(seconds: end - start, preferredTimescale: 600))

        // What the recording itself was encoded at, which is the floor the
        // export must not fall below.
        let original = AVURLAsset(url: source)
        let originalTrack = try await original.loadTracks(withMediaType: .video).first
        let sourceSize = try await originalTrack?.load(.naturalSize) ?? .zero
        let sourceDataRate = try await originalTrack?.load(.estimatedDataRate) ?? 0

        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = range
        let frames = AVAssetReaderVideoCompositionOutput(
            videoTracks: try await asset.loadTracks(withMediaType: .video),
            videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        // Resolution is carried by the composition's renderSize, and the
        // compositor draws every effect into it.
        frames.videoComposition = composition
        frames.alwaysCopiesSampleData = false
        guard reader.canAdd(frames) else { throw ExportError.unavailable }
        reader.add(frames)

        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        var mixed: AVAssetReaderAudioMixOutput?
        if !audioTracks.isEmpty {
            let output = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsNonInterleaved: false,
                AVLinearPCMIsBigEndianKey: false,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
            ])
            output.audioMix = musicMix
            output.alwaysCopiesSampleData = false
            if reader.canAdd(output) { reader.add(output); mixed = output }
        }

        let writer = try AVAssetWriter(outputURL: temporary, fileType: options.format == .mp4 ? .mp4 : .mov)
        writer.shouldOptimizeForNetworkUse = true
        let picture = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings(
            canvas: settings.canvasSize, frameRate: options.frameRate.rawValue,
            source: sourceSize, sourceDataRate: Double(sourceDataRate)))
        picture.expectsMediaDataInRealTime = false
        guard writer.canAdd(picture) else { throw ExportError.unavailable }
        writer.add(picture)
        var speaker: AVAssetWriterInput?
        if mixed != nil {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 256_000,
            ])
            input.expectsMediaDataInRealTime = false
            if writer.canAdd(input) { writer.add(input); speaker = input }
        }

        guard reader.startReading() else {
            throw ExportError.failed(reader.error?.localizedDescription ?? "The recording could not be read.")
        }
        guard writer.startWriting() else {
            throw ExportError.failed(writer.error?.localizedDescription ?? "The video could not be written.")
        }
        // Samples keep the times they have in the composition, and the
        // session says which of those is the beginning of the file — which
        // is how a trimmed export starts at zero.
        writer.startSession(atSourceTime: range.start)

        let length = max(0.01, range.duration.seconds)
        let began = range.start.seconds
        let pumps = DispatchGroup()
        /// Each input pulls from its own output as fast as the encoder will
        /// take it. Both run at once: an asset reader holds what it has
        /// decoded until it is collected, so draining one track to the end
        /// while the other waits is how an export runs out of memory.
        func drain(_ input: AVAssetWriterInput, from output: AVAssetReaderOutput, on label: String, reporting: Bool) {
            pumps.enter()
            input.requestMediaDataWhenReady(on: DispatchQueue(label: label)) {
                while input.isReadyForMoreMediaData {
                    guard reader.status == .reading, let buffer = output.copyNextSampleBuffer() else {
                        input.markAsFinished(); pumps.leave(); return
                    }
                    if reporting {
                        let at = CMSampleBufferGetPresentationTimeStamp(buffer).seconds
                        if at.isFinite { progress(min(0.99, max(0, (at - began) / length))) }
                    }
                    guard input.append(buffer) else {
                        input.markAsFinished(); pumps.leave(); return
                    }
                }
            }
        }
        drain(picture, from: frames, on: "com.focusflow.export.video", reporting: true)
        if let speaker, let mixed { drain(speaker, from: mixed, on: "com.focusflow.export.audio", reporting: false) }
        await withCheckedContinuation { continuation in
            pumps.notify(queue: .global(qos: .userInitiated)) { continuation.resume() }
        }

        if reader.status == .failed {
            writer.cancelWriting()
            throw ExportError.failed(reader.error?.localizedDescription ?? "The recording could not be read.")
        }
        // Audio packets may straddle the reader's trim endpoint. Bound the
        // writer session explicitly so AAC padding cannot lengthen the edit.
        guard writer.status == .writing else {
            throw ExportError.failed(writer.error?.localizedDescription ?? "The encoder stopped before the edit finished.")
        }
        writer.endSession(atSourceTime: range.end)
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw ExportError.failed(writer.error?.localizedDescription ?? "Unknown error")
        }
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
    let timeMap: PlaybackTimeMap
    let screenTrackID: CMPersistentTrackID
    let cameraTrackID: CMPersistentTrackID
    let screenTransform: CGAffineTransform
    let cameraTransform: CGAffineTransform
    init(timeRange: CMTimeRange, settings: ExportSettings, screenTrackID: CMPersistentTrackID, cameraTrackID: CMPersistentTrackID, screenTransform: CGAffineTransform = .identity, cameraTransform: CGAffineTransform = .identity, timeMap: PlaybackTimeMap? = nil) {
        self.timeRange = timeRange
        self.settings = settings
        self.timeMap = timeMap ?? PlaybackTimeMap(duration: timeRange.duration.seconds * settings.playbackRate, rate: settings.playbackRate, segments: settings.segments)
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
    /// Metal-backed where the hardware allows. The default context falls back
    /// to the CPU for parts of a long filter chain, and this chain is long —
    /// which is what made the preview stutter as effects were added.
    private let context: CIContext = {
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device, options: [
                .cacheIntermediates: false,
                .priorityRequestLow: false,
            ])
        }
        return CIContext(options: [.cacheIntermediates: false])
    }()

    /// The last few source frames, newest last.
    ///
    /// Content motion — a scroll — moves the page while the viewport stays
    /// still, so it cannot be measured from the camera path. Mixing the
    /// neighbouring frames in gives it a real shutter instead, which is what
    /// stops scrolling strobing. Requests can arrive on more than one thread,
    /// hence the lock.
    private let historyLock = NSLock()
    private var history: [(time: Double, image: CIImage)] = []
    /// When the wheel turned, in order. Worked out once: the recording does
    /// not change under a composition.
    private var scrollTimes: [Double]?

    /// How far either side of a wheel event the shutter stays open.
    static let scrollBlurWindow: Double = 0.22

    /// Whether the content is moving under its own steam at this moment.
    ///
    /// Blending the neighbouring frames gives a scroll a real shutter, but
    /// it is a frame of the recording mixed into another frame of it: where
    /// nothing is scrolling it is a ghost over text that was perfectly
    /// sharp, which is the recording made worse for nothing. So it is
    /// spent where the recording says the wheel actually turned. A capture
    /// that reports no wheel events at all — an imported video — says
    /// nothing either way, and is softened throughout as it always was.
    private func scrolling(at time: Double, settings: ExportSettings) -> Bool {
        guard !settings.scrollEvents.isEmpty else { return true }
        let times: [Double]
        if let cached = scrollTimes { times = cached }
        else { times = settings.scrollEvents.map(\.time).sorted(); scrollTimes = times }
        let window = Self.scrollBlurWindow
        var low = 0, high = times.count
        while low < high {
            let mid = (low + high) / 2
            if times[mid] < time - window { low = mid + 1 } else { high = mid }
        }
        return low < times.count && times[low] <= time + window
    }

    /// `sourceTime` is where this frame sits in the recording, which is what
    /// the wheel events are timed against; `time` is where it sits in the
    /// composition, which is what decides whether two frames are neighbours.
    private func rememberAndBlend(_ image: CIImage, at time: Double, sourceTime: Double? = nil, settings: ExportSettings) -> CIImage {
        historyLock.lock()
        defer { historyLock.unlock() }

        let wanted = settings.motion.scrollBlur != false && scrolling(at: sourceTime ?? time, settings: settings)
        let strength = max(0, min(1, settings.motion.scrollBlurStrength ?? 0.32))
        let step = 1 / Double(max(1, settings.exportOptions.frameRate.rawValue))

        // A seek or a jump leaves the history unrelated to this frame.
        if let last = history.last, time <= last.time || time - last.time > step * 2.5 {
            history.removeAll(keepingCapacity: true)
        }

        var result = image
        if wanted && strength > 0.01 {
            let depth = settings.motion.scrollBlurLong == true ? 2 : 1
            let usable = history.suffix(depth).reversed()
            // Each neighbour contributes less than the one before it.
            var weight = strength * 0.5
            for neighbour in usable {
                result = result.applyingFilter("CIMix", parameters: [
                    kCIInputBackgroundImageKey: neighbour.image,
                    kCIInputAmountKey: weight,
                ]).cropped(to: image.extent)
                weight *= 0.55
            }
        }

        history.append((time, image))
        if history.count > 3 { history.removeFirst(history.count - 3) }
        return result
    }
    var sourcePixelBufferAttributes: [String: Any]? = [
        kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_32BGRA, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
    ]
    var requiredPixelBufferAttributesForRenderContext: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
    ]
    private var renderContext: AVVideoCompositionRenderContext?

    /// Exposes the blending path to the checks, which have no AVFoundation
    /// request to drive it with.
    func blendForTesting(_ image: CIImage, at time: Double, settings: ExportSettings) -> CIImage {
        rememberAndBlend(image, at: time, settings: settings)
    }

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {
        renderContext = newRenderContext
        historyLock.lock(); history.removeAll(); scrollTimes = nil; historyLock.unlock()
    }

    func cancelAllPendingVideoCompositionRequests() {
        context.clearCaches()
        historyLock.lock(); history.removeAll(); scrollTimes = nil; historyLock.unlock()
    }

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        autoreleasepool {
            guard let instruction = request.videoCompositionInstruction as? CompositionInstruction,
                  let sourceBuffer = request.sourceFrame(byTrackID: instruction.screenTrackID),
                  let outputBuffer = renderContext?.newPixelBuffer() else {
                request.finish(with: ExportError.unavailable); return
            }
            let settings = instruction.settings
            let canvas = CGRect(origin: .zero, size: settings.canvasSize)
            let time = instruction.timeMap.sourceTime(for: request.compositionTime.seconds)
            var source = normalized(CIImage(cvPixelBuffer: sourceBuffer).transformed(by: instruction.screenTransform))
            // Applied to the recording only: the cursor and the window frame
            // are drawn later and must stay sharp.
            source = rememberAndBlend(source, at: request.compositionTime.seconds, sourceTime: time, settings: settings)
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
            let region: CGRect
            if spot.tracksSelection == true {
                let tracked = MotionEngine.selectionRegion(spot, at: time, samples: settings.pointerSamples)
                region = CGRect(x: source.extent.width * tracked.minX,
                                y: source.extent.height * (1 - tracked.maxY),
                                width: source.extent.width * tracked.width,
                                height: source.extent.height * tracked.height)
            } else {
                let w = source.extent.width * spot.regionWidth, h = source.extent.height * spot.regionHeight
                region = CGRect(x: source.extent.width * spot.x - w / 2, y: source.extent.height * (1 - spot.y) - h / 2, width: w, height: h)
            }
            let mask = CIFilter.roundedRectangleGenerator()
            mask.extent = region
            mask.radius = Float(min(region.width, region.height) * 0.18); mask.color = .white
            let feather = max(12, source.extent.width / 1920 * (18 + 82 * min(1, max(0, spot.spotlightFeather ?? 0.7))))
            let dimAlpha = strength * min(0.65, max(0, spot.spotlightOpacity ?? 0.24)) * min(1.4, max(0.5, spot.intensity))
            let dimmed = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: dimAlpha)).cropped(to: source.extent).composited(over: source)
            let softMask = mask.outputImage!.cropped(to: region.insetBy(dx: -feather * 4, dy: -feather * 4))
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: feather])
            source = source.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: dimmed, kCIInputMaskImageKey: softMask])
        }
        source = applySelectionHighlight(to: source, at: time, settings: settings)
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
            let zoomMotion = abs(next.width - previous.width) / max(0.01, viewport.width) * layout.content.width * 0.1
            // Measured as a share of the frame rather than in pixels. A
            // twelve pixel smear is nothing across a 4K frame and ruinous
            // across a small one, and it was the same twelve either way.
            // The ceiling is deliberately low: blur is detail thrown away,
            // and a moving frame needs only its hard edge taken off.
            let ceiling = layout.content.width * 0.0035
            let wanted = (hypot(dx, dy) * 0.12 + zoomMotion) * max(0, min(1, settings.motion.motionBlurStrength ?? 0.35))
            let radius = min(ceiling, wanted)
            // Below this it is invisible, and above the ceiling it is the
            // ceiling — so a fast move is softened, never smeared.
            if radius > ceiling * 0.12 && radius > 0.4 {
                source = source.clampedToExtent().applyingFilter("CIMotionBlur", parameters: [kCIInputRadiusKey: radius, kCIInputAngleKey: atan2(-dy, dx)]).cropped(to: layout.content)
            }
        }
        // A frame standing in space is resampled corner to corner later on,
        // and a resample is a small low-pass filter: text comes out of a
        // lean very slightly woolly even with every blur switched off. The
        // answer is to put the edges back before the warp takes them, while
        // the content is still a solid rectangle — sharpening afterwards
        // would work on the transparent surround too and rim the frame.
        let stance = MotionEngine.stance(at: time, segments: settings.segments)
        if settings.cameraMove.crisp != false {
            let depth = leaning(at: time, settings: settings, stance: stance, width: Double(layout.content.width))
            let sharpness = min(0.6, depth * 2.2)
            if sharpness > 0.03 {
                source = source.applyingFilter("CISharpenLuminance", parameters: [
                    "inputSharpness": sharpness,
                    kCIInputRadiusKey: max(1.0, Double(layout.content.width) / 1920 * 1.6),
                ]).cropped(to: layout.content)
            }
        }
        // Give the recording a small amount of parallax inside its window.
        // The full pose is applied to the composed window below, using the
        // same stance and timing, so both layers move together.
        var contentMove = settings.cameraMove
        contentMove.move = .none
        contentMove.pose = settings.cameraMove.pose.weighted(FramePose.contentParallax)
        var contentStance = stance
        contentStance.pose = stance.pose.weighted(FramePose.contentParallax)
        if settings.cameraMove.move != .none {
            // The older animated window effect owns its blur. A simultaneous
            // content pose should not apply that blur a second time.
            contentMove.blur = .none
            contentMove.focusBlur = 0
        }
        if contentMove.isActive || !contentStance.isNeutral {
            source = applyCameraMove(source, at: time, canvas: layout.content,
                                     settings: settings, move: contentMove,
                                     stance: contentStance, fillContent: true)
        }
        if let header = RenderAssets.header(settings.frame, rect: layout.header) { source = header.composited(over: source) }
        // Corners and shadow are written in the editor's own pixels, where
        // the canvas is 1920 across. They have to be read as a share of the
        // frame, or the same project would have rounder corners the smaller
        // it was exported — and the preview, which is composed at a size of
        // its own, would not match the file.
        let unit = canvas.width / 1920
        let rounded = CIFilter.roundedRectangleGenerator()
        rounded.extent = layout.outer; rounded.radius = Float(settings.cornerRadius * unit); rounded.color = .white
        let mask = rounded.outputImage!.cropped(to: canvas)
        let clear = CIImage(color: .clear).cropped(to: canvas)
        source = source.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: clear, kCIInputMaskImageKey: mask])
        if settings.shadow > 0 {
            let shadow = settings.shadow * unit
            let shade = mask.applyingFilter("CIColorMatrix", parameters: ["inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0.35)])
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: shadow])
                .transformed(by: CGAffineTransform(translationX: 0, y: -shadow / 3))
            source = source.composited(over: shade)
        }
        let motion = settings.motion
        let progress = MotionCurve.smooth.value((time - settings.trimStart) / max(0.1, motion.duration))
        // Move the frame, chrome, shadow and recorded content as one object.
        // Keep blur on the content for 3D poses; legacy window animations
        // retain their existing whole-window blur behaviour.
        if settings.cameraMove.isActive || !stance.pose.isNeutral {
            var windowMove = settings.cameraMove
            var windowStance = stance
            if settings.cameraMove.move == .none {
                windowMove.blur = .none; windowMove.focusBlur = 0
                windowStance.blur = .none; windowStance.amount = 0
            }
            source = applyCameraMove(source, at: time, canvas: canvas,
                                     settings: settings, move: windowMove,
                                     stance: windowStance)
        }
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
        // Graded before the background goes behind it: the background is the
        // user's own colour choice and should not take the wash.
        if !settings.grade.isIdentity { source = applyGrade(source, settings.grade, canvas: canvas) }
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
        // Last of all, so nothing is ever laid over the words — not the
        // camera, not the progress line, not a 3D lean.
        result = applyCaptions(to: result, at: time, settings: settings, canvas: canvas)
        return result.cropped(to: canvas)
    }

    /// The spoken line for this moment, over the finished frame.
    func applyCaptions(to image: CIImage, at time: Double, settings: ExportSettings, canvas: CGRect) -> CIImage {
        let captions = settings.captions
        guard captions.isVisible, let cue = captions.cue(at: time),
              let drawn = CaptionRenderer.render(cue: cue, at: time, settings: captions,
                                                 accent: settings.cursor.accentColor, canvas: canvas) else { return image }
        let motion = CaptionRenderer.motion(for: cue, at: time, animation: captions.animation)
        guard motion.opacity > 0.004 else { return image }

        var result = image
        let box = drawn.box.offsetBy(dx: 0, dy: motion.lift * drawn.box.height)
        // Softening the picture behind the words is the one backdrop that
        // cannot be drawn into the caption's own bitmap: it is made of what
        // is underneath it.
        if captions.backdrop == .blur {
            let region = box.insetBy(dx: -canvas.width * 0.004, dy: -canvas.height * 0.004).intersection(canvas)
            if !region.isEmpty {
                let radius = max(6, canvas.height * 0.016)
                var panel = image.clampedToExtent()
                    .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
                    .cropped(to: region)
                let tint = max(0, min(1, captions.backdropOpacity))
                if tint > 0.004 {
                    let wash = CIImage(color: CIColor(cgColor: CGColor(red: captions.backdropColor.r, green: captions.backdropColor.g, blue: captions.backdropColor.b, alpha: tint))).cropped(to: region)
                    panel = wash.composited(over: panel)
                }
                let radiusPx = min(region.height / 2, canvas.height * captions.size * captions.backdropRadius)
                if let mask = rounded(region, radius: radiusPx, color: CGColor(gray: 1, alpha: 1)) {
                    panel = panel.applyingFilter("CIBlendWithMask", parameters: [
                        kCIInputBackgroundImageKey: CIImage(color: .clear).cropped(to: region),
                        kCIInputMaskImageKey: mask])
                }
                result = opacity(panel, motion.opacity).composited(over: result)
            }
        }

        var placed = drawn.image.transformed(by: CGAffineTransform(translationX: box.minX, y: box.minY))
        if abs(motion.scale - 1) > 0.001 {
            // Grown about where it sits, so a line springs up in place
            // rather than drifting out of its own box.
            let centre = CGPoint(x: box.midX, y: box.midY)
            placed = placed.transformed(by: CGAffineTransform(translationX: centre.x, y: centre.y)
                .scaledBy(x: motion.scale, y: motion.scale)
                .translatedBy(x: -centre.x, y: -centre.y))
        }
        return opacity(placed, motion.opacity).composited(over: result).cropped(to: canvas)
    }

    /// Applies the chosen look: colour controls, a tint wash, exposure and a
    /// vignette. The frame's alpha is used as the mask for the wash, so the
    /// rounded corners and the shadow behind them survive.
    private func applyGrade(_ image: CIImage, _ settings: GradeSettings, canvas: CGRect) -> CIImage {
        var result = image
        let grade = settings.grade
        let controls = grade.controls

        let contrast = max(0.2, controls.contrast * max(0.1, settings.contrast))
        result = result.applyingFilter("CIColorControls", parameters: [
            kCIInputSaturationKey: controls.saturation,
            kCIInputContrastKey: contrast,
            kCIInputBrightnessKey: controls.brightness,
        ])

        if settings.exposure != 0 {
            result = result.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: settings.exposure])
        }

        if let tint = grade.tint, tint.amount > 0 {
            let wash = CIImage(color: CIColor(red: tint.r, green: tint.g, blue: tint.b, alpha: 1))
                .cropped(to: result.extent)
            let masked = wash.applyingFilter("CIBlendWithAlphaMask", parameters: [
                kCIInputBackgroundImageKey: CIImage(color: .clear).cropped(to: result.extent),
                kCIInputMaskImageKey: result,
            ])
            result = opacity(masked, tint.amount).composited(over: result)
        }

        if grade.bloom > 0 {
            result = result.applyingFilter("CIBloom", parameters: [
                kCIInputRadiusKey: max(canvas.width, canvas.height) / 180,
                kCIInputIntensityKey: grade.bloom,
            ]).cropped(to: result.extent)
        }

        if settings.vignette > 0 {
            result = result.applyingFilter("CIVignetteEffect", parameters: [
                kCIInputCenterKey: CIVector(x: result.extent.midX, y: result.extent.midY),
                kCIInputRadiusKey: max(result.extent.width, result.extent.height) * 0.62,
                kCIInputIntensityKey: settings.vignette * 1.8,
                "inputFalloff": 0.5,
            ]).cropped(to: result.extent)
        }

        return result
    }

    /// Projects either the recorded content or a legacy whole-window move.
    ///
    /// `CIPerspectiveTransform` maps the four corners of the image onto an
    /// arbitrary quad, which is exactly a tilt: pull one edge in and push the
    /// other out and the frame recedes. The receding edge is then softened
    /// with a graduated blur, so the depth reads as depth rather than as a
    /// skewed rectangle.
    private func applyCameraMove(_ image: CIImage, at time: Double, canvas: CGRect,
                                 settings: ExportSettings,
                                 move: CameraMoveSettings,
                                 stance: MotionEngine.FrameStance = MotionEngine.FrameStance(),
                                 fillContent: Bool = false) -> CIImage {
        let elapsed = time - settings.trimStart
        guard elapsed >= 0 else { return image }

        let frame = fillContent ? image.extent : canvas
        guard frame.width > 1, frame.height > 1 else { return image }
        let playing = move.performance(at: elapsed, clip: settings.trimEnd - settings.trimStart, width: Double(frame.width))
        if playing.settled, !move.isPlaced, !move.hasStandaloneBlur, stance.isNeutral { return image }
        let scale = playing.scale, shiftX = playing.shiftX

        // Turning and leaning by hand, on top of whatever the move is doing.
        // Where the frame stands, plus whatever the timeline is leaning it
        // to. The corners themselves are worked out by the shared geometry,
        // so the handles drawn over the preview sit on the same quad.
        let placed = move.pose.added(stance.pose)
        let lean = placed.lean(adding: playing.lean)
        let quad = placed.projection(of: frame, canvas: canvas, lean: lean,
                                     scale: scale, shiftX: shiftX)

        var result: CIImage
        if fillContent && placed.isNeutral {
            // A blur with no 3D pose needs no perspective resampling.
            result = image
        } else {
            // Corners run bottom-left, bottom-right, top-right, top-left.
            let perspective = CIFilter.perspectiveTransform()
            if fillContent {
                // Extend edge pixels before projecting, then crop back to the
                // window's content opening. This prevents transparent wedges.
                let overscan = max(0.22, min(1.5,
                    abs(placed.yaw) * 0.42 + abs(placed.pitch) * 0.34 +
                    abs(placed.panX) * 0.7 + abs(placed.panY) * 0.7 +
                    max(0, 1 - placed.zoom) * 1.4))
                let expanded = frame.insetBy(dx: -frame.width * overscan,
                                             dy: -frame.height * overscan)
                let extendedQuad = ProjectiveMap(frame, to: quad).quad(of: expanded)
                perspective.inputImage = image.clampedToExtent().cropped(to: expanded)
                perspective.bottomLeft = extendedQuad.bottomLeft
                perspective.bottomRight = extendedQuad.bottomRight
                perspective.topRight = extendedQuad.topRight
                perspective.topLeft = extendedQuad.topLeft
            } else {
                // The shadow may extend beyond the canvas. Carry its full
                // image extent through the same canvas projection rather
                // than letting it change the frame's perspective geometry.
                let imageQuad = ProjectiveMap(frame, to: quad).quad(of: image.extent)
                perspective.inputImage = image
                perspective.bottomLeft = imageQuad.bottomLeft
                perspective.bottomRight = imageQuad.bottomRight
                perspective.topRight = imageQuad.topRight
                perspective.topLeft = imageQuad.topLeft
            }
            guard let projected = perspective.outputImage else { return image }
            result = projected
        }

        if fillContent {
            result = result.cropped(to: frame)
            // The original recording is the rear plane. At an extreme turn
            // the projected plane can reveal a sliver of it; keep that real
            // content visible instead of a transparent hole to the canvas.
            if !placed.isNeutral { result = result.composited(over: image).cropped(to: frame) }
            // A restrained falloff on the receding side gives the moving
            // picture a light cue while leaving the chrome and text sharp.
            let depth = min(1, abs(placed.yaw) + abs(placed.pitch))
            if depth > 0.04 {
                let gradient = CIFilter.linearGradient()
                let directionX = placed.yaw / depth, directionY = placed.pitch / depth
                gradient.point0 = CGPoint(x: frame.midX - directionX * frame.width * 0.5,
                                          y: frame.midY - directionY * frame.height * 0.5)
                gradient.point1 = CGPoint(x: frame.midX + directionX * frame.width * 0.5,
                                          y: frame.midY + directionY * frame.height * 0.5)
                gradient.color0 = .clear
                gradient.color1 = CIColor(red: 0, green: 0, blue: 0, alpha: min(0.11, depth * 0.08))
                if let shade = gradient.outputImage?.cropped(to: frame) {
                    result = shade.composited(over: result).cropped(to: frame)
                }
            }
        }

        // A blur asked for on the timeline is this moment's; the panel's is
        // the standing one.
        let timelineBlur = stance.blur != .none && stance.amount > 0.01
        let strength = max(0, min(1, timelineBlur ? stance.amount : move.focusBlur))
        let angle = timelineBlur ? stance.angle : move.blurAngle
        switch timelineBlur ? stance.blur : move.blur {
        case .none: return result
        case .radial:
            guard strength > 0.01 else { return result }
            return result.clampedToExtent().applyingFilter("CIZoomBlur", parameters: [
                kCIInputCenterKey: CIVector(x: canvas.midX, y: canvas.midY),
                "inputAmount": max(1, Double(frame.width) / 1920 * 42 * strength),
            ]).cropped(to: result.extent)
        case .directional:
            guard strength > 0.01 else { return result }
            return result.clampedToExtent().applyingFilter("CIMotionBlur", parameters: [
                kCIInputRadiusKey: max(1, Double(frame.width) / 1920 * 32 * strength),
                kCIInputAngleKey: angle * .pi / 180,
            ]).cropped(to: result.extent)
        case .tiltShift:
            guard strength > 0.01 else { return result }
            return tiltShifted(result, strength: strength, focus: move.blurFocus, band: move.blurBand)
        case .depth:
            break
        }

        // Depth of field across the receding axis. Skipped when there is no
        // lean to justify it, since a graduated blur is not cheap.
        if strength > 0.01 && lean.depth > 0.004 {
            let radius = max(1.0, min(14.0, Double(frame.width) / 1920 * 13 * strength))
            let gradient = CIFilter.linearGradient()
            // Sharp where the frame is nearest, soft where it recedes.
            let recedingRight = lean.right >= lean.left
            gradient.point0 = CGPoint(x: recedingRight ? result.extent.minX : result.extent.maxX, y: result.extent.midY)
            gradient.point1 = CGPoint(x: recedingRight ? result.extent.maxX : result.extent.minX, y: result.extent.midY)
            // White keeps the frame sharp under CIBlendWithMask, so the near
            // edge is white and the receding one black. (The opposite of what
            // CIMaskedVariableBlur wanted, where white meant more blur.)
            gradient.color0 = CIColor(red: 1, green: 1, blue: 1)
            gradient.color1 = CIColor(red: 0, green: 0, blue: 0)
            if let mask = gradient.outputImage?.cropped(to: result.extent) {
                // Blur once and fade it in through the gradient, rather than
                // CIMaskedVariableBlur, which evaluates a different radius per
                // pixel and costs many times more for the same look.
                let blurred = result.clampedToExtent()
                    .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
                    .cropped(to: result.extent)
                result = result.applyingFilter("CIBlendWithMask", parameters: [
                    kCIInputBackgroundImageKey: blurred,
                    kCIInputMaskImageKey: mask,
                ]).cropped(to: result.extent)
            }
        }

        return result
    }

    /// A sharp band across the frame with soft ground above and below it,
    /// which is what a tilted lens does and why a scene shot through one
    /// reads as a model of itself.
    private func tiltShifted(_ image: CIImage, strength: Double, focus: Double, band: Double) -> CIImage {
        let extent = image.extent
        guard extent.height > 2 else { return image }
        let centre = extent.minY + extent.height * max(0, min(1, focus))
        let half = extent.height * max(0.02, min(0.9, band)) / 2
        let feather = max(2, extent.height * 0.12)
        let white = CIColor(red: 1, green: 1, blue: 1), black = CIColor(red: 0, green: 0, blue: 0)

        func edge(from: Double, to: Double) -> CIImage? {
            let gradient = CIFilter.linearGradient()
            gradient.point0 = CGPoint(x: extent.midX, y: from)
            gradient.point1 = CGPoint(x: extent.midX, y: to)
            gradient.color0 = white
            gradient.color1 = black
            return gradient.outputImage?.cropped(to: extent)
        }
        // White inside the band: under CIBlendWithMask white keeps the sharp
        // frame, so the two falls to black are what softens.
        guard let below = edge(from: centre - half, to: centre - half - feather),
              let above = edge(from: centre + half, to: centre + half + feather) else { return image }
        let mask = below.applyingFilter("CIDarkenBlendMode", parameters: [kCIInputBackgroundImageKey: above])

        let blurred = image.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: max(1.0, Double(extent.width) / 1920 * 22 * strength)])
            .cropped(to: extent)
        return image.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: blurred,
            kCIInputMaskImageKey: mask,
        ]).cropped(to: extent)
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
        rounded.radius = Float(settings.cameraShape == .circle ? height / 2 : min(height / 2, settings.cameraCornerRadius * canvas.width / 1920))
        rounded.color = .white
        let transparent = CIImage(color: .clear).cropped(to: canvas)
        let clipped = camera.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: transparent,
            kCIInputMaskImageKey: rounded.outputImage?.cropped(to: canvas) ?? CIImage(color: .white).cropped(to: target)
        ])
        return clipped.composited(over: background).cropped(to: canvas)
    }

    /// How far the frame is leaning at this moment, as a fraction of its
    /// width — the pose, plus whatever a playing move is adding.
    private func leaning(at time: Double, settings: ExportSettings,
                         stance: MotionEngine.FrameStance, width: Double) -> Double {
        let move = settings.cameraMove
        guard move.isActive || !stance.isNeutral else { return 0 }
        let playing = move.performance(at: time - settings.trimStart,
                                       clip: settings.trimEnd - settings.trimStart, width: width)
        return move.pose.added(stance.pose).lean(adding: playing.lean).depth
    }

    /// A wash over the text someone is selecting, following the range as
    /// it grows. An application's own selection colour is often a pale
    /// blue that all but disappears once a recording is scaled down.
    private func applySelectionHighlight(to image: CIImage, at time: Double, settings: ExportSettings) -> CIImage {
        guard settings.selectionFocus.highlight else { return image }
        let extent = image.extent
        let unit = extent.width / 1920
        let opacity = max(0, min(1, settings.selectionFocus.highlightOpacity))
        guard opacity > 0.01 else { return image }
        var result = image

        for segment in settings.segments where segment.selectionStartTime != nil && segment.selectionEndTime != nil {
            let strength = MotionEngine.envelope(segment, time: time)
            guard strength > 0.01 else { continue }
            let range = MotionEngine.selectedRange(segment, at: time, samples: settings.pointerSamples)
            let line = max(10, 34 * unit)
            // A drag along one line has no height of its own, so it is
            // given a line's worth; a drag down a paragraph keeps its own.
            // Frame coordinates run down the picture and image ones run up
            // it, so the range's bottom edge is the larger y.
            let bottom = (1 - range.maxY) * extent.height - line * 0.5
            let top = (1 - range.minY) * extent.height + line * 0.5
            let box = CGRect(x: range.minX * extent.width - line * 0.12,
                             y: bottom,
                             width: max(line * 0.4, range.width * extent.width + line * 0.24),
                             height: max(line, top - bottom))
            guard let wash = rounded(box, radius: min(box.height / 2, line * 0.28), color: settings.cursor.accentColor) else { continue }
            result = self.opacity(wash, strength * opacity).composited(over: result)
        }
        return result.cropped(to: extent)
    }

    /// A filled, rounded rectangle in one colour — the shape every one of
    /// these graphics is made of.
    private func rounded(_ rect: CGRect, radius: Double, color: CGColor) -> CIImage? {
        guard rect.width > 0.5, rect.height > 0.5 else { return nil }
        let filter = CIFilter.roundedRectangleGenerator()
        filter.extent = rect
        filter.radius = Float(max(0, min(radius, Double(min(rect.width, rect.height)) / 2)))
        filter.color = CIColor(cgColor: color)
        return filter.outputImage?.cropped(to: rect)
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
        // A comet behind a pointer that is travelling, and nothing behind
        // one that is still. Thirty frames a second turns a fast move into
        // a pointer that was here and is suddenly there; a trail is what
        // says it crossed the distance.
        if settings.showCursor, settings.cursor.trail == true,
           let pointer = CursorMotion.sample(at: time, samples: settings.pointerSamples, smoothed: settings.smoothCursor),
           let glow = RenderAssets.highlight(accent: settings.cursor.accentColor, key: settings.cursor.accentKey) {
            let unit = target.width / 1920
            let span = 0.1 + 0.26 * max(0, min(1, settings.cursor.trailLength ?? 0.5))
            let strength = max(0, min(1, settings.cursor.trailOpacity ?? 0.3))
            let steps = 12
            for step in 1...steps {
                let share = Double(step) / Double(steps)
                guard let past = CursorMotion.sample(at: time - span * share, samples: settings.pointerSamples, smoothed: true) else { continue }
                // Only where it actually moved: a still pointer would
                // otherwise pile its own trail up underneath itself.
                let travelled = hypot(past.x - pointer.x, past.y - pointer.y)
                guard travelled > 0.002 else { continue }
                let size = 78 * unit * settings.cursorSize * 0.45 * (1 - share * 0.5)
                let placed = glow
                    .transformed(by: CGAffineTransform(scaleX: size / glow.extent.width, y: size / glow.extent.height))
                    .transformed(by: CGAffineTransform(translationX: past.x * target.width - size / 2,
                                                       y: (1 - past.y) * target.height - size / 2))
                // Thinning towards the tail, and towards a pointer that is
                // barely moving, so the comet is as long as the move was.
                result = opacity(placed, strength * pow(1 - share * 0.75, 1.6) * min(1, travelled * 25)).composited(over: result)
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
        if settings.showCursor, let pointer = CursorMotion.sample(at: time, samples: settings.pointerSamples, smoothed: settings.smoothCursor) {
            // Automatic means the shape the system reported, except while
            // text is being written, where it is a text cursor whatever the
            // pointer happened to be resting over.
            let automatic = settings.cursor.shape == nil || settings.cursor.shape == .automatic
            let typing = MotionEngine.isTyping(at: time, segments: settings.segments)
            let resolvedShape = automatic ? (typing ? .text : pointer.shape ?? .arrow) : settings.cursor.shape!
            guard let cursor = RenderAssets.cursor(settings.cursor, shape: resolvedShape) else { return result.cropped(to: image.extent) }
            // A ring, a dot or someone's own artwork is the pointer
            // whatever the system said was under it, and it is drawn at
            // the same three-times scale as the arrow rather than at
            // system size.
            let style = settings.cursor.style
            let drawnMark = style.isMark
            let ownArtwork = style == .custom && RenderAssets.custom(path: settings.cursor.customImagePath ?? "") != nil
            let isText = resolvedShape == .text && !drawnMark && !ownArtwork
            let isSystem = !drawnMark && !ownArtwork && (style == .macOS || style == .custom || isText)
            // The I-beam is a thin glyph and reads much smaller than the arrow
            // at the same scale, so it carries its own multiplier.
            let shapeScale = settings.cursorSize * (isText ? max(0.1, settings.cursor.textScale) : 1)
            var scale = isSystem ? settings.cursorPointScale * shapeScale : target.width / 1920 * shapeScale / 3
            if settings.clickEffects, let click {
                let age = (time - click.time) / 0.42
                if age < 1 { scale *= 1 - 0.22 * exp(-age * 10) + 0.15 * sin(age * .pi) }
            }
            // Swells while it travels and settles when it arrives, so the
            // eye is carried along with the move rather than having to
            // find where the pointer stopped.
            if settings.cursor.swell == true,
               let before = CursorMotion.sample(at: time - 0.06, samples: settings.pointerSamples, smoothed: true),
               let after = CursorMotion.sample(at: time + 0.06, samples: settings.pointerSamples, smoothed: true) {
                let speed = hypot(after.x - before.x, after.y - before.y) / 0.12
                scale *= 1 + min(1, speed / 1.6) * max(0, min(1, settings.cursor.swellAmount ?? 0.3))
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
