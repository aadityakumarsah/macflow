import SwiftUI

/// The 3D camera, on the canvas rather than behind six sliders.
///
/// Leaning a frame through space is a thing you do by looking at it, and
/// the inspector made it a thing you do by reading labels and guessing
/// which number moves which edge. This draws the frame where it is actually
/// standing — the same quad the renderer warps the picture onto, worked out
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

    /// The frame itself, in view coordinates before it leans anywhere.
    private var square: CGRect {
        let layout = FrameLayout.make(canvas: canvas, sourceSize: model.contentSize,
                                      padding: model.padding, frame: model.frameAppearance)
        return layout.outer
    }

    /// Where a pose puts the frame, in view coordinates.
    ///
    /// The renderer warps the whole canvas and the frame travels with it,
    /// so the frame's corners are found by carrying them through the canvas
    /// map — not by warping the frame on its own, which would drift from
    /// the picture as the lean deepens.
    private func quad(for pose: FramePose) -> FrameQuad {
        let warped = pose.projection(of: canvas, canvas: canvas, lean: pose.lean())
        return ProjectiveMap(canvas, to: warped).quad(of: square).flipped(in: canvasSize.height)
    }

    private var pose: FramePose { model.editedPose }
    private var outline: FrameQuad { quad(for: pose) }

    /// The handles are placed off the outline, so they travel with the lean.
    private var centre: CGPoint {
        let corners = outline.corners
        return CGPoint(x: corners.map(\.x).reduce(0, +) / 4, y: corners.map(\.y).reduce(0, +) / 4)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // The whole frame is the grip for turning and leaning: a 3D
            // camera is the picture itself being moved, so that is what you
            // take hold of.
            shape(outline)
                .fill(AppTheme.green.opacity(0.001))
                .contentShape(shape(outline))
                .gesture(turnAndLean)
                .help("Drag to turn and lean the frame")

            shape(outline)
                .stroke(AppTheme.green, style: StrokeStyle(lineWidth: 1.6, lineJoin: .round))
                .allowsHitTesting(false)

            // Where the frame is actually standing at this moment, when a
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

            handle(at: centre, icon: "move.3d", help: "Drag to slide the frame", gesture: pan)
            handle(at: rollHandle, icon: "rotate.3d", help: "Drag to roll the frame", gesture: roll)
            handle(at: depthHandle, icon: "arrow.up.and.down", help: "Drag up to push in, down to pull back", gesture: push)
        }
        .frame(width: canvasSize.width, height: canvasSize.height)
    }

    /// The faint outline, drawn only when it says something the solid one
    /// does not: a move that is playing, or a segment partway through its
    /// sweep, puts the frame somewhere other than the pose being held.
    private var ghost: FrameQuad? {
        let standing = model.standingPose
        return standing == pose ? nil : quad(for: standing)
    }

    private var rollHandle: CGPoint {
        let top = CGPoint(x: (outline.topLeft.x + outline.topRight.x) / 2,
                          y: (outline.topLeft.y + outline.topRight.y) / 2)
        return CGPoint(x: top.x, y: max(14, top.y - 26))
    }

    private var depthHandle: CGPoint {
        let bottom = CGPoint(x: (outline.bottomLeft.x + outline.bottomRight.x) / 2,
                             y: (outline.bottomLeft.y + outline.bottomRight.y) / 2)
        return CGPoint(x: bottom.x, y: min(canvasSize.height - 14, bottom.y + 26))
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

    private var turnAndLean: some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named("canvas"))
            .onChanged { value in
                let from = begin()
                // Dragging an edge away from you turns the frame that way:
                // pull the right side left and the right side recedes.
                model.editedPose = from
                    .setting { $0.yaw = clamped(from.yaw - Double(value.translation.width / canvasSize.width) * 2) }
                    .setting { $0.pitch = clamped(from.pitch + Double(value.translation.height / canvasSize.height) * 2) }
            }
            .onEnded { _ in grabbed = nil }
    }

    private var pan: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("canvas"))
            .onChanged { value in
                let from = begin()
                model.editedPose = from
                    .setting { $0.panX = clamped(from.panX + Double(value.translation.width / canvasSize.width) * 2) }
                    .setting { $0.panY = clamped(from.panY - Double(value.translation.height / canvasSize.height) * 2) }
            }
            .onEnded { _ in grabbed = nil }
    }

    private var roll: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("canvas"))
            .onChanged { value in
                let from = begin()
                model.editedPose = from.setting {
                    $0.roll = clamped(from.roll + Double(value.translation.width / canvasSize.width) * 2)
                }
            }
            .onEnded { _ in grabbed = nil }
    }

    private var push: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("canvas"))
            .onChanged { value in
                let from = begin()
                let zoom = from.zoom - Double(value.translation.height / canvasSize.height) * 1.2
                model.editedPose = from.setting { $0.zoom = max(0.6, min(1.8, zoom)) }
            }
            .onEnded { _ in grabbed = nil }
    }
}

/// The strip that says what the handles are holding and gets out of the way.
struct Frame3DBar: View {
    @EnvironmentObject private var model: EditorModel

    private var editingSegment: Bool { model.posedSegment != nil }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "cube.transparent").foregroundStyle(AppTheme.green)
            VStack(alignment: .leading, spacing: 1) {
                Text(editingSegment ? "3D camera on the timeline" : "Where the frame stands")
                    .font(.system(size: 11, weight: .semibold))
                Text(editingSegment
                     ? "Drag the picture to turn and lean this move."
                     : "Drag the picture to turn and lean it for the whole recording.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer()
            if !editingSegment {
                Button("Make it a move") {
                    model.addSegment(.perspective)
                    // Into the middle of it, where the lean is at its
                    // deepest: a 3D segment sweeps, so at its first frame
                    // there is nothing to see or take hold of.
                    if let segment = model.selectedSegment {
                        model.seek(to: min(model.duration, segment.start + segment.duration / 2))
                    }
                }
                    .font(.caption)
                    .help("Adds a 3D camera segment at the playhead, so the lean happens for a few seconds rather than throughout.")
                    .disabled(model.videoURL == nil)
            }
            Button("Stand it square") {
                model.editedPose = .neutral
            }.font(.caption).disabled(model.editedPose.isNeutral)
            Button { model.show3DCanvas = false } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Hide the 3D handles")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(AppTheme.panel, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(AppTheme.line))
    }
}
