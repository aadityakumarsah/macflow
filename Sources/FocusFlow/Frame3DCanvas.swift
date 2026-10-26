import AppKit
import SwiftUI

enum CanvasMotionTool: String, CaseIterable, Identifiable {
    case slide = "Slide", tilt = "Tilt", rotate = "Rotate", depth = "Depth"
    var id: String { rawValue }
}

/// The 3D camera, on the canvas rather than behind six sliders.
///
/// Leaning the frame and its recorded content through space is a thing you do by looking at it, and
/// the inspector made it a thing you do by reading labels and guessing
/// which number moves which edge. This draws the frame where it is actually
/// standing — the same quad the renderer projects the picture onto, worked out
/// by the same code — and lets it be taken hold of: drag the picture to
/// turn and lean it, the handle in the middle to slide it, the one above
/// to roll it, the one below to push in and pull back.
///
/// What it holds is whichever pose is in front of you: a 3D camera segment
/// when the playhead is inside the selected one, otherwise where the frame
/// stands for the whole recording.
struct Frame3DOverlay: View {
    @EnvironmentObject private var model: EditorModel
    let canvasSize: CGSize

    /// The pose when the drag began, so a drag is an offset from where the
    /// frame was rather than an accumulation of deltas.
    @State private var grabbed: FramePose?

    private var canvas: CGRect { CGRect(origin: .zero, size: canvasSize) }

    /// The outer frame follows the full pose, including its chrome and shadow.
    private func map(for pose: FramePose) -> ProjectiveMap {
        let playing = model.cameraMove.performance(at: model.playhead - model.trimStart,
            clip: model.trimEnd - model.trimStart, width: Double(canvas.width))
        let outer = pose.projection(of: canvas, canvas: canvas, lean: pose.lean(adding: playing.lean),
                                    scale: playing.scale, shiftX: playing.shiftX)
        return ProjectiveMap(canvas, to: outer)
    }

    /// A second guide shows the restrained parallax inside the moving frame.
    private func contentQuad(for pose: FramePose, in content: CGRect,
                             outerMap: ProjectiveMap) -> FrameQuad {
        let innerPose = model.cameraMove.pose.weighted(FramePose.contentParallax)
            .added(MotionEngine.stance(at: model.playhead, segments: model.segments).pose.weighted(FramePose.contentParallax))
        let inner = innerPose.projection(of: content, canvas: content,
                                          lean: innerPose.lean())
        return FrameQuad(bottomLeft: outerMap(inner.bottomLeft), bottomRight: outerMap(inner.bottomRight),
                         topRight: outerMap(inner.topRight), topLeft: outerMap(inner.topLeft))
            .flipped(in: canvasSize.height)
    }

