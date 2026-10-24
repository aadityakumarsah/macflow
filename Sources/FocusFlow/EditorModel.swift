import AppKit
import AVFoundation
import AVKit
import SwiftUI

@MainActor
final class EditorModel: ObservableObject {
    @Published var videoURL: URL?
    @Published var player = AVPlayer()
    @Published var cameraURL: URL?
    @Published var duration: Double = 0
    @Published var playhead: Double = 0
    @Published var isPlaying = false
    @Published var segments: [EditSegment] = [] { willSet { remember() } didSet { changed() } }
    @Published var selectedSegmentID: UUID?
    @Published var background: BackgroundStyle = .aurora { willSet { remember() } didSet { changed() } }
    @Published var ratio: CanvasRatio = .source {
        willSet { remember() }
        didSet {
            guard ratio != oldValue else { return }
            if autoAdjustCanvas { adjustForRatio() }
            changed()
        }
    }
    @Published var customBackground = CustomBackground() { willSet { remember() } didSet { changed() } }
    /// Only meaningful while `ratio` is `.custom`.
    @Published var customRatio = CGSize(width: 16, height: 10) {
        willSet { remember() }
        didSet {
            guard ratio == .custom, customRatio != oldValue else { return }
            if autoAdjustCanvas { adjustForRatio() }
            changed()
        }
    }
    @Published var exportOptions = ExportOptions() { willSet { remember() } didSet { changed() } }
    /// Re-fits padding and the camera when the aspect changes. On by default;
    /// any manual change to those controls afterwards is left alone.
    @Published var autoAdjustCanvas = true
    /// Hides the rails, inspector and timeline and gives the preview the
    /// whole window, for watching the result rather than editing it.
    @Published var theatreMode = false
    @Published var padding: Double = 7 { willSet { remember() } didSet { changed() } }
    @Published var cornerRadius: Double = 18 { willSet { remember() } didSet { changed() } }
    @Published var shadow: Double = 30 { willSet { remember() } didSet { changed() } }
    @Published var cursorSize: Double = 1 { willSet { remember() } didSet { changed() } }
    @Published var clickEffects = true { willSet { remember() } didSet { changed() } }
    @Published var showCursor = true { willSet { remember() } didSet { changed() } }
    @Published var smoothCursor = true { willSet { remember() } didSet { changed() } }
    @Published var cursorShadow = true { willSet { remember() } didSet { changed() } }
    @Published var showKeystrokes = false { willSet { remember() } didSet { changed() } }
    @Published var showCamera = true { willSet { remember() } didSet { changed() } }
    @Published var cameraSize: Double = 0.24 { willSet { remember() } didSet { changed() } }
    @Published var cameraX: Double = 0.82 { willSet { remember() } didSet { changed() } }
    @Published var cameraY: Double = 0.78 { willSet { remember() } didSet { changed() } }
    @Published var cameraCornerRadius: Double = 14 { willSet { remember() } didSet { changed() } }
    @Published var cameraShape: CameraShape = .roundedRectangle { willSet { remember() } didSet { changed() } }
    @Published var cameraMirrored = false { willSet { remember() } didSet { changed() } }
    @Published var trimStart: Double = 0 { willSet { remember() } didSet { changed() } }
    @Published var trimEnd: Double = 0 { willSet { remember() } didSet { changed() } }
    @Published var playbackRate: Double = 1 { willSet { remember() } didSet { changed() } }
    @Published var muted = false { willSet { remember() } didSet { changed() } }
    @Published var frameAppearance = FrameAppearance() { willSet { remember() } didSet { changed() } }
    @Published var motionAppearance = MotionAppearance() { willSet { remember() } didSet { changed() } }
    @Published var cursorAppearance = CursorAppearance() { willSet { remember() } didSet { changed() } }
    @Published var showCropEditor = false
    @Published var pointerSamples: [PointerSample] = []
    @Published var recordedClicks: [RecordedClick] = []
    @Published var keystrokes: [KeystrokeEvent] = []
    @Published var sourceSize = CGSize(width: 1920, height: 1080)
    @Published var showRecorder = false
    @Published var showLibrary = false
    @Published var inspectorTab = "Canvas"
    @Published var exportProgress: Double?
    @Published var message: String?
    @Published var canUndo = false
    @Published var canRedo = false
    @Published var isPreparingPreview = false
    @Published var saveStatus = "All changes saved locally"
    let library = RecordingLibrary()
    let browserRecorder = BrowserRecorderBridge()
    private var timeObserver: Any?
    private var undoStack: [ProjectDocument] = []
    private var redoStack: [ProjectDocument] = []
    private var restoring = false
    private var lastHistory = Date.distantPast
    private var previewTask: Task<Void, Never>?
    private var openTask: Task<Void, Never>?
    private var metadata = RecordingMetadata.empty

