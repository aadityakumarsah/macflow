import AVKit
import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: EditorModel
    @EnvironmentObject private var updater: Updater

    var body: some View {
        VStack(spacing: 0) {
            if !model.theatreMode {
                TopBar()
                UpdateBanner()
                Divider().overlay(AppTheme.line)
            }
            HStack(spacing: 0) {
                if !model.theatreMode {
                    ToolRail()
                    Divider().overlay(AppTheme.line)
                }
                VStack(spacing: 0) {
                    PreviewArea()
                    if !model.theatreMode && model.videoURL != nil {
                        Divider().overlay(AppTheme.line)
                        TimelineView()
                    }
                }
                if !model.theatreMode && model.videoURL != nil {
                    Divider().overlay(AppTheme.line)
                    InspectorView()
                }
            }
        }
        .background(model.theatreMode ? Color.black : AppTheme.workspace)
        .tint(AppTheme.green)
        .sheet(isPresented: $model.showCropEditor) { CropEditor() }
        .sheet(isPresented: $model.showRecorder) { RecorderView() }
        .sheet(isPresented: $model.showLibrary) { RecordingLibraryView(library: model.library) }
        .onOpenURL { url in
            guard url.scheme == "focusflow", url.host == "record-tab", url.path.isEmpty else { return }
            model.showRecorder = false
            Task {
                // A public web page posting video to loopback triggers Chrome's
                // local-network permission. Use the identical bundled studio
                // on the loopback origin for this web-to-app handoff instead.
                do { try await model.browserRecorder.launch(hosted: false) }
                catch { model.message = "Could not open the tab studio: \(error.localizedDescription)" }
            }
        }
        .alert("FocusFlow", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
            Button("OK") { model.message = nil }
        } message: { Text(model.message ?? "") }
        .background(
            // Escape leaves theatre mode. A hidden toolbar with no way back
            // would be a trap.
            Button("") { if model.theatreMode { model.setTheatreMode(false) } }
                .keyboardShortcut(.escape, modifiers: [])
                .opacity(0)
        )
        .task {
            // A quiet check at launch, then every few hours, so a window left
            // open for days still learns about a release. Reports nothing
            // unless there is actually a newer build.
            await updater.check(userInitiated: false)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Updater.recheckInterval))
                if Task.isCancelled { break }
                await updater.check(userInitiated: false)
            }
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
            Text("FocusFlow").font(.system(size: 15, weight: .semibold))
            Divider().frame(height: 22).padding(.horizontal, 4)
            VStack(alignment: .leading, spacing: 3) {
                Text(model.videoURL?.deletingPathExtension().lastPathComponent ?? "Studio").font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text(model.videoURL == nil ? "Your screen, beautifully presented" : model.saveStatus).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer()
            Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }.disabled(!model.canUndo).help("Undo ⌘Z")
            Button { model.redo() } label: { Image(systemName: "arrow.uturn.forward") }.disabled(!model.canRedo).help("Redo ⇧⌘Z")
            Menu {
                Button("Save project…") { model.saveProject() }.disabled(model.videoURL == nil)
                Button("Move recording to Trash…", role: .destructive) { confirmDelete = true }
                    .disabled(!model.library.recordings.contains(where: { $0.url == model.videoURL }))
            } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).fixedSize().help("Project actions")
            Button { model.toggleTheatreMode() } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                .help("Full screen preview ⌃⌘F")
                .disabled(model.videoURL == nil)
            Button { model.export() } label: {
                if let progress = model.exportProgress {
                    HStack(spacing: 7) { ProgressView(value: progress).frame(width: 58); Text("\(Int(progress * 100))%") }
                } else { Label("Export video", systemImage: "square.and.arrow.up") }
            }
            .buttonStyle(.plain).padding(.horizontal, 13).padding(.vertical, 8)
            .background(AppTheme.green.opacity(model.videoURL == nil ? 0.4 : 1), in: RoundedRectangle(cornerRadius: 8)).foregroundStyle(.white).fontWeight(.semibold)
            .disabled(model.exportProgress != nil || model.videoURL == nil)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 20).frame(height: 64).background(AppTheme.panel)
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
    private let sections: [(String, String)] = [
        ("Canvas", "rectangle.on.rectangle"), ("Cursor", "cursorarrow"),
        ("Motion", "sparkles"), ("Camera", "video"), ("Audio", "speaker.wave.2"),
        ("Export", "square.and.arrow.up")
    ]
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            RailButton(title: "Record", icon: "record.circle", active: false) { model.showRecorder = true }
            RailButton(title: "Recordings", icon: "film.stack", active: false) {
                Task { await model.library.refresh(); model.showLibrary = true }
            }
            RailButton(title: "Open file", icon: "folder", active: false) { model.importVideo() }
            Divider().padding(.vertical, 14)
            Text("STUDIO").font(.system(size: 9, weight: .semibold)).tracking(1.5)
                .foregroundStyle(.tertiary).padding(.horizontal, 12).padding(.bottom, 6)
            ForEach(sections, id: \.0) { title, icon in
                RailButton(title: title, icon: icon, active: model.inspectorTab == title && model.videoURL != nil) {
                    model.inspectorTab = title
                }.disabled(model.videoURL == nil)
            }
            Spacer()
            Label("Saved on this Mac", systemImage: "internaldrive")
                .font(.system(size: 10)).foregroundStyle(.secondary).padding(10)
        }
        .padding(12).padding(.top, 8).frame(width: 164).background(AppTheme.panel)
    }
}