    private var pose: FramePose { model.standingPose }
    var body: some View {
        let layout = FrameLayout.make(canvas: canvas, sourceSize: model.contentSize,
                                      padding: model.padding, frame: model.frameAppearance)
        // Share one outer projection between the frame, content guide, hit
        // area and handles so they cannot drift apart while a pose changes.
        let outerMap = map(for: pose)
        let outline = outerMap.quad(of: layout.outer).flipped(in: canvasSize.height)
        let contentOutline = contentQuad(for: pose, in: layout.content, outerMap: outerMap)
        let standing = model.standingPose
        let ghost = standing == pose ? nil : map(for: standing).quad(of: layout.outer)
            .flipped(in: canvasSize.height)
        let corners = outline.corners
        let centre = CGPoint(x: corners.map(\.x).reduce(0, +) / 4, y: corners.map(\.y).reduce(0, +) / 4)
        let rollHandle = CGPoint(x: (outline.topLeft.x + outline.topRight.x) / 2,
                                 y: max(14, (outline.topLeft.y + outline.topRight.y) / 2 - 26))
        let depthHandle = CGPoint(x: (outline.bottomLeft.x + outline.bottomRight.x) / 2,
                                  y: min(canvasSize.height - 14, (outline.bottomLeft.y + outline.bottomRight.y) / 2 + 26))
        ZStack(alignment: .topLeading) {
            if model.snap3D {
                Path { path in
                    if abs(pose.panX) < 0.018 {
                        path.move(to: CGPoint(x: canvasSize.width / 2, y: 0))
                        path.addLine(to: CGPoint(x: canvasSize.width / 2, y: canvasSize.height))
                    }
                    if abs(pose.panY) < 0.018 {
                        path.move(to: CGPoint(x: 0, y: canvasSize.height / 2))
                        path.addLine(to: CGPoint(x: canvasSize.width, y: canvasSize.height / 2))
                    }
                }.stroke(AppTheme.green.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .allowsHitTesting(false)
            }
            // The whole framed shot is the grip; content follows the drag.
            shape(outline)
                .fill(AppTheme.green.opacity(0.001))
                .contentShape(shape(outline))
                .gesture(turnAndLean)
                .help("Drag to \(model.canvasTool.rawValue.lowercased()) the selected layer")

            shape(outline)
                .stroke(AppTheme.green, style: StrokeStyle(lineWidth: 1.6, lineJoin: .round))
                .allowsHitTesting(false)

            shape(contentOutline)
                .stroke(AppTheme.green.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [5, 3]))
                .allowsHitTesting(false)

            // Where the frame is actually projected at this moment, when a
            // move or a sweep has it somewhere other than the pose being
            // held. Without it, dragging inside a segment that sweeps looks
            // like the handles are lying.
            if let ghost {
                shape(ghost)
                    .stroke(AppTheme.green.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .allowsHitTesting(false)
            }

            ForEach(Array(outline.corners.enumerated()), id: \.offset) { corner in
                Circle().fill(AppTheme.green).frame(width: 7, height: 7)
                    .position(corner.element).allowsHitTesting(false)
            }

            handle(at: centre, icon: "move.3d", help: "Drag to slide the frame and content", gesture: pan)
            handle(at: rollHandle, icon: "rotate.3d", help: "Drag to roll the frame and content", gesture: roll)
            handle(at: depthHandle, icon: "arrow.up.and.down", help: "Drag up to push in, down to pull back", gesture: push)
        }
        .frame(width: canvasSize.width, height: canvasSize.height)
    }

    private func shape(_ quad: FrameQuad) -> Path {
        var path = Path()
        path.move(to: quad.bottomLeft)
        path.addLine(to: quad.bottomRight)
        path.addLine(to: quad.topRight)
        path.addLine(to: quad.topLeft)
        path.closeSubpath()
        return path
    }

    private func handle(at point: CGPoint, icon: String, help: String, gesture: some Gesture) -> some View {
        Circle()
            .fill(AppTheme.green)
            .overlay(Image(systemName: icon).font(.system(size: 10, weight: .semibold)).foregroundStyle(.white))
            .frame(width: 22, height: 22)
            .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
            .position(point)
            .gesture(gesture)
            .help(help)
    }

    /// Starts a drag, pausing playback: a frame moving under the handles
    /// while they are being dragged is impossible to aim.
    private func begin() -> FramePose {
        if let grabbed { return grabbed }
        model.prepareCanvasDrag()
        let pose = model.editedPose
        grabbed = pose
        return pose
    }

    private func clamped(_ value: Double, _ limit: Double = 1) -> Double { max(-limit, min(limit, value)) }

    /// Shift rounds the pose to a step, so a lean can be exactly a
    /// quarter turn rather than nearly one. Read from the keyboard
    /// directly: a drag is already under way by the time it is held, and
    /// a gesture modifier would have to be decided before it began.
    private func settle(_ pose: FramePose) -> FramePose {
        if NSEvent.modifierFlags.contains(.shift) { return pose.clamped.snapped() }
        guard model.snap3D else { return pose.clamped }
        let others = (model.posedSegment == nil ? FramePose.neutral : model.cameraMove.pose).added(MotionEngine.stance(at: model.playhead,
            segments: model.segments.filter { $0.id != model.posedSegment?.id }).pose)
        var result = pose.clamped
        // Snap the visible, combined pose to the canvas axes, even in a nested layer.
        if abs(result.panX + others.panX) < 0.018 { result.panX = -others.panX }
        if abs(result.panY + others.panY) < 0.018 { result.panY = -others.panY }
        if abs(result.roll + others.roll) < 0.018 { result.roll = -others.roll }
        return result.clamped
    }

    private var turnAndLean: some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named("canvas"))
            .onChanged { value in
                let from = begin()
                // Dragging an edge away from you turns the frame that way:
                // pull the right side left and the right side recedes.
                let dx = Double(value.translation.width / canvasSize.width) * 2
                let dy = Double(value.translation.height / canvasSize.height) * 2
                var next = from
                switch model.canvasTool {
                case .tilt: next.yaw -= dx; next.pitch += dy
                case .slide: next.panX += dx; next.panY -= dy
                case .rotate: next.roll += dx
                case .depth: next.zoom -= dy * 0.6
                }
                model.editedPose = settle(next)
            }
            .onEnded { _ in grabbed = nil; model.endPoseGesture() }
    }

    private var pan: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("canvas"))
            .onChanged { value in
                let from = begin()
                model.editedPose = settle(from
                    .setting { $0.panX = clamped(from.panX + Double(value.translation.width / canvasSize.width) * 2) }
                    .setting { $0.panY = clamped(from.panY - Double(value.translation.height / canvasSize.height) * 2) })
            }
            .onEnded { _ in grabbed = nil; model.endPoseGesture() }
    }

    private var roll: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("canvas"))
            .onChanged { value in
                let from = begin()
                model.editedPose = settle(from.setting {
                    $0.roll = clamped(from.roll + Double(value.translation.width / canvasSize.width) * 2)
                })
            }
            .onEnded { _ in grabbed = nil; model.endPoseGesture() }
    }

    private var push: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("canvas"))
            .onChanged { value in
                let from = begin()
                let zoom = from.zoom - Double(value.translation.height / canvasSize.height) * 1.2
                model.editedPose = settle(from.setting { $0.zoom = max(0.6, min(1.8, zoom)) })
            }
            .onEnded { _ in grabbed = nil; model.endPoseGesture() }
    }
}

