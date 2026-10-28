import AppKit
import AVFoundation
import AVKit
import SwiftUI

@MainActor
final class EditorModel: ObservableObject {
    @Published var videoURL: URL?
    @Published var player = AVPlayer()
    @Published var cameraURL: URL?
    @Published var duration: Double = 0 { didSet { cachedTimeMap = nil } }
    @Published var playhead: Double = 0
    @Published var isPlaying = false
    @Published var segments: [EditSegment] = [] {
        willSet { remember() }
        didSet {
            if segments.filter({ $0.kind == .speed }) != oldValue.filter({ $0.kind == .speed }) { cachedTimeMap = nil }
            changed(reusingMedia: segments.filter { $0.kind != .perspective } == oldValue.filter { $0.kind != .perspective })
        }
    }
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
    @Published var grade = GradeSettings() { willSet { remember() } didSet { changed() } }
    @Published var cameraMove = CameraMoveSettings() { willSet { remember() } didSet { changed(reusingMedia: true) } }
    @Published var typingFollow = TypingFollowSettings() { willSet { remember() } didSet { changed() } }
    @Published var selectionFocus = SelectionFocusSettings() { willSet { remember() } didSet { changed() } }
    @Published var sounds = SoundSettings() { willSet { remember() } didSet { changed() } }
    /// Captions only change pixels, so the assembled tracks — music loops,
    /// hundreds of sound cues — are reused rather than rebuilt for a colour.
    @Published var captions = CaptionSettings() { willSet { remember() } didSet { changed(reusingMedia: true) } }
    @Published var captionProgress: Double?
    @Published var captionStatus: String?
    /// The line the caption controls and the preview handle are acting on.
    @Published var selectedCaptionID: UUID?
    /// Whether a finished recording is transcribed without being asked.
    /// A preference rather than a project setting: it is about how this Mac
    /// behaves, not about one video.
    @Published var automaticCaptions = UserDefaults.standard.object(forKey: EditorModel.automaticCaptionsKey) as? Bool ?? true {
        didSet { UserDefaults.standard.set(automaticCaptions, forKey: Self.automaticCaptionsKey) }
    }
    static let automaticCaptionsKey = "FocusFlow.automaticCaptions"
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
    @Published var cursorSize: Double = 1.25 { willSet { remember() } didSet { changed() } }
    @Published var clickEffects = true { willSet { remember() } didSet { changed() } }
    @Published var showCursor = true { willSet { remember() } didSet { changed() } }
    @Published var smoothCursor = true { willSet { remember() } didSet { changed() } }
    @Published var cursorShadow = true { willSet { remember() } didSet { changed() } }
    @Published var showKeystrokes = false { willSet { remember() } didSet { changed() } }
    @Published var showCamera = true { willSet { remember() } didSet { changed() } }
    @Published var cameraSize: Double = 0.24 { willSet { remember() } didSet { changed() } }
    @Published var cameraHeightScale: Double = 1 { willSet { remember() } didSet { changed() } }
    @Published var cameraSubjectScale: Double = 1 { willSet { remember() } didSet { changed() } }
    @Published var cameraX: Double = 0.82 { willSet { remember() } didSet { changed() } }
    @Published var cameraY: Double = 0.78 { willSet { remember() } didSet { changed() } }
    @Published var cameraCornerRadius: Double = 14 { willSet { remember() } didSet { changed() } }
    @Published var cameraShape: CameraShape = .roundedRectangle { willSet { remember() } didSet { changed() } }
    @Published var cameraMirrored = false { willSet { remember() } didSet { changed() } }
    @Published var trimStart: Double = 0 { willSet { remember() } didSet { changed() } }
    @Published var trimEnd: Double = 0 { willSet { remember() } didSet { changed() } }
    @Published var playbackRate: Double = 1 { willSet { remember() } didSet { cachedTimeMap = nil; changed() } }
    @Published var muted = false { willSet { remember() } didSet { changed() } }
    @Published var musicURL: URL? { willSet { remember() } didSet { changed() } }
    @Published var musicVolume: Double = 0.35 { willSet { remember() } didSet { changed() } }
    @Published var frameAppearance = FrameAppearance() { willSet { remember() } didSet { changed() } }
    @Published var motionAppearance = MotionAppearance() { willSet { remember() } didSet { changed() } }
    @Published var cursorAppearance = CursorAppearance() { willSet { remember() } didSet { changed() } }
    @Published var showCropEditor = false
    /// Whether the 3D handles are drawn over the preview.
    @Published var show3DCanvas = false
    @Published var canvasTool: CanvasMotionTool = .tilt
    @Published var snap3D = true
    @Published var heldTimelineLanes: [EffectLane]?
    private var poseGestureActive = false
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
    private var previewMediaDirty = true
    private var previewSourceURL: URL?
    private var movePreviewTask: Task<Void, Never>?
    private var movePreviewEnd: Double?
    private var openTask: Task<Void, Never>?
    private var captionTask: Task<Void, Never>?
    /// Set by a finished recording, acted on once the file has been opened
    /// and its duration is known.
    private var captionsWantedOnOpen = false
    private var metadata = RecordingMetadata.empty
    var recordingMetadata: RecordingMetadata { metadata }

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

