import AppKit
import AVFoundation
import Network

@MainActor
final class BrowserRecorderBridge: ObservableObject {
    /// Where the hosted copy of the studio lives. Only these may post a
    /// recording to the local bridge, and only with a valid session token —
    /// which reaches the page through the URL fragment when this app opens
    /// it, so a passing visitor never has one.
    static let webStudioOrigins = [
        "https://macflow-delta.vercel.app",
        "https://aadityakumarsah.github.io",
    ]
    static let webStudioURL = "https://macflow-delta.vercel.app/studio/"

    /// Opening the hosted studio means its code is fetched over the network
    /// rather than read from this signed app bundle. Off by default.
    static var usesWebStudio: Bool {
        get { UserDefaults.standard.bool(forKey: "FocusFlowUsesWebStudio") }
        set { UserDefaults.standard.set(newValue, forKey: "FocusFlowUsesWebStudio") }
    }

    @Published var status = "Choose a Chrome tab and preview it before recording."
    @Published private(set) var isActive = false
    var onFinish: ((URL, RecordingMetadata) -> Void)?
    private var listener: NWListener?
    private var token = UUID().uuidString
    private var directory: URL?
    private var port: UInt16 = 0
    private var sessionHosted = false
    private var didFinish = false
    private var isFinalizing = false
    private var captureID: String?
    private var lastActivity = Date.distantPast
    private let pointer = BrowserPointerCapture()

    var sessionURL: URL? { isActive ? studioURL : nil }

    private var studioURL: URL? {
        // The hosted page needs the port too, since it cannot infer it from
        // its own origin the way the locally served copy can.
        sessionHosted
            ? URL(string: "\(BrowserRecorderBridge.webStudioURL)#\(token)&port=\(port)")
            : URL(string: "http://127.0.0.1:\(port)/#\(token)")
    }
    func launch(openInBrowser: Bool = true, hosted: Bool? = nil) async throws {
        if didFinish { stop() }
        sessionHosted = hosted ?? BrowserRecorderBridge.usesWebStudio
        guard !isActive else { if openInBrowser { openBrowser() }; return }
        token = UUID().uuidString; didFinish = false; isFinalizing = false; captureID = nil
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("FocusFlow-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory!, withIntermediateDirectories: true)
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let server = try NWListener(using: parameters)
        listener = server
        server.newConnectionHandler = { [weak self] connection in
            let request = LocalHTTPRequest(connection: connection) { method, path, headers, body, respond in
                Task { @MainActor in
                    guard let self else { respond(503, "text/plain", Data("FocusFlow closed".utf8), [:]); return }
                    await self.handle(method: method, path: path, headers: headers, body: body, rawRespond: respond)
                }
            }
            request.start()
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let startup = ListenerStartup(continuation)
            server.stateUpdateHandler = { state in
                switch state {
                case .ready: startup.finish(.success(()))
                case .failed(let error): startup.finish(.failure(error))
                case .cancelled: startup.finish(.failure(CancellationError()))
                default: break
                }
            }
            server.start(queue: DispatchQueue(label: "app.focusflow.browser"))
        }
        guard let boundPort = server.port else { throw ExportError.failed("Could not start the local tab recorder.") }
        port = boundPort.rawValue; isActive = true
        status = "Chrome is ready. Select a tab, then start recording there."
        if openInBrowser { openBrowser() }
    }

    private func openBrowser() {
        guard let url = studioURL else { return }
        if let chrome = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome") {
            NSWorkspace.shared.open([url], withApplicationAt: chrome, configuration: NSWorkspace.OpenConfiguration())
        } else { NSWorkspace.shared.open(url) }
    }
    func stop() {
        pointer.discard()
        listener?.cancel(); listener = nil; isActive = false
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
    }

