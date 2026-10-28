import AppKit
import SwiftUI

/// Everything to do with the spoken word: writing it down, styling it, and
/// correcting it.
struct CaptionsPanel: View {
    @EnvironmentObject private var model: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            CaptionGenerateSection()
            if !model.captions.cues.isEmpty {
                Divider()
                CaptionLookSection()
                Divider()
                CaptionTypeSection()
                Divider()
                CaptionBackdropSection()
                Divider()
                CaptionTimingSection()
                Divider()
                CaptionLinesSection()
            }
        }
    }
}

private struct CaptionGenerateSection: View {
    @EnvironmentObject private var model: EditorModel
    @State private var languages: [(identifier: String, name: String)] = []

    var body: some View {
        InspectorSection(title: "CAPTIONS") {
            if model.captions.cues.isEmpty {
                Text("Listen to the recording and write the narration out as captions, in time with what was said.")
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Toggle("Show captions", isOn: Binding(
                    get: { model.captions.enabled },
                    set: { model.captions.enabled = $0 }))
            }

            Picker("Spoken language", selection: Binding(
                get: { model.captions.language },
                set: { model.captions.language = $0 })) {
                    ForEach(languages, id: \.identifier) { Text($0.name).tag($0.identifier) }
                }
                .disabled(model.captionsBusy)
                .onAppear {
                    guard languages.isEmpty else { return }
                    var available = CaptionTranscriber.supportedLanguages
                    if !available.contains(where: { $0.identifier == model.captions.language }),
                       let fallback = available.first {
                        model.captions.language = fallback.identifier
                    }
                    if available.isEmpty { available = [(model.captions.language, model.captions.language)] }
                    languages = available
                }

            if let progress = model.captionProgress {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: progress)
                    HStack {
                        Text("Listening… \(Int(progress * 100))%").font(.caption2).foregroundStyle(.secondary)
                        Spacer()
                        Button("Stop") { model.cancelCaptions() }.font(.caption)
                    }
                }
            } else {
                HStack {
                    Button {
                        model.generateCaptions()
                    } label: {
                        Label(model.captions.cues.isEmpty ? "Generate captions" : "Generate again",
                              systemImage: "waveform.badge.mic")
                    }.disabled(model.videoURL == nil)
                    if !model.captions.cues.isEmpty {
                        Menu("Save file…") {
                            Button("SubRip (.srt)") { model.exportCaptionFile() }
                            Button("WebVTT (.vtt)") { model.exportCaptionFile(asVTT: true) }
                        }.fixedSize()
                    }
                }.font(.caption)
            }

            Toggle("Write captions automatically after recording", isOn: Binding(
                get: { model.automaticCaptions },
                set: { model.automaticCaptions = $0 }))
            Text(model.automaticCaptions
                 ? "A recording with narration in it is transcribed as soon as it opens. macOS asks for permission the first time."
                 : "Captions are written only when you press the button above.")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            if let status = model.captionStatus {
                Text(status).font(.caption2)
                    .foregroundStyle(status.hasPrefix("Caption") || status.contains(" lines covering ") ? Color.secondary : Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(CaptionTranscriber.onDeviceAvailable(model.captions.language)
                 ? "Recognition runs on this Mac. The audio does not leave it."
                 : "This language has no on-device model installed, so recognition uses Apple's speech service and the audio is sent there. Add the language under System Settings › General › Language & Region to keep it local.")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct CaptionLookSection: View {
    @EnvironmentObject private var model: EditorModel

    var body: some View {
        InspectorSection(title: "LOOK") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 76), spacing: 6)], spacing: 6) {
                ForEach(CaptionPreset.allCases) { preset in
                    Button { model.applyCaptionPreset(preset) } label: {
                        Text(preset.rawValue).font(.system(size: 11, weight: .medium))
                            .frame(maxWidth: .infinity).padding(.vertical, 7)
                            .background(AppTheme.elevated, in: RoundedRectangle(cornerRadius: 7))
                    }.buttonStyle(.plain).help(preset.detail)
                }
            }
            Picker("Animation", selection: binding(\.animation)) {
                ForEach(CaptionAnimation.allCases) { Text($0.rawValue).tag($0) }
            }
            Text(model.captions.animation.detail).font(.caption2).foregroundStyle(.secondary)
            if model.captions.animation.highlightsWords {
                Toggle("Fill behind the spoken word", isOn: binding(\.highlightFill))
                ColorPicker("Spoken word", selection: colorBinding(\.highlightColorOrAccent), supportsOpacity: false)
                    .font(.caption)
            }
        }
    }

    private func binding<T>(_ path: WritableKeyPath<CaptionSettings, T>) -> Binding<T> {
        Binding(get: { model.captions[keyPath: path] }, set: { model.captions[keyPath: path] = $0 })
    }

    private func colorBinding(_ path: WritableKeyPath<CaptionSettings, RGBColor>) -> Binding<Color> {
        CaptionColor.binding(model, path)
    }
}

