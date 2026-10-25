import SwiftUI

@main
struct FocusFlowApp: App {
    @StateObject private var model = EditorModel()
    @StateObject private var updater = Updater()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environmentObject(updater)
                .frame(minWidth: 1180, minHeight: 760)
                .preferredColorScheme(.light)
        }
        .windowStyle(.hiddenTitleBar)

        Settings {
            SettingsView()
                .environmentObject(updater)
                .environmentObject(model)
        }

        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    Task { await updater.check(userInitiated: true) }
                }.disabled(updater.isBusy)
            }
            CommandGroup(after: .toolbar) {
                Button(model.theatreMode ? "Exit Full Screen Preview" : "Full Screen Preview") {
                    model.toggleTheatreMode()
                }
                .keyboardShortcut("f", modifiers: [.control, .command])
                .disabled(model.videoURL == nil)
            }
            // Delete removes the selected effect, which is what every other
            // timeline does and what the key is expected to do here.
            CommandGroup(after: .pasteboard) {
                Button("Delete Effect") { model.deleteSelected() }
                    .keyboardShortcut(.delete, modifiers: [])
                    .disabled(model.selectedSegmentID == nil)
                Button("Duplicate Effect") { model.duplicateSelected() }
                    .keyboardShortcut("d", modifiers: .command)
                    .disabled(model.selectedSegmentID == nil)
                Button("Split Effect at Playhead") { model.splitSelected() }
                    .keyboardShortcut("b", modifiers: .command)
                    .disabled(!model.canSplitSelected)
            }
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") { model.undo() }.keyboardShortcut("z").disabled(!model.canUndo)
                Button("Redo") { model.redo() }.keyboardShortcut("z", modifiers: [.command, .shift]).disabled(!model.canRedo)
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save Project…") { model.saveProject() }.keyboardShortcut("s").disabled(model.videoURL == nil)
            }
            CommandGroup(replacing: .newItem) {
                Button("New Recording") { model.showRecorder = true }
                    .keyboardShortcut("n")
                Button("Open Recording…") { model.importVideo() }
                    .keyboardShortcut("o")
            }
        }
    }
}
