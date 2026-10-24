import SwiftUI

struct TimelineView: View {
    @EnvironmentObject private var model: EditorModel
    private let labelWidth: CGFloat = 76
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Text("TIMELINE").font(.system(size: 10, weight: .semibold)).tracking(1).foregroundStyle(.secondary)
                Text("\(model.segments.count) effects").font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Button { model.addSegment(.zoom) } label: { Label("Zoom", systemImage: "plus.magnifyingglass") }
                Button { model.addSegment(.blur) } label: { Label("Blur", systemImage: "drop") }
                Divider().frame(height: 14)
                Button { model.duplicateSelected() } label: { Image(systemName: "plus.square.on.square") }.disabled(model.selectedSegment == nil).help("Duplicate selected segment")
                Button { model.splitSelected() } label: { Image(systemName: "scissors") }
                    .disabled(!model.canSplitSelected)
                    .help(model.selectedSegment == nil
                          ? "Select a segment to split it"
                          : model.canSplitSelected
                            ? "Split selected segment at playhead"
                            : "Move the playhead inside the selected segment to split it")
                Button { model.deleteSelected() } label: { Label("Delete", systemImage: "trash") }.disabled(model.selectedSegment == nil)
            }.buttonStyle(.plain).font(.caption).padding(.horizontal, 16).frame(height: 40).disabled(model.videoURL == nil)
            GeometryReader { geo in
                let width = max(1, geo.size.width - labelWidth - 18)
                VStack(spacing: 6) {
                    ruler(width: width).padding(.leading, labelWidth)
                    HStack(spacing: 0) {
                        Label("Video", systemImage: "film").font(.system(size: 10, weight: .medium)).frame(width: labelWidth, alignment: .leading)
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 6).fill(AppTheme.green.opacity(0.13))
                            HStack(spacing: 5) {
                                Image(systemName: "waveform.path").font(.caption)
                                Text(model.videoURL?.lastPathComponent ?? "Record or import to begin").font(.system(size: 10)).lineLimit(1)
                            }.foregroundStyle(AppTheme.green).padding(.horizontal, 12)
                            if model.duration > 0 {
                                Rectangle().fill(AppTheme.panel.opacity(0.7)).frame(width: width * model.trimStart / model.duration)
                                Rectangle().fill(AppTheme.panel.opacity(0.7)).frame(width: width * (1 - model.trimEnd / model.duration)).offset(x: width * model.trimEnd / model.duration)
                            }
                        }.frame(width: width, height: 32)
                            .contentShape(Rectangle())
                            .gesture(DragGesture(minimumDistance: 0).onChanged { model.seek(to: Double($0.location.x / width) * model.duration) })
                    }
                    ForEach(SegmentKind.availableCases) { kind in row(kind: kind, width: width) }
                }
                .padding(.horizontal, 9)
                .overlay(alignment: .topLeading) {
                    if model.duration > 0 {
                        VStack(spacing: 0) {
                            RoundedRectangle(cornerRadius: 2).fill(AppTheme.green).frame(width: 8, height: 10)
                            Rectangle().fill(AppTheme.green).frame(width: 1, height: 215)
                        }.offset(x: 9 + labelWidth + width * model.playhead / model.duration - 4, y: 3).allowsHitTesting(false)
                    }
                }
            }
            HStack {
                Text("Drag to move · pull edges to resize").font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Button("Set in") { model.setTrimStart() }
                Text("\(model.trimStart, specifier: "%.1f") – \(model.trimEnd, specifier: "%.1f") s").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                Button("Set out") { model.setTrimEnd() }
                Button("Reset trim") { model.resetTrim() }
            }.font(.caption2).buttonStyle(.plain).padding(.horizontal, 16).padding(.bottom, 12).disabled(model.videoURL == nil)
        }.frame(height: 310).background(AppTheme.panel)
        .onDeleteCommand { model.deleteSelected() }
    }
    func ruler(width: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            ForEach(0..<7) { i in
                Text(format(model.duration * Double(i) / 6)).font(.system(size: 9, design: .monospaced)).foregroundStyle(.tertiary)
                    .offset(x: (width - 28) * CGFloat(i) / 6)
            }
        }.frame(width: width, height: 20, alignment: .leading).contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { model.seek(to: Double($0.location.x / width) * model.duration) })
    }
    func row(kind: SegmentKind, width: CGFloat) -> some View {
        HStack(spacing: 0) {
            Label(kind.title, systemImage: kind.symbol).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary).frame(width: labelWidth, alignment: .leading)
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 5).fill(AppTheme.elevated)
                ForEach(model.segments.filter { $0.kind == kind }) { SegmentBlock(segment: $0, fullWidth: width) }
            }.frame(width: width, height: 27).clipped()
        }
    }
    func format(_ seconds: Double) -> String { String(format: "%02d:%02d", Int(max(0, seconds)) / 60, Int(max(0, seconds)) % 60) }
}

struct SegmentBlock: View {
    @EnvironmentObject private var model: EditorModel
    let segment: EditSegment
    let fullWidth: CGFloat
    @State private var dragOrigin: EditSegment?
    var color: Color {
        switch segment.kind { case .zoom: AppTheme.green; case .pan: .blue; case .spotlight: .orange; case .callout: .pink; default: .purple }
    }
    var body: some View {
        let width = max(16, CGFloat(segment.duration / max(model.duration, 0.1)) * fullWidth)
        HStack(spacing: 0) {
            handle(leading: true)
            Text(width > 55 ? segment.kind.title : "").font(.system(size: 9, weight: .semibold)).lineLimit(1)
                .frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 2).onChanged { value in
                    select(); if dragOrigin == nil { dragOrigin = segment }
                    guard let origin = dragOrigin else { return }
                    model.updateSelected { $0.start = max(0, min(model.duration - origin.duration, origin.start + Double(value.translation.width / fullWidth) * model.duration)) }
                }.onEnded { _ in dragOrigin = nil })
            handle(leading: false)
        }
        .foregroundStyle(color).frame(width: width, height: 23)
        .background(color.opacity(0.16), in: RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(color.opacity(model.selectedSegmentID == segment.id ? 1 : 0.25), lineWidth: model.selectedSegmentID == segment.id ? 1.5 : 1))
        .offset(x: CGFloat(segment.start / max(model.duration, 0.1)) * fullWidth)
        .onTapGesture { select(); model.seek(to: segment.start + min(0.5, segment.duration / 2)) }
        .contextMenu {
            Button("Duplicate") { select(); model.duplicateSelected() }
            Button("Split at playhead") { select(); model.splitSelected() }
                .disabled(!(model.playhead > segment.start + 0.1 && model.playhead < segment.end - 0.1))
            Button("Delete", role: .destructive) { select(); model.deleteSelected() }
        }
    }
    func select() { model.selectedSegmentID = segment.id; model.inspectorTab = "Segment" }
    func handle(leading: Bool) -> some View {
        RoundedRectangle(cornerRadius: 1).fill(color.opacity(0.5)).frame(width: 2, height: 10).padding(.horizontal, 4).frame(height: 23).contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 1).onChanged { value in
                select(); if dragOrigin == nil { dragOrigin = segment }
                guard let origin = dragOrigin else { return }
                let delta = Double(value.translation.width / fullWidth) * model.duration
                model.updateSelected {
                    if leading {
                        $0.start = min(origin.end - 0.1, max(0, origin.start + delta)); $0.duration = origin.end - $0.start
                    } else { $0.duration = max(0.1, min(model.duration - origin.start, origin.duration + delta)) }
                }
            }.onEnded { _ in dragOrigin = nil })
    }
}
