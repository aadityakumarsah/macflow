import SwiftUI

struct AudioPanel: View {
    @EnvironmentObject private var model: EditorModel
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
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

        }
    }
}

struct CameraPanel: View {
    @EnvironmentObject private var model: EditorModel
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
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
                    Text("Drag the camera frame directly on the preview to reposition it.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            } else {
                ContentUnavailableView("No camera track", systemImage: "video", description: Text("Enable Camera before your next recording to add an editable camera layer."))
            }
        }
    }
}

struct MotionPanel: View {
    @EnvironmentObject private var model: EditorModel
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            InspectorSection(title: "Add an effect") {
                Text("Direct attention to the details that matter.").font(.caption).foregroundStyle(.secondary)
                ForEach(SegmentKind.availableCases) { kind in
                    Button { model.addSegment(kind) } label: {
                        HStack { Label(kind.title, systemImage: kind.symbol); Spacer(); Image(systemName: "plus") }
                            .padding(12).background(AppTheme.elevated, in: RoundedRectangle(cornerRadius: 8))
                    }.buttonStyle(.plain)
                }
            }
            MotionAppearanceInspector()
        }
    }
}

struct ExportPanel: View {
    @EnvironmentObject private var model: EditorModel
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            ExportInspector()
            InspectorSection(title: "Ready to share") {
                LabeledContent("Duration", value: String(format: "%.1f seconds", model.outputDuration))
                LabeledContent("Canvas", value: "\(Int(model.canvasSize.width)) × \(Int(model.canvasSize.height))")
                Text("Your cursor, clicks, camera, and effects are included in the exported video.")
                    .font(.caption).foregroundStyle(.secondary)
                Button { model.export() } label: {
                    Label(model.exportProgress == nil ? "Export video" : "Exporting…", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity).padding(.vertical, 8)
                }.buttonStyle(.borderedProminent).disabled(model.exportProgress != nil)
            }
        }
    }
}
