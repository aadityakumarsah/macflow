import SwiftUI

struct WindowAppearanceInspector: View {
    @EnvironmentObject private var model: EditorModel
    var body: some View {
        InspectorSection(title: "CONTENT & WINDOW") {
            Button { model.showCropEditor = true } label: { Label("Crop to tab or pane…", systemImage: "crop") }.disabled(model.videoURL == nil)
            if model.frameAppearance.crop != .full {
                HStack {
                    Text("Content cropped").font(.caption).foregroundStyle(AppTheme.green)
                    Spacer(); Button("Reset") { model.frameAppearance.crop = .full }.font(.caption)
                }
            }
            Picker("Frame", selection: $model.frameAppearance.chrome) {
                ForEach(WindowChrome.allCases) { Text($0.rawValue).tag($0) }
            }
            if model.frameAppearance.chrome != .none {
                TextField("Window title (optional)", text: $model.frameAppearance.title).textFieldStyle(.roundedBorder)
                Toggle("Traffic lights", isOn: $model.frameAppearance.trafficLights)
                InspectorSlider(title: "Title bar height", value: $model.frameAppearance.barHeight, range: 28...90, suffix: "")
                if model.frameAppearance.trafficLights { InspectorSlider(title: "Control size", value: $model.frameAppearance.lightSize, range: 10...24, suffix: "") }
            }
        }
    }
}

struct MotionAppearanceInspector: View {
    @EnvironmentObject private var model: EditorModel
    var body: some View {
        InspectorSection(title: "MOTION") {
            Picker("Entrance", selection: $model.motionAppearance.entrance) { ForEach(EntranceStyle.allCases) { Text($0.rawValue).tag($0) } }
            Toggle("Fade out at end", isOn: $model.motionAppearance.fadeOut)
            if model.motionAppearance.entrance != .none || model.motionAppearance.fadeOut {
                InspectorSlider(title: "Transition", value: $model.motionAppearance.duration, range: 0.2...2, suffix: "s")
            }
            Button { model.addAutoZooms() } label: { Label("Rebuild click zooms", systemImage: "sparkles") }.disabled(model.recordedClicks.isEmpty)
            Text("Add Zoom or Pan from the left rail. Drag a focus point on the preview to direct the motion.").font(.caption2).foregroundStyle(.secondary)
        }
    }
}

struct CursorAppearanceInspector: View {
    @EnvironmentObject private var model: EditorModel
    var body: some View {
        InspectorSection(title: "CURSOR & CLICKS") {
            if model.pointerSamples.isEmpty {
                Text("This video has no separate cursor track. Styled cursors and recorded click effects are available with native Window or Display capture.").font(.caption2).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 9) {
                Toggle("Show cursor", isOn: $model.showCursor)
                Picker("Style", selection: $model.cursorAppearance.style) { ForEach(PointerStyle.allCases) { Text($0.rawValue).tag($0) } }
                Picker("Shape", selection: Binding(get: { model.cursorAppearance.shape ?? .automatic }, set: { model.cursorAppearance.shape = $0 })) {
                    ForEach(PointerShape.allCases) { Text($0.rawValue).tag($0) }
                }
                Text("1× uses the Mac’s original cursor size. Automatic follows recorded arrow/text changes; choose Text to override.").font(.caption2).foregroundStyle(.secondary)
                Picker("Accent", selection: $model.cursorAppearance.accent) { ForEach(EffectAccent.allCases) { Text($0.rawValue).tag($0) } }
                Toggle("Smooth movement", isOn: $model.smoothCursor)
                Toggle("Gentle tilt", isOn: $model.cursorAppearance.sway)
                Toggle("Cursor shadow", isOn: $model.cursorShadow)
                Toggle("Click effects", isOn: $model.clickEffects)
                if model.clickEffects { Picker("Click", selection: $model.cursorAppearance.clickStyle) { ForEach(ClickStyle.allCases) { Text($0.rawValue).tag($0) } } }
                InspectorSlider(title: "Size", value: $model.cursorSize, range: 0.7...2.4, suffix: "×")
            }.disabled(model.pointerSamples.isEmpty)
            Toggle("Shortcut badges", isOn: $model.showKeystrokes).disabled(model.keystrokes.isEmpty)
        }
    }
}

