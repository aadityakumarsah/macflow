import AppKit
import SwiftUI

/// The keys every video editor has: space to play, the arrows to step
/// through, I and O for the two ends of the clip.
///
/// They are taken with a local event monitor rather than menu key
/// equivalents. A menu item whose shortcut carries no modifier claims that
/// key for the whole window, including from a field someone is typing into —
/// which is how Delete came to remove the selected effect while a callout
/// was being written. A monitor can ask who has the keyboard first and leave
/// them to it.
struct EditorKeys: ViewModifier {
    @EnvironmentObject private var model: EditorModel
    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
            .onAppear {
                guard monitor == nil else { return }
                monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
                    MainActor.assumeIsolated { handle(event) ? nil : event }
                }
            }
            .onDisappear {
                if let monitor { NSEvent.removeMonitor(monitor) }
                monitor = nil
            }
    }

    /// True when the key was ours, and so should go no further.
    @MainActor private func handle(_ event: NSEvent) -> Bool {
        // Whoever is typing gets the key, every time.
        if event.window?.firstResponder is NSTextView { return false }
        // A sheet in front is its own world, and the editor is not in it.
        guard model.videoURL != nil, !model.showRecorder, !model.showLibrary, !model.showCropEditor else { return false }
        // Shift is a modifier these keys use; the rest belong to the menus.
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
        let coarse = event.modifierFlags.contains(.shift)

        switch event.keyCode {
        case 49:                                            // space
            model.togglePlayback()
        case 123:                                           // left
            model.seek(to: model.playhead - (coarse ? 1 : 1.0 / 30))
        case 124:                                           // right
            model.seek(to: model.playhead + (coarse ? 1 : 1.0 / 30))
        case 51, 117:                                       // delete, forward delete
            guard model.selectedSegmentID != nil else { return false }
            model.deleteSelected()
        default:
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "i": model.setTrimStart()
            case "o": model.setTrimEnd()
            case "s": guard model.canSplitSelected else { return false }; model.splitSelected()
            case "[": model.seek(to: model.trimStart)
            case "]": model.seek(to: model.trimEnd)
            default: return false
            }
        }
        return true
    }
}

extension View {
    func editorKeys() -> some View { modifier(EditorKeys()) }
}
