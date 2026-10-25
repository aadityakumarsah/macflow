import AVFoundation
import SwiftUI

enum CameraRecorderError: LocalizedError {
    case permissionDenied, noCamera, configurationFailed, sessionNotRunning, notReady, writerFailed(String)
    var errorDescription: String? {
        switch self {
        case .permissionDenied: "Camera access is required to include your video."
        case .noCamera: "No camera was found on this Mac."
        case .configurationFailed: "The camera could not be configured."
        case .sessionNotRunning: "The camera did not start. Another app may be using it — close it and switch the camera on again."
        case .notReady: "The camera was not ready to record."
        case .writerFailed(let reason): "The camera recording could not be started: \(reason)"
        }
    }
}

/// The file the camera is being written to, and the little state that goes
/// with it. Only the capture queue touches any of it — which is the whole
/// reason it sits apart from the recorder's main-actor state.
private final class CameraFile: @unchecked Sendable {
    let url: URL
    private let writer: AVAssetWriter
    private var input: AVAssetWriterInput?
    private(set) var firstFrame: Date?
    private(set) var failure: String?
    private var started = false

    init(url: URL) throws {
        self.url = url
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    }

    /// The input is built from the first frame rather than from the device's
    /// advertised format: what the camera actually hands over is the only
    /// size the file can be, and a mismatch is silently fatal.
    func append(_ buffer: CMSampleBuffer) {
        guard failure == nil, CMSampleBufferDataIsReady(buffer) else { return }
        if input == nil {
            guard let description = CMSampleBufferGetFormatDescription(buffer) else { return }
            let size = CMVideoFormatDescriptionGetDimensions(description)
            let width = Int(size.width) / 2 * 2, height = Int(size.height) / 2 * 2
            guard width > 1, height > 1 else { return }
            let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: min(12_000_000, width * height * 5)]
            ])
            video.expectsMediaDataInRealTime = true
            guard writer.canAdd(video) else { failure = "the camera video could not be written"; return }
            writer.add(video)
            input = video
        }
        guard let input else { return }
        if !started {
            guard writer.startWriting() else {
                failure = writer.error?.localizedDescription ?? "the camera file could not be opened"
                return
            }
            writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(buffer))
            firstFrame = Date()
            started = true
        }
        guard writer.status == .writing, input.isReadyForMoreMediaData else { return }
        input.append(buffer)
    }

    /// The written file, or nil with a reason. A camera that produced no
    /// frames at all leaves nothing behind rather than an unplayable stub.
    func finish() async -> (URL?, String?) {
        guard started, writer.status == .writing else {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            return (nil, failure ?? "the camera produced no frames")
        }
        input?.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            try? FileManager.default.removeItem(at: url)
            return (nil, writer.error?.localizedDescription ?? "the camera file could not be finished")
        }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard size > 0 else {
            try? FileManager.default.removeItem(at: url)
            return (nil, "the camera recorded nothing")
        }
        return (url, nil)
    }
}

/// Hands the capture queue its file without the main actor reaching into it.
/// Everything here is touched on the capture queue, or from the main actor
/// through `sync` on that queue, which is the same thing in a queue.
private final class CameraMailbox: @unchecked Sendable {
    private var file: CameraFile?
    func put(_ file: CameraFile?) { self.file = file }
    func current() -> CameraFile? { file }
    func take() -> CameraFile? { defer { file = nil }; return file }
}

