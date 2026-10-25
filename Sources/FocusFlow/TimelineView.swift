import SwiftUI

struct TimelineView: View {
    @EnvironmentObject private var model: EditorModel
    private let labelWidth: CGFloat = 76
    private var visibleKinds: [SegmentKind] {
        SegmentKind.availableCases.filter { kind in model.segments.contains { $0.kind == kind } }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Text("TIMELINE").font(.system(size: 10, weight: .semibold)).tracking(1).foregroundStyle(.secondary)
                Text("\(model.segments.count) effects").font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Menu {
                    ForEach(SegmentKind.availableCases) { kind in
                        Button { model.addSegment(kind) } label: { Label(kind.title, systemImage: kind.symbol) }
                    }
                } label: { Label("Add effect", systemImage: "plus") }.menuStyle(.borderlessButton).fixedSize()
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
                            // Where the video starts and ends, dragged on the
                            // video itself. The buttons below do the same from
                            // the playhead, but nobody looks for a button to
                            // do what the edge of a clip is for.
                            .overlay(alignment: .leading) {
                                if model.duration > 0 {
                                    TrimHandle(edge: .start, fullWidth: width)
                                    TrimHandle(edge: .end, fullWidth: width)
                                }
                            }
                            .coordinateSpace(name: TrimHandle.space)
                    }
                    ForEach(visibleKinds) { kind in row(kind: kind, width: width) }
                }
                .padding(.horizontal, 9)
                .overlay(alignment: .topLeading) {
                    if model.duration > 0 {
                        VStack(spacing: 0) {
                            RoundedRectangle(cornerRadius: 2).fill(AppTheme.green).frame(width: 8, height: 10)
                            Rectangle().fill(AppTheme.green).frame(width: 1, height: CGFloat(62 + visibleKinds.count * 33))
                        }.offset(x: 9 + labelWidth + width * model.playhead / model.duration - 4, y: 3).allowsHitTesting(false)
                    }
                }
            }
            HStack {
                Text("Drag the video's edges to set where it starts and ends")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .help("Space play · ← → step a frame, with Shift a second · I in · O out · S split · [ ] jump to the ends")
                Spacer()
                Button("Set in") { model.setTrimStart() }
                Text("\(model.trimStart, specifier: "%.1f") – \(model.trimEnd, specifier: "%.1f") s").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                Button("Set out") { model.setTrimEnd() }
                Button("Reset trim") { model.resetTrim() }
            }.font(.caption2).buttonStyle(.plain).padding(.horizontal, 16).padding(.bottom, 12).disabled(model.videoURL == nil)
        }.frame(height: CGFloat(146 + visibleKinds.count * 33)).background(AppTheme.panel)
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
            .coordinateSpace(name: SegmentBlock.space)
        }
    }
    func format(_ seconds: Double) -> String { String(format: "%02d:%02d", Int(max(0, seconds)) / 60, Int(max(0, seconds)) % 60) }
}

/// One end of the kept stretch of video, dragged along the video track.
struct TrimHandle: View {
    enum Edge { case start, end }
    static let space = "videoTrack"
    @EnvironmentObject private var model: EditorModel
    let edge: Edge
    let fullWidth: CGFloat
    @State private var dragging = false

    private var time: Double { edge == .start ? model.trimStart : model.trimEnd }

    var body: some View {
        let position = fullWidth * time / max(0.001, model.duration)
        RoundedRectangle(cornerRadius: 3)
            .fill(dragging ? AppTheme.green : AppTheme.green.opacity(0.85))
            .frame(width: 9, height: 32)
            .overlay {
                VStack(spacing: 2) {
                    ForEach(0..<2, id: \.self) { _ in Capsule().fill(.white.opacity(0.9)).frame(width: 1, height: 9) }
                }
            }
            .overlay(alignment: edge == .start ? .bottomLeading : .bottomTrailing) {
                if dragging {
                    Text(format(time)).font(.system(size: 9, design: .monospaced))
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(AppTheme.panel, in: RoundedRectangle(cornerRadius: 3))
                        .fixedSize().offset(y: 18)
                }
            }
            // Half the handle hangs outside the kept stretch, so neither one
            // covers the frame it is pointing at.
            .offset(x: edge == .start ? position : position - 9)
            .contentShape(Rectangle().inset(by: -6))
            .onHover { NSCursor.resizeLeftRight.set(); if !$0 { NSCursor.arrow.set() } }
            // Measured against the track rather than the handle: the handle
            // is offset, and a dragged view's own space moves with it.
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named(TrimHandle.space))
                    .onChanged { value in
                        dragging = true
                        let at = Double(value.location.x) / Double(fullWidth) * model.duration
                        if edge == .start { model.setTrimStart(to: at) } else { model.setTrimEnd(to: at) }
                    }
                    .onEnded { _ in dragging = false; model.seek(to: edge == .start ? model.trimStart : model.trimEnd) }
            )
            .help(edge == .start ? "Where the video starts" : "Where the video ends")
    }
    private func format(_ seconds: Double) -> String {
        String(format: "%d:%04.1f", Int(max(0, seconds)) / 60, seconds.truncatingRemainder(dividingBy: 60))
    }
}