private struct CaptionTypeSection: View {
    @EnvironmentObject private var model: EditorModel
    private var families: [String] { NSFontManager.shared.availableFontFamilies }

    var body: some View {
        InspectorSection(title: "TYPE") {
            Picker("Font", selection: binding(\.fontName)) {
                Text("System").tag("")
                Divider()
                ForEach(families, id: \.self) { Text($0).tag($0) }
            }
            HStack {
                Toggle("Bold", isOn: binding(\.bold))
                Toggle("Italic", isOn: binding(\.italic))
            }
            Picker("Capitals", selection: binding(\.casing)) {
                ForEach(CaptionCasing.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented)
            InspectorSlider(title: "Size", value: percent(\.size, scale: 100), range: 2...14, suffix: "%")
            InspectorSlider(title: "Letter spacing", value: percent(\.tracking, scale: 100), range: -4...20, suffix: "%")
            InspectorSlider(title: "Line spacing", value: binding(\.lineSpacing), range: 0.8...2, suffix: "×")
            ColorPicker("Text colour", selection: CaptionColor.binding(model, \.textColor), supportsOpacity: false)
                .font(.caption)
            InspectorSlider(title: "Outline", value: percent(\.outlineWidth, scale: 100), range: 0...25, suffix: "%")
            if model.captions.outlineWidth > 0.0001 {
                ColorPicker("Outline colour", selection: CaptionColor.binding(model, \.outlineColor), supportsOpacity: false)
                    .font(.caption)
            }
            InspectorSlider(title: "Shadow", value: percent(\.shadow, scale: 100), range: 0...100, suffix: "%")
        }
    }

    private func binding<T>(_ path: WritableKeyPath<CaptionSettings, T>) -> Binding<T> {
        Binding(get: { model.captions[keyPath: path] }, set: { model.captions[keyPath: path] = $0 })
    }

    /// Shares of the canvas or the font size read as percentages here,
    /// which is how they are actually thought about.
    private func percent(_ path: WritableKeyPath<CaptionSettings, Double>, scale: Double) -> Binding<Double> {
        Binding(get: { model.captions[keyPath: path] * scale },
                set: { model.captions[keyPath: path] = $0 / scale })
    }
}

private struct CaptionBackdropSection: View {
    @EnvironmentObject private var model: EditorModel

    var body: some View {
        InspectorSection(title: "BACKGROUND") {
            Picker("Behind the words", selection: binding(\.backdrop)) {
                ForEach(CaptionBackdrop.allCases) { Text($0.rawValue).tag($0) }
            }
            Text(model.captions.backdrop.detail).font(.caption2).foregroundStyle(.secondary)
            if model.captions.backdrop != .none {
                if model.captions.backdrop != .blur {
                    ColorPicker("Colour", selection: CaptionColor.binding(model, \.backdropColor), supportsOpacity: false)
                        .font(.caption)
                }
                InspectorSlider(title: "Strength", value: percent(\.backdropOpacity), range: 0...100, suffix: "%")
                InspectorSlider(title: "Corners", value: percent(\.backdropRadius), range: 0...100, suffix: "%")
                if model.captions.backdrop != .blur {
                    InspectorSlider(title: "Inset", value: percent(\.backdropPadding), range: 0...150, suffix: "%")
                }
            }
        }
    }

    private func binding<T>(_ path: WritableKeyPath<CaptionSettings, T>) -> Binding<T> {
        Binding(get: { model.captions[keyPath: path] }, set: { model.captions[keyPath: path] = $0 })
    }
    private func percent(_ path: WritableKeyPath<CaptionSettings, Double>) -> Binding<Double> {
        Binding(get: { model.captions[keyPath: path] * 100 },
                set: { model.captions[keyPath: path] = $0 / 100 })
    }
}

private struct CaptionTimingSection: View {
    @EnvironmentObject private var model: EditorModel