    init(restoreLatest: Bool = true) {
        Task {
            guard restoreLatest else { return }
            await library.refresh()
            guard videoURL == nil else { return }
            if let path = UserDefaults.standard.string(forKey: "FocusFlow.lastRecording"), FileManager.default.fileExists(atPath: path) {
                let url = URL(fileURLWithPath: path)
                open(url: url, metadata: library.metadata(for: url))
            }
        }
        browserRecorder.onFinish = { [weak self] url, metadata in
            guard let self else { return }
            Task {
                await self.finishRecording(url: url, metadata: metadata)
                self.showRecorder = false
                // The recording was made in Chrome, so the app is behind the
                // browser. Come forward with the result already open — this is
                // the handoff the browser page has just told the user about.
                NSApplication.shared.activate(ignoringOtherApps: true)
                NSApplication.shared.windows.first?.makeKeyAndOrderFront(nil)
            }
        }
    }

    var selectedSegment: EditSegment? { segments.first { $0.id == selectedSegmentID } }
    var outputDuration: Double { max(0, trimEnd - trimStart) / playbackRate }

    var contentSize: CGSize {
        let crop = frameAppearance.crop.rect(in: sourceSize)
        return crop.size
    }
    var canvasSize: CGSize {
        var size = contentSize
        if frameAppearance.chrome != .none { size.height += size.width * frameAppearance.barHeight / 1920 }
        return exportOptions.canvas(from: ratio.size(for: size, custom: ratio == .custom ? customRatio : nil))
    }

    /// Re-fits the composition after the canvas aspect changes.
    ///
    /// Fitting is aspect-preserving, so a 16:9 recording dropped into a 9:16
    /// canvas becomes a thin band with most of the frame left as background.
    /// Padding is pulled in as the two aspects diverge, and the camera moves
    /// into the empty area rather than sitting on top of the content.
    private func adjustForRatio() {
        let content = contentSize
        guard content.width > 0, content.height > 0 else { return }
        let canvas = ratio.size(for: content, custom: ratio == .custom ? customRatio : nil)
        guard canvas.width > 0, canvas.height > 0 else { return }

        let contentAspect = content.width / content.height
        let canvasAspect = canvas.width / canvas.height
        // 1 when the two match, falling away as they diverge.
        let agreement = min(contentAspect, canvasAspect) / max(contentAspect, canvasAspect)

        padding = (2 + 6 * agreement).rounded()

        if canvasAspect < contentAspect * 0.85 {
            // Tall canvas: a band is free above the content.
            cameraX = 0.5
            cameraY = 0.17
        } else if canvasAspect > contentAspect * 1.15 {
            // Wide canvas: free space to the side.
            cameraX = 0.87
            cameraY = 0.5
        } else {
            cameraX = 0.82
            cameraY = 0.78
        }
    }