/// The strip that says what the handles are holding and gets out of the way.
struct Frame3DBar: View {
    @EnvironmentObject private var model: EditorModel
    @State private var showingPresets = false
    @State private var showingTiming = false
    private var layerTitle: String {
        let layers = model.segments.filter { $0.kind == .perspective }
        guard let index = layers.firstIndex(where: { $0.id == model.selectedSegmentID }) else { return "Layers" }
        return "Layer \(index + 1)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button { showingPresets = true } label: {
                    Label("Choose a 3D look", systemImage: "square.grid.2x2")
                }.buttonStyle(.borderedProminent).tint(AppTheme.green)
                    .disabled(model.videoURL == nil)
                    .popover(isPresented: $showingPresets) { ThreeDPresetPicker { showingPresets = false } }
                if model.selectedSegment?.poseKeyframes?.isEmpty != false {
                    Button("Draw my move") { model.customizeThreeDPath() }
                } else {
                    Button("Timing") { showingTiming = true }
                        .popover(isPresented: $showingTiming) {
                            if let segment = model.selectedSegment {
                                VStack(spacing: 16) {
                                    InspectorSlider(title: "Start", value: Binding(get: { model.selectedSegment?.start ?? segment.start }, set: { v in model.updateSelected { $0.start = v } }), range: 0...max(0.1, model.duration), suffix: "s")
                                    InspectorSlider(title: "Duration", value: Binding(get: { model.selectedSegment?.duration ?? segment.duration }, set: { v in model.updateSelected { $0.duration = v } }), range: 0.2...max(0.3, model.duration), suffix: "s")
                                }.padding(16).frame(width: 280)
                            }
                        }
                }
                if model.selectedSegment?.kind == .perspective {
                    Button { model.previewThreeDMove() } label: { Label("Preview", systemImage: "play.fill") }
                }
                Spacer(minLength: 0)
                Menu {
                    ForEach(CameraMoveSettings.quickPoses, id: \.name) { preset in
                        Button(preset.name) { model.editedPose = preset.pose }
                    }
                } label: { Image(systemName: "rotate.3d") }
                    .help("Static poses for the frame and content")
                Button { model.show3DCanvas = false } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Hide the 3D controls")
            }
            HStack {
                Menu {
                    Button("New 3D layer") { model.addThreeDLayer(nested: false) }
                    Button("Nested move inside selected") { model.addThreeDLayer(nested: true) }
                        .disabled(model.selectedSegment?.kind != .perspective)
                    Divider()
                    ForEach(Array(model.segments.filter { $0.kind == .perspective }.enumerated()), id: \.element.id) { index, layer in
                        Button("Layer \(index + 1) · \(String(format: "%.1f–%.1fs", layer.start, layer.end))") { model.selectThreeDLayer(layer.id) }
                    }
                } label: { Label(layerTitle, systemImage: "square.3.layers.3d") }
                Picker("Drag tool", selection: $model.canvasTool) {
                    ForEach(CanvasMotionTool.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).labelsHidden()
                Toggle("Snap", isOn: $model.snap3D).toggleStyle(.checkbox)
            }
            if let segment = model.selectedSegment, segment.poseKeyframes?.isEmpty == false {
                PosePathStrip(segment: segment)
            }
            Text("Drag with the selected tool · Shift snaps to steps · Layers adds nested motion")
                .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .font(.caption)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(AppTheme.panel, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(AppTheme.line))
    }
}

