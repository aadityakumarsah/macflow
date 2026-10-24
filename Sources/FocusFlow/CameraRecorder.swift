import AVFoundation
import SwiftUI

enum CameraRecorderError: LocalizedError {
    case permissionDenied, noCamera, configurationFailed
    var errorDescription: String? {
        switch self {
        case .permissionDenied: "Camera access is required to include your video."
        case .noCamera: "No camera was found on this Mac."
        case .configurationFailed: "The camera could not be configured."
        }
    }
}

@MainActor
final class CameraRecorder: NSObject, ObservableObject, AVCaptureFileOutputRecordingDelegate {
    @Published private(set) var isReady = false
    @Published private(set) var isRecording = false
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
        configuredID = camera.uniqueID
        isReady = true
    }

    func start() throws {
        guard isReady, !output.isRecording else { return }
        let directory = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0].appendingPathComponent("FocusFlow", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd HH.mm.ss.SSS"
        let url = directory.appendingPathComponent("Camera \(formatter.string(from: Date())).mov")
        try? FileManager.default.removeItem(at: url)
        recordingURL = url
        recordingStartedAt = Date()
        output.startRecording(to: url, recordingDelegate: self)
        isRecording = true
    }

    func stop() async -> URL? {
        guard output.isRecording else { return recordingURL }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            output.stopRecording()
        }
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