    private func handle(method: String, path: String, headers: [String: String], body: Data, rawRespond: @escaping (Int, String, Data, [String: String]) -> Void) async {
        let localOrigin = "http://127.0.0.1:\(port)"
        let requestOrigin = headers["origin"]

        // The studio page can be served by this app or by our own web host.
        // Either way the media is posted here, to this machine; the web copy
        // just needs to be named explicitly, because the browser will not let
        // a remote page reach loopback without being told it may.
        let allowedOrigins = [localOrigin] + BrowserRecorderBridge.webStudioOrigins
        let originAllowed = requestOrigin.map(allowedOrigins.contains) ?? false

        var cors: [String: String] = [:]
        if let requestOrigin, originAllowed {
            cors["Access-Control-Allow-Origin"] = requestOrigin
            cors["Access-Control-Allow-Headers"] = "Content-Type, X-FocusFlow-Token, X-FocusFlow-Capture"
            cors["Access-Control-Allow-Methods"] = "POST, OPTIONS"
            cors["Access-Control-Max-Age"] = "600"
            cors["Vary"] = "Origin"
            // Chrome treats a public page reaching 127.0.0.1 as Private
            // Network Access and blocks it unless the preflight says the
            // target consents. Without this the hosted studio cannot post
            // here at all, however correct the rest of the CORS is.
            if headers["access-control-request-private-network"] == "true" {
                cors["Access-Control-Allow-Private-Network"] = "true"
            }
        }

        // Shadow the raw responder so every existing reply carries the CORS
        // headers without each call site repeating them.
        func respond(_ status: Int, _ type: String, _ data: Data) {
            rawRespond(status, type, data, cors)
        }

        guard headers["host"] == "127.0.0.1:\(port)" else { respond(403, "text/plain", Data()); return }

        // The custom headers make every POST non-simple, so the browser asks
        // first. Answer before any token check: a preflight carries no token.
        if method == "OPTIONS" {
            respond(originAllowed ? 204 : 403, "text/plain", Data())
            return
        }
        if method == "GET" {
            let file: String
            switch path { case "/": file = "index.html"; case "/recorder.js": file = "recorder.js"; case "/style.css": file = "style.css"; default: respond(404, "text/plain", Data()); return }
            let packaged = Bundle.main.resourceURL.flatMap { Bundle(url: $0.appendingPathComponent("FocusFlow_FocusFlow.bundle")) }
            let url = (packaged ?? Bundle.module).url(forResource: file, withExtension: nil, subdirectory: "BrowserRecorder")
            guard let url, let data = try? Data(contentsOf: url) else { respond(404, "text/plain", Data()); return }
            respond(200, file.hasSuffix("html") ? "text/html" : file.hasSuffix("js") ? "text/javascript" : "text/css", data)
            return
        }
        guard method == "POST", originAllowed, headers["x-focusflow-token"] == token, let directory else { respond(403, "text/plain", Data("Invalid recording session".utf8)); return }
        do {
            guard let requestID = headers["x-focusflow-capture"], UUID(uuidString: requestID) != nil else {
                respond(403, "text/plain", Data("Missing recording identifier".utf8)); return
            }
            if path == "/begin" {
                guard !didFinish, !isFinalizing else { respond(409, "text/plain", Data("Open a new tab studio session from FocusFlow.".utf8)); return }
                if let captureID, captureID != requestID, Date().timeIntervalSince(lastActivity) < 120 {
                    respond(409, "text/plain", Data("Another tab is recording. Stop or close that recorder before starting here.".utf8)); return
                }
                if captureID != requestID {
                    for file in ["screen.mp4", "camera.mp4"] { try? FileManager.default.removeItem(at: directory.appendingPathComponent(file)) }
                }
                captureID = requestID; lastActivity = Date()
                // The page reports the captured surface size; without it the
                // pointer cannot be placed inside the tab, so clicks are
                // simply not collected rather than guessed at.
                let info = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
                let width = (info["width"] as? NSNumber)?.doubleValue ?? 0
                let height = (info["height"] as? NSNumber)?.doubleValue ?? 0
                pointer.begin(viewportPixels: CGSize(width: width, height: height))
                respond(200, "text/plain", Data("Ready".utf8)); return
            }
            guard requestID == captureID else { respond(409, "text/plain", Data("This capture session has ended. Download the backup and start a new session.".utf8)); return }
            lastActivity = Date()
            if path == "/heartbeat" { respond(200, "text/plain", Data()); return }
            // The browser drops paused time from the video, so the pointer
            // timeline has to drop it too or every later click lands late.
            if path == "/started" { pointer.markRecordingStarted(); respond(200, "text/plain", Data()); return }
            if path == "/pause" { pointer.pause(); respond(200, "text/plain", Data()); return }
            if path == "/resume" { pointer.resume(); respond(200, "text/plain", Data()); return }
            if path == "/release" {
                if !isFinalizing { captureID = nil; pointer.discard() }
                respond(200, "text/plain", Data()); return
            }
            if path == "/screen" || path == "/camera" {
                guard !didFinish, !isFinalizing, !body.isEmpty else { throw ExportError.failed("This session has already finished.") }
                let file = directory.appendingPathComponent(path == "/screen" ? "screen.mp4" : "camera.mp4")
                if !FileManager.default.fileExists(atPath: file.path) { FileManager.default.createFile(atPath: file.path, contents: nil) }
                let handle = try FileHandle(forWritingTo: file); defer { try? handle.close() }
                try handle.seekToEnd(); try handle.write(contentsOf: body)
                status = "Recording Chrome tab • saving locally"
                respond(200, "text/plain", Data("Saved".utf8))
            } else if path == "/finish" {
                if didFinish { respond(200, "text/plain", Data("Already saved".utf8)); return }
                guard !isFinalizing else { respond(409, "text/plain", Data("Finishing".utf8)); return }
                isFinalizing = true; defer { isFinalizing = false }
                let info = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
                let source = directory.appendingPathComponent("screen.mp4")
                let asset = AVURLAsset(url: source)
                guard (try await asset.load(.duration)).seconds > 0, let track = try await asset.loadTracks(withMediaType: .video).first else { throw ExportError.unavailable }
                let size = try await track.load(.naturalSize)
                let library = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0].appendingPathComponent("FocusFlow", isDirectory: true)
                try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
                let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd HH.mm.ss.SSS"
                let name = formatter.string(from: Date())
                let video = library.appendingPathComponent("Tab \(name).mp4")
                var cameraName: String?
                let camera = directory.appendingPathComponent("camera.mp4")
                if FileManager.default.fileExists(atPath: camera.path) {
                    let cameraAsset = AVURLAsset(url: camera)
                    guard (try await cameraAsset.load(.isPlayable)) else { throw ExportError.failed("The camera recording is unreadable. Download the backup in Chrome.") }
                    cameraName = "Camera \(name).mp4"
                    try FileManager.default.copyItem(at: camera, to: library.appendingPathComponent(cameraName!))
                }
                do { try FileManager.default.copyItem(at: source, to: video) }
                catch { if let cameraName { try? FileManager.default.removeItem(at: library.appendingPathComponent(cameraName)) }; throw error }
                var presentation: CameraPresentation?
                if let object = info["cameraPresentation"], let data = try? JSONSerialization.data(withJSONObject: object),
                   var value = try? JSONDecoder().decode(CameraPresentation.self, from: data) {
                    value.x = min(1, max(0, value.x)); value.y = min(1, max(0, value.y)); value.size = min(0.48, max(0.12, value.size))
                    presentation = value
                }
                pointer.stop()
                var metadata = RecordingMetadata(clicks: pointer.clicks, pointerSamples: pointer.samples, keystrokes: [], sourceWidth: size.width, sourceHeight: size.height, sourceName: String((info["sourceName"] as? String ?? "Chrome tab").prefix(200)), cameraFileName: cameraName, cameraPresentation: presentation)
                metadata.embeddedCursor = info["cursorIncluded"] as? Bool
                metadata.typingEvents = pointer.typingEvents
                metadata.scrollEvents = pointer.scrollEvents
                didFinish = true; status = "Saved to your library. Ready to edit."
                respond(200, "text/plain", Data("Saved to FocusFlow".utf8)); onFinish?(video, metadata)
            } else { respond(404, "text/plain", Data()) }
        } catch { status = error.localizedDescription; respond(500, "text/plain", Data(error.localizedDescription.utf8)) }
    }
}