/// A local timeline for just the selected move; other effects remain untouched.
struct PosePathStrip: View {
    @EnvironmentObject private var model: EditorModel
    let segment: EditSegment
    @State private var dragging = false
    private var progress: Double { max(0, min(1, (model.playhead - segment.start) / segment.duration)) }
    private var points: [PoseKeyframe] { (segment.poseKeyframes ?? []).filter { $0.time >= 0 && $0.time <= 1 } }

    private func step(_ direction: Double) {
        let output = model.timeMap.outputTime(for: model.playhead) + direction / Double(model.exportOptions.frameRate.rawValue)
        let source = model.timeMap.sourceTime(for: output)
        model.seekPose((source - segment.start) / max(0.001, segment.duration))
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Button("Start") { model.seekPose(0) }
                Button("End") { model.seekPose(1) }
                Button { step(-1) } label: { Image(systemName: "backward.frame") }
                    .help("Previous output frame")
                Button { step(1) } label: { Image(systemName: "forward.frame") }
                    .help("Next output frame")
                Text(String(format: "%.2f / %.2f s", progress * segment.duration, segment.duration))
                    .monospacedDigit().foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Button("Add point") { model.addPosePoint() }.disabled(model.posedSegment == nil)
                Button { model.removePosePoint() } label: { Image(systemName: "trash") }
                    .help("Delete this point")
                    .disabled(model.currentPosePoint == nil || progress <= 0 || progress >= 1)
            }
            GeometryReader { proxy in
                let width = max(1, proxy.size.width - 20)
                ZStack(alignment: .leading) {
                    Capsule().fill(AppTheme.line).frame(height: 4)
                    Rectangle().fill(AppTheme.green.opacity(0.12)).frame(height: 30)
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                            model.seekPose(Double((value.location.x - 10) / width))
                        })
                    Rectangle().fill(AppTheme.green).frame(width: 2, height: 30)
                        .offset(x: 10 + progress * width).allowsHitTesting(false)
                    ForEach(points) { point in
                        Image(systemName: "diamond.fill")
                            .foregroundStyle(abs(point.time - progress) < 0.000001 ? AppTheme.green : Color.secondary)
                            .frame(width: 20, height: 30).contentShape(Rectangle())
                            .offset(x: point.time * width)
                            .onTapGesture { model.seekPose(point.time) }
                            .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .named("posePath"))
                                .onChanged { value in
                                    if !dragging { model.beginPoseGesture(); dragging = true }
                                    model.movePosePoint(point.id, to: Double((value.location.x - 10) / width))
                                }
                                .onEnded { _ in model.endPoseGesture(); dragging = false })
                            .help("Click to edit this pose. Drag to change when it happens.")
                            .accessibilityLabel("Pose at \(String(format: "%.2f", point.time * segment.duration)) seconds")
                    }
                }.coordinateSpace(name: "posePath")
            }.frame(height: 30)
            HStack {
                Button("Reset pose") {
                    model.beginPoseGesture(); model.editedPose = .neutral; model.endPoseGesture()
                }.disabled(model.posedSegment == nil)
                Button("Return at end") {
                    model.seekPose(1)
                    model.beginPoseGesture(); model.editedPose = .neutral; model.endPoseGesture()
                }
                Menu {
                    Button("Reverse path") { model.reversePosePath() }
                    ForEach([0.5, 1.0, 1.5, 2.0, 4.0], id: \.self) { rate in
                        Button("Video range \(rate, specifier: "%.1f")×") { model.speedSelectedRange(rate) }
                    }
                } label: { Image(systemName: "ellipsis.circle") }
                Spacer(minLength: 4)
                Picker("Motion", selection: Binding(get: { segment.curve ?? .smooth }, set: { curve in
                    model.updateSelected { $0.curve = curve }
                })) {
                    ForEach(MotionCurve.allCases) { Text($0.rawValue).tag($0) }
                }.labelsHidden().frame(width: 100)
            }
        }
    }
}