/// Records the camera to its own file beside the screen.
///
/// The frames are taken from a video data output and written with
/// AVAssetWriter, rather than handed to AVCaptureMovieFileOutput. The movie
/// output is less code, but on this Mac it answers a request to record with
///
///     Fig assert: "status == 0" … Setting properties failed for file format
///     compressor node (err=-67444)
///
/// and then writes nothing at all: the session runs, the preview is live,
/// the delegate reports a file that does not exist. Writing the frames is
/// the same path the screen recorder already takes, and every failure in it
/// is one this code can see and report.
@MainActor
final class CameraRecorder: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    @Published private(set) var isReady = false
    @Published private(set) var isRecording = false
    /// Why the camera produced nothing. The camera records alongside the
    /// screen and can fail on its own, and it used to do so in silence.
    @Published private(set) var failureMessage: String?

    let session = AVCaptureSession()
    private let frames = DispatchQueue(label: "app.focusflow.camera", qos: .userInitiated)
    private var output: AVCaptureVideoDataOutput?
    private let mailbox = CameraMailbox()
    private var configuredID: String?
    private(set) var recordingStartedAt: Date?

    var devices: [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external], mediaType: .video, position: .unspecified).devices
    }

    func prepare(deviceID: String? = nil) async throws {
        if isReady, deviceID == nil || configuredID == deviceID { return }
        guard !isRecording else { return }
        let granted: Bool
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: granted = true
        case .notDetermined: granted = await AVCaptureDevice.requestAccess(for: .video)
        default: granted = false
        }
        guard granted else { throw CameraRecorderError.permissionDenied }
        guard let camera = devices.first(where: { $0.uniqueID == deviceID }) ?? AVCaptureDevice.default(for: .video) else { throw CameraRecorderError.noCamera }
        let input = try AVCaptureDeviceInput(device: camera)
        if session.isRunning { session.stopRunning() }
        session.beginConfiguration()
        session.inputs.forEach { session.removeInput($0) }
        session.outputs.forEach { session.removeOutput($0) }
        if session.canSetSessionPreset(.high) { session.sessionPreset = .high }
        // A fresh output every time. An output carries the state of the
        // session it was configured for, and the one here is rebuilt whenever
        // the camera is switched or chosen again.
        let frames = AVCaptureVideoDataOutput()
        frames.alwaysDiscardsLateVideoFrames = true
        frames.setSampleBufferDelegate(self, queue: self.frames)
        guard session.canAddInput(input), session.canAddOutput(frames) else {
            session.commitConfiguration(); throw CameraRecorderError.configurationFailed
        }
        session.addInput(input)
        session.addOutput(frames)
        session.commitConfiguration()
        session.startRunning()
        // startRunning reports nothing, and a session that refused to start —
        // the camera belongs to another app, say — left isReady true, the
        // preview black and the recording empty.
        guard session.isRunning else { isReady = false; throw CameraRecorderError.sessionNotRunning }
        output = frames
        configuredID = camera.uniqueID
        failureMessage = nil
        isReady = true
    }

    func start() throws {
        guard !isRecording else { return }
        // Refusing out loud. Starting the screen recording with a camera that
        // quietly declined is how a recording arrives with the camera switched
        // on in the editor and no camera in it.
        guard isReady, output != nil else { throw CameraRecorderError.notReady }
        guard session.isRunning else { isReady = false; throw CameraRecorderError.sessionNotRunning }
        let directory = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0].appendingPathComponent("FocusFlow", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd HH.mm.ss.SSS"
        let url = directory.appendingPathComponent("Camera \(formatter.string(from: Date())).mov")
        let file: CameraFile
        do { file = try CameraFile(url: url) }
        catch { throw CameraRecorderError.writerFailed(error.localizedDescription) }
        failureMessage = nil
        recordingStartedAt = Date()
        frames.sync { mailbox.put(file) }
        isRecording = true
    }

    /// The written file, or nil if there is none worth keeping.
    ///
    /// Taking the file out on the capture queue settles any frame still being
    /// written, so nothing is appending to it once this returns.
    func stop() async -> URL? {
        guard let file = frames.sync(execute: { mailbox.take() }) else { return nil }
        isRecording = false
        let (url, failure) = await file.finish()
        // The camera's clock starts at its first frame, not at the moment it
        // was asked to record, and the editor lines the two tracks up by that
        // instant.
        if let first = file.firstFrame { recordingStartedAt = first }
        if let failure { failureMessage = "The camera recorded nothing: \(failure)" }
        return url
    }

    func shutdown() {
        guard !isRecording else { return }
        if session.isRunning { session.stopRunning() }
        output?.setSampleBufferDelegate(nil, queue: nil)
        isReady = false
    }

    /// Already on the capture queue: that is the queue the delegate was set
    /// with, and the only place the file is written.
    nonisolated func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        mailbox.current()?.append(sampleBuffer)
    }
}

struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession
    func makeNSView(context: Context) -> CameraPreviewView {
        let view = CameraPreviewView()
        view.previewLayer.session = session
        return view
    }
    func updateNSView(_ nsView: CameraPreviewView, context: Context) { nsView.previewLayer.session = session }
}

final class CameraPreviewView: NSView {
    let previewLayer = AVCaptureVideoPreviewLayer()
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        previewLayer.videoGravity = .resizeAspectFill
        layer?.addSublayer(previewLayer)
    }
    required init?(coder: NSCoder) { nil }
    override func layout() { super.layout(); previewLayer.frame = bounds }
}
