import AVFoundation
import Foundation

struct RecordingItem: Identifiable, Hashable {
    var id: String { url.path }
    let url: URL
    let createdAt: Date
    let fileSize: Int64
    let duration: Double

    var formattedDuration: String {
        guard duration.isFinite else { return "--:--" }
        return String(format: "%02d:%02d", Int(duration) / 60, Int(duration) % 60)
    }

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }
}

@MainActor
final class RecordingLibrary: ObservableObject {
    @Published private(set) var recordings: [RecordingItem] = []
    @Published private(set) var isLoading = false

    let directory: URL

    init() {
        directory = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FocusFlow", isDirectory: true)
    }

    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let keys: Set<URLResourceKey> = [.creationDateKey, .contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
            let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])
                .filter {
                    ["mp4", "mov", "m4v"].contains($0.pathExtension.lowercased()) &&
                    !$0.lastPathComponent.hasPrefix("Camera ")
                }
            var items: [RecordingItem] = []
            for url in urls {
                let values = try? url.resourceValues(forKeys: keys)
                guard values?.isRegularFile == true else { continue }
                let asset = AVURLAsset(url: url)
                let seconds = (try? await asset.load(.duration).seconds) ?? 0
                items.append(RecordingItem(
                    url: url,
                    createdAt: values?.creationDate ?? values?.contentModificationDate ?? .distantPast,
                    fileSize: Int64(values?.fileSize ?? 0),
                    duration: seconds
                ))
            }
            recordings = items.sorted { $0.createdAt > $1.createdAt }
        } catch {
            recordings = []
        }
    }

    func register(_ url: URL, metadata: RecordingMetadata) async throws {
        let sidecar = url.deletingPathExtension().appendingPathExtension("focusflow.json")
        let data = try JSONEncoder().encode(metadata)
        try data.write(to: sidecar, options: .atomic)
        await refresh()
    }

    func metadata(for url: URL) -> RecordingMetadata {
        let sidecar = url.deletingPathExtension().appendingPathExtension("focusflow.json")
        if let data = try? Data(contentsOf: sidecar), let metadata = try? JSONDecoder().decode(RecordingMetadata.self, from: data) {
            return metadata
        }
        let legacySidecar = url.deletingPathExtension().appendingPathExtension("clicks.json")
        guard let data = try? Data(contentsOf: legacySidecar) else { return .empty }
        let clicks = (try? JSONDecoder().decode([RecordedClick].self, from: data)) ?? []
        return RecordingMetadata(clicks: clicks, pointerSamples: [], keystrokes: [], sourceWidth: 0, sourceHeight: 0, sourceName: "")
    }

    func delete(_ item: RecordingItem) async throws {
        let metadata = metadata(for: item.url)
        var urls = [
            item.url,
            item.url.deletingPathExtension().appendingPathExtension("focusflow.json"),
            item.url.deletingPathExtension().appendingPathExtension("clicks.json"),
            item.url.deletingPathExtension().appendingPathExtension("edits.json")
        ]
        if let cameraFileName = metadata.cameraFileName {
            urls.append(item.url.deletingLastPathComponent().appendingPathComponent(cameraFileName))
        }
        for url in urls where FileManager.default.fileExists(atPath: url.path) {
            var trashedURL: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &trashedURL)
        }
        await refresh()
    }
}
