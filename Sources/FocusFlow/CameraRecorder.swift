import AVFoundation
import SwiftUI

enum CameraRecorderError: LocalizedError {
    case permissionDenied, noCamera, configurationFailed, sessionNotRunning, notReady
    var errorDescription: String? {
        switch self {
        case .permissionDenied: "Camera access is required to include your video."
        case .noCamera: "No camera was found on this Mac."
        case .configurationFailed: "The camera could not be configured."
        case .sessionNotRunning: "The camera did not start. Another app may be using it — close it and switch the camera on again."
        case .notReady: "The camera was not ready to record."
        }
    }
}

@MainActor
final class CameraRecorder: NSObject, ObservableObject, AVCaptureFileOutputRecordingDelegate {
    @Published private(set) var isReady = false
    @Published private(set) var isRecording = false
    /// Why the camera produced nothing. The camera records to its own file
    /// alongside the screen, so it can fail on its own, and it used to do so
    /// in silence: the recording finished, the editor found no camera track,
    /// and nothing anywhere said why.
    @Published private(set) var failureMessage: String?
    let session = AVCaptureSession()
    private let output = AVCaptureMovieFileOutput()
    private var continuation: CheckedContinuation<URL?, Never>?
    private var recordingURL: URL?
    private(set) var recordingStartedAt: Date?

    var devices: [AVCaptureDevice] { AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external], mediaType: .video, position: .unspecified).devices }
    private var configuredID: String?
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
        session.sessionPreset = .high
        guard session.canAddInput(input), session.canAddOutput(output) else {
            session.commitConfiguration(); throw CameraRecorderError.configurationFailed
        }
        session.addInput(input)
        session.addOutput(output)
        session.commitConfiguration()
        session.startRunning()
        // startRunning reports nothing, and a session that refused to start —
        // the camera belongs to another app, say — left isReady true, the
        // preview black and the recording empty.
        guard session.isRunning else { isReady = false; throw CameraRecorderError.sessionNotRunning }
        configuredID = camera.uniqueID
        failureMessage = nil
        isReady = true
    }

    func start() throws {
        guard !output.isRecording else { return }
        // Refusing out loud. Starting the screen recording with a camera that
        // quietly declined is how a recording arrives with the camera switched
        // on in the editor and no camera in it.
        guard isReady else { throw CameraRecorderError.notReady }
        guard session.isRunning else { isReady = false; throw CameraRecorderError.sessionNotRunning }
        guard output.connection(with: .video)?.isActive == true else { throw CameraRecorderError.configurationFailed }
        let directory = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0].appendingPathComponent("FocusFlow", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd HH.mm.ss.SSS"
        let url = directory.appendingPathComponent("Camera \(formatter.string(from: Date())).mov")
        try? FileManager.default.removeItem(at: url)
        recordingURL = url
        recordingStartedAt = Date()
        failureMessage = nil
        output.startRecording(to: url, recordingDelegate: self)
        isRecording = true
    }

    /// The written file, or nil if there is none worth keeping.
    ///
    /// A recording that ended early — the camera was taken away, the session
    /// stopped — leaves `output.isRecording` false, and this used to hand back
    /// the URL it had meant to write regardless. The name reached the
    /// recording's metadata, the editor looked for a file that was never
    /// written, and the camera silently vanished.
    func stop() async -> URL? {
        guard output.isRecording else { return written(recordingURL) }
        let url = await withCheckedContinuation { continuation in
            self.continuation = continuation
            output.stopRecording()
        }
        return written(url)
    }

    private func written(_ url: URL?) -> URL? {
        guard let url else { return nil }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard size > 0 else {
            if failureMessage == nil { failureMessage = "The camera recorded nothing." }
            recordingURL = nil
            return nil
        }
        return url
    }

    func shutdown() {
        guard !output.isRecording else { return }
        if session.isRunning { session.stopRunning() }
        isReady = false
    }

    nonisolated func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL, from connections: [AVCaptureConnection]) {
        let start = Date()
        Task { @MainActor [weak self] in self?.recordingStartedAt = start }
    }

    nonisolated func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.isRecording = false
            let success = error == nil || (error as NSError?)?.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool == true
            if !success, let error { self.failureMessage = "The camera stopped recording: \(error.localizedDescription)" }
            let url = success ? outputFileURL : nil
            self.recordingURL = url
            self.continuation?.resume(returning: url)
            self.continuation = nil
        }
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
