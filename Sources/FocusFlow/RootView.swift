import AVKit
import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: EditorModel
    @EnvironmentObject private var updater: Updater

    var body: some View {
        VStack(spacing: 0) {
            TopBar()
            UpdateBanner()
            Divider().overlay(AppTheme.line)
            HStack(spacing: 0) {
                ToolRail()
                Divider().overlay(AppTheme.line)
                VStack(spacing: 0) {
                    PreviewArea()
                    Divider().overlay(AppTheme.line)
                    TimelineView()
                }
                Divider().overlay(AppTheme.line)
                InspectorView()
            }
        }
        .background(AppTheme.workspace)
        .sheet(isPresented: $model.showCropEditor) { CropEditor() }
        .sheet(isPresented: $model.showRecorder) { RecorderView() }
        .sheet(isPresented: $model.showLibrary) { RecordingLibraryView(library: model.library) }
        .alert("FocusFlow", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
            Button("OK") { model.message = nil }
        } message: { Text(model.message ?? "") }
        .task {
            // A quiet check at launch; it reports nothing unless there is
            // actually a newer build.
            await updater.check(userInitiated: false)
        }
    }
}

/// Sits under the toolbar only when there is something to say.
struct UpdateBanner: View {
    @EnvironmentObject private var updater: Updater

    var body: some View {
        switch updater.state {
        case let .available(release) where !updater.dismissed:
            banner {
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(AppTheme.green)
                VStack(alignment: .leading, spacing: 1) {
                    Text("FocusFlow \(release.version.description) is available")
                        .font(.system(size: 12, weight: .semibold))
                    Text("You are on \(updater.currentVersion.description). Updating takes a few seconds and reopens the app.")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer()
                if let page = release.pageURL {
                    Button("What's new") { NSWorkspace.shared.open(page) }
                        .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Button("Install and relaunch") { updater.install(release) }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(AppTheme.green, in: RoundedRectangle(cornerRadius: 7))
                    .foregroundStyle(.white)
                Button { updater.dismissed = true } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Not now")
            }

        case let .downloading(progress):
            banner {
                ProgressView(value: progress).frame(width: 120)
                Text("Downloading the update… \(Int(progress * 100))%")
                    .font(.system(size: 12))
                Spacer()
            }

        case .installing:
            banner {
                ProgressView().controlSize(.small)
                Text("Installing. FocusFlow will reopen on its own.")
                    .font(.system(size: 12))
                Spacer()
            }

        case let .failed(reason):
            banner(tint: Color.orange.opacity(0.12)) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(reason).font(.system(size: 12)).lineLimit(2)
                Spacer()
                Button("Dismiss") { updater.clearStatus() }
                    .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
            }

        case .upToDate where !updater.dismissed:
            banner {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(AppTheme.green)
                Text("FocusFlow \(updater.currentVersion.description) is the latest version.")
                    .font(.system(size: 12))
                Spacer()
                Button("Dismiss") { updater.clearStatus() }
                    .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
            }

        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private func banner<Content: View>(tint: Color = AppTheme.green.opacity(0.08),
                                       @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 10) { content() }
            .padding(.horizontal, 16)
            .frame(height: 44)
            .background(tint)
    }
}

struct TopBar: View {
    @EnvironmentObject private var model: EditorModel
    @State private var confirmDelete = false
    var body: some View {
        HStack(spacing: 14) {
            AppIconMark(size: 27)
            Text("FocusFlow").font(.system(size: 15, weight: .bold))
            VStack(alignment: .leading, spacing: 3) {
                Text(model.videoURL?.deletingPathExtension().lastPathComponent ?? "Your next great demo").font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text(model.videoURL == nil ? "Record · refine · share" : model.saveStatus).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer()
            Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }.disabled(!model.canUndo).help("Undo ⌘Z")
            Button { model.redo() } label: { Image(systemName: "arrow.uturn.forward") }.disabled(!model.canRedo).help("Redo ⇧⌘Z")
            Button { confirmDelete = true } label: { Image(systemName: "trash") }
                .help("Move this recording to Trash")
                .disabled(!model.library.recordings.contains(where: { $0.url == model.videoURL }))
            Button { model.saveProject() } label: { Label("Save", systemImage: "square.and.arrow.down") }
                .buttonStyle(.plain).foregroundStyle(.secondary).disabled(model.videoURL == nil)
            Button { model.export() } label: {
                if let progress = model.exportProgress {
                    HStack(spacing: 7) { ProgressView(value: progress).frame(width: 58); Text("\(Int(progress * 100))%") }
                } else { Label("Export", systemImage: "arrow.up.right") }
            }
            .buttonStyle(.plain).padding(.horizontal, 13).padding(.vertical, 8)
            .background(AppTheme.green.opacity(model.videoURL == nil ? 0.4 : 1), in: RoundedRectangle(cornerRadius: 8)).foregroundStyle(.white).fontWeight(.semibold)
            .disabled(model.exportProgress != nil || model.videoURL == nil)
        }
        .padding(.horizontal, 16).frame(height: 52).background(AppTheme.panel)
        .alert("Move this recording to Trash?", isPresented: $confirmDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Move to Trash", role: .destructive) {
                guard let item = model.library.recordings.first(where: { $0.url == model.videoURL }) else { return }
                Task { do { try await model.deleteRecording(item) } catch { model.message = error.localizedDescription } }
            }
        } message: { Text("The screen video, camera layer, and saved edits will move to the Mac Trash, where you can recover them.") }
    }
}

struct ToolRail: View {
    @EnvironmentObject private var model: EditorModel
    var body: some View {
        VStack(spacing: 9) {
            RailButton(title: "Record", icon: "record.circle", active: true) { model.showRecorder = true }
            RailButton(title: "Library", icon: "film.stack", active: false) {
                Task { await model.library.refresh(); model.showLibrary = true }
            }
            RailButton(title: "Import", icon: "square.and.arrow.down", active: false) { model.importVideo() }
            Divider().overlay(AppTheme.line).padding(.vertical, 4)
            ForEach(SegmentKind.availableCases) { kind in
                RailButton(title: kind.title, icon: kind.symbol, active: false) { model.addSegment(kind) }.disabled(model.videoURL == nil)
            }
            Spacer()
            RailButton(title: "Delete", icon: "trash", active: false) { model.deleteSelected() }
                .disabled(model.selectedSegmentID == nil)
        }
        .padding(10).frame(width: 86).background(AppTheme.panel)
    }
}

struct RailButton: View {
    let title: String, icon: String, active: Bool, action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 17, weight: .medium))
                Text(title).font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(active ? AppTheme.green : .secondary)
            .frame(maxWidth: .infinity).padding(.vertical, 9)
            .background(active ? AppTheme.green.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 9))
        }.buttonStyle(.plain)
    }
}

