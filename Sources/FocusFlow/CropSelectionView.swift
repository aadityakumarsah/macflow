import SwiftUI
import AVFoundation

/// The overlay and image share the same fitted rect, including on portrait sources.
struct CropSelectionView: View {
    let image: CGImage
    @Binding var region: ContentRegion
    @State private var resizeOrigin: ContentRegion?
    var body: some View {
        GeometryReader { proxy in
            let scale = min(proxy.size.width / CGFloat(image.width), proxy.size.height / CGFloat(image.height))
            let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
            let crop = region.rect(in: size)
            ZStack(alignment: .topLeading) {
                Image(decorative: image, scale: 1).resizable().frame(width: size.width, height: size.height)
                Path { path in
                    path.addRect(CGRect(origin: .zero, size: size)); path.addRect(crop)
                }.fill(.black.opacity(0.5), style: FillStyle(eoFill: true)).allowsHitTesting(false)
                Rectangle().stroke(.white, style: StrokeStyle(lineWidth: 1.5, dash: [6, 3]))
                    .frame(width: crop.width, height: crop.height).offset(x: crop.minX, y: crop.minY).allowsHitTesting(false)
                ForEach(0..<4) { corner in
                    Circle().fill(AppTheme.green).overlay(Circle().stroke(.white, lineWidth: 1.5)).frame(width: 9, height: 9)
                        .padding(7).contentShape(Rectangle())
                        .position(x: corner % 2 == 0 ? crop.minX : crop.maxX, y: corner < 2 ? crop.minY : crop.maxY)
                        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                            if resizeOrigin == nil { resizeOrigin = region }
                            guard let original = resizeOrigin else { return }
                            let left = corner % 2 == 0, top = corner < 2
                            let opposite = CGPoint(x: left ? original.x + original.width : original.x, y: top ? original.y + original.height : original.y)
                            let moving = CGPoint(x: min(1, max(0, (left ? original.x : original.x + original.width) + value.translation.width / size.width)), y: min(1, max(0, (top ? original.y : original.y + original.height) + value.translation.height / size.height)))
                            region = ContentRegion.selection(from: opposite, to: moving)
                        }.onEnded { _ in resizeOrigin = nil })
                }
            }
            .frame(width: size.width, height: size.height).contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 3).onChanged { value in
                func point(_ p: CGPoint) -> CGPoint { CGPoint(x: min(1, max(0, p.x / size.width)), y: min(1, max(0, p.y / size.height))) }
                region = ContentRegion.selection(from: point(value.startLocation), to: point(value.location))
            })
            .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
        }
        .help("Drag over the content you want to keep")
    }
}

struct CropEditor: View {
    @EnvironmentObject private var model: EditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var image: CGImage?
    @State private var region = ContentRegion.full
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Choose your content").font(.title2.bold())
            Text("Drag around the tab content or pane you want to keep. The original video stays available.").foregroundStyle(.secondary)
            ZStack {
                Color.black.opacity(0.85)
                if let image { CropSelectionView(image: image, region: $region).padding(12) }
                else if let error { Text(error).foregroundStyle(.white) }
                else { ProgressView() }
            }.frame(height: 430).clipShape(RoundedRectangle(cornerRadius: 12))
            HStack {
                Button("Full content") { region = .full }
                Text("\(Int(region.width * 100))% × \(Int(region.height * 100))%").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Apply crop") { model.frameAppearance.crop = region.bounded; dismiss() }.buttonStyle(.borderedProminent).tint(AppTheme.green).disabled(image == nil).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 800).task {
            region = model.frameAppearance.crop
            guard let url = model.videoURL else { return }
            do {
                let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: 1600, height: 1200)
                image = try await generator.image(at: CMTime(seconds: min(model.playhead, max(0, model.duration - 0.05)), preferredTimescale: 600)).image
            } catch { self.error = error.localizedDescription }
        }
    }
}