    var body: some View {
        InspectorSection(title: "PLACING") {
            Picker("Position", selection: binding(\.placement)) {
                ForEach(CaptionPlacement.presets) { Text($0.rawValue).tag($0) }
                if model.captions.placement == .free { Text("Dragged").tag(CaptionPlacement.free) }
            }.pickerStyle(.segmented)
            HStack {
                Text("Or drag the caption on the preview to put it anywhere.")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
                if model.captions.placement == .free || model.captions.cues.contains(where: \.isPlaced) {
                    Button("Reset") { model.resetCaptionPlacement() }.font(.caption)
                }
            }.fixedSize(horizontal: false, vertical: true)
            if model.captions.placement != .free {
                InspectorSlider(title: "Nudge", value: Binding(
                    get: { model.captions.offset * 100 },
                    set: { model.captions.offset = $0 / 100 }), range: -40...40, suffix: "%")
            }
            InspectorSlider(title: "Widest line", value: Binding(
                get: { model.captions.maxWidth * 100 },
                set: { model.captions.maxWidth = $0 / 100 }), range: 20...100, suffix: "%")
            VStack(spacing: 7) {
                HStack {
                    Text("Words per line").font(.caption)
                    Spacer()
                    Text("\(model.captions.wordsPerLine)").font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                }
                Slider(value: Binding(
                    get: { Double(model.captions.wordsPerLine) },
                    set: { model.reflowCaptions(wordsPerLine: Int($0.rounded())) }), in: 1...14, step: 1)
                    .tint(AppTheme.green)
            }
            Text("Changing this re-splits the lines you already have — it does not listen again.")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func binding<T>(_ path: WritableKeyPath<CaptionSettings, T>) -> Binding<T> {
        Binding(get: { model.captions[keyPath: path] }, set: { model.captions[keyPath: path] = $0 })
    }
}

private struct CaptionLinesSection: View {
    @EnvironmentObject private var model: EditorModel

    var body: some View {
        InspectorSection(title: "LINES") {
            HStack {
                Text("\(model.captions.cues.count) lines").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { model.addCaptionCue() } label: { Label("Add", systemImage: "plus") }.font(.caption)
            }
            Text("Lines also appear on the timeline: drag them to retime, click one to edit it here, and drag it on the preview to place it.")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ForEach(model.captions.cues) { cue in
                CaptionCueRow(cue: cue)
            }
        }
    }
}

private struct CaptionCueRow: View {
    @EnvironmentObject private var model: EditorModel
    let cue: CaptionCue
    @State private var draft = ""
    @FocusState private var editing: Bool

    private var isCurrent: Bool { model.playhead >= cue.start && model.playhead < cue.end }
    private var isSelected: Bool { model.selectedCaptionID == cue.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Button { model.selectCaption(cue.id); model.seek(to: cue.start + 0.01) } label: {
                    Text(stamp(cue.start)).font(.system(size: 10, design: .monospaced))
                }.buttonStyle(.plain).help("Jump to this line and select it")
                Text("→ \(stamp(cue.end))").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                if cue.isPlaced {
                    Button { model.updateCaptionCue(cue.id) { $0.x = nil; $0.y = nil } } label: {
                        Image(systemName: "pin.fill").font(.system(size: 9))
                    }.buttonStyle(.plain).foregroundStyle(AppTheme.green)
                        .help("This line has a place of its own. Click to return it to the others.")
                }
                Spacer()
                Button { model.removeCaptionCue(cue.id) } label: { Image(systemName: "trash") }
                    .buttonStyle(.plain).font(.system(size: 10)).help("Delete this line")
            }
            TextField("Line", text: $draft, axis: .vertical)
                .font(.system(size: 11)).textFieldStyle(.plain).lineLimit(1...4)
                .focused($editing)
                .onSubmit { commit() }
                .onChange(of: editing) { if !editing { commit() } }
        }
        .padding(8)
        .background(isSelected ? AppTheme.green.opacity(0.18) : isCurrent ? AppTheme.green.opacity(0.08) : AppTheme.elevated,
                    in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(isSelected ? AppTheme.green : .clear))
        .onTapGesture { model.selectCaption(cue.id) }
        .onAppear { draft = cue.text }
        .onChange(of: cue.text) { draft = cue.text }
    }

    private func commit() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text != cue.text else { return }
        guard !text.isEmpty else { draft = cue.text; return }
        model.updateCaptionCue(cue.id) { $0.text = text }
    }

    private func stamp(_ seconds: Double) -> String {
        String(format: "%d:%05.2f", Int(max(0, seconds)) / 60, max(0, seconds).truncatingRemainder(dividingBy: 60))
    }
}

/// Bridges the stored sRGB triples to SwiftUI's colour wells.
private enum CaptionColor {
    static func binding(_ model: EditorModel, _ path: WritableKeyPath<CaptionSettings, RGBColor>) -> Binding<Color> {
        Binding(
            get: {
                let c = model.captions[keyPath: path]
                return Color(red: c.r, green: c.g, blue: c.b)
            },
            set: { newValue in
                let resolved = NSColor(newValue).usingColorSpace(.sRGB) ?? .white
                model.captions[keyPath: path] = RGBColor(r: Double(resolved.redComponent),
                                                         g: Double(resolved.greenComponent),
                                                         b: Double(resolved.blueComponent))
            })
    }
}

extension CaptionSettings {
    /// The word highlight is the effect accent until it is given a colour
    /// of its own, which is the first time the well is touched.
    var highlightColorOrAccent: RGBColor {
        get { highlightColor ?? RGBColor(r: 0.17, g: 0.55, b: 1) }
        set { highlightColor = newValue }
    }
}
