import SwiftUI

/// Presets store ordinary editable poses. Older projects need no migration,
/// and a manual adjustment can keep using the same strength control.
enum ThreeDPreset: String, CaseIterable, Identifiable {
    case orbit, rise, showcase, drift, push, tilt, slideLeft, slideRight, slideUp, slideDown, zoomLeft, zoomRight, pullBack
    var id: String { rawValue }
    var title: String {
        switch self {
        case .orbit: "Orbit"
        case .rise: "Rise"
        case .showcase: "Showcase"
        case .drift: "Drift"
        case .push: "Push in"
        case .tilt: "Tilt reveal"
        case .slideLeft: "Slide left"
        case .slideRight: "Slide right"
        case .slideUp: "Slide up"
        case .slideDown: "Slide down"
        case .zoomLeft: "Zoom left"
        case .zoomRight: "Zoom right"
        case .pullBack: "Pull back"
        }
    }
    var detail: String {
        switch self {
        case .orbit: "Sweep from side to side"
        case .rise: "Lift into the frame"
        case .showcase: "Hold a polished angle"
        case .drift: "Float across the shot"
        case .push: "Move closer to the detail"
        case .tilt: "Lean back, then settle"
        case .slideLeft: "Glide left and return"
        case .slideRight: "Glide right and return"
        case .slideUp: "Lift and settle back"
        case .slideDown: "Drop and settle back"
        case .zoomLeft: "Move closer on the left"
        case .zoomRight: "Move closer on the right"
        case .pullBack: "Pull away, then return"
        }
    }
    var pose: FramePose {
        switch self {
        case .orbit: FramePose(pitch: 0.12, yaw: 0.48, zoom: 0.96)
        case .rise: FramePose(pitch: 0.32, panY: 0.12, zoom: 0.96)
        case .showcase: FramePose(pitch: 0.18, yaw: -0.35, roll: -0.07, zoom: 0.92)
        case .drift: FramePose(yaw: 0.18, roll: 0.06, panX: 0.16, zoom: 0.96)
        case .push: FramePose(pitch: 0.08, yaw: 0.12, zoom: 1.14)
        case .tilt: FramePose(pitch: 0.45, zoom: 0.94)
        case .slideLeft: FramePose(panX: -0.3)
        case .slideRight: FramePose(panX: 0.3)
        case .slideUp: FramePose(panY: 0.3)
        case .slideDown: FramePose(panY: -0.3)
        case .zoomLeft: FramePose(panX: 0.22, zoom: 1.4)
        case .zoomRight: FramePose(panX: -0.22, zoom: 1.4)
        case .pullBack: FramePose(zoom: 0.7)
        }
    }
    var sweeps: Bool { [.orbit, .rise, .drift, .push].contains(self) }

    func apply(to segment: inout EditSegment) {
        segment.poseKeyframes = nil
        segment.pose = pose
        segment.posePreset = rawValue
        segment.poseStrength = 0.75
        segment.poseReversed = false
        segment.sweeps = sweeps
        segment.blur = FrameBlur.none
        segment.blurAmount = 0
        segment.curve = .smooth
        segment.transition = min(0.8, segment.duration / 3)
    }
}

struct ThreeDPresetPicker: View {
    @EnvironmentObject private var model: EditorModel
    var onChoose: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("3D moves").font(.headline)
            Text(model.selectedSegment?.kind == .perspective
                 ? "Choose a look for this move."
                 : "Choose a look to add at the playhead.")
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(ThreeDPreset.allCases) { preset in
                    Button {
                        model.applyThreeDPreset(preset)
                        onChoose()
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            ThreeDPresetThumbnail(pose: preset.pose).frame(height: 66)
                            Text(preset.title).font(.system(size: 12, weight: .semibold))
                            Text(preset.detail).font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading).padding(9)
                        .background(AppTheme.elevated, in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(
                            model.selectedSegment?.posePreset == preset.rawValue ? AppTheme.green : AppTheme.line,
                            lineWidth: 1))
                    }.buttonStyle(.plain).accessibilityLabel("Apply \(preset.title) 3D move")
                }
            }
            }.frame(maxHeight: 460)
        }.padding(16).frame(width: 340)
            .disabled(model.videoURL == nil || model.duration <= 0)
    }
}

