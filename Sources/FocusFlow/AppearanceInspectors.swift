import SwiftUI
import CoreImage

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
            Toggle("Animated canvas and progress line", isOn: Binding(get: { model.motionAppearance.ambientGraphics != false }, set: { model.motionAppearance.ambientGraphics = $0 }))
            Toggle("Automatic motion blur", isOn: Binding(get: { model.motionAppearance.automaticMotionBlur != false }, set: { model.motionAppearance.automaticMotionBlur = $0 }))
            if model.motionAppearance.automaticMotionBlur != false {
                InspectorSlider(title: "Blur strength", value: Binding(get: { model.motionAppearance.motionBlurStrength ?? 0.55 }, set: { model.motionAppearance.motionBlurStrength = $0 }), range: 0...1, suffix: "")
            }
            Picker("Entrance", selection: $model.motionAppearance.entrance) { ForEach(EntranceStyle.allCases) { Text($0.rawValue).tag($0) } }
            Toggle("Fade out at end", isOn: $model.motionAppearance.fadeOut)
            if model.motionAppearance.entrance != .none || model.motionAppearance.fadeOut {
                InspectorSlider(title: "Transition", value: $model.motionAppearance.duration, range: 0.2...2, suffix: "s")
            }
            Button { model.rebuildAutoEdits() } label: { Label("Create automatic edit", systemImage: "sparkles") }
                .disabled(model.recordedClicks.isEmpty && model.pointerSamples.isEmpty)
                .help("Build click zooms, spotlights, accent frames, callouts, and text selection focus from recorded interactions. Replaces timeline effects.")
            Button { model.addAutoZooms() } label: { Label("Rebuild click zooms only", systemImage: "plus.magnifyingglass") }
                .disabled(model.recordedClicks.isEmpty)

            // A greyed-out button with no explanation reads as broken.
            if model.recordedClicks.isEmpty && model.videoURL != nil {
                Text("No clicks were recorded with this video. Text selection effects can still be generated when pointer movement was captured.")
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                Text("Add Zoom in the Motion panel. Drag its focus point on the preview to direct the motion.").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

struct CursorAppearanceInspector: View {
    @EnvironmentObject private var model: EditorModel
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            if model.pointerSamples.isEmpty {
                Label("No editable cursor track", systemImage: "info.circle").font(.system(size: 12, weight: .semibold))
                Text("Record a Window or Display in FocusFlow to resize the cursor after recording. A cursor already inside a video cannot be resized separately.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                if model.recordingMetadata.embeddedCursor == true {
                    Text("Chrome included its cursor in these video pixels. FocusFlow turns off the extra cursor so two pointers never overlap. Use Window or Display recording in FocusFlow for a fully replaceable cursor.")
                        .font(.caption).foregroundStyle(.orange)
                }
                CursorStylePreview(size: model.cursorSize, appearance: model.cursorAppearance,
                                   visible: model.showCursor && model.recordingMetadata.embeddedCursor != true, shadow: model.cursorShadow,
                                   clicks: model.clickEffects && !model.recordedClicks.isEmpty).equatable()
                if model.recordingMetadata.embeddedCursor != true {
                    Text("The replacement cursor is drawn inside the video frame, above the recorded content and beneath callouts and window chrome. It appears in preview and export.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 24) {
                InspectorSection(title: "Cursor") {
                    Toggle("Show cursor", isOn: $model.showCursor)
                    InspectorSlider(title: "Size", value: $model.cursorSize, range: 0.5...10, suffix: "×")
                    HStack(spacing: 6) {
                        ForEach([1.0, 1.25, 1.5, 2, 3], id: \.self) { size in
                            Button { model.cursorSize = size } label: {
                                Text(String(format: "%g×", size)).font(.system(size: 11, weight: .semibold))
                                    .frame(maxWidth: .infinity).padding(.vertical, 7)
                                    .background(abs(model.cursorSize - size) < 0.01 ? AppTheme.green.opacity(0.1) : AppTheme.elevated, in: RoundedRectangle(cornerRadius: 6))
                                    .foregroundStyle(abs(model.cursorSize - size) < 0.01 ? AppTheme.green : .secondary)
                            }.buttonStyle(.plain).accessibilityLabel("Cursor size \(size.formatted()) times")
                        }
                    }
                    Picker("Style", selection: $model.cursorAppearance.style) { ForEach(PointerStyle.allCases) { Text($0.rawValue).tag($0) } }
                    Picker("Shape", selection: Binding(get: { model.cursorAppearance.shape ?? .automatic }, set: { model.cursorAppearance.shape = $0 })) {
                        ForEach(PointerShape.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Text("Automatic follows recorded arrow and text cursor changes.").font(.caption2).foregroundStyle(.secondary)
                    Toggle("Smooth movement", isOn: $model.smoothCursor)
                    Toggle("Cursor shadow", isOn: $model.cursorShadow)
                }.disabled(model.recordingMetadata.embeddedCursor == true)
                Divider()
                InspectorSection(title: "Click effects") {
                    Toggle("Animate clicks", isOn: $model.clickEffects).disabled(model.recordedClicks.isEmpty)
                    if model.recordedClicks.isEmpty {
                        Text("No clicks were recorded in this video.").font(.caption2).foregroundStyle(.secondary)
                    }
                    if model.clickEffects {
                        Picker("Animation", selection: $model.cursorAppearance.clickStyle) {
                            ForEach(ClickStyle.allCases) { Text($0.rawValue).tag($0) }
                        }.disabled(model.recordedClicks.isEmpty)
                        if model.cursorAppearance.clickStyle != .press {
                            InspectorSlider(title: "Effect size", value: optional(\.clickScale, fallback: 1), range: 0.5...3, suffix: "×")
                                .disabled(model.recordedClicks.isEmpty)
                        }
                    }
                    ColorPicker("Effect color", selection: Binding(get: {
                        let c = model.cursorAppearance.accentRGB
                        return Color(red: c.0, green: c.1, blue: c.2)
                    }, set: { value in
                        guard let c = NSColor(value).usingColorSpace(.deviceRGB) else { return }
                        model.cursorAppearance.customAccent = RGBColor(r: c.redComponent, g: c.greenComponent, b: c.blueComponent)
                    }), supportsOpacity: false)
                    HStack(spacing: 10) {
                        ForEach(EffectAccent.allCases) { accent in
                            Button {
                                var appearance = model.cursorAppearance
                                appearance.accent = accent; appearance.customAccent = nil
                                model.cursorAppearance = appearance
                            } label: {
                                Circle().fill(Color(cgColor: accent.cgColor)).frame(width: 22, height: 22)
                                    .padding(3).overlay(Circle().stroke(model.cursorAppearance.customAccent == nil && model.cursorAppearance.accent == accent ? AppTheme.green : .clear, lineWidth: 1.5))
                            }.buttonStyle(.plain).help(accent.rawValue).accessibilityLabel(accent.rawValue)
                        }
                        Spacer()
                    }
                }
                Divider()
                InspectorSection(title: "Pointer highlight") {
                    Toggle("Follow with a soft glow", isOn: Binding(get: { model.cursorAppearance.highlight ?? false }, set: { model.cursorAppearance.highlight = $0 }))
                    if model.cursorAppearance.highlight == true {
                        InspectorSlider(title: "Spread", value: optional(\.highlightSize, fallback: 3.4), range: 0.4...5, suffix: "×")
                        InspectorSlider(title: "Opacity", value: optional(\.highlightOpacity, fallback: 0.22), range: 0.05...0.8, suffix: "")
                    }
                }.disabled(model.recordingMetadata.embeddedCursor == true)
                DisclosureGroup("Advanced") {
                    VStack(alignment: .leading, spacing: 14) {
                        Toggle("Gentle tilt", isOn: $model.cursorAppearance.sway)
                        InspectorSlider(title: "Text cursor scale", value: $model.cursorAppearance.textScale, range: 0.5...10, suffix: "×")
                        InspectorSlider(title: "Cursor opacity", value: optional(\.opacity, fallback: 1), range: 0...1, suffix: "")
                    }.padding(.top, 12)
                }.font(.caption).disabled(model.recordingMetadata.embeddedCursor == true)
            }.disabled(model.pointerSamples.isEmpty)
            Toggle("Show keyboard shortcuts", isOn: $model.showKeystrokes).disabled(model.keystrokes.isEmpty)
            Button("Reset cursor settings") { model.resetCursorSettings() }
                .buttonStyle(.borderless).disabled(model.pointerSamples.isEmpty)
        }
    }
    private func optional(_ path: WritableKeyPath<CursorAppearance, Double?>, fallback: Double) -> Binding<Double> {
        Binding(get: { model.cursorAppearance[keyPath: path] ?? fallback }, set: { model.cursorAppearance[keyPath: path] = $0 })
    }
}

/// Uses the export compositor, so the style swatch shows the actual cursor artwork.
struct CursorStylePreview: View, Equatable {
    let size: Double
    let appearance: CursorAppearance
    let visible: Bool
    let shadow: Bool
    let clicks: Bool
    private static let context = CIContext()
    private static let compositor = FocusFlowCompositor()
    private var preview: CGImage? {
        let rect = CGRect(x: 0, y: 0, width: 960, height: 480)
        let source = CIImage(color: CIColor(red: 0.94, green: 0.95, blue: 0.98)).cropped(to: rect)
        var settings = ExportSettings(background: .graphite, canvasSize: rect.size, padding: 0, cornerRadius: 0, shadow: 0, segments: [], pointerSamples: [], clicks: [], keystrokes: [], cursorSize: size, clickEffects: clicks, showKeystrokes: false, cameraURL: nil, showCamera: false, cameraSize: 0.2, cameraX: 0.8, cameraY: 0.8, cameraCornerRadius: 0, cameraShape: .circle, showCursor: visible, smoothCursor: true, cursorShadow: shadow, frame: FrameAppearance(chrome: .none), cursor: appearance)
        settings.pointerSamples = [PointerSample(time: 0.95, x: 0.47, y: 0.46, shape: .arrow), PointerSample(time: 1.05, x: 0.47, y: 0.46, shape: .arrow)]
        settings.clicks = clicks ? [RecordedClick(time: 0.85, x: 0.47, y: 0.46)] : []
        let detail = CGRect(x: rect.width * 0.47 - 130, y: rect.height * 0.54 - 65, width: 260, height: 130)
        return Self.context.createCGImage(Self.compositor.renderFrame(source: source, time: 1, settings: settings), from: detail)
    }
    var body: some View {
        VStack(spacing: 0) {
            if let preview { Image(decorative: preview, scale: 2).resizable().scaledToFit() }
            HStack {
                Text("STYLE PREVIEW").font(.system(size: 9, weight: .medium)).tracking(1)
                Spacer()
                Text("\(size, specifier: "%.1f")×").font(.system(size: 10, weight: .semibold, design: .monospaced))
            }.foregroundStyle(.secondary).padding(12)
        }.background(AppTheme.elevated, in: RoundedRectangle(cornerRadius: 10))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(AppTheme.line))
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
                Text("Included backgrounds").font(.caption2).foregroundStyle(.secondary)
                LazyVGrid(columns: [.init(.flexible()), .init(.flexible()), .init(.flexible())], spacing: 8) {
                    ForEach(BuiltInBackground.allCases) { asset in
                        Button {
                            model.customBackground.imagePath = asset.reference
                            model.customBackground.imageFills = true
                        } label: {
                            VStack(spacing: 3) {
                                if let url = asset.url, let image = NSImage(contentsOf: url) {
                                    Image(nsImage: image).resizable().scaledToFill()
                                        .frame(height: 48).frame(maxWidth: .infinity).clipped()
                                }
                                Text(asset.title).font(.system(size: 9)).lineLimit(1)
                            }
                            .background(AppTheme.elevated, in: RoundedRectangle(cornerRadius: 7))
                            .clipShape(RoundedRectangle(cornerRadius: 7))
                            .overlay(RoundedRectangle(cornerRadius: 7).stroke(model.customBackground.imagePath == asset.reference ? AppTheme.green : AppTheme.line, lineWidth: 2))
                        }.buttonStyle(.plain).accessibilityLabel("Use \(asset.title) background")
                    }
                }
                HStack {
                    Button("Choose image…") { chooseImage() }
                    if model.customBackground.imagePath != nil {
                        Button("Clear") { model.customBackground.imagePath = nil }
                    }
                }.font(.caption)
                if let path = model.customBackground.imagePath {
                    Text((path as NSString).lastPathComponent)
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    if !FileManager.default.fileExists(atPath: BuiltInBackground.url(for: path)?.path ?? path) {
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