struct RailButton: View {
    let title: String, icon: String, active: Bool, action: () -> Void
    @State private var hovered = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: icon).font(.system(size: 14, weight: .medium)).frame(width: 18)
                Text(title).font(.system(size: 12, weight: active ? .semibold : .medium))
                Spacer(minLength: 0)
            }
            .foregroundStyle(active ? AppTheme.green : Color.primary.opacity(0.75))
            .padding(.horizontal, 12).frame(height: 38)
            .background(active ? AppTheme.green.opacity(0.09) : hovered ? AppTheme.elevated : .clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }.buttonStyle(.plain).onHover { hovered = $0 }
    }
}

struct PreviewArea: View {
    @EnvironmentObject private var model: EditorModel
    @State private var showCustomRatio = false
    var body: some View {
        GeometryReader { proxy in
            let canvas = canvasSize(in: proxy.size)
            if model.videoURL == nil {
                EmptyCanvas().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
            VStack(spacing: 14) {
                HStack {
                    if model.theatreMode {
                        Button {
                            model.setTheatreMode(false)
                        } label: {
                            Label("Exit full screen", systemImage: "arrow.down.right.and.arrow.up.left")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(.white.opacity(0.12), in: Capsule())
                        .foregroundStyle(.white)
                        .help("Escape also leaves full screen")
                    } else {
                        Label("PREVIEW", systemImage: "viewfinder").font(.system(size: 10, weight: .semibold)).tracking(1)
                    }
                    Spacer()
                    if model.theatreMode {
                        Text(model.ratio.rawValue).font(.caption)
                    } else {
                        Button {
                            model.ratio = .custom
                            showCustomRatio = true
                        } label: {
                            Label("Custom ratio", systemImage: "aspectratio")
                                .font(.system(size: 11, weight: .medium))
                                .padding(.horizontal, 10).padding(.vertical, 7)
                                .background(AppTheme.panel, in: RoundedRectangle(cornerRadius: 7))
                        }
                        .buttonStyle(.plain).foregroundStyle(AppTheme.green)
                        .help("Set a custom width and height for your video")
                        .popover(isPresented: $showCustomRatio, arrowEdge: .bottom) {
                            VStack(alignment: .leading, spacing: 16) {
                                AspectRatioInspector()
                                HStack {
                                    Spacer()
                                    Button("Done") { showCustomRatio = false }
                                        .buttonStyle(.borderedProminent)
                                }
                            }.padding(20).frame(width: 320).tint(AppTheme.green)
                        }
                    }
                    Text("\(Int(model.canvasSize.width)) × \(Int(model.canvasSize.height))")
                        .font(.caption.monospacedDigit()).help("Output canvas size")
                }
                .foregroundStyle(model.theatreMode ? .white.opacity(0.65) : .secondary)
                .padding(.horizontal, 30).padding(.top, 18)
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
            }
        }.background(model.theatreMode ? Color.black : AppTheme.workspace)
    }
    func canvasSize(in available: CGSize) -> CGSize {
        let render = model.canvasSize, ratio = render.width / render.height
        // Theatre mode keeps only enough room for the transport and the exit
        // control; the editor layout leaves space for its surrounding chrome.
        let insetW: CGFloat = model.theatreMode ? 24 : 60
        let insetH: CGFloat = model.theatreMode ? 96 : 122
        let maxW = max(100, available.width - insetW), maxH = max(100, available.height - insetH)
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
        VStack(spacing: 28) {
            ZStack {
                RoundedRectangle(cornerRadius: 24).fill(AppTheme.green.opacity(0.06)).frame(width: 100, height: 100)
                Image(systemName: "rectangle.inset.filled.and.cursorarrow")
                    .font(.system(size: 42, weight: .light)).foregroundStyle(AppTheme.green)
            }
            VStack(spacing: 12) {
                Text("Good recordings start here.").font(.system(size: 30, weight: .semibold)).tracking(-0.8)
                Text("Capture your screen. Give every detail a little polish.")
                    .font(.system(size: 14)).foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Button { model.showRecorder = true } label: {
                    Label("New recording", systemImage: "record.circle").padding(.horizontal, 20).frame(height: 42)
                }.buttonStyle(.plain).background(AppTheme.green, in: RoundedRectangle(cornerRadius: 10)).foregroundStyle(.white)
                Button { model.importVideo() } label: {
                    Label("Open video", systemImage: "folder").padding(.horizontal, 20).frame(height: 42)
                }.buttonStyle(.plain).panelStyle(radius: 10)
            }.font(.system(size: 13, weight: .semibold))
            HStack(alignment: .top, spacing: 24) {
                feature("cursorarrow", "A clearer cursor", "Resize it after recording.")
                feature("sparkles", "A little movement", "Zoom in on what matters.")
                feature("rectangle.on.rectangle", "Your finishing touch", "Frame it. Export it. Share it.")
            }.padding(24).panelStyle(radius: 14).padding(.top, 18)
            Text("Local recording. No account needed.").font(.system(size: 11)).foregroundStyle(.tertiary)
        }.padding(36)
    }
    private func feature(_ icon: String, _ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Image(systemName: icon).font(.system(size: 17)).foregroundStyle(AppTheme.green)
            Text(title).font(.system(size: 12, weight: .semibold))
            Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
        }.frame(width: 160, alignment: .leading)
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
            HStack {
                Text(model.inspectorTab == "Segment" ? "Edit effect" : model.inspectorTab).font(.system(size: 15, weight: .semibold))
                Spacer()
                if model.inspectorTab == "Segment" {
                    Button { model.inspectorTab = "Motion" } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).help("Back to motion")
                }
            }.padding(20)
            Divider()
            ScrollView {
                Group {
                    switch model.inspectorTab {
                    case "Cursor": CursorAppearanceInspector().padding(18)
                    case "Motion": MotionPanel().padding(18)
                    case "Camera": CameraPanel().padding(18)
                    case "Audio": AudioPanel().padding(18)
                    case "Export": ExportPanel().padding(18)
                    case "Segment": SegmentInspector()
                    default: CanvasInspector()
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }.frame(width: 292).background(AppTheme.panel)
        .toggleStyle(.switch).controlSize(.small)
    }
}

struct CanvasInspector: View {
    @EnvironmentObject private var model: EditorModel
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            AspectRatioInspector()
            Divider()
            BackgroundInspector()
            WindowAppearanceInspector()
            InspectorSlider(title: "Padding", value: $model.padding, range: 0...18, suffix: "%")
            InspectorSlider(title: "Corners", value: $model.cornerRadius, range: 0...40, suffix: "")
            InspectorSlider(title: "Shadow", value: $model.shadow, range: 0...50, suffix: "")

        }.padding(16)
    }
}