/// Small, bounded HTTP receiver. Each media chunk is persisted separately, so native memory
/// use does not grow with the recording. No LAN listener, remote uploads, or arbitrary paths.
private final class LocalHTTPRequest {
    let connection: NWConnection
    let handler: (String, String, [String: String], Data, @escaping (Int, String, Data, [String: String]) -> Void) -> Void
    var buffer = Data()
    var finished = false
    init(connection: NWConnection, handler: @escaping (String, String, [String: String], Data, @escaping (Int, String, Data, [String: String]) -> Void) -> Void) { self.connection = connection; self.handler = handler }
    func start() { connection.start(queue: .global(qos: .userInitiated)); receive() }
    func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] data, _, complete, error in
            if let data { buffer.append(data) }
            guard buffer.count <= 32 * 1024 * 1024 else { respond(413, "text/plain", Data("Chunk too large".utf8)); return }
            if let boundary = buffer.range(of: Data("\r\n\r\n".utf8)) {
                guard boundary.lowerBound < 16384, let text = String(data: buffer[..<boundary.lowerBound], encoding: .utf8) else { respond(400, "text/plain", Data()); return }
                let lines = text.components(separatedBy: "\r\n"), first = lines[0].split(separator: " ")
                guard first.count == 3 else { respond(400, "text/plain", Data()); return }
                var headers: [String: String] = [:]
                for line in lines.dropFirst() {
                    if let colon = line.firstIndex(of: ":") { headers[String(line[..<colon]).lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces) }
                }
                guard headers["transfer-encoding"] == nil, let length = Int(headers["content-length"] ?? "0"), length >= 0, length < 32 * 1024 * 1024 else { respond(400, "text/plain", Data()); return }
                if buffer.count - boundary.upperBound >= length {
                    let body = Data(buffer[boundary.upperBound..<(boundary.upperBound + length)])
                    handler(String(first[0]), String(first[1]), headers, body) { [self] status, type, data, extra in respond(status, type, data, extra) }
                    return
                }
            } else if buffer.count > 16384 { respond(400, "text/plain", Data()); return }
            if complete || error != nil { connection.cancel() } else { receive() }
        }
    }
    func respond(_ status: Int, _ type: String, _ body: Data, _ extra: [String: String] = [:]) {
        guard !finished else { return }; finished = true
        let extraHeaders = extra.map { "\($0.key): \($0.value)\r\n" }.joined()
        var response = Data("HTTP/1.1 \(status) Result\r\nContent-Type: \(type); charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nReferrer-Policy: no-referrer\r\nContent-Security-Policy: default-src 'self'; script-src 'self'; style-src 'self'; media-src 'self' blob:; connect-src 'self'; frame-ancestors 'none'\r\n\(extraHeaders)\r\n".utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { [connection] _ in connection.cancel() })
    }
}


/// The listener can report multiple states; the lock guarantees one continuation resume.
private final class ListenerStartup: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    init(_ continuation: CheckedContinuation<Void, Error>) { self.continuation = continuation }
    func finish(_ result: Result<Void, Error>) {
        lock.lock(); let pending = continuation; continuation = nil; lock.unlock()
        pending?.resume(with: result)
    }
}