struct SegmentMotionInspector: View {
    @EnvironmentObject private var model: EditorModel
    let segment: EditSegment
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if segment.kind != .blur {
                Picker("Easing", selection: Binding(get: { segment.curve ?? .smooth }, set: { value in model.updateSelected { $0.curve = value } })) {
                    ForEach(MotionCurve.allCases) { Text($0.rawValue).tag($0) }
                }
                InspectorSlider(title: "Ease in / out", value: Binding(get: { segment.transition ?? 0.7 }, set: { value in model.updateSelected { $0.transition = value } }), range: 0.1...2, suffix: "s")
            }
            if segment.kind == .zoom {
                Toggle("Follow cursor", isOn: Binding(get: { segment.followsCursor ?? false }, set: { value in model.updateSelected { $0.followsCursor = value } })).disabled(model.pointerSamples.isEmpty)
            }
            if segment.kind == .pan {
                InspectorSlider(title: "End X", value: Binding(get: { segment.endX ?? 0.7 }, set: { value in model.updateSelected { $0.endX = value } }), range: 0...1, suffix: "")
                InspectorSlider(title: "End Y", value: Binding(get: { segment.endY ?? 0.5 }, set: { value in model.updateSelected { $0.endY = value } }), range: 0...1, suffix: "")
            }
            if segment.kind == .callout {
                TextField("Callout text", text: Binding(get: { segment.text ?? "Look here" }, set: { value in model.updateSelected { $0.text = String(value.prefix(80)) } })).textFieldStyle(.roundedBorder)
            }
            Text("Scrub inside the segment, then click or drag on the preview to position it.").font(.caption2).foregroundStyle(.secondary)
        }
    }
}

struct EditableFocusOverlay: View {
    @EnvironmentObject private var model: EditorModel
    let canvasSize: CGSize
    @State private var dragViewport: CGRect?
    var body: some View {
        if let segment = model.selectedSegment, model.playhead >= segment.start, model.playhead <= segment.end {
            let layout = FrameLayout.make(canvas: CGRect(origin: .zero, size: canvasSize), sourceSize: model.contentSize, padding: model.padding, frame: model.frameAppearance)
            let rect = CGRect(x: layout.content.minX, y: canvasSize.height - layout.content.maxY, width: layout.content.width, height: layout.content.height)
            let crop = model.frameAppearance.crop.bounded
            let viewport = dragViewport ?? MotionEngine.viewport(at: model.playhead, segments: model.segments, samples: model.pointerSamples, crop: crop)
            let x = rect.minX + ((segment.x - crop.x) / crop.width - viewport.minX) / viewport.width * rect.width
            let y = rect.minY + ((segment.y - crop.y) / crop.height - viewport.minY) / viewport.height * rect.height
            ZStack(alignment: .topLeading) {
                Rectangle().fill(.clear).frame(width: rect.width, height: rect.height).position(x: rect.midX, y: rect.midY).contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("canvas")).onChanged { value in
                        if dragViewport == nil { dragViewport = viewport; model.player.pause(); model.isPlaying = false }
                        let px = min(1, max(0, (value.location.x - rect.minX) / rect.width)), py = min(1, max(0, (value.location.y - rect.minY) / rect.height))
                        model.updateSelected {
                            $0.x = crop.x + (viewport.minX + px * viewport.width) * crop.width
                            $0.y = crop.y + (viewport.minY + py * viewport.height) * crop.height
                            if $0.kind == .zoom { $0.followsCursor = false }
                        }
                    }.onEnded { _ in dragViewport = nil })
                if rect.contains(CGPoint(x: x, y: y)) {
                    Image(systemName: "plus.circle.fill").font(.system(size: 22)).foregroundStyle(.white, AppTheme.green).shadow(radius: 3).position(x: x, y: y).allowsHitTesting(false)
                }
            }.frame(width: canvasSize.width, height: canvasSize.height).help("Drag to set the selected effect’s focus")
        }
    }
}

