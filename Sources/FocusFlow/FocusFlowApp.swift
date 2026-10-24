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

        Settings { SettingsView() }

        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    Task { await updater.check(userInitiated: true) }
                }.disabled(updater.isBusy)
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