struct PreviewArea: View {
    @EnvironmentObject private var model: EditorModel
    var body: some View {
        GeometryReader { proxy in
            let canvas = canvasSize(in: proxy.size)
            VStack(spacing: 14) {
                HStack {
                    Label("PREVIEW", systemImage: "viewfinder").font(.system(size: 10, weight: .semibold)).tracking(1)
                    Spacer()
                    Text(model.ratio.rawValue).font(.caption)
                    if model.videoURL != nil { Text("\(Int(model.sourceSize.width)) × \(Int(model.sourceSize.height))").font(.caption.monospacedDigit()) }
                }.foregroundStyle(.secondary).padding(.horizontal, 30).padding(.top, 18)
                Spacer(minLength: 0)
                ZStack {
                    if model.videoURL != nil {
                        NativeVideoPlayer(player: model.player).allowsHitTesting(false)
                        EditableFocusOverlay(canvasSize: canvas)
                        if model.showCamera, model.cameraURL != nil { EditableCameraOverlay(canvasSize: canvas) }
                        if model.isPreparingPreview { ProgressView("Preparing preview…").padding(16).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) }
                    } else { EmptyCanvas() }
                }
                .frame(width: canvas.width, height: canvas.height)
                .coordinateSpace(name: "canvas")
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(AppTheme.line))
                .shadow(color: .black.opacity(0.12), radius: 24, y: 12)
                PlaybackControls()
                Spacer(minLength: 10)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }.background(AppTheme.workspace)
    }
    func canvasSize(in available: CGSize) -> CGSize {
        let render = model.canvasSize, ratio = render.width / render.height
        let maxW = max(100, available.width - 60), maxH = max(100, available.height - 122)
        return maxW / maxH > ratio ? CGSize(width: maxH * ratio, height: maxH) : CGSize(width: maxW, height: maxW / ratio)
    }
}