/// Shared by the always-visible preview shortcut and the top of the Canvas panel.
struct AspectRatioInspector: View {
    @EnvironmentObject private var model: EditorModel
    var body: some View {
        InspectorSection(title: "Aspect ratio") {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                ForEach(CanvasRatio.allCases) { ratio in
                    Button { model.ratio = ratio } label: {
                        Text(ratio.rawValue).font(.system(size: 11, weight: .medium))
                            .frame(maxWidth: .infinity).frame(height: 32)
                            .foregroundStyle(model.ratio == ratio ? AppTheme.green : .primary)
                            .background(model.ratio == ratio ? AppTheme.green.opacity(0.1) : AppTheme.elevated, in: RoundedRectangle(cornerRadius: 7))
                            .overlay(RoundedRectangle(cornerRadius: 7).stroke(model.ratio == ratio ? AppTheme.green.opacity(0.4) : .clear))
                    }.buttonStyle(.plain)
                        .accessibilityLabel(ratio == .custom ? "Custom aspect ratio" : "Aspect ratio \(ratio.rawValue)")
                        .accessibilityAddTraits(model.ratio == ratio ? .isSelected : [])
                }
            }
            if model.ratio == .custom {
                HStack(alignment: .bottom, spacing: 8) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Width").font(.caption2).foregroundStyle(.secondary)
                        RatioField(value: $model.customRatio.width).accessibilityLabel("Aspect ratio width")
                    }
                    Text(":").foregroundStyle(.secondary).padding(.bottom, 4)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Height").font(.caption2).foregroundStyle(.secondary)
                        RatioField(value: $model.customRatio.height).accessibilityLabel("Aspect ratio height")
                    }
                    Spacer()
                    Button {
                        model.customRatio = CGSize(width: model.customRatio.height, height: model.customRatio.width)
                    } label: {
                        Image(systemName: "arrow.left.arrow.right").frame(width: 28, height: 26)
                    }.buttonStyle(.borderless).help("Swap width and height")
                        .accessibilityLabel("Swap aspect ratio width and height")
                }.padding(.top, 5)
                Text("Use proportions, like 16 : 10 or 2.39 : 1.")
                    .font(.caption2).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    ForEach(CanvasPreset.all) { preset in
                        Button(preset.label) { model.customRatio = preset.size }
                            .buttonStyle(.borderless).font(.caption2)
                            .frame(maxWidth: .infinity).padding(.vertical, 5)
                            .background(AppTheme.elevated, in: RoundedRectangle(cornerRadius: 5))
                    }
                }
            }
            Text("Output: \(Int(model.canvasSize.width)) × \(Int(model.canvasSize.height))")
                .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            Toggle("Re-fit when the ratio changes", isOn: $model.autoAdjustCanvas)
                .font(.caption).toggleStyle(.switch).controlSize(.small)
                .help("Pulls in the padding and moves the camera into the free area after switching aspect.")
        }
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
                if [.blur, .spotlight, .pixelate, .outline].contains(segment.kind) {
                    InspectorSlider(title: "Region width", value: Binding(get: { segment.regionWidth }, set: { v in model.updateSelected { $0.width = v } }), range: 0.02...1, suffix: "")
                    InspectorSlider(title: "Region height", value: Binding(get: { segment.regionHeight }, set: { v in model.updateSelected { $0.height = v } }), range: 0.02...1, suffix: "")
                    if segment.kind == .blur { Button("Blur full frame") { model.updateSelected { $0.width = 1; $0.height = 1; $0.x = 0.5; $0.y = 0.5 } }
                    Text("This region follows the recording before zoom. Scrub inside the segment to inspect it.").font(.caption2).foregroundStyle(.secondary) }
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
    var body: some View { VStack(alignment: .leading, spacing: 9) { Text(title.localizedCapitalized).font(.system(size: 12, weight: .semibold)).foregroundStyle(.primary); content } }
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


/// A ratio component. Accepts a decimal so 2.39 : 1 works, and refuses zero,
/// which would make the canvas degenerate.
private struct RatioField: View {
    @Binding var value: CGFloat
    @State private var text: String = ""

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.roundedBorder)
            .frame(width: 58)
            .multilineTextAlignment(.center)
            .font(.system(.caption, design: .monospaced))
            .onAppear { text = format(value) }
            .onChange(of: value) { _, new in
                if abs((Double(text) ?? -1) - Double(new)) > 0.0001 { text = format(new) }
            }
            .onSubmit { commit() }
            .onChange(of: text) { _, _ in commit() }
    }

    private func commit() {
        guard let parsed = Double(text.replacingOccurrences(of: ",", with: ".")),
              parsed > 0, parsed <= 1000 else { return }
        value = CGFloat(parsed)
    }

    private func format(_ value: CGFloat) -> String {
        let rounded = (Double(value) * 100).rounded() / 100
        return rounded == rounded.rounded() ? String(Int(rounded)) : String(rounded)
    }
}

struct CanvasPreset: Identifiable {
    let label: String
    let size: CGSize
    var id: String { label }

    static let all: [CanvasPreset] = [
        CanvasPreset(label: "21:9", size: CGSize(width: 21, height: 9)),
        CanvasPreset(label: "2.39:1", size: CGSize(width: 2.39, height: 1)),
        CanvasPreset(label: "3:2", size: CGSize(width: 3, height: 2)),
        CanvasPreset(label: "4:5", size: CGSize(width: 4, height: 5)),
    ]
}
