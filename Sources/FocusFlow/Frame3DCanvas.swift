import AppKit
import SwiftUI

/// The 3D camera, on the canvas rather than behind six sliders.
///
/// Leaning the recorded content through space is a thing you do by looking at it, and
/// the inspector made it a thing you do by reading labels and guessing
/// which number moves which edge. This draws the content where it is actually
/// standing — the same quad the renderer projects the picture onto, worked out
/// by the same code — and lets it be taken hold of: drag the picture to
/// turn and lean it, the handle in the middle to slide it, the one above
/// to roll it, the one below to push in and pull back.
///
/// What it holds is whichever pose is in front of you: a 3D camera segment
/// when the playhead is inside the selected one, otherwise where the content
/// stands for the whole recording.
struct Frame3DOverlay: View {
    @EnvironmentObject private var model: EditorModel
    let canvasSize: CGSize

    /// The pose when the drag began, so a drag is an offset from where the
    /// content was rather than an accumulation of deltas.
    @State private var grabbed: FramePose?

    private var canvas: CGRect { CGRect(origin: .zero, size: canvasSize) }

    /// The recorded content opening, in view coordinates.
    private var square: CGRect {
        let layout = FrameLayout.make(canvas: canvas, sourceSize: model.contentSize,
                                      padding: model.padding, frame: model.frameAppearance)
        return layout.content
    }

    /// Where the renderer projects the content before clipping it back into
    /// the window's fixed opening.
    private func quad(for pose: FramePose) -> FrameQuad {
        pose.projection(of: square, canvas: square, lean: pose.lean())
            .flipped(in: canvasSize.height)
    }

    private var pose: FramePose { model.editedPose }
    var body: some View {
        // Compute the projection once per update, shared by the hit area,
        // outline, corners, and all three handles.
        let outline = quad(for: pose)
        let corners = outline.corners
        let centre = CGPoint(x: corners.map(\.x).reduce(0, +) / 4, y: corners.map(\.y).reduce(0, +) / 4)
        let rollHandle = CGPoint(x: (outline.topLeft.x + outline.topRight.x) / 2,
                                 y: max(14, (outline.topLeft.y + outline.topRight.y) / 2 - 26))
        let depthHandle = CGPoint(x: (outline.bottomLeft.x + outline.bottomRight.x) / 2,
                                  y: min(canvasSize.height - 14, (outline.bottomLeft.y + outline.bottomRight.y) / 2 + 26))
        ZStack(alignment: .topLeading) {
            // The projected content is the grip for turning and leaning.
            shape(outline)
                .fill(AppTheme.green.opacity(0.001))
                .contentShape(shape(outline))
                .gesture(turnAndLean)
                .help("Drag to turn and lean the recorded content")

            shape(outline)
                .stroke(AppTheme.green, style: StrokeStyle(lineWidth: 1.6, lineJoin: .round))
                .allowsHitTesting(false)

            // Where the content is actually projected at this moment, when a
            // move or a sweep has it somewhere other than the pose being
            // held. Without it, dragging inside a segment that sweeps looks
            // like the handles are lying.
            if let standing = ghost {
                shape(standing)
                    .stroke(AppTheme.green.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .allowsHitTesting(false)
            }

            ForEach(Array(outline.corners.enumerated()), id: \.offset) { corner in
                Circle().fill(AppTheme.green).frame(width: 7, height: 7)
                    .position(corner.element).allowsHitTesting(false)
            }

            handle(at: centre, icon: "move.3d", help: "Drag to slide the content", gesture: pan)
            handle(at: rollHandle, icon: "rotate.3d", help: "Drag to roll the content", gesture: roll)
            handle(at: depthHandle, icon: "arrow.up.and.down", help: "Drag up to push in, down to pull back", gesture: push)
        }
        .frame(width: canvasSize.width, height: canvasSize.height)
    }

    /// The faint outline, drawn only when it says something the solid one
    /// does not: a move that is playing, or a segment partway through its
    /// sweep, puts the content somewhere other than the pose being held.
    private var ghost: FrameQuad? {
        let standing = model.standingPose
        return standing == pose ? nil : quad(for: standing)
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
        model.player.pause(); model.isPlaying = false
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
        NSEvent.modifierFlags.contains(.shift) ? pose.clamped.snapped() : pose.clamped
    }

    private var turnAndLean: some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named("canvas"))
            .onChanged { value in
                let from = begin()
                // Dragging an edge away from you turns the frame that way:
                // pull the right side left and the right side recedes.
                model.editedPose = settle(from
                    .setting { $0.yaw = clamped(from.yaw - Double(value.translation.width / canvasSize.width) * 2) }
                    .setting { $0.pitch = clamped(from.pitch + Double(value.translation.height / canvasSize.height) * 2) })
            }
            .onEnded { _ in grabbed = nil }
    }

    private var pan: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("canvas"))
            .onChanged { value in
                let from = begin()
                model.editedPose = settle(from
                    .setting { $0.panX = clamped(from.panX + Double(value.translation.width / canvasSize.width) * 2) }
                    .setting { $0.panY = clamped(from.panY - Double(value.translation.height / canvasSize.height) * 2) })
            }
            .onEnded { _ in grabbed = nil }
    }

    private var roll: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("canvas"))
            .onChanged { value in
                let from = begin()
                model.editedPose = settle(from.setting {
                    $0.roll = clamped(from.roll + Double(value.translation.width / canvasSize.width) * 2)
                })
            }
            .onEnded { _ in grabbed = nil }
    }

    private var push: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("canvas"))
            .onChanged { value in
                let from = begin()
                let zoom = from.zoom - Double(value.translation.height / canvasSize.height) * 1.2
                model.editedPose = settle(from.setting { $0.zoom = max(0.6, min(1.8, zoom)) })
            }
            .onEnded { _ in grabbed = nil }
    }
}

/// The strip that says what the handles are holding and gets out of the way.
struct Frame3DBar: View {
    @EnvironmentObject private var model: EditorModel
    @State private var showingPresets = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button { showingPresets = true } label: {
                    Label("Choose a 3D look", systemImage: "square.grid.2x2")
                }.buttonStyle(.borderedProminent).tint(AppTheme.green)
                    .disabled(model.videoURL == nil)
                    .popover(isPresented: $showingPresets) { ThreeDPresetPicker { showingPresets = false } }
                if model.selectedSegment?.kind == .perspective {
                    Button { model.previewThreeDMove() } label: { Label("Preview", systemImage: "play.fill") }
                }
                Spacer(minLength: 0)
                Menu {
                    ForEach(CameraMoveSettings.quickPoses, id: \.name) { preset in
                        Button(preset.name) { model.editedPose = preset.pose }
                    }
                } label: { Image(systemName: "rotate.3d") }
                    .help("Static poses for the recorded content")
                Button { model.show3DCanvas = false } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Hide the 3D controls")
            }
            Text(model.posedSegment != nil
                 ? "Drag to adjust this move. Change strength and duration in the inspector."
                 : "Choose a look to animate. Drag the content to adjust its overall angle.")
                .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .font(.caption)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(AppTheme.panel, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(AppTheme.line))
    }
}
