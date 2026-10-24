import SwiftUI

struct AudioPanel: View {
    @EnvironmentObject private var model: EditorModel
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            InspectorSection(title: "EDIT & AUDIO") {
                Picker("Speed", selection: $model.playbackRate) {
                    ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { Text("\($0, specifier: "%.2g")×").tag($0) }
                }
                Toggle("Mute recording audio", isOn: $model.muted)
                HStack {
                    Button { model.chooseMusic() } label: { Label("Add music…", systemImage: "music.note") }
                    if model.musicURL != nil { Button("Remove") { model.musicURL = nil } }
                }.font(.caption)
                if let url = model.musicURL {
                    Text(url.lastPathComponent).font(.caption2).lineLimit(1).truncationMode(.middle)
                    if FileManager.default.fileExists(atPath: url.path) {
                        InspectorSlider(title: "Music volume", value: $model.musicVolume, range: 0...1, suffix: "")
                        Text("Music loops to the end of the recording and plays in preview and export.")
                            .font(.caption2).foregroundStyle(.secondary)
                    } else {
                        Text("Music file missing. Choose it again to include it in export.")
                            .font(.caption2).foregroundStyle(.orange)
                    }
                }
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
                    InspectorSlider(title: "Frame size", value: $model.cameraSize, range: 0.12...0.48, suffix: "")
                    if model.cameraShape == .roundedRectangle {
                        InspectorSlider(title: "Frame height", value: $model.cameraHeightScale, range: 0.65...1.7, suffix: "×")
                    }
                    InspectorSlider(title: "Subject size", value: $model.cameraSubjectScale, range: 1...3, suffix: "×")
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
                Text("Choose an effect, then place and resize it on the timeline.").font(.caption).foregroundStyle(.secondary)
                effectGroup("MOVEMENT", kinds: [.zoom])
                effectGroup("ATTENTION", kinds: [.spotlight, .outline, .callout])
                effectGroup("PRIVACY", kinds: [.blur, .pixelate])
            }
            MotionAppearanceInspector()
        }
    }

    private func effectGroup(_ title: String, kinds: [SegmentKind]) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 9, weight: .semibold)).tracking(1.1).foregroundStyle(.secondary)
                .padding(.top, 8)
            ForEach(kinds) { kind in
                Button { model.addSegment(kind) } label: {
                    HStack(spacing: 11) {
                        Image(systemName: kind.symbol).font(.system(size: 15, weight: .medium))
                            .foregroundStyle(AppTheme.green).frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(kind.title).font(.system(size: 12, weight: .semibold))
                            Text(kind.detail).font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "plus").font(.caption).foregroundStyle(AppTheme.green)
                    }
                    .padding(11).background(AppTheme.elevated, in: RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(AppTheme.line))
                }.buttonStyle(.plain).accessibilityLabel("Add \(kind.title) effect")
            }
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
                Button { model.previewEdit() } label: { Label("Play edited preview", systemImage: "play.rectangle") }
                    .disabled(model.videoURL == nil || model.isPreparingPreview)
                Text("Preview uses the same video and audio mix as export.")
                    .font(.caption2).foregroundStyle(.secondary)
                Button { model.export() } label: {
                    Label(model.exportProgress == nil ? "Export video" : "Exporting…", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity).padding(.vertical, 8)
                }.buttonStyle(.borderedProminent).disabled(model.exportProgress != nil)
            }
        }
    }
}