struct EditableCameraOverlay: View {
    @EnvironmentObject private var model: EditorModel
    let canvasSize: CGSize
    @State private var origin: CGPoint?
    @State private var hovered = false
    var body: some View {
        let height = min(canvasSize.width, canvasSize.height) * model.cameraSize
        let width = model.cameraShape == .circle ? height : height * 1.45
        let x = max(width / 2, min(canvasSize.width - width / 2, model.cameraX * canvasSize.width))
        let y = max(height / 2, min(canvasSize.height - height / 2, model.cameraY * canvasSize.height))
        RoundedRectangle(cornerRadius: model.cameraShape == .circle ? height / 2 : 10)
            .fill(.clear).contentShape(Rectangle())
            .overlay(RoundedRectangle(cornerRadius: model.cameraShape == .circle ? height / 2 : 10).stroke(hovered ? AppTheme.green : .clear, style: StrokeStyle(lineWidth: 2, dash: [5])))
            .frame(width: width, height: height).position(x: x, y: y)
            .onHover { hovered = $0 }
            .gesture(DragGesture(coordinateSpace: .named("canvas")).onChanged { value in
                if origin == nil { origin = CGPoint(x: x, y: y) }
                guard let origin else { return }
                model.cameraX = max(width / 2, min(canvasSize.width - width / 2, origin.x + value.translation.width)) / canvasSize.width
                model.cameraY = max(height / 2, min(canvasSize.height - height / 2, origin.y + value.translation.height)) / canvasSize.height
            }.onEnded { _ in origin = nil })
            .help("Drag to reposition camera")
    }
}

struct NativeVideoPlayer: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}

struct EmptyCanvas: View {
    @EnvironmentObject private var model: EditorModel
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(hex: 0xE2EBDC), Color(hex: 0xD5E8D8), Color(hex: 0xEEF0DE)], startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(spacing: 14) {
                Image(systemName: "rectangle.inset.filled.and.cursorarrow").font(.system(size: 44, weight: .light)).foregroundStyle(AppTheme.green)
                Text("A little focus. A better story.").font(.system(size: 24, weight: .semibold))
                Text("Record your screen. Make every detail count.").foregroundStyle(.secondary).font(.subheadline)
                HStack(spacing: 10) {
                    Button { model.showRecorder = true } label: { Label("New recording", systemImage: "record.circle") }.buttonStyle(.plain).padding(.horizontal, 14).padding(.vertical, 8).background(AppTheme.green, in: RoundedRectangle(cornerRadius: 8)).foregroundStyle(.white)
                    Button("Open video or project") { model.importVideo() }
                }.padding(.top, 10)
            }.padding(20)
        }
    }
}

struct PlaybackControls: View {
    @EnvironmentObject private var model: EditorModel
    var body: some View {
        HStack(spacing: 16) {
            Button { model.seek(to: max(0, model.playhead - 5)) } label: { Image(systemName: "gobackward.5") }
            Button { model.togglePlayback() } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill").frame(width: 28, height: 28)
                    .background(.white).foregroundStyle(.black).clipShape(Circle())
            }.buttonStyle(.plain).disabled(model.videoURL == nil)
            Button { model.seek(to: min(model.duration, model.playhead + 5)) } label: { Image(systemName: "goforward.5") }
            Button { model.muted.toggle() } label: { Image(systemName: model.muted ? "speaker.slash" : "speaker.wave.2") }.help("Mute preview and export")
            Text("\(format(model.playhead)) / \(format(model.duration))").font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
        }.buttonStyle(.plain)
    }
    func format(_ seconds: Double) -> String { String(format: "%02d:%02d", Int(seconds) / 60, Int(seconds) % 60) }
}

struct InspectorView: View {
    @EnvironmentObject private var model: EditorModel
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Picker("Inspector", selection: $model.inspectorTab) {
                Text("Canvas").tag("Canvas"); Text("Segment").tag("Segment")
            }.pickerStyle(.segmented).padding(14)
            Divider().overlay(AppTheme.line)
            ScrollView {
                if model.inspectorTab == "Canvas" { CanvasInspector() }
                else { SegmentInspector() }
            }
        }.frame(width: 280).background(AppTheme.panel)
    }
}

