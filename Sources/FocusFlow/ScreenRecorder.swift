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
    private var monitor: Any?
    private(set) var clicks: [RecordedClick] = []
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
    private var targetPID: pid_t?
    private var targetWindowID: CGWindowID?
    private var lastFrameUpdate = Date.distantPast
    private var lastLeftButtonDown = false
    private var outputURL: URL?

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
        switch resolvedTarget {
        case .display(let display):
            filter = SCContentFilter(display: display, excludingApplications: content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }, exceptingWindows: [])
            width = max(2, display.width / 2 * 2)
            height = max(2, display.height / 2 * 2)
            captureFrame = display.frame
        case .window(let window):
            targetPID = window.owningApplication?.processID; targetWindowID = window.windowID
            filter = SCContentFilter(desktopIndependentWindow: window)
            let scale = CGFloat(filter.pointPixelScale)
            width = max(2, Int(window.frame.width * scale) / 2 * 2)
            height = max(2, Int(window.frame.height * scale) / 2 * 2)
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
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: min(24_000_000, width * height * 5),
                AVVideoExpectedSourceFrameRateKey: frameRate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ])
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
        recordingStart = firstFrameDate ?? Date()
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
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            self?.recordKeystroke(event)
        }
    }

    @MainActor
    func stop() async throws -> URL {
        guard let stream, let writer, let url = outputURL else { throw RecorderError.noFrames }
        timer?.invalidate()
        timer = nil
        pointerTimer?.invalidate()
        pointerTimer = nil
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
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

    private func recordKeystroke(_ event: NSEvent) {
        guard isRecording else { return }
        if let targetPID, NSWorkspace.shared.frontmostApplication?.processIdentifier != targetPID { return }
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
                firstFrameDate = Date()
                writer.startSession(atSourceTime: pts)
                firstPTS = pts
                startedSession = true
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
