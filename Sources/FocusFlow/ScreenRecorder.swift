import AppKit
import AVFoundation
import CoreMedia
import CoreImage
import ScreenCaptureKit

enum CaptureTarget {
    case display(SCDisplay)
    case window(SCWindow)

    var name: String {
        switch self {
        case .display: "Entire display"
        case .window(let window): window.title ?? window.owningApplication?.applicationName ?? "Selected window"
        }
    }
}

enum RecorderError: LocalizedError {
    case noDisplay, missingWindow, writerFailed, noFrames, unreadableOutput, microphoneUnsupported
    var errorDescription: String? {
        switch self {
        case .noDisplay: "No display is available to record."
        case .missingWindow: "The selected window has closed. Choose it again before recording."
        case .writerFailed: "The video writer could not be created."
        case .noFrames: "No screen frames were captured. Check Screen Recording permission in System Settings."
        case .unreadableOutput: "The recording was written, but macOS could not read it back."
        case .microphoneUnsupported: "Microphone capture requires macOS 15 or newer."
        }
    }
}

final class ScreenRecorder: NSObject, ObservableObject, SCStreamOutput, SCStreamDelegate {
    @Published private(set) var previewImage: CGImage?
    private let previewContext = CIContext(options: [.cacheIntermediates: false])
    private var lastPreviewPTS = -Double.infinity
    @Published private(set) var isRecording = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var errorMessage: String?

    private let captureQueue = DispatchQueue(label: "app.focusflow.capture", qos: .userInteractive)
    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var microphoneInput: AVAssetWriterInput?
    private var startedSession = false
    private var firstPTS: CMTime?
    private var timer: Timer?
    private var pointerTimer: Timer?
    private var keyPresses: KeyPressTap?
    private(set) var clicks: [RecordedClick] = []
    private(set) var typingEvents: [TypingEvent] = []
    private(set) var scrollEvents: [ScrollEvent] = []
    private(set) var pointerSamples: [PointerSample] = []
    private(set) var keystrokes: [KeystrokeEvent] = []
    private(set) var sourceSize = CGSize.zero
    private(set) var sourcePointSize = CGSize.zero
    private(set) var sourceName = ""
    private var captureFrame = CGRect.zero
    private var captureRegion = ContentRegion.full
    private var relativeCaptureRect = CGRect.zero
    private var recordingStart = Date()
    private(set) var firstFrameDate: Date?
    private var didRebaseToFirstFrame = false
    private var targetPID: pid_t?
    private var targetWindowID: CGWindowID?
    private var lastFrameUpdate = Date.distantPast
    private var lastLeftButtonDown = false
    private var outputURL: URL?

    /// The pixel size a capture should be made at.
    ///
    /// A display and a window both report their size in points. A MacBook's
    /// built-in screen is 1512 x 982 of them and 3024 x 1964 pixels, so
    /// asking ScreenCaptureKit for the point size recorded the Mac at half
    /// its resolution — every pixel of detail thrown away before the editor
    /// ever saw it, and nothing downstream could put it back.
    static func capturePixels(points: CGSize, scale: CGFloat) -> CGSize {
        let scale = scale.isFinite && scale > 0 ? scale : 1
        // H.264 and HEVC both reject odd dimensions.
        return CGSize(width: max(2, (points.width * scale / 2).rounded() * 2),
                      height: max(2, (points.height * scale / 2).rounded() * 2))
    }