/// Where a dragged effect ends up.
///
/// Apart from the view so it can be checked: these are the sums that decide
/// whether an effect can be moved at all, and they were wrong in a way no
/// amount of looking at the drawing code would show.
enum TimelineDrag {
    /// Moved bodily, keeping the point it was picked up by under the pointer.
    static func moved(origin: EditSegment, pointer: Double, grabbedAt offset: Double, duration: Double) -> Double {
        max(0, min(duration - origin.duration, pointer - offset))
    }
    /// Dragged by one end. The edge goes to the pointer, the other end stays,
    /// and the effect keeps a tenth of a second of itself.
    static func resized(origin: EditSegment, leading: Bool, pointer: Double, duration: Double) -> (start: Double, length: Double) {
        if leading {
            let start = min(origin.end - 0.1, max(0, pointer))
            return (start, origin.end - start)
        }
        return (origin.start, max(0.1, min(duration - origin.start, pointer - origin.start)))
    }
}

struct SegmentBlock: View {
    /// The track the block sits on. Every drag is measured against it.
    ///
    /// Not against the block: the block is placed with an offset that the
    /// drag itself changes, so its own coordinate space travels with the
    /// pointer. A translation measured there collapses towards nothing as
    /// soon as the block starts following — the block jumps once and then
    /// sticks, which is what made these impossible to move.
    static let space = "timelineTrack"
    @EnvironmentObject private var model: EditorModel
    let segment: EditSegment
    let fullWidth: CGFloat
    @State private var dragOrigin: EditSegment?
    /// How far into the block it was picked up, so it does not jump to put
    /// its start under the pointer.
    @State private var grabOffset: Double?
    var color: Color {
        switch segment.kind { case .zoom: AppTheme.green; case .pan: .blue; case .spotlight: .orange; case .callout: .pink; default: .purple }
    }
    /// Where a point on the track falls in the recording.
    private func time(_ x: CGFloat) -> Double {
        Double(x) / Double(max(1, fullWidth)) * model.duration
    }

    var body: some View {
        // Wide enough that both ends and the middle can be taken hold of,
        // however short the effect is.
        let width = max(34, CGFloat(segment.duration / max(model.duration, 0.1)) * fullWidth)
        HStack(spacing: 0) {
            handle(leading: true)
            Text(width > 55 ? segment.kind.title : "").font(.system(size: 9, weight: .semibold)).lineLimit(1)
                .frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle())
                .onHover { NSCursor.openHand.push(); if !$0 { NSCursor.pop() } }
                .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .named(SegmentBlock.space)).onChanged { value in
                    select()
                    if dragOrigin == nil {
                        dragOrigin = segment
                        grabOffset = time(value.startLocation.x) - segment.start
                    }
                    guard let origin = dragOrigin, let grabOffset else { return }
                    let start = TimelineDrag.moved(origin: origin, pointer: time(value.location.x),
                                                   grabbedAt: grabOffset, duration: model.duration)
                    model.updateSelected { $0.start = start }
                }.onEnded { _ in dragOrigin = nil; grabOffset = nil })
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
    /// One end of the effect. The edge goes where the pointer is, which is
    /// the only thing that reads as dragging an edge.
    func handle(leading: Bool) -> some View {
        RoundedRectangle(cornerRadius: 1.5).fill(color.opacity(0.8)).frame(width: 3, height: 13)
            .padding(.horizontal, 5).frame(height: 23).contentShape(Rectangle())
            .onHover { NSCursor.resizeLeftRight.push(); if !$0 { NSCursor.pop() } }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named(SegmentBlock.space)).onChanged { value in
                select(); if dragOrigin == nil { dragOrigin = segment }
                guard let origin = dragOrigin else { return }
                let edge = TimelineDrag.resized(origin: origin, leading: leading,
                                                pointer: time(value.location.x), duration: model.duration)
                model.updateSelected { $0.start = edge.start; $0.duration = edge.length }
            }.onEnded { _ in dragOrigin = nil })
    }
}