    func open(url: URL, metadata: RecordingMetadata = .empty, project: ProjectDocument? = nil) {
        guard FileManager.default.fileExists(atPath: url.path) else { message = "This recording is no longer available on this Mac."; return }
        openTask?.cancel(); previewTask?.cancel()
        player.pause(); isPlaying = false
        restoring = true
        videoURL = url; self.metadata = project?.metadata ?? metadata
        playhead = 0; duration = 0; segments = []; selectedSegmentID = nil; inspectorTab = "Canvas"
        background = .aurora; ratio = .source; padding = 7; cornerRadius = 18; shadow = 30
        cursorSize = 1; clickEffects = true; showCursor = true; smoothCursor = true; cursorShadow = true
        showKeystrokes = false; showCamera = true; cameraSize = 0.24; cameraX = 0.82; cameraY = 0.78
        cameraCornerRadius = 14; cameraShape = .roundedRectangle; cameraMirrored = false
        trimStart = 0; trimEnd = 0; playbackRate = 1; muted = false
        frameAppearance = FrameAppearance(); motionAppearance = MotionAppearance(); cursorAppearance = CursorAppearance()
        customBackground = CustomBackground(); exportOptions = ExportOptions()
        customRatio = CGSize(width: 16, height: 10)
        if let camera = self.metadata.cameraPresentation {
            cameraX = camera.x; cameraY = camera.y; cameraSize = camera.size; cameraShape = camera.shape; cameraMirrored = camera.mirrored
        }
        recordedClicks = self.metadata.clicks; pointerSamples = self.metadata.pointerSamples; keystrokes = self.metadata.keystrokes
        cameraURL = self.metadata.cameraFileName.map { url.deletingLastPathComponent().appendingPathComponent($0) }
        if let cameraURL, !FileManager.default.fileExists(atPath: cameraURL.path) { self.cameraURL = nil }
        restoring = false
        undoStack = []; redoStack = []; updateHistory()
        UserDefaults.standard.set(url.path, forKey: "FocusFlow.lastRecording")
        player.replaceCurrentItem(with: nil)
        isPreparingPreview = true
        openTask = Task {
            do {
                let asset = AVURLAsset(url: url)
                let seconds = try await asset.load(.duration).seconds
                guard seconds.isFinite, seconds > 0, let track = try await asset.loadTracks(withMediaType: .video).first else { throw ExportError.unavailable }
                let size = try await track.load(.naturalSize).applying(track.load(.preferredTransform))
                try Task.checkCancellation()
                guard videoURL == url else { return }
                restoring = true
                duration = seconds; trimEnd = seconds
                sourceSize = CGSize(width: abs(size.width), height: abs(size.height))
                segments = Self.zoomSegments(from: self.metadata.clicks, duration: duration)
                restoring = false
                if let saved = project ?? readProject(at: editsURL(for: url)) { restore(saved) }
                changed()
            } catch is CancellationError {} catch { isPreparingPreview = false; message = "Could not open recording: \(error.localizedDescription)" }
        }
    }