struct BackgroundInspector: View {
    @EnvironmentObject private var model: EditorModel

    var body: some View {
        InspectorSection(title: "BACKGROUND") {
            Picker("Source", selection: $model.customBackground.kind) {
                ForEach(BackgroundKind.allCases) { Text($0.title).tag($0) }
            }.labelsHidden()

            switch model.customBackground.kind {
            case .preset:
                LazyVGrid(columns: [.init(.flexible()), .init(.flexible()), .init(.flexible())], spacing: 8) {
                    ForEach(BackgroundStyle.allCases) { style in
                        Button { model.background = style } label: {
                            BackgroundGradient(style: style)
                                .frame(height: 42)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .overlay(RoundedRectangle(cornerRadius: 8)
                                    .stroke(model.background == style ? AppTheme.green : .white.opacity(0.1), lineWidth: 2))
                        }.buttonStyle(.plain).help(style.title)
                    }
                }

            case .solid:
                ColorPicker("Colour", selection: colorBinding(\.top), supportsOpacity: false)

            case .gradient:
                ColorPicker("From", selection: colorBinding(\.top), supportsOpacity: false)
                ColorPicker("To", selection: colorBinding(\.bottom), supportsOpacity: false)
                InspectorSlider(title: "Angle", value: $model.customBackground.angle, range: 0...360, suffix: "°")

            case .image:
                HStack {
                    Button("Choose image…") { chooseImage() }
                    if model.customBackground.imagePath != nil {
                        Button("Clear") { model.customBackground.imagePath = nil }
                    }
                }.font(.caption)
                if let path = model.customBackground.imagePath {
                    Text((path as NSString).lastPathComponent)
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    if !FileManager.default.fileExists(atPath: path) {
                        Text("This file has moved — the gradient is drawn instead.")
                            .font(.caption2).foregroundStyle(.orange)
                    }
                }
                Picker("Fit", selection: $model.customBackground.imageFills) {
                    Text("Fill").tag(true)
                    Text("Fit").tag(false)
                }.pickerStyle(.segmented)
                InspectorSlider(title: "Dim", value: $model.customBackground.dim, range: 0...0.8, suffix: "")

            case .blur:
                InspectorSlider(title: "Blur", value: $model.customBackground.blurRadius, range: 4...120, suffix: "")
                InspectorSlider(title: "Dim", value: $model.customBackground.dim, range: 0...0.8, suffix: "")
            }
        }
    }

    /// Bridges the stored sRGB triple to SwiftUI's Color for the picker.
    private func colorBinding(_ path: WritableKeyPath<CustomBackground, RGBColor>) -> Binding<Color> {
        Binding(
            get: {
                let c = model.customBackground[keyPath: path]
                return Color(red: c.r, green: c.g, blue: c.b)
            },
            set: { newValue in
                let resolved = NSColor(newValue).usingColorSpace(.sRGB) ?? .black
                model.customBackground[keyPath: path] = RGBColor(
                    r: Double(resolved.redComponent),
                    g: Double(resolved.greenComponent),
                    b: Double(resolved.blueComponent))
            })
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.customBackground.imagePath = url.path
    }
}

struct ExportInspector: View {
    @EnvironmentObject private var model: EditorModel

    var body: some View {
        InspectorSection(title: "EXPORT") {
            Picker("Format", selection: $model.exportOptions.format) {
                ForEach(ExportFormat.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented)

            Picker("Resolution", selection: $model.exportOptions.resolution) {
                ForEach(ExportResolution.allCases) { Text($0.rawValue).tag($0) }
            }.labelsHidden()

            Picker("Frame rate", selection: $model.exportOptions.frameRate) {
                ForEach(ExportFrameRate.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented)

            let size = model.canvasSize
            Text("\(Int(size.width)) × \(Int(size.height)) · \(model.exportOptions.frameRate.rawValue) fps")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}