struct CanvasInspector: View {
    @EnvironmentObject private var model: EditorModel
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            BackgroundInspector()
            InspectorSection(title: "FORMAT") {
                Picker("Ratio", selection: $model.ratio) { ForEach(CanvasRatio.allCases) { Text($0.rawValue).tag($0) } }.labelsHidden()
                Toggle("Re-fit when the ratio changes", isOn: $model.autoAdjustCanvas)
                    .font(.caption)
                    .help("Pulls in the padding and moves the camera into the free area after switching aspect.")
            }
            ExportInspector()
            WindowAppearanceInspector()
            MotionAppearanceInspector()
            InspectorSlider(title: "Padding", value: $model.padding, range: 0...18, suffix: "%")
            InspectorSlider(title: "Corners", value: $model.cornerRadius, range: 0...40, suffix: "")
            InspectorSlider(title: "Shadow", value: $model.shadow, range: 0...50, suffix: "")
            CursorAppearanceInspector()
            InspectorSection(title: "EDIT & AUDIO") {
                Picker("Speed", selection: $model.playbackRate) {
                    ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { Text("\($0, specifier: "%.2g")×").tag($0) }
                }
                Toggle("Mute audio", isOn: $model.muted)
                HStack {
                    Button("Set in") { model.setTrimStart() }.help("Trim start to playhead")
                    Button("Set out") { model.setTrimEnd() }.help("Trim end to playhead")
                    Button("Reset") { model.resetTrim() }
                }.font(.caption)
                Text("Export: \(model.outputDuration, specifier: "%.1f") s").font(.caption).foregroundStyle(.secondary)
            }
            if model.cameraURL != nil {
                InspectorSection(title: "CAMERA") {
                    Toggle("Mirror camera", isOn: $model.cameraMirrored)
                    Toggle("Include camera", isOn: Binding(get: { model.showCamera }, set: { model.setCameraVisible($0) }))
                    Picker("Shape", selection: $model.cameraShape) {
                        ForEach(CameraShape.allCases) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented)
                    InspectorSlider(title: "Size", value: $model.cameraSize, range: 0.12...0.48, suffix: "")
                    InspectorSlider(title: "Position X", value: $model.cameraX, range: 0.08...0.92, suffix: "")
                    InspectorSlider(title: "Position Y", value: $model.cameraY, range: 0.08...0.92, suffix: "")
                    if model.cameraShape == .roundedRectangle {
                        InspectorSlider(title: "Corners", value: $model.cameraCornerRadius, range: 0...40, suffix: "")
                    }
                    Text("Drag the green camera frame directly on the preview to reposition it.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }.padding(16)
    }
}

struct SegmentInspector: View {
    @EnvironmentObject private var model: EditorModel
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let segment = model.selectedSegment {
                Label(segment.kind.title, systemImage: segment.kind.symbol).font(.headline).foregroundStyle(AppTheme.green)
                InspectorSlider(title: "Start", value: Binding(get: { segment.start }, set: { v in model.updateSelected { $0.start = v } }), range: 0...max(0.1, model.duration), suffix: "s")
                InspectorSlider(title: "Duration", value: Binding(get: { segment.duration }, set: { v in model.updateSelected { $0.duration = v } }), range: 0.2...max(0.3, model.duration), suffix: "s")
                InspectorSlider(title: segment.kind == .zoom || segment.kind == .pan ? "Depth" : segment.kind == .callout ? "Text size" : "Amount", value: Binding(get: { segment.intensity }, set: { v in model.updateSelected { $0.intensity = v } }), range: 1...3, suffix: "×")
                if SegmentKind.availableCases.contains(segment.kind) {
                    InspectorSlider(title: "Focus X", value: Binding(get: { segment.x }, set: { v in model.updateSelected { $0.x = v } }), range: 0...1, suffix: "")
                    InspectorSlider(title: "Focus Y", value: Binding(get: { segment.y }, set: { v in model.updateSelected { $0.y = v } }), range: 0...1, suffix: "")
                }
                SegmentMotionInspector(segment: segment)
                if segment.kind == .blur || segment.kind == .spotlight {
                    InspectorSlider(title: "Region width", value: Binding(get: { segment.regionWidth }, set: { v in model.updateSelected { $0.width = v } }), range: 0.02...1, suffix: "")
                    InspectorSlider(title: "Region height", value: Binding(get: { segment.regionHeight }, set: { v in model.updateSelected { $0.height = v } }), range: 0.02...1, suffix: "")
                    if segment.kind == .blur { Button("Blur full frame") { model.updateSelected { $0.width = 1; $0.height = 1; $0.x = 0.5; $0.y = 0.5 } }
                    Text("Blur is applied in source coordinates before zoom. Scrub inside this segment to inspect the result.").font(.caption2).foregroundStyle(.secondary) }
                }
                HStack {
                    Button("Duplicate") { model.duplicateSelected() }
                    Button("Split at playhead") { model.splitSelected() }
                }.font(.caption)
                Button(role: .destructive) { model.deleteSelected() } label: { Label("Delete segment", systemImage: "trash") }
            } else {
                ContentUnavailableView("No segment selected", systemImage: "timeline.selection", description: Text("Select a segment in the timeline to edit it."))
            }
        }.padding(16)
    }
}

struct InspectorSection<Content: View>: View {
    let title: String; @ViewBuilder let content: Content
    var body: some View { VStack(alignment: .leading, spacing: 9) { Text(title).font(.system(size: 10, weight: .bold)).foregroundStyle(.tertiary); content } }
}

struct InspectorSlider: View {
    let title: String; @Binding var value: Double; let range: ClosedRange<Double>; let suffix: String
    var body: some View {
        VStack(spacing: 7) {
            HStack { Text(title).font(.caption); Spacer(); Text("\(value, specifier: "%.1f")\(suffix)").font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary) }
            Slider(value: $value, in: range).tint(AppTheme.green)
        }
    }
}
