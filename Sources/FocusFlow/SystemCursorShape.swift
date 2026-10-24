import AppKit

/// Best-effort system cursor detection. Current macOS may return nil; the editor
/// always offers an explicit Arrow / Text override for those recordings.
enum SystemCursorShape {
    private static let textImages = [NSCursor.iBeam.image.tiffRepresentation, NSCursor.iBeamCursorForVerticalLayout.image.tiffRepresentation].compactMap { $0 }
    static func current() -> PointerShape {
        guard let image = NSCursor.currentSystem?.image.tiffRepresentation else { return .arrow }
        return textImages.contains(image) ? .text : .arrow
    }
}