    func finishRecording(url: URL, metadata: RecordingMetadata) async {
        do { try await library.register(url, metadata: metadata) }
        catch { message = "Video saved, but metadata could not be written: \(error.localizedDescription)" }
        open(url: url, metadata: metadata)
    }
    func openLibraryItem(_ item: RecordingItem) { open(url: item.url, metadata: library.metadata(for: item.url)); showLibrary = false }
    func importVideo() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.movie, .video, .json]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if url.pathExtension == "json" {
            guard let project = readProject(at: url) else { message = "Choose a FocusFlow project file or a video."; return }
            let source = URL(fileURLWithPath: project.videoPath)
            open(url: source, metadata: library.metadata(for: source), project: project)
        } else { open(url: url, metadata: library.metadata(for: url)) }
    }

    func togglePlayback() {
        guard videoURL != nil else { return }
        if isPlaying { player.pause() } else {
            if playhead >= trimEnd - 0.05 || playhead < trimStart { seek(to: trimStart) }
            player.play()
        }
        isPlaying.toggle()
    }
    func seek(to seconds: Double) {
        playhead = max(0, min(duration, seconds))
        player.seek(to: CMTime(seconds: playhead / playbackRate, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }
    func setCameraVisible(_ visible: Bool) { showCamera = visible }
    func addSegment(_ kind: SegmentKind) {
        guard duration > 0 else { return }
        lastHistory = .distantPast
        let start = min(playhead, max(0, duration - 0.2))
        let crop = frameAppearance.crop.bounded
        let segment = EditSegment(kind: kind, start: start, duration: min(kind == .pan ? 4 : 2.5, duration - start), intensity: kind == .zoom || kind == .pan ? 1.65 : kind == .callout ? 1 : 2, x: crop.x + crop.width * 0.5, y: crop.y + crop.height * 0.5, transition: 0.7, curve: .smooth, endX: crop.x + crop.width * 0.75, endY: crop.y + crop.height * 0.5, text: kind == .callout ? "Look here" : nil)
        segments.append(segment); selectedSegmentID = segment.id; inspectorTab = "Segment"
    }
    func deleteSelected() {
        guard let id = selectedSegmentID else { return }
        lastHistory = .distantPast; segments.removeAll { $0.id == id }; selectedSegmentID = nil
    }
    func duplicateSelected() {
        guard var segment = selectedSegment else { return }
        lastHistory = .distantPast; segment.id = UUID(); segment.start = min(max(0, duration - segment.duration), segment.end + 0.1)
        segments.append(segment); selectedSegmentID = segment.id
    }
    /// Splitting needs the playhead inside the segment, with room either
    /// side. Exposed so the button can be disabled rather than silently doing
    /// nothing when it is pressed.
    var canSplitSelected: Bool {
        guard let segment = selectedSegment else { return false }
        return playhead > segment.start + 0.1 && playhead < segment.end - 0.1
    }

    func splitSelected() {
        guard canSplitSelected, var segment = selectedSegment else { return }
        lastHistory = .distantPast
        let oldEnd = segment.end
        updateSelected { $0.duration = playhead - $0.start }
        segment.id = UUID(); segment.start = playhead; segment.duration = oldEnd - playhead
        segments.append(segment); selectedSegmentID = segment.id
    }
    func updateSelected(_ change: (inout EditSegment) -> Void) {
        guard let index = segments.firstIndex(where: { $0.id == selectedSegmentID }) else { return }
        var segment = segments[index]; change(&segment)
        segment.start = min(max(0, segment.start), max(0, duration - 0.1))
        segment.duration = max(0.1, min(segment.duration, duration - segment.start))
        if segment.kind == .blur || segment.kind == .spotlight {
            segment.width = max(0.02, min(1, segment.regionWidth)); segment.height = max(0.02, min(1, segment.regionHeight))
            segment.x = max(segment.regionWidth / 2, min(1 - segment.regionWidth / 2, segment.x))
            segment.y = max(segment.regionHeight / 2, min(1 - segment.regionHeight / 2, segment.y))
        }
        segments[index] = segment
    }
    /// Enters or leaves theatre mode, taking the window to macOS full screen
    /// with it so the preview really does fill the display.
    func setTheatreMode(_ on: Bool) {
        guard theatreMode != on else { return }
        theatreMode = on
        guard let window = NSApplication.shared.windows.first(where: { $0.isVisible && $0.contentView != nil }) else { return }
        let isFullScreen = window.styleMask.contains(.fullScreen)
        if on != isFullScreen { window.toggleFullScreen(nil) }
    }

    func toggleTheatreMode() { setTheatreMode(!theatreMode) }

    func setTrimStart() { trimStart = max(0, min(playhead, trimEnd - 0.1)) }
    func setTrimEnd() { trimEnd = min(duration, max(playhead, trimStart + 0.1)) }
    func resetTrim() { trimStart = 0; trimEnd = duration }

    private func remember() {
        guard !restoring, videoURL != nil, duration > 0 else { return }
        if Date().timeIntervalSince(lastHistory) > 0.4 {
            undoStack.append(document()); if undoStack.count > 80 { undoStack.removeFirst() }
            lastHistory = Date()
        }
        redoStack = []; updateHistory()
    }
    private func updateHistory() { canUndo = !undoStack.isEmpty; canRedo = !redoStack.isEmpty }
    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(document()); restore(previous); updateHistory(); changed(); lastHistory = .distantPast
    }
    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(document()); restore(next); updateHistory(); changed(); lastHistory = .distantPast
    }
    private func restore(_ d: ProjectDocument) {
        restoring = true
        segments = d.segments; background = d.background; ratio = d.ratio; padding = d.padding
        cornerRadius = d.cornerRadius; shadow = d.shadow; cursorSize = d.cursorSize; clickEffects = d.clickEffects
        showCursor = d.showCursor ?? true; smoothCursor = d.smoothCursor ?? true; cursorShadow = d.cursorShadow ?? true
        showKeystrokes = d.showKeystrokes ?? false; showCamera = d.showCamera ?? true
        cameraSize = d.cameraSize ?? 0.24; cameraX = d.cameraX ?? 0.82; cameraY = d.cameraY ?? 0.78
        cameraCornerRadius = d.cameraCornerRadius ?? 14; cameraShape = d.cameraShape ?? .roundedRectangle; cameraMirrored = d.cameraMirrored ?? false
        trimStart = max(0, min(d.trimStart ?? 0, duration - 0.1)); trimEnd = min(duration, max(trimStart + 0.1, d.trimEnd ?? duration))
        playbackRate = max(0.25, min(3, d.playbackRate ?? 1)); muted = d.muted ?? false
        frameAppearance = d.frameAppearance ?? FrameAppearance(chrome: .none)
        motionAppearance = d.motionAppearance ?? MotionAppearance()
        cursorAppearance = d.cursorAppearance ?? CursorAppearance()
        customBackground = d.customBackground ?? CustomBackground()
        exportOptions = d.exportOptions ?? ExportOptions()
        customRatio = CGSize(width: d.customRatioWidth ?? 16, height: d.customRatioHeight ?? 10)
        restoring = false
    }
    private func document() -> ProjectDocument {
        ProjectDocument(videoPath: videoURL?.path ?? "", segments: segments, background: background, ratio: ratio, padding: padding, cornerRadius: cornerRadius, shadow: shadow, cursorSize: cursorSize, clickEffects: clickEffects, showCursor: showCursor, smoothCursor: smoothCursor, cursorShadow: cursorShadow, showKeystrokes: showKeystrokes, showCamera: showCamera, cameraSize: cameraSize, cameraX: cameraX, cameraY: cameraY, cameraCornerRadius: cameraCornerRadius, cameraShape: cameraShape, cameraMirrored: cameraMirrored, trimStart: trimStart, trimEnd: trimEnd, playbackRate: playbackRate, muted: muted, metadata: metadata, frameAppearance: frameAppearance, motionAppearance: motionAppearance, cursorAppearance: cursorAppearance, customBackground: customBackground, exportOptions: exportOptions, customRatioWidth: customRatio.width, customRatioHeight: customRatio.height)
    }
    private func readProject(at url: URL) -> ProjectDocument? { guard let data = try? Data(contentsOf: url) else { return nil }; return try? JSONDecoder().decode(ProjectDocument.self, from: data) }
    private func editsURL(for url: URL) -> URL { url.deletingPathExtension().appendingPathExtension("edits.json") }
    func saveProject() {
        guard let videoURL else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = videoURL.deletingPathExtension().lastPathComponent + ".project.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard url != videoURL.deletingPathExtension().appendingPathExtension("focusflow.json") else { message = "Use a .project.json filename to preserve capture metadata."; return }
        do { try JSONEncoder().encode(document()).write(to: url, options: .atomic); saveStatus = "Project saved" }
        catch { message = error.localizedDescription }
    }
    func settings() -> ExportSettings {
        ExportSettings(background: background, canvasSize: canvasSize, padding: padding, cornerRadius: cornerRadius, shadow: shadow, segments: segments, pointerSamples: pointerSamples, clicks: recordedClicks, keystrokes: keystrokes, cursorSize: cursorSize, clickEffects: clickEffects, showKeystrokes: showKeystrokes, cameraURL: cameraURL, showCamera: showCamera, cameraSize: cameraSize, cameraX: cameraX, cameraY: cameraY, cameraCornerRadius: cameraCornerRadius, cameraShape: cameraShape, showCursor: showCursor, smoothCursor: smoothCursor, cursorShadow: cursorShadow, cameraMirrored: cameraMirrored, trimStart: trimStart, trimEnd: trimEnd, playbackRate: playbackRate, muted: muted, cameraTimeOffset: metadata.cameraTimeOffset ?? 0, frame: frameAppearance, motion: motionAppearance, cursor: cursorAppearance, cursorPointScale: sourceSize.width / max(1, metadata.sourcePointWidth ?? sourceSize.width), customBackground: customBackground, exportOptions: exportOptions)
    }
    private func changed() {
        guard !restoring, let url = videoURL, duration > 0 else { return }
        previewTask?.cancel(); saveStatus = "Saving…"
        previewTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(180))
                let settings = settings()
                let (asset, composition) = try await VideoExporter.composition(source: url, settings: settings)
                try Task.checkCancellation()
                let time = playhead, playing = isPlaying
                let item = AVPlayerItem(asset: asset); item.videoComposition = composition
                player.replaceCurrentItem(with: item); seek(to: time); if playing { player.play() }
                installTimeObserver(); isPreparingPreview = false
                try JSONEncoder().encode(document()).write(to: editsURL(for: url), options: .atomic)
                saveStatus = "All changes saved locally"
            } catch is CancellationError {} catch { isPreparingPreview = false; saveStatus = "Could not save edits"; message = error.localizedDescription }
        }
    }
    func export() {
        guard let videoURL else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [exportOptions.format == .mp4 ? .mpeg4Movie : .quickTimeMovie]
        panel.nameFieldStringValue = videoURL.deletingPathExtension().lastPathComponent
            + " — edited." + exportOptions.format.fileExtension
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        exportProgress = 0; let settings = settings()
        Task {
            do {
                try await VideoExporter.export(source: videoURL, destination: destination, settings: settings) { progress in Task { @MainActor in self.exportProgress = progress } }
                exportProgress = nil; NSWorkspace.shared.activateFileViewerSelecting([destination])
            } catch { exportProgress = nil; message = error.localizedDescription }
        }
    }
    func deleteRecording(_ item: RecordingItem) async throws {
        if videoURL == item.url {
            previewTask?.cancel(); openTask?.cancel(); player.pause(); player.replaceCurrentItem(with: nil)
            videoURL = nil; duration = 0; playhead = 0; isPlaying = false; cameraURL = nil; segments = []
            selectedSegmentID = nil; inspectorTab = "Canvas"; trimStart = 0; trimEnd = 0
            recordedClicks = []; pointerSamples = []; keystrokes = []; metadata = .empty
            undoStack = []; redoStack = []; updateHistory(); UserDefaults.standard.removeObject(forKey: "FocusFlow.lastRecording")
        }
        try await library.delete(item)
    }
    private func installTimeObserver() {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1.0 / 60, preferredTimescale: 600), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, self.isPlaying else { return }
                self.playhead = time.seconds.isFinite ? time.seconds * self.playbackRate : 0
                if self.playhead >= self.trimEnd - 0.02 { self.player.pause(); self.isPlaying = false; self.seek(to: self.trimEnd) }
            }
        }
    }
    func addAutoZooms() {
        lastHistory = .distantPast
        segments.removeAll { $0.kind == .zoom }
        segments.append(contentsOf: Self.zoomSegments(from: recordedClicks, duration: duration))
    }
    static func zoomSegments(from clicks: [RecordedClick], duration: Double) -> [EditSegment] {
        MotionEngine.autoZooms(clicks: clicks, duration: duration)
    }
}