    /// What the 3D handles on the canvas are holding: a selected 3D camera
    /// segment when the playhead is inside one, otherwise nothing — in
    /// which case they hold where the frame stands for the whole recording.
    var posedSegment: EditSegment? {
        guard let segment = selectedSegment, segment.kind == .perspective,
              playhead >= segment.start, playhead <= segment.end else { return nil }
        return segment
    }

    /// The pose the handles move, wherever it happens to live.
    var editedPose: FramePose {
        get {
            guard let segment = posedSegment else { return cameraMove.pose }
            if let frames = segment.poseKeyframes, !frames.isEmpty {
                return PosePath.pose(at: (playhead - segment.start) / segment.duration,
                                     in: frames, curve: segment.curve ?? .smooth)
            }
            return segment.effectivePose
        }
        set {
            if selectedSegment?.poseKeyframes?.isEmpty == false && posedSegment == nil { return }
            if let segment = posedSegment, segment.poseKeyframes?.isEmpty == false {
                let progress = max(0, min(1, (playhead - segment.start) / segment.duration))
                updateSelected {
                    var frames = $0.poseKeyframes ?? []
                    if let index = frames.firstIndex(where: { abs($0.time - progress) < 0.000001 }) {
                        frames[index].pose = newValue.clamped
                    } else { frames.append(PoseKeyframe(time: progress, pose: newValue.clamped)) }
                    $0.poseKeyframes = frames.sorted { $0.time < $1.time }
                }
            } else if posedSegment != nil {
                updateSelected {
                    $0.pose = newValue; $0.posePreset = nil
                    $0.poseStrength = 1; $0.poseReversed = false
                }
            }
            else {
                // One assignment, so one undo step and one recomposition
                // rather than six.
                var move = cameraMove
                move.pitch = newValue.pitch; move.yaw = newValue.yaw; move.roll = newValue.roll
                move.panX = newValue.panX; move.panY = newValue.panY; move.zoom = newValue.zoom
                cameraMove = move
            }
        }
    }

    /// Where the frame actually stands at the playhead, move and timeline
    /// included — which is not the pose being edited whenever a move is
    /// playing or a 3D segment is sweeping through its lean.
    var standingPose: FramePose {
        cameraMove.pose.added(MotionEngine.stance(at: playhead, segments: segments).pose)
    }
    private var cachedTimeMap: PlaybackTimeMap?
    var timeMap: PlaybackTimeMap {
        if let cachedTimeMap { return cachedTimeMap }
        let map = PlaybackTimeMap(duration: duration, rate: playbackRate, segments: segments)
        cachedTimeMap = map
        return map
    }
    var playerTimeMap: PlaybackTimeMap {
        (player.currentItem?.videoComposition?.instructions.first as? CompositionInstruction)?.timeMap ?? timeMap
    }
    var outputDuration: Double { max(0, timeMap.outputTime(for: trimEnd) - timeMap.outputTime(for: trimStart)) }
    func stepFrame(_ direction: Double) {
        let output = timeMap.outputTime(for: playhead) + direction / Double(exportOptions.frameRate.rawValue)
        seek(to: timeMap.sourceTime(for: output))
    }

    func resetCursorSettings() {
        lastHistory = .distantPast
        remember()
        restoring = true
        cursorSize = 4; showCursor = true; smoothCursor = true
        cursorShadow = true; clickEffects = true; showKeystrokes = false
        cursorAppearance = CursorAppearance()
        restoring = false
        changed()
    }

    var contentSize: CGSize {
        let crop = frameAppearance.crop.rect(in: sourceSize)
        return crop.size
    }
    var canvasSize: CGSize {
        var size = contentSize
        if frameAppearance.chrome != .none { size.height += size.width * frameAppearance.barHeight / 1920 }
        return exportOptions.canvas(from: ratio.size(for: size, custom: ratio == .custom ? customRatio : nil))
    }

