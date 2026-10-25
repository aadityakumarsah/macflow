import Foundation

/// The three sounds a screen recording can be given back: the keyboard under
/// a run of typing, a click under a click, and the paper-shuffle of a scroll.
///
/// Each is one clip, bundled with the app. A clip is laid down where the
/// thing happened and repeated until that stretch is covered, with the last
/// repetition cut where the typing stops — so a ten-second passage of typing
/// is the clip over and over rather than eight seconds of keyboard and two of
/// silence, and a two-second one is the first two seconds of it.
enum SoundKind: String, Codable, CaseIterable, Identifiable {
    case typing, clicking, scrolling
    var id: String { rawValue }
    var title: String {
        switch self {
        case .typing: "Typing"
        case .clicking: "Clicks"
        case .scrolling: "Scrolling"
        }
    }
    var url: URL? { Bundle.module.url(forResource: rawValue, withExtension: "mp3", subdirectory: "Sounds") }
}

struct SoundSettings: Codable, Equatable {
    var typing = true
    var clicking = true
    var scrolling = true
    var typingVolume: Double = 0.45
    var clickingVolume: Double = 0.55
    var scrollingVolume: Double = 0.4

    func isOn(_ kind: SoundKind) -> Bool {
        switch kind {
        case .typing: typing
        case .clicking: clicking
        case .scrolling: scrolling
        }
    }
    func volume(_ kind: SoundKind) -> Double {
        let value = switch kind {
        case .typing: typingVolume
        case .clicking: clickingVolume
        case .scrolling: scrollingVolume
        }
        return min(1, max(0, value))
    }
}

/// A stretch of the timeline a sound covers. `end` equal to `start` is a
/// single hit — a click — which plays the clip once rather than filling
/// anything.
struct SoundCue: Equatable {
    var kind: SoundKind
    var start: Double
    var end: Double
    var fills: Bool { end > start }
}

enum SoundTrack {
    /// Silence that ends a run. Typing is given a longer one than the camera
    /// gets: the sound of a keyboard reads as continuous across the pause for
    /// a word, where the frame would have no business moving.
    static let typingGap = 0.9
    static let scrollGap = 0.45
    /// A little sound past the last event, so a run does not stop dead on it.
    static let tail = 0.12

    /// What to play and when, from what the recording saw happen. Derived
    /// rather than stored, so it follows every change to the edit without
    /// anything having to be regenerated or kept in step by hand.
    static func cues(clicks: [RecordedClick],
                     typing: [TypingEvent],
                     scrolling: [ScrollEvent],
                     duration: Double,
                     settings: SoundSettings) -> [SoundCue] {
        guard duration > 0 else { return [] }
        var cues: [SoundCue] = []

        func runs(_ times: [Double], gap: Double, kind: SoundKind) {
            for run in MotionEngine.typingRuns(times.filter { $0 >= 0 && $0 < duration }, gap: gap) {
                // A single stray event is not a run of anything.
                guard run.count >= 2, let first = run.first, let last = run.last else { continue }
                cues.append(SoundCue(kind: kind, start: first, end: min(duration, last + tail)))
            }
        }
        if settings.isOn(.typing) { runs(typing.map(\.time), gap: typingGap, kind: .typing) }
        if settings.isOn(.scrolling) { runs(scrolling.map(\.time), gap: scrollGap, kind: .scrolling) }
        if settings.isOn(.clicking) {
            for click in clicks where click.time >= 0 && click.time < duration {
                cues.append(SoundCue(kind: .clicking, start: click.time, end: click.time))
            }
        }
        return cues.sorted { $0.start < $1.start }
    }
}