/// Lightweight vector thumbnails use the same projection as the video.
/// No video decode or continuously running animation for preset cards.
struct ThreeDPresetThumbnail: View {
    let pose: FramePose
    var body: some View {
        Canvas { context, size in
            let canvas = CGRect(origin: .zero, size: size)
            let frame = canvas.insetBy(dx: size.width * 0.16, dy: size.height * 0.16)
            let outer = pose.projection(of: canvas, canvas: canvas, lean: pose.lean())
            let outerMap = ProjectiveMap(canvas, to: outer)
            let innerPose = pose.weighted(FramePose.contentParallax)
            let inner = innerPose.projection(of: frame, canvas: frame, lean: innerPose.lean())
            let innerMap = ProjectiveMap(frame, to: inner)
            func path(_ rect: CGRect, content: Bool = false) -> Path {
                let first = content ? innerMap.quad(of: rect) : FrameQuad.rect(rect)
                let quad = FrameQuad(bottomLeft: outerMap(first.bottomLeft),
                                     bottomRight: outerMap(first.bottomRight),
                                     topRight: outerMap(first.topRight),
                                     topLeft: outerMap(first.topLeft)).flipped(in: size.height)
                var path = Path()
                path.addLines(quad.corners + [quad.bottomLeft]); path.closeSubpath()
                return path
            }
            let framePath = path(frame)
            var clipped = context
            clipped.clip(to: framePath)
            clipped.fill(framePath, with: .linearGradient(
                Gradient(colors: [AppTheme.green.opacity(0.8), Color.blue.opacity(0.55)]),
                startPoint: .zero, endPoint: CGPoint(x: size.width, y: size.height)))
            for row in 0..<3 {
                let line = CGRect(x: frame.minX + frame.width * 0.12,
                                  y: frame.minY + frame.height * (0.22 + Double(row) * 0.22),
                                  width: frame.width * (row == 2 ? 0.42 : 0.7), height: 2)
                clipped.fill(path(line, content: true), with: .color(.white.opacity(0.75)))
            }
            let titlebar = CGRect(x: frame.minX, y: frame.maxY - 4,
                                  width: frame.width, height: 4)
            clipped.fill(path(titlebar), with: .color(.white.opacity(0.75)))
            context.stroke(framePath, with: .color(.white.opacity(0.9)), lineWidth: 2)
        }.background(Color.black.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
    }
}

struct ThreeDMoveControls: View {
    @EnvironmentObject private var model: EditorModel
    let segment: EditSegment
    @State private var showingPresets = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button { showingPresets = true } label: {
                Label(segment.posePreset.flatMap(ThreeDPreset.init(rawValue:))?.title ?? "Choose a 3D look",
                      systemImage: "square.grid.2x2")
            }
            .popover(isPresented: $showingPresets) { ThreeDPresetPicker { showingPresets = false } }
            if segment.poseKeyframes?.isEmpty != false {
                InspectorSlider(title: "Strength", value: Binding(
                    get: { segment.poseStrength ?? 1 },
                    set: { value in model.updateSelected { $0.poseStrength = value } }), range: 0...1, suffix: "")
                Toggle("Reverse direction", isOn: Binding(
                    get: { segment.poseReversed ?? false },
                    set: { value in model.updateSelected { $0.poseReversed = value } }))
            }
            Button("Customize motion path") { model.customizeThreeDPath() }
            VStack(alignment: .leading, spacing: 8) {
                Button { model.previewThreeDMove() } label: { Label("Preview move", systemImage: "play.fill") }
                Button("Edit on canvas") {
                    model.show3DCanvas = true
                    model.seek(to: segment.start + segment.duration * 0.72)
                }
            }.font(.caption)
        }
    }
}