    /// How the capture itself is encoded.
    ///
    /// The rate scales with the frame rate as well as the frame, which the
    /// flat per-pixel figure this replaced did not: a Retina display at 60
    /// fps carries four times the pixels of the 1080p30 this was tuned for
    /// and was being written at a third of the bits per pixel. Screen
    /// content is flat colour and hard edges, and edges are the first thing
    /// a mean bitrate softens, so it is generous by camera standards.
    static func captureSettings(width: Int, height: Int, frameRate: Int) -> [String: Any] {
        let pixels = Double(width) * Double(height)
        // H.264's levels top out around 4096 on a side, and the hardware
        // encoder refuses beyond that — which a 6K display would be.
        let overSized = max(width, height) > 4096
        let codec: AVVideoCodecType = overSized ? .hevc : .h264
        let perPixel = overSized ? 0.085 : 0.12
        let bitrate = min(150_000_000, max(8_000_000, pixels * Double(frameRate) * perPixel))
        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: Int(bitrate),
            AVVideoExpectedSourceFrameRateKey: frameRate,
            AVVideoMaxKeyFrameIntervalKey: frameRate * 2,
        ]
        if !overSized { compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel }
        return [
            AVVideoCodecKey: codec,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: compression,
        ]
    }

    @MainActor
    func start(target: CaptureTarget? = nil, region: ContentRegion = .full, capturesAudio: Bool = true, capturesMicrophone: Bool = false, frameRate: Int = 60) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let fallbackDisplay = content.displays.first else { throw RecorderError.noDisplay }
        let resolvedTarget: CaptureTarget
        switch target {
        case .window(let previous):
            guard let current = content.windows.first(where: { $0.windowID == previous.windowID }) else { throw RecorderError.missingWindow }
            resolvedTarget = .window(current)
        case .display(let previous):
            guard let current = content.displays.first(where: { $0.displayID == previous.displayID }) else { throw RecorderError.noDisplay }
            resolvedTarget = .display(current)
        case nil: resolvedTarget = .display(fallbackDisplay)
        }

        let directory = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FocusFlow", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss.SSS"
        let url = directory.appendingPathComponent("Recording \(formatter.string(from: Date())).mp4")
        try? FileManager.default.removeItem(at: url)

        let assetWriter = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let filter: SCContentFilter
        var width: Int
        var height: Int
        targetPID = nil; targetWindowID = nil
        firstFrameDate = nil
        typingEvents = []
        scrollEvents = []
        switch resolvedTarget {
        case .display(let display):
            filter = SCContentFilter(display: display, excludingApplications: content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }, exceptingWindows: [])
            let pixels = Self.capturePixels(points: display.frame.size, scale: CGFloat(filter.pointPixelScale))
            width = Int(pixels.width); height = Int(pixels.height)
            captureFrame = display.frame
        case .window(let window):
            targetPID = window.owningApplication?.processID; targetWindowID = window.windowID
            filter = SCContentFilter(desktopIndependentWindow: window)
            let pixels = Self.capturePixels(points: window.frame.size, scale: CGFloat(filter.pointPixelScale))
            width = Int(pixels.width); height = Int(pixels.height)
            captureFrame = window.frame
        }
        let fullSize = CGSize(width: width, height: height)
        let pixelCrop = region.pixelRect(in: fullSize)
        captureRegion = ContentRegion(x: pixelCrop.minX / fullSize.width, y: pixelCrop.minY / fullSize.height, width: pixelCrop.width / fullSize.width, height: pixelCrop.height / fullSize.height)
        let sourceRect = captureRegion.rect(in: captureFrame.size)
        relativeCaptureRect = sourceRect
        sourcePointSize = sourceRect.size
        captureFrame = sourceRect.offsetBy(dx: captureFrame.minX, dy: captureFrame.minY)
        width = Int(pixelCrop.width); height = Int(pixelCrop.height)
        sourceSize = CGSize(width: width, height: height)
        sourceName = resolvedTarget.name + (region == .full ? "" : " · Selected area")
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: Self.captureSettings(width: width, height: height, frameRate: frameRate))
        video.expectsMediaDataInRealTime = true
        guard assetWriter.canAdd(video) else { throw RecorderError.writerFailed }
        assetWriter.add(video)

        var systemAudio: AVAssetWriterInput?
        if capturesAudio {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 192_000
            ])
            input.expectsMediaDataInRealTime = true
            if assetWriter.canAdd(input) { assetWriter.add(input); systemAudio = input }
        }
        var microphoneAudio: AVAssetWriterInput?
        if capturesMicrophone {
            guard #available(macOS 15.0, *) else { throw RecorderError.microphoneUnsupported }
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 128_000
            ])
            input.expectsMediaDataInRealTime = true
            if assetWriter.canAdd(input) { assetWriter.add(input); microphoneAudio = input }
        }

        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        if region != .full { config.sourceRect = sourceRect }
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(frameRate))
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.queueDepth = 6
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        config.scalesToFit = true
        config.excludesCurrentProcessAudio = true
        config.capturesAudio = capturesAudio
        config.sampleRate = 48_000
        config.channelCount = 2
        if #available(macOS 15.0, *) { config.captureMicrophone = capturesMicrophone }

        let capture = SCStream(filter: filter, configuration: config, delegate: self)
        try capture.addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue)
        if capturesAudio { try capture.addStreamOutput(self, type: .audio, sampleHandlerQueue: captureQueue) }
        if capturesMicrophone, #available(macOS 15.0, *) {
            try capture.addStreamOutput(self, type: .microphone, sampleHandlerQueue: captureQueue)
        }

        writer = assetWriter
        videoInput = video
        audioInput = systemAudio
        microphoneInput = microphoneAudio
        stream = capture
        outputURL = url
        clicks = []
        pointerSamples = []
        keystrokes = []
        startedSession = false
        firstPTS = nil
        errorMessage = nil
        guard assetWriter.startWriting() else { throw assetWriter.error ?? RecorderError.writerFailed }
        do { try await capture.startCapture() }
        catch { assetWriter.cancelWriting(); self.stream = nil; self.writer = nil; try? FileManager.default.removeItem(at: url); throw error }
        lastPreviewPTS = -Double.infinity
        isRecording = true
        elapsed = 0
        // Provisional: the video's zero is the first frame, which has not
        // arrived yet. Everything stamped before it is rebased below.
        recordingStart = Date()
        didRebaseToFirstFrame = false
        lastLeftButtonDown = false
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.elapsed = Date().timeIntervalSince(self.recordingStart)
            }
        }
        pointerTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.samplePointerAndClicks() }
        }
        keyPresses = KeyPressTap { [weak self] event in
            self?.recordKeystroke(event)
        } onScroll: { [weak self] _ in
            self?.recordScroll()
        }
    }

    @MainActor
    func stop() async throws -> URL {
        guard let stream, let writer, let url = outputURL else { throw RecorderError.noFrames }
        timer?.invalidate()
        timer = nil
        pointerTimer?.invalidate()
        pointerTimer = nil
        keyPresses?.invalidate(); keyPresses = nil
        defer { self.stream = nil; self.writer = nil; isRecording = false }
        try? await stream.stopCapture()
        isRecording = false
        await withCheckedContinuation { continuation in
            captureQueue.async { continuation.resume() }
        }
        guard startedSession else { writer.cancelWriting(); try? FileManager.default.removeItem(at: url); throw RecorderError.noFrames }
        videoInput?.markAsFinished()
        audioInput?.markAsFinished()
        microphoneInput?.markAsFinished()
        await writer.finishWriting()
        self.stream = nil
        guard writer.status == .completed else {
            throw writer.error ?? RecorderError.noFrames
        }
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard (values.fileSize ?? 0) > 0 else { throw RecorderError.noFrames }
        let savedAsset = AVURLAsset(url: url)
        guard (try? await savedAsset.load(.isPlayable)) == true else { throw RecorderError.unreadableOutput }
        return url
    }

    /// Shifts everything captured before the first video frame onto the
    /// video's own clock. Runs once, on the few samples taken during startup.
    @MainActor
    private func rebaseTimeline(to firstFrame: Date) {
        guard !didRebaseToFirstFrame else { return }
        didRebaseToFirstFrame = true
        let delta = firstFrame.timeIntervalSince(recordingStart)
        recordingStart = firstFrame
        guard delta > 0.001 else { return }

        // A sample taken before the first frame has no frame to sit on, so it
        // is dropped rather than clamped onto zero where it would pile up.
        pointerSamples = pointerSamples.compactMap { sample in
            let time = sample.time - delta
            return time >= 0 ? PointerSample(time: time, x: sample.x, y: sample.y, shape: sample.shape) : nil
        }
        clicks = clicks.compactMap { click in
            let time = click.time - delta
            return time >= 0 ? RecordedClick(time: time, x: click.x, y: click.y) : nil
        }
        keystrokes = keystrokes.compactMap { key in
            let time = key.time - delta
            return time >= 0 ? KeystrokeEvent(time: time, text: key.text) : nil
        }
        typingEvents = typingEvents.compactMap { event in
            let time = event.time - delta
            return time >= 0 ? TypingEvent(time: time) : nil
        }
        scrollEvents = scrollEvents.compactMap { event in
            let time = event.time - delta
            return time >= 0 ? ScrollEvent(time: time) : nil
        }
    }

    @MainActor
    private func samplePointerAndClicks() {
        guard isRecording, let event = CGEvent(source: nil) else { return }
        if let targetPID, NSWorkspace.shared.frontmostApplication?.processIdentifier != targetPID { return }
        if let targetWindowID, Date().timeIntervalSince(lastFrameUpdate) > 0.25 {
            lastFrameUpdate = Date()
            if let info = (CGWindowListCopyWindowInfo(.optionIncludingWindow, targetWindowID) as? [[String: Any]])?.first,
               let bounds = info[kCGWindowBounds as String] as? [String: Any],
               let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary) {
                captureFrame = captureRegion == .full ? frame : relativeCaptureRect.offsetBy(dx: frame.minX, dy: frame.minY)
            }
        }
        let location = event.location
        guard captureFrame.contains(location) else {
            lastLeftButtonDown = CGEventSource.buttonState(.combinedSessionState, button: .left)
            return
        }
        let x = min(1, max(0, (location.x - captureFrame.minX) / max(captureFrame.width, 1)))
        let y = min(1, max(0, (location.y - captureFrame.minY) / max(captureFrame.height, 1)))
        let t = Date().timeIntervalSince(recordingStart)
        let down = CGEventSource.buttonState(.combinedSessionState, button: .left)
        pointerSamples.append(PointerSample(time: t, x: x, y: y, shape: SystemCursorShape.current(), pressed: down))
        if down && !lastLeftButtonDown {
            clicks.append(RecordedClick(time: t, x: x, y: y))
        }
        lastLeftButtonDown = down
    }

    /// Momentum scrolling arrives dozens of times a second and all that is
    /// wanted is the shape of the run, so the wheel is sampled rather than
    /// transcribed.
    private func recordScroll() {
        guard isRecording else { return }
        if let targetPID, NSWorkspace.shared.frontmostApplication?.processIdentifier != targetPID { return }
        let time = Date().timeIntervalSince(recordingStart)
        guard time - (scrollEvents.last?.time ?? -1) > 0.05 else { return }
        scrollEvents.append(ScrollEvent(time: time))
    }

    private func recordKeystroke(_ event: NSEvent) {
        guard isRecording else { return }
        if let targetPID, NSWorkspace.shared.frontmostApplication?.processIdentifier != targetPID { return }

        // That a key was pressed, and when. Following typing needs to know it
        // is happening; it does not need to know what was written, so no
        // character and no key code is kept — only the instant.
        if event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            typingEvents.append(TypingEvent(time: Date().timeIntervalSince(recordingStart)))
        }

        // Store shortcut badges only; never collect ordinary typed text.
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty == false,
              let characters = event.charactersIgnoringModifiers, !characters.isEmpty else { return }
        var parts: [String] = []
        if event.modifierFlags.contains(.command) { parts.append("⌘") }
        if event.modifierFlags.contains(.option) { parts.append("⌥") }
        if event.modifierFlags.contains(.control) { parts.append("⌃") }
        if event.modifierFlags.contains(.shift), characters.count == 1 { parts.append("⇧") }
        let named: String
        switch event.keyCode {
        case 36: named = "↩"
        case 48: named = "Tab"
        case 49: named = "Space"
        case 51: named = "⌫"
        case 53: named = "Esc"
        case 123: named = "←"
        case 124: named = "→"
        case 125: named = "↓"
        case 126: named = "↑"
        default: named = characters.uppercased()
        }
        parts.append(named)
        let stroke = KeystrokeEvent(time: Date().timeIntervalSince(recordingStart), text: parts.joined())
        DispatchQueue.main.async { [weak self] in self?.keystrokes.append(stroke) }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            self?.timer?.invalidate()
            self?.pointerTimer?.invalidate()
            self?.keyPresses?.invalidate()
            self?.keyPresses = nil
            self?.errorMessage = error.localizedDescription
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard sampleBuffer.isValid, CMSampleBufferDataIsReady(sampleBuffer), let writer else { return }
        let pts = sampleBuffer.presentationTimeStamp
        if outputType == .screen {
            guard isCompleteFrame(sampleBuffer) else { return }
            if pts.seconds - lastPreviewPTS >= 0.1, let buffer = sampleBuffer.imageBuffer {
                lastPreviewPTS = pts.seconds
                let source = CIImage(cvPixelBuffer: buffer)
                let scaled = source.transformed(by: CGAffineTransform(scaleX: 800 / source.extent.width, y: 800 / source.extent.width))
                if let image = previewContext.createCGImage(scaled, from: scaled.extent) {
                    DispatchQueue.main.async { [weak self] in self?.previewImage = image }
                }
            }
            if !startedSession {
                let arrived = Date()
                firstFrameDate = arrived
                writer.startSession(atSourceTime: pts)
                firstPTS = pts
                startedSession = true
                // ScreenCaptureKit takes a moment to deliver its first frame.
                // Until now samples were timed from the capture request, which
                // is earlier than the video's zero, so the drawn cursor
                // trailed the real one by that gap. Rebase onto the frame.
                Task { @MainActor [weak self] in self?.rebaseTimeline(to: arrived) }
            }
            if videoInput?.isReadyForMoreMediaData == true { videoInput?.append(sampleBuffer) }
        } else if outputType == .audio, startedSession, audioInput?.isReadyForMoreMediaData == true {
            audioInput?.append(sampleBuffer)
        } else if #available(macOS 15.0, *), outputType == .microphone, startedSession, microphoneInput?.isReadyForMoreMediaData == true {
            microphoneInput?.append(sampleBuffer)
        }
    }

    private func isCompleteFrame(_ sample: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let statusRaw = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: statusRaw) else { return false }
        return status == .complete
    }
}

extension CMTime {
    static func - (lhs: CMTime, rhs: CMTime) -> CMTime { CMTimeSubtract(lhs, rhs) }
}