    /// The canvas the preview is composed at.
    ///
    /// Export now keeps the recording's own resolution, so a 4K capture is
    /// four times the pixels of a 1080p one through a long chain of filters,
    /// several times a second, while someone drags a slider. The preview
    /// composes at a size that keeps up instead. Everything in the frame is
    /// a proportion of the canvas, so it is the same picture either way —
    /// and the preview is drawn into a few hundred points of window
    /// whatever it was composed at.
    var previewCanvasSize: CGSize {
        let canvas = canvasSize
        let limit: CGFloat = 1920
        let longest = max(canvas.width, canvas.height)
        guard longest > limit else { return canvas }
        return CanvasRatio.even(CGSize(width: canvas.width * limit / longest,
                                       height: canvas.height * limit / longest))
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
        cursorSize = 4; clickEffects = true; showCursor = self.metadata.embeddedCursor != true; smoothCursor = true; cursorShadow = true
        showKeystrokes = false; showCamera = true; cameraSize = 0.24; cameraHeightScale = 1; cameraSubjectScale = 1; cameraX = 0.82; cameraY = 0.78
        cameraCornerRadius = 14; cameraShape = .roundedRectangle; cameraMirrored = false
        trimStart = 0; trimEnd = 0; playbackRate = 1; muted = false; musicURL = nil; musicVolume = 0.35
        frameAppearance = FrameAppearance(); motionAppearance = MotionAppearance(); cursorAppearance = CursorAppearance()
        customBackground = CustomBackground(); exportOptions = ExportOptions()
        customRatio = CGSize(width: 16, height: 10)
        grade = GradeSettings(); cameraMove = CameraMoveSettings(); typingFollow = TypingFollowSettings(); sounds = SoundSettings()
        captions = CaptionSettings(); captionProgress = nil; captionStatus = nil; captionTask?.cancel(); captionTask = nil
        selectedCaptionID = nil
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
                segments = MotionEngine.autoEdits(clicks: self.metadata.clicks, samples: self.metadata.pointerSamples, duration: duration, typing: self.metadata.typingEvents ?? [], typingFollow: self.typingFollow, selection: self.selectionFocus)
                restoring = false
                if let saved = project ?? readProject(at: editsURL(for: url)) { restore(saved) }
                changed()
                if captionsWantedOnOpen {
                    captionsWantedOnOpen = false
                    await captionFreshRecording(asset)
                }
            } catch is CancellationError {} catch { isPreparingPreview = false; message = "Could not open recording: \(error.localizedDescription)" }
        }
    }

    func finishRecording(url: URL, metadata: RecordingMetadata) async {
        do { try await library.register(url, metadata: metadata) }
        catch { message = "Video saved, but metadata could not be written: \(error.localizedDescription)" }
        // A recording that was just made is the one case where transcribing
        // without being asked is wanted: the narration is fresh, and nobody
        // records themselves talking in order to not have it written down.
        captionsWantedOnOpen = automaticCaptions
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
        movePreviewTask?.cancel(); movePreviewEnd = nil
        guard videoURL != nil else { return }
        if isPlaying { player.pause() } else {
            if playhead >= trimEnd - 0.05 || playhead < trimStart { seek(to: trimStart) }
            player.play()
        }
        isPlaying.toggle()
    }
    func previewEdit() {
        movePreviewTask?.cancel(); movePreviewEnd = nil
        guard videoURL != nil else { return }
        player.pause()
        seek(to: trimStart)
        player.play()
        isPlaying = true
    }
    func chooseMusic() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        musicURL = url
    }
    // MARK: - Captions

    var captionsBusy: Bool { captionProgress != nil }

    /// Listens to the recording and writes the lines.
    ///
    /// Anything already there is replaced, which is what "generate" means
    /// — and it is one undo step, so a set of hand-edited lines is never
    /// lost to a stray press.
    func generateCaptions() {
        guard let videoURL, !captionsBusy else { return }
        captionStatus = nil
        captionProgress = 0
        let language = captions.language
        let perLine = captions.wordsPerLine
        captionTask = Task {
            do {
                let words = try await CaptionTranscriber.words(in: videoURL, language: language) { share in
                    Task { @MainActor in
                        guard self.captionProgress != nil else { return }
                        self.captionProgress = min(0.99, share)
                    }
                }
                try Task.checkCancellation()
                var updated = captions
                updated.cues = CaptionBuilder.cues(from: words, wordsPerLine: perLine)
                updated.enabled = true
                captions = updated
                captionProgress = nil
                captionStatus = "\(updated.cues.count) lines from \(words.count) words."
            } catch is CancellationError {
                captionProgress = nil
            } catch {
                captionProgress = nil
                captionStatus = error.localizedDescription
            }
        }
    }

    /// Transcribes a recording that has just been made, quietly.
    ///
    /// Quietly is the point: nothing is asked, nothing pops up, and a
    /// recording with no narration in it simply produces no captions
    /// rather than an error in the middle of the editor. Anything that
    /// went wrong is left in the Captions panel for whoever goes looking.
    private func captionFreshRecording(_ asset: AVAsset) async {
        guard automaticCaptions, !captionsBusy else { return }
        // A refusal already on record is not worth asking about again after
        // every recording. The first time, macOS asks — which is the one
        // interruption this feature cannot avoid, and it happens with the
        // recording in front of you rather than out of nowhere.
        guard !CaptionTranscriber.permissionRefused else { return }
        // Nothing was said, so there is nothing to write down. No captions
        // and no complaint.
        guard let tracks = try? await asset.loadTracks(withMediaType: .audio), !tracks.isEmpty else { return }
        generateCaptions()
    }

    func cancelCaptions() {
        captionTask?.cancel(); captionTask = nil
        captionProgress = nil
        captionStatus = "Caption generation stopped."
    }

    func applyCaptionPreset(_ preset: CaptionPreset) {
        var updated = preset.apply(to: captions)
        updated.cues = CaptionBuilder.reflow(captions.cues, wordsPerLine: updated.wordsPerLine)
        captions = updated
    }

    /// Re-splits the existing lines, which is cheap — no second listen.
    func reflowCaptions(wordsPerLine: Int) {
        var updated = captions
        updated.wordsPerLine = wordsPerLine
        updated.cues = CaptionBuilder.reflow(captions.cues, wordsPerLine: wordsPerLine)
        captions = updated
    }

    func addCaptionCue() {
        var updated = captions
        let start = min(max(playhead, 0), max(0, duration - 0.6))
        let next = updated.cues.first { $0.start > start }?.start ?? .greatestFiniteMagnitude
        let cue = CaptionCue(start: start, duration: min(2, max(0.6, next - start)), text: "New line")
        updated.cues.append(cue)
        updated.cues.sort { $0.start < $1.start }
        updated.enabled = true
        captions = updated
        selectCaption(cue.id)
    }

    func removeCaptionCue(_ id: UUID) {
        var updated = captions
        updated.cues.removeAll { $0.id == id }
        captions = updated
        if selectedCaptionID == id { selectedCaptionID = nil }
    }

    func updateCaptionCue(_ id: UUID, _ change: (inout CaptionCue) -> Void) {
        guard let index = captions.cues.firstIndex(where: { $0.id == id }) else { return }
        var updated = captions
        change(&updated.cues[index])
        updated.cues[index].duration = max(0.2, updated.cues[index].duration)
        updated.cues.sort { $0.start < $1.start }
        captions = updated
    }

    // MARK: - Caption lines on the timeline and the canvas

    var selectedCaption: CaptionCue? { captions.cue(selectedCaptionID) }

    func selectCaption(_ id: UUID?) {
        selectedCaptionID = id
        if id != nil {
            selectedSegmentID = nil
            inspectorTab = "Captions"
        }
    }

    /// Moves a line, or the whole track, to a point on the canvas.
    ///
    /// With a line selected the drag moves that line alone, which is what
    /// the caption that happens to sit over the thing being pointed at
    /// needs. With nothing selected it moves every line together, which is
    /// what someone dragging the caption usually means.
    func placeCaption(at point: CGPoint, cue id: UUID?) {
        let x = min(1, max(0, point.x)), y = min(1, max(0, point.y))
        if let id, captions.cues.contains(where: { $0.id == id }) {
            updateCaptionCue(id) { $0.x = x; $0.y = y }
        } else {
            var updated = captions
            updated.placement = .free
            updated.x = x; updated.y = y
            // Lines pinned somewhere of their own would ignore the drag and
            // look like nothing happened, so they come along with it.
            for index in updated.cues.indices { updated.cues[index].x = nil; updated.cues[index].y = nil }
            captions = updated
        }
    }

    /// Back to a preset placement, dropping any by-hand positions.
    func resetCaptionPlacement() {
        var updated = captions
        updated.placement = .bottom
        updated.x = 0.5; updated.y = 0.86; updated.offset = 0
        for index in updated.cues.indices { updated.cues[index].x = nil; updated.cues[index].y = nil }
        captions = updated
    }

    /// One undo step for a whole drag, rather than one every 0.4 seconds.
    func beginCaptionGesture() { beginPoseGesture() }
    func endCaptionGesture() { endPoseGesture() }

    /// Moves a line bodily along the timeline, keeping its length.
    func moveCaption(_ id: UUID, to start: Double) {
        updateCaptionCue(id) { $0.start = max(0, min(duration - $0.duration, start)) }
    }

    /// Drags one end of a line. The other end stays, and a line keeps at
    /// least a fifth of a second of itself.
    func resizeCaption(_ id: UUID, leading: Bool, to time: Double) {
        updateCaptionCue(id) { cue in
            if leading {
                let start = min(cue.end - 0.2, max(0, time))
                cue.duration = cue.end - start
                cue.start = start
            } else {
                cue.duration = max(0.2, min(duration - cue.start, time - cue.start))
            }
        }
    }

    /// The lines as the exported file sees them: trimmed away where the
    /// edit trims, and on the output clock, so a subtitle file dropped on
    /// YouTube beside the export lines up with it.
    func exportableCues() -> [CaptionCue] {
        let origin = timeMap.outputTime(for: trimStart)
        return captions.cues.compactMap { cue in
            let from = max(cue.start, trimStart), to = min(cue.end, trimEnd)
            guard to > from + 0.05 else { return nil }
            let start = timeMap.outputTime(for: from) - origin
            let end = timeMap.outputTime(for: to) - origin
            guard end > start else { return nil }
            var moved = cue
            moved.start = start; moved.duration = end - start
            return moved
        }
    }

    /// Writes the lines out as a subtitle file, for a platform that would
    /// rather have them switchable than burned into the picture.
    func exportCaptionFile(asVTT: Bool = false) {
        let cues = exportableCues()
        guard !cues.isEmpty else { message = "There are no caption lines to write out."; return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = (videoURL?.deletingPathExtension().lastPathComponent ?? "Captions")
            + (asVTT ? ".vtt" : ".srt")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = asVTT ? CaptionBuilder.vtt(cues, casing: captions.casing)
                         : CaptionBuilder.srt(cues, casing: captions.casing)
        do { try text.write(to: url, atomically: true, encoding: .utf8); saveStatus = "Captions written" }
        catch { message = error.localizedDescription }
    }

    func seek(to seconds: Double) {
        playhead = max(0, min(duration, seconds))
        player.seek(to: CMTime(seconds: playerTimeMap.outputTime(for: playhead), preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }
    func setCameraVisible(_ visible: Bool) { showCamera = visible }
    func applyThreeDPreset(_ preset: ThreeDPreset) {
        guard videoURL != nil, duration > 0, trimEnd > trimStart else { return }
        player.pause(); isPlaying = false
        lastHistory = .distantPast
        if selectedSegment?.kind == .perspective {
            updateSelected { preset.apply(to: &$0) }
        } else {
            let length = min(3.0, trimEnd - trimStart)
            let start = min(max(trimStart, playhead), trimEnd - length)
            var segment = EditSegment(kind: .perspective, start: start, duration: length,
                                      intensity: 1, x: 0.5, y: 0.5)
            preset.apply(to: &segment)
            segments.append(segment)
            selectedSegmentID = segment.id
        }
        inspectorTab = "Segment"
        if let segment = selectedSegment { seek(to: segment.start + segment.duration * 0.72) }
    }

    /// A layer is a separate effect. Its local pose adds to existing motion,
    /// so creating a nested move never replaces the selected one.
    func addThreeDLayer(nested: Bool) {
        guard videoURL != nil, trimEnd > trimStart else { return }
        let parent = nested && selectedSegment?.kind == .perspective ? selectedSegment : nil
        let lower = max(trimStart, parent?.start ?? trimStart)
        let upper = min(trimEnd, parent?.end ?? trimEnd)
        guard upper - lower >= 0.1 else { return }
        let length = min(upper - lower, max(0.1, min(3, (upper - lower) * (parent == nil ? 1 : 0.5))))
        let start = min(max(lower, playhead), upper - length)
        var layer = EditSegment(kind: .perspective, start: start, duration: length, intensity: 1, x: 0.5, y: 0.5)
        layer.poseKeyframes = [PoseKeyframe(time: 0, pose: .neutral),
                               PoseKeyframe(time: 0.5, pose: .neutral),
                               PoseKeyframe(time: 1, pose: .neutral)]
        layer.curve = .smooth
        lastHistory = .distantPast
        segments.append(layer); selectedSegmentID = layer.id
        show3DCanvas = true; inspectorTab = "Segment"; seekPose(0.5)
    }

    func selectThreeDLayer(_ id: UUID) {
        guard let layer = segments.first(where: { $0.id == id && $0.kind == .perspective }) else { return }
        selectedSegmentID = id; inspectorTab = "Segment"
        seekPose(max(0, min(1, (playhead - layer.start) / layer.duration)))
    }

    func speedSelectedRange(_ speed: Double) {
        guard let selected = selectedSegment else { addSegment(.speed); updateSelected { $0.intensity = speed }; return }
        if selected.kind == .speed { updateSelected { $0.intensity = speed }; return }
        var range = EditSegment(kind: .speed, start: selected.start, duration: selected.duration,
                                intensity: speed, x: 0.5, y: 0.5)
        range.curve = .linear
        lastHistory = .distantPast; segments.append(range); selectedSegmentID = range.id
        inspectorTab = "Segment"
    }

    func reversePosePath() {
        guard let segment = selectedSegment, let frames = segment.poseKeyframes else { return }
        lastHistory = .distantPast
        updateSelected { $0.poseKeyframes = frames.map { f in
            var frame = f; frame.time = 1 - f.time; return frame
        }.sorted { $0.time < $1.time } }
    }

    func prepareCanvasDrag() {
        let time = playhead
        beginPoseGesture()
        if let segment = posedSegment, segment.poseKeyframes?.isEmpty != false {
            customizeThreeDPath(); seek(to: time)
        }
    }

    func beginTimelineGesture() {
        heldTimelineLanes = EffectLane.pack(segments)
        beginPoseGesture()
    }
    func endTimelineGesture() {
        heldTimelineLanes = nil
        endPoseGesture()
    }

    /// Capture a gesture once; long drags remain a single undo action.
    func beginPoseGesture() {
        player.pause(); isPlaying = false
        movePreviewTask?.cancel(); movePreviewEnd = nil
        guard !poseGestureActive else { return }
        lastHistory = .distantPast; remember(); poseGestureActive = true
    }
    func endPoseGesture() { poseGestureActive = false; lastHistory = .distantPast }

    func customizeThreeDPath() {
        guard videoURL != nil, duration > 0 else { return }
        if selectedSegment?.kind != .perspective { applyThreeDPreset(.orbit) }
        guard let segment = selectedSegment, segment.kind == .perspective else { return }
        player.pause(); isPlaying = false
        lastHistory = .distantPast
        if segment.poseKeyframes?.isEmpty != false {
            // Preserve the existing move at meaningful points when making it editable.
            let points = [0.0, 0.25, 0.5, 0.75, 1.0].map { t in
                PoseKeyframe(time: t, pose: MotionEngine.stance(
                    at: segment.start + segment.duration * t, segments: [segment]).pose)
            }
            updateSelected { $0.poseKeyframes = points; $0.posePreset = nil }
        }
        show3DCanvas = true
        seek(to: segment.start)
    }

    func seekPose(_ progress: Double) {
        guard let segment = selectedSegment, segment.kind == .perspective else { return }
        player.pause(); isPlaying = false; movePreviewTask?.cancel(); movePreviewEnd = nil
        seek(to: segment.start + max(0, min(1, progress)) * segment.duration)
    }

    func addPosePoint() {
        guard posedSegment?.poseKeyframes?.isEmpty == false else { return }
        beginPoseGesture(); let pose = editedPose; editedPose = pose; endPoseGesture()
    }

    func movePosePoint(_ id: UUID, to progress: Double) {
        guard let segment = selectedSegment, let frames = segment.poseKeyframes,
              let frame = frames.first(where: { $0.id == id }), frame.time > 0, frame.time < 1 else { return }
        let gap = min(0.01, 1 / max(1, segment.duration * 60))
        let lower = max(0, frames.filter { $0.time < frame.time }.map(\.time).max() ?? 0)
        let upper = min(1, frames.filter { $0.time > frame.time }.map(\.time).min() ?? 1)
        let time = max(lower + gap, min(upper - gap, progress))
        guard upper - lower > 2 * gap else { return }
        updateSelected { s in
            if let index = s.poseKeyframes?.firstIndex(where: { $0.id == id }) {
                s.poseKeyframes?[index].time = time
            }
        }
        seekPose(time)
    }

    var currentPosePoint: PoseKeyframe? {
        guard let segment = posedSegment else { return nil }
        let t = (playhead - segment.start) / segment.duration
        return segment.poseKeyframes?.first { abs($0.time - t) < 0.000001 }
    }

    func removePosePoint() {
        guard let point = currentPosePoint, point.time > 0, point.time < 1 else { return }
        lastHistory = .distantPast
        updateSelected { $0.poseKeyframes?.removeAll { $0.id == point.id } }
    }

    func previewThreeDMove() {
        guard let segment = selectedSegment, segment.kind == .perspective else { return }
        let start = max(trimStart, segment.start), end = min(trimEnd, segment.end)
        guard end > start else { return }
        movePreviewTask?.cancel()
        player.pause(); isPlaying = false
        let pending = previewTask
        movePreviewTask = Task { [weak self] in
            await pending?.value
            guard let self, !Task.isCancelled, self.selectedSegmentID == segment.id,
                  let item = self.player.currentItem else { return }
            self.playhead = start
            let arrived = await self.player.seek(to: CMTime(seconds: self.playerTimeMap.outputTime(for: start), preferredTimescale: 600),
                                                 toleranceBefore: .zero, toleranceAfter: .zero)
            guard arrived, !Task.isCancelled, self.player.currentItem === item else { return }
            self.movePreviewEnd = end
            self.player.play(); self.isPlaying = true
        }
    }
    func addSegment(_ kind: SegmentKind) {
        guard duration > 0 else { return }
        lastHistory = .distantPast
        let start = min(playhead, max(0, duration - 0.2))
        let crop = frameAppearance.crop.bounded
        var segment = EditSegment(kind: kind, start: start, duration: min(kind == .pan ? 4 : 2.5, duration - start), intensity: kind == .zoom || kind == .pan ? 1.65 : kind == .callout ? 1 : 2, x: crop.x + crop.width * 0.5, y: crop.y + crop.height * 0.5, width: kind == .outline ? 0.35 : nil, height: kind == .outline ? 0.25 : nil, transition: 0.7, curve: .smooth, endX: crop.x + crop.width * 0.75, endY: crop.y + crop.height * 0.5, text: kind == .callout ? "Look here" : nil)
        if kind == .perspective {
            // Something to look at straight away: a lean that sweeps across
            // the shot and settles back, rather than a segment that does
            // nothing until six sliders have been found.
            segment.pose = FramePose(pitch: 0.22, yaw: 0.38, zoom: 1.04)
            segment.sweeps = true
            // No blur: a lean is for looking at something more closely,
            // and softening the picture is the opposite of that. The
            // blur picker is right there for anyone who wants one.
            segment.blur = FrameBlur.none
            segment.blurAmount = 0
            segment.duration = min(3, max(0.6, duration - start))
            segment.transition = 0.8
        }
        segments.append(segment); selectedSegmentID = segment.id; inspectorTab = "Segment"
    }
    func deleteSelected() {
        if let id = selectedCaptionID { removeCaptionCue(id); return }
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
        let fraction = (playhead - segment.start) / segment.duration
        updateSelected {
            $0.duration = playhead - $0.start
            $0.poseKeyframes = segment.poseKeyframes?.map { frame in
                var copy = frame; copy.time /= fraction; return copy
            }
        }
        segment.poseKeyframes = segment.poseKeyframes?.map { frame in
            var copy = frame; copy.time = (copy.time - fraction) / (1 - fraction); return copy
        }
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
        guard segment != segments[index] else { return }
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

    func setTrimStart() { setTrimStart(to: playhead) }
    func setTrimEnd() { setTrimEnd(to: playhead) }
    /// Dragged on the timeline rather than taken from the playhead. Each end
    /// stops short of the other, so the kept stretch cannot be closed up.
    func setTrimStart(to time: Double) { trimStart = max(0, min(time, trimEnd - 0.1)) }
    func setTrimEnd(to time: Double) { trimEnd = min(duration, max(time, trimStart + 0.1)) }
    func resetTrim() { trimStart = 0; trimEnd = duration }

    private func remember() {
        guard !restoring, !poseGestureActive, videoURL != nil, duration > 0 else { return }
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
        cameraSize = d.cameraSize ?? 0.24; cameraHeightScale = d.cameraHeightScale ?? 1; cameraSubjectScale = d.cameraSubjectScale ?? 1
        cameraX = d.cameraX ?? 0.82; cameraY = d.cameraY ?? 0.78
        cameraCornerRadius = d.cameraCornerRadius ?? 14; cameraShape = d.cameraShape ?? .roundedRectangle; cameraMirrored = d.cameraMirrored ?? false
        trimStart = max(0, min(d.trimStart ?? 0, duration - 0.1)); trimEnd = min(duration, max(trimStart + 0.1, d.trimEnd ?? duration))
        playbackRate = max(0.25, min(3, d.playbackRate ?? 1)); muted = d.muted ?? false
        musicURL = d.musicPath.map { URL(fileURLWithPath: $0) }; musicVolume = min(1, max(0, d.musicVolume ?? 0.35))
        frameAppearance = d.frameAppearance ?? FrameAppearance(chrome: .none)
        motionAppearance = d.motionAppearance ?? MotionAppearance()
        cursorAppearance = d.cursorAppearance ?? CursorAppearance()
        customBackground = d.customBackground ?? CustomBackground()
        exportOptions = d.exportOptions ?? ExportOptions()
        customRatio = CGSize(width: d.customRatioWidth ?? 16, height: d.customRatioHeight ?? 10)
        grade = d.grade ?? GradeSettings()
        cameraMove = d.cameraMove ?? CameraMoveSettings()
        typingFollow = d.typingFollow ?? TypingFollowSettings()
        selectionFocus = d.selectionFocus ?? SelectionFocusSettings()
        sounds = d.sounds ?? SoundSettings()
        captions = d.captions ?? CaptionSettings()
        restoring = false
    }
    private func document() -> ProjectDocument {
        ProjectDocument(videoPath: videoURL?.path ?? "", segments: segments, background: background, ratio: ratio, padding: padding, cornerRadius: cornerRadius, shadow: shadow, cursorSize: cursorSize, clickEffects: clickEffects, showCursor: showCursor, smoothCursor: smoothCursor, cursorShadow: cursorShadow, showKeystrokes: showKeystrokes, showCamera: showCamera, cameraSize: cameraSize, cameraHeightScale: cameraHeightScale, cameraSubjectScale: cameraSubjectScale, cameraX: cameraX, cameraY: cameraY, cameraCornerRadius: cameraCornerRadius, cameraShape: cameraShape, cameraMirrored: cameraMirrored, trimStart: trimStart, trimEnd: trimEnd, playbackRate: playbackRate, muted: muted, musicPath: musicURL?.path, musicVolume: musicVolume, metadata: metadata, frameAppearance: frameAppearance, motionAppearance: motionAppearance, cursorAppearance: cursorAppearance, customBackground: customBackground, exportOptions: exportOptions, grade: grade, cameraMove: cameraMove, typingFollow: typingFollow, selectionFocus: selectionFocus, sounds: sounds, captions: captions, customRatioWidth: customRatio.width, customRatioHeight: customRatio.height, schema: ProjectDocument.schemaVersion)
    }
    /// Read, and brought up to today's defaults — a project saved before
    /// one of them changed should not be stuck with it.
    private func readProject(at url: URL) -> ProjectDocument? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONDecoder().decode(ProjectDocument.self, from: data))?.migrated()
    }
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
    func settings(preview: Bool = false) -> ExportSettings {
        ExportSettings(background: background, canvasSize: preview ? previewCanvasSize : canvasSize, padding: padding, cornerRadius: cornerRadius, shadow: shadow, segments: segments, pointerSamples: pointerSamples, clicks: recordedClicks, keystrokes: keystrokes, cursorSize: cursorSize, clickEffects: clickEffects, showKeystrokes: showKeystrokes, cameraURL: cameraURL, showCamera: showCamera, cameraSize: cameraSize, cameraHeightScale: cameraHeightScale, cameraSubjectScale: cameraSubjectScale, cameraX: cameraX, cameraY: cameraY, cameraCornerRadius: cameraCornerRadius, cameraShape: cameraShape, showCursor: showCursor && metadata.embeddedCursor != true, smoothCursor: smoothCursor, cursorShadow: cursorShadow, cameraMirrored: cameraMirrored, trimStart: trimStart, trimEnd: trimEnd, playbackRate: playbackRate, muted: muted, musicURL: musicURL, musicVolume: musicVolume, cameraTimeOffset: metadata.cameraTimeOffset ?? 0, frame: frameAppearance, motion: motionAppearance, cursor: cursorAppearance, cursorPointScale: sourceSize.width / max(1, metadata.sourcePointWidth ?? sourceSize.width), customBackground: customBackground, grade: grade, cameraMove: cameraMove, exportOptions: exportOptions, typingEvents: metadata.typingEvents ?? [], scrollEvents: metadata.scrollEvents ?? [], sounds: sounds, selectionFocus: selectionFocus, captions: captions)
    }
    private func changed(reusingMedia: Bool = false) {
        guard !restoring, let url = videoURL, duration > 0 else { return }
        if !reusingMedia { previewMediaDirty = true }
        movePreviewTask?.cancel(); movePreviewEnd = nil
        previewTask?.cancel(); saveStatus = "Saving…"
        previewTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(180))
                let settings = settings(preview: true)
                let item: AVPlayerItem
                if !previewMediaDirty, previewSourceURL == url, let current = player.currentItem,
                   let previous = current.videoComposition,
                   let composition = VideoExporter.updatingPresentation(previous, settings: settings) {
                    // 3D edits only change pixels. Reuse the assembled tracks,
                    // including music loops and hundreds of sound cues.
                    item = AVPlayerItem(asset: current.asset)
                    item.videoComposition = composition; item.audioMix = current.audioMix
                } else {
                    let (asset, composition, musicMix) = try await VideoExporter.composition(source: url, settings: settings)
                    item = AVPlayerItem(asset: asset); item.videoComposition = composition; item.audioMix = musicMix
                }
                try Task.checkCancellation()
                let time = playhead, playing = isPlaying
                previewMediaDirty = false; previewSourceURL = url
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
            recordedClicks = []; pointerSamples = []; keystrokes = []; metadata = .empty; musicURL = nil
            undoStack = []; redoStack = []; updateHistory(); UserDefaults.standard.removeObject(forKey: "FocusFlow.lastRecording")
        }
        try await library.delete(item)
    }
    private func installTimeObserver() {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1.0 / 60, preferredTimescale: 600), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, self.isPlaying else { return }
                self.playhead = time.seconds.isFinite ? self.playerTimeMap.sourceTime(for: time.seconds) : 0
                let end = min(self.trimEnd, self.movePreviewEnd ?? self.trimEnd)
                if self.playhead >= end - 0.02 {
                    self.player.pause(); self.isPlaying = false; self.movePreviewEnd = nil; self.seek(to: end)
                }
            }
        }
    }
    /// Regenerates the automatic pass with the current typing settings.
    func rebuildAutomaticEdit() {
        guard videoURL != nil, duration > 0 else { return }
        lastHistory = .distantPast
        segments = MotionEngine.autoEdits(clicks: recordedClicks, samples: pointerSamples, duration: duration,
                                          typing: metadata.typingEvents ?? [], typingFollow: typingFollow,
                                          selection: selectionFocus)
    }

    func addAutoZooms() {
        lastHistory = .distantPast
        segments.removeAll { $0.kind == .zoom }
        segments.append(contentsOf: Self.zoomSegments(from: recordedClicks, duration: duration))
    }
    func rebuildAutoEdits() {
        guard duration > 0 else { return }
        lastHistory = .distantPast
        segments = MotionEngine.autoEdits(clicks: recordedClicks, samples: pointerSamples, duration: duration, typing: metadata.typingEvents ?? [], typingFollow: typingFollow, selection: selectionFocus)
    }
    static func zoomSegments(from clicks: [RecordedClick], duration: Double) -> [EditSegment] {
        MotionEngine.autoZooms(clicks: clicks, duration: duration)
    }
}
