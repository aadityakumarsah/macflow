import AppKit
import SwiftUI

struct RecordingLibraryView: View {
    @EnvironmentObject private var model: EditorModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var library: RecordingLibrary
    init(library: RecordingLibrary) { self.library = library }
    @State private var deleteCandidate: RecordingItem?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                AppIconMark(size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Recording library").font(.title2.bold())
                    Text("Stored locally in Movies/FocusFlow").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { NSWorkspace.shared.open(model.library.directory) } label: { Label("Show in Finder", systemImage: "folder") }
                Button { dismiss() } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).font(.title2).foregroundStyle(.secondary)
            }.padding(20)
            Divider().overlay(AppTheme.line)

            if library.isLoading {
                Spacer(); ProgressView("Loading recordings…"); Spacer()
            } else if library.recordings.isEmpty {
                ContentUnavailableView("No recordings yet", systemImage: "film.stack", description: Text("Finish a screen recording and it will appear here automatically."))
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 14)], spacing: 14) {
                        ForEach(library.recordings) { item in
                            RecordingCard(item: item, open: { model.openLibraryItem(item); dismiss() }, delete: { deleteCandidate = item })
                        }
                    }.padding(20)
                }
            }
        }
        .frame(minWidth: 760, minHeight: 520)
        .background(AppTheme.workspace)
        .task { await model.library.refresh() }
        .alert("Move recording to Trash?", isPresented: Binding(get: { deleteCandidate != nil }, set: { if !$0 { deleteCandidate = nil } })) {
            Button("Cancel", role: .cancel) { deleteCandidate = nil }
            Button("Delete", role: .destructive) {
                guard let item = deleteCandidate else { return }
                deleteCandidate = nil
                Task {
                    do { try await model.deleteRecording(item) }
                    catch { model.message = "Could not move the recording to Trash: \(error.localizedDescription)" }
                }
            }
        } message: {
            Text("The screen recording, camera recording, and edit metadata will be moved to the Mac Trash.")
        }
    }
}

struct RecordingCard: View {
    let item: RecordingItem
    let open: () -> Void
    let delete: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: open) {
                VStack(alignment: .leading, spacing: 10) {
                    ZStack {
                        LinearGradient(colors: [Color(hex: 0x172033), Color(hex: 0x0D1220)], startPoint: .topLeading, endPoint: .bottomTrailing)
                        Image(systemName: "play.rectangle.fill").font(.system(size: 38)).foregroundStyle(AppTheme.green)
                        Text(item.formattedDuration).font(.system(.caption, design: .monospaced)).padding(.horizontal, 7).padding(.vertical, 4)
                            .background(.black.opacity(0.7), in: Capsule()).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing).padding(9)
                    }.frame(height: 124).clipShape(RoundedRectangle(cornerRadius: 10))
                    Text(item.url.deletingPathExtension().lastPathComponent).font(.subheadline.weight(.semibold)).lineLimit(1)
                    HStack {
                        Text(item.createdAt.formatted(date: .abbreviated, time: .shortened))
                        Spacer()
                        Text(item.formattedSize)
                    }.font(.caption2).foregroundStyle(.secondary)
                }.padding(10)
            }
            .buttonStyle(.plain)
            Button(action: delete) {
                Image(systemName: "trash.fill").padding(8).background(.black.opacity(0.72), in: Circle())
            }
            .buttonStyle(.plain).foregroundStyle(.red).padding(18)
        }
        .background(AppTheme.elevated, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(AppTheme.line))
    }
}
