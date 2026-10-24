import SwiftUI

@main
struct FocusFlowApp: App {
    @StateObject private var model = EditorModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .frame(minWidth: 1180, minHeight: 760)
                .preferredColorScheme(.light)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
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
