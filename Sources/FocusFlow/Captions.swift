import AVFoundation
import Foundation
import Speech

/// One word, and when it was said. Times are recording time, the same clock
/// every effect on the timeline runs on, so captions follow trims and speed
/// changes with everything else.
struct CaptionWord: Codable, Equatable {
    var text: String
    var start: Double
    var duration: Double
    var end: Double { start + duration }
}

/// One line of caption on screen.
struct CaptionCue: Identifiable, Codable, Equatable {
    var id = UUID()
    var start: Double
    var duration: Double
    var text: String
    var words: [CaptionWord] = []
    /// Where this one line sits, if it has been dragged somewhere of its
    /// own. Nil follows the track's placement, which is almost always what
    /// is wanted — the override exists for the line that would otherwise
    /// cover the thing it is talking about.
    var x: Double? = nil
    var y: Double? = nil
    var end: Double { start + duration }
    var isPlaced: Bool { x != nil && y != nil }

    /// Word timings that match the text as it stands.
    ///
    /// The recognised timings are kept as long as the line is the one that
    /// was recognised. Once it has been rewritten they no longer describe
    /// it, so the cue's own span is shared out across the new words by
    /// their length — which is what the word-by-word styles animate to, and
    /// is better than animating to the wrong word.
    var timedWords: [CaptionWord] {
        let spelled = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !spelled.isEmpty else { return [] }
        if words.count == spelled.count, zip(words, spelled).allSatisfy({ $0.text == $1 }) { return words }
        let weights = spelled.map { Double(max(1, $0.count)) }
        let total = weights.reduce(0, +)
        var at = start
        return zip(spelled, weights).map { word, weight in
            let span = duration * weight / total
            defer { at += span }
            return CaptionWord(text: word, start: at, duration: span)
        }
    }
}

enum CaptionPlacement: String, Codable, CaseIterable, Identifiable {
    case bottom = "Bottom", middle = "Middle", top = "Top"
    /// Wherever it was dragged to. Not offered as a button — it is what
    /// the preview sets when the caption is moved by hand.
    case free = "Custom"
    var id: String { rawValue }
    /// The three that are worth a button.
    static let presets: [CaptionPlacement] = [.top, .middle, .bottom]
}

enum CaptionBackdrop: String, Codable, CaseIterable, Identifiable {
    case none = "None", block = "Block", pill = "Rounded", blur = "Blurred", fade = "Soft fade"
    var id: String { rawValue }
    var detail: String {
        switch self {
        case .none: "Text alone, over the picture."
        case .block: "A straight panel behind the words."
        case .pill: "A rounded panel behind the words."
        case .blur: "The picture itself, softened behind the words."
        case .fade: "A gradient that fades out towards the edges."
        }
    }
}

enum CaptionAnimation: String, Codable, CaseIterable, Identifiable {
    case none = "Cut", fade = "Fade", pop = "Pop", rise = "Rise"
    case karaoke = "Word by word", typewriter = "Typewriter"
    var id: String { rawValue }
    /// Whether the active word is picked out as the line plays.
    var highlightsWords: Bool { self == .karaoke }
    var detail: String {
        switch self {
        case .none: "Each line appears and disappears outright."
        case .fade: "Lines fade in and out."
        case .pop: "Lines spring up to size."
        case .rise: "Lines slide up into place."
        case .karaoke: "The word being spoken is picked out."
        case .typewriter: "The line is written out as it is said."
        }
    }
}

enum CaptionCasing: String, Codable, CaseIterable, Identifiable {
    case spoken = "As spoken", upper = "UPPER", lower = "lower"
    var id: String { rawValue }
    func apply(_ text: String) -> String {
        switch self {
        case .spoken: text
        case .upper: text.uppercased()
        case .lower: text.lowercased()
        }
    }
}

/// A complete look, applied in one go. Everything a preset sets can still be
/// changed afterwards — it is a starting point, not a mode.
enum CaptionPreset: String, CaseIterable, Identifiable {
    case clean = "Clean", bold = "Bold", shorts = "Shorts", podcast = "Podcast"
    case neon = "Neon", broadcast = "Broadcast"
    var id: String { rawValue }

    var detail: String {
        switch self {
        case .clean: "Plain white type on a soft panel."
        case .bold: "Heavy type with a hard outline."
        case .shorts: "Big, capitalised, one word lit at a time."
        case .podcast: "Roomy lines on a rounded block."
        case .neon: "Accent-lit type with a glow."
        case .broadcast: "Small type on a straight bar, as television does it."
        }
    }

    /// Applied over whatever is already set, so the words, the language and
    /// the chosen font family survive switching looks.
    func apply(to settings: CaptionSettings) -> CaptionSettings {
        var s = settings
        switch self {
        case .clean:
            s.size = 0.055; s.bold = true; s.casing = .spoken
            s.backdrop = .pill; s.backdropOpacity = 0.6; s.outlineWidth = 0; s.shadow = 0.4
            s.animation = .fade; s.wordsPerLine = 7; s.textColor = RGBColor(r: 1, g: 1, b: 1)
        case .bold:
            s.size = 0.07; s.bold = true; s.casing = .spoken
            s.backdrop = .none; s.backdropOpacity = 0; s.outlineWidth = 0.08; s.shadow = 0.5
            s.animation = .rise; s.wordsPerLine = 6; s.textColor = RGBColor(r: 1, g: 1, b: 1)
        case .shorts:
            s.size = 0.085; s.bold = true; s.casing = .upper
            s.backdrop = .none; s.backdropOpacity = 0; s.outlineWidth = 0.1; s.shadow = 0.45
            s.animation = .karaoke; s.wordsPerLine = 4; s.highlightFill = true
            s.textColor = RGBColor(r: 1, g: 1, b: 1)
        case .podcast:
            s.size = 0.05; s.bold = false; s.casing = .spoken
            s.backdrop = .pill; s.backdropOpacity = 0.78; s.backdropPadding = 0.55
            s.outlineWidth = 0; s.shadow = 0.25; s.animation = .fade; s.wordsPerLine = 9
            s.textColor = RGBColor(r: 1, g: 1, b: 1)
        case .neon:
            s.size = 0.072; s.bold = true; s.casing = .upper
            s.backdrop = .blur; s.backdropOpacity = 0.4; s.outlineWidth = 0.05; s.shadow = 0.7
            s.animation = .karaoke; s.wordsPerLine = 5; s.highlightFill = false
            s.textColor = RGBColor(r: 1, g: 1, b: 1)
        case .broadcast:
            s.size = 0.042; s.bold = false; s.casing = .spoken
            s.backdrop = .block; s.backdropOpacity = 0.85; s.backdropPadding = 0.4
            s.outlineWidth = 0; s.shadow = 0; s.animation = .none; s.wordsPerLine = 10
            s.textColor = RGBColor(r: 1, g: 1, b: 1)
        }
        return s
    }
}

/// Everything about how a caption looks, and the lines themselves.
struct CaptionSettings: Codable, Equatable {
    /// Off until there is something to show. Generating turns it on.
    var enabled = false
    var cues: [CaptionCue] = []
    /// What was spoken, as a BCP-47 identifier.
    var language = "en-US"

    /// Empty is the system font. Anything else is a family name.
    var fontName = ""
    var bold = true
    var italic = false
    /// A share of the canvas height, so a caption is the same size on a
    /// 1080p export as on a 4K one.
    var size: Double = 0.055
    /// Extra letter spacing, as a share of the font size.
    var tracking: Double = 0
    /// Multiplies the font's own line height.
    var lineSpacing: Double = 1.12

    var textColor = RGBColor(r: 1, g: 1, b: 1)
    /// Picks out the word being spoken. Nil follows the effect accent, so a
    /// project that has chosen a colour once has chosen it everywhere.
    var highlightColor: RGBColor?
    /// Whether the active word is filled behind or simply recoloured.
    var highlightFill = true

    var casing: CaptionCasing = .spoken
    var placement: CaptionPlacement = .bottom
    /// Where the caption sits when it has been dragged, as a share of the
    /// canvas measured from its top-left — the same way the camera layer's
    /// position is kept. Only read while `placement` is `.free`.
    var x: Double = 0.5
    var y: Double = 0.86
    /// Moves the line off a preset placement, as a share of the canvas
    /// height. A dragged caption carries its position outright, so this
    /// does not apply to one.
    var offset: Double = 0
    /// The widest a line may run, as a share of the canvas width.
    var maxWidth: Double = 0.82
    var wordsPerLine = 7

    var backdrop: CaptionBackdrop = .pill
    var backdropColor = RGBColor(r: 0.04, g: 0.05, b: 0.07)
    var backdropOpacity: Double = 0.6
    /// Corner rounding and inset, both as shares of the font size.
    var backdropRadius: Double = 0.42
    var backdropPadding: Double = 0.45

    /// Stroke around the glyphs, as a share of the font size.
    var outlineWidth: Double = 0
    var outlineColor = RGBColor(r: 0, g: 0, b: 0)
    /// Drop shadow strength, 0 to 1.
    var shadow: Double = 0.4

    var animation: CaptionAnimation = .fade

    /// Nothing is drawn unless there is something to draw.
    var isVisible: Bool { enabled && !cues.isEmpty }

    /// Where the middle of a line belongs, as a share of the canvas from
    /// its top-left corner.
    ///
    /// One answer, used by the renderer and by the handle drawn over the
    /// preview, so what is dragged is what is drawn. `height` is the share
    /// of the canvas the line occupies, which is what keeps a preset
    /// placement clear of the edge whatever size the type is.
    func anchor(for cue: CaptionCue?, height: Double) -> CGPoint {
        if let cue, let x = cue.x, let y = cue.y { return CGPoint(x: x, y: y) }
        if placement == .free { return CGPoint(x: x, y: y) }
        let margin = 0.055 + height / 2
        let centre: Double
        switch placement {
        case .top: centre = margin
        case .middle: centre = 0.5
        case .bottom, .free: centre = 1 - margin
        }
        return CGPoint(x: 0.5, y: centre + offset)
    }

    /// The cue covering a moment, if any.
    func cue(at time: Double) -> CaptionCue? {
        cues.last { time >= $0.start && time < $0.end }
    }

    /// Distinguishes one cached caption bitmap from another. Everything that
    /// changes the drawing is in here; nothing that does not is.
    var styleKey: String {
        [fontName, "\(bold)", "\(italic)", String(format: "%.4f", size), String(format: "%.3f", tracking),
         String(format: "%.3f", lineSpacing), "\(textColor)", "\(highlightColor.map(String.init(describing:)) ?? "-")",
         "\(highlightFill)", casing.rawValue, String(format: "%.3f", maxWidth), backdrop.rawValue,
         "\(backdropColor)", String(format: "%.3f", backdropOpacity), String(format: "%.3f", backdropRadius),
         String(format: "%.3f", backdropPadding), String(format: "%.3f", outlineWidth), "\(outlineColor)",
         String(format: "%.3f", shadow), animation.rawValue].joined(separator: "|")
    }

    /// The cue the caption controls are acting on, if that one is still here.
    func cue(_ id: UUID?) -> CaptionCue? {
        guard let id else { return nil }
        return cues.first { $0.id == id }
    }
}

/// Turning a stream of recognised words into lines worth reading.
enum CaptionBuilder {
    /// How long a line may stay up before it is split, however few words it has.
    static let maxDuration: Double = 3.6
    /// A pause this long ends a line: it is almost always the end of a thought.
    static let breath: Double = 0.62
    /// A line is held a little past the last word so it can be finished.
    static let hold: Double = 0.45
    static let minimumDuration: Double = 0.7

    static func endsSentence(_ word: String) -> Bool {
        guard let last = word.last else { return false }
        return ".!?…".contains(last)
    }

    /// Lines, in order, never overlapping.
    static func cues(from words: [CaptionWord], wordsPerLine: Int) -> [CaptionCue] {
        let limit = max(1, min(14, wordsPerLine))
        var lines: [[CaptionWord]] = []
        var current: [CaptionWord] = []
        for word in words.sorted(by: { $0.start < $1.start }) {
            if let previous = current.last {
                let broke = current.count >= limit
                    || endsSentence(previous.text)
                    || word.start - previous.end > breath
                    || word.end - current[0].start > maxDuration
                if broke { lines.append(current); current = [] }
            }
            current.append(word)
        }
        if !current.isEmpty { lines.append(current) }

        var cues = lines.map { line in
            CaptionCue(start: line[0].start,
                       duration: max(minimumDuration, (line.last?.end ?? line[0].end) - line[0].start),
                       text: line.map(\.text).joined(separator: " "),
                       words: line)
        }
        // Hold each line on until the next one is due, up to a limit: the
        // last word of a sentence should not vanish the instant it is said.
        for index in cues.indices {
            let ceiling = index + 1 < cues.count ? cues[index + 1].start : .greatestFiniteMagnitude
            let wanted = cues[index].end + hold
            cues[index].duration = max(minimumDuration, min(wanted, ceiling) - cues[index].start)
        }
        return cues
    }

    /// Re-flows existing lines to a new words-per-line without transcribing
    /// again, which is what the control in the panel does.
    static func reflow(_ cues: [CaptionCue], wordsPerLine: Int) -> [CaptionCue] {
        let words = cues.flatMap(\.timedWords)
        guard !words.isEmpty else { return cues }
        return Self.cues(from: words, wordsPerLine: wordsPerLine)
    }

    private static func stamp(_ seconds: Double, separator: String) -> String {
        let total = max(0, seconds)
        let hours = Int(total) / 3600, minutes = (Int(total) % 3600) / 60, secs = Int(total) % 60
        let milliseconds = Int((total - floor(total)) * 1000)
        return String(format: "%02d:%02d:%02d%@%03d", hours, minutes, secs, separator, milliseconds)
    }

    /// SubRip, which is what YouTube, Premiere and everything else take.
    static func srt(_ cues: [CaptionCue], casing: CaptionCasing = .spoken) -> String {
        cues.enumerated().map { index, cue in
            "\(index + 1)\n\(stamp(cue.start, separator: ",")) --> \(stamp(cue.end, separator: ","))\n\(casing.apply(cue.text))\n"
        }.joined(separator: "\n")
    }

    static func vtt(_ cues: [CaptionCue], casing: CaptionCasing = .spoken) -> String {
        "WEBVTT\n\n" + cues.map { cue in
            "\(stamp(cue.start, separator: ".")) --> \(stamp(cue.end, separator: "."))\n\(casing.apply(cue.text))\n"
        }.joined(separator: "\n")
    }
}

enum CaptionError: LocalizedError {
    case denied, restricted, unavailable(String), noAudio, silent, noSpeech, failed(String), cancelled
    var errorDescription: String? {
        switch self {
        case .denied:
            "FocusFlow needs permission to use speech recognition. Allow it in System Settings › Privacy & Security › Speech Recognition, then generate again."
        case .restricted:
            "Speech recognition is turned off for this Mac."
        case .unavailable(let language):
            "Speech recognition is not available for \(language) on this Mac. Choose another language, or add it under System Settings › General › Language & Region."
        case .noAudio:
            "This recording has no audio to caption. Record with the microphone or system audio switched on."
        case .silent:
            "This recording's audio is silent, so there is nothing to caption. Switch Microphone on in the recorder before recording narration — microphone capture needs macOS 15 or newer."
        case .noSpeech:
            "No speech was recognised. Check that the spoken language above matches the narration, and that the voice is clear of background audio."
        case .cancelled:
            "Caption generation was cancelled."
        case .failed(let reason):
            "Captions could not be generated: \(reason)"
        }
    }
}

/// Listening to the recording and writing down what was said.
///
/// Recognition runs on this Mac wherever the language supports it, so the
/// audio does not leave the machine — the same bargain the rest of the app
/// makes. A language that has no on-device model falls back to Apple's
/// service, which is said plainly in the panel before anything is sent.
enum CaptionTranscriber {
    /// A long file is recognised in pieces. One request covering an hour
    /// either refuses outright or returns nothing useful; these are short
    /// enough to be reliable and long enough to carry sentence context.
    static let chunk: Double = 50
    /// Pieces overlap so a word spoken across a join is not lost. The
    /// repeated words are dropped when the pieces are stitched together.
    static let overlap: Double = 1.5
    /// Below this, a track is carrying its own noise floor and nothing else.
    static let silence = 0.004
    /// How long one piece may take before it is given up on. Recognising
    /// fifty seconds takes a few seconds on device; this is an abandoned
    /// request, not a slow one.
    static let stall: Double = 240

    static var supportedLanguages: [(identifier: String, name: String)] {
        let current = Locale.current
        return SFSpeechRecognizer.supportedLocales()
            .map { ($0.identifier, current.localizedString(forIdentifier: $0.identifier) ?? $0.identifier) }
            .sorted { $0.name < $1.name }
    }

    static func onDeviceAvailable(_ language: String) -> Bool {
        SFSpeechRecognizer(locale: Locale(identifier: language))?.supportsOnDeviceRecognition ?? false
    }

    /// Whether there is any point starting: a refusal already on record
    /// should not be asked about again after every recording.
    static var permissionRefused: Bool {
        let status = SFSpeechRecognizer.authorizationStatus()
        return status == .denied || status == .restricted
    }

    static func authorize() async -> SFSpeechRecognizerAuthorizationStatus {
        let status = SFSpeechRecognizer.authorizationStatus()
        guard status == .notDetermined else { return status }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
    }

    /// Every word in the recording, in order.
    static func words(in url: URL, language: String, progress: @escaping @Sendable (Double) -> Void) async throws -> [CaptionWord] {
        let asset = AVURLAsset(url: url)
        guard try await !asset.loadTracks(withMediaType: .audio).isEmpty else { throw CaptionError.noAudio }
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { throw CaptionError.noAudio }

        switch await authorize() {
        case .authorized: break
        case .denied: throw CaptionError.denied
        case .restricted, .notDetermined: throw CaptionError.restricted
        @unknown default: throw CaptionError.restricted
        }

        let locale = Locale(identifier: language)
        let name = Locale.current.localizedString(forIdentifier: language) ?? language
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            throw CaptionError.unavailable(name)
        }
        let onDevice = recognizer.supportsOnDeviceRecognition

        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("focusflow-captions-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let step = chunk - overlap
        let pieces = max(1, Int(ceil(duration / step)))
        var collected: [CaptionWord] = []
        var loudest = 0.0
        for piece in 0..<pieces {
            try Task.checkCancellation()
            let offset = Double(piece) * step
            let length = min(chunk, duration - offset)
            guard length > 0.2 else { break }
            progress(Double(piece) / Double(pieces))
            let slice = scratch.appendingPathComponent("piece-\(piece).wav")
            let peak = try await extractAudio(from: asset, range: CMTimeRange(
                start: CMTime(seconds: offset, preferredTimescale: 600),
                duration: CMTime(seconds: length, preferredTimescale: 600)), to: slice)
            loudest = max(loudest, peak)
            // Nothing on the track but the noise floor. Handing that to the
            // recogniser costs seconds per piece and returns nothing.
            guard peak > silence else { continue }
            let spoken = try await recognize(slice, recognizer: recognizer, onDevice: onDevice)
            for word in spoken {
                let placed = CaptionWord(text: word.text, start: word.start + offset, duration: word.duration)
                // Anything already heard in the overlap is the same word
                // twice, so the first hearing of it is the one that stands.
                guard placed.start >= (collected.last?.end ?? -1) - 0.08 else { continue }
                collected.append(placed)
            }
        }
        progress(1)
        guard !collected.isEmpty else {
            throw loudest > silence ? CaptionError.noSpeech : CaptionError.silent
        }
        return collected
    }

    /// The audio of one stretch of the recording, on its own, as a file the
    /// recogniser will accept. Returns the loudest sample in it, which is
    /// how "nothing was said" is told apart from "nothing was recorded".
    ///
    /// Every audio track is mixed down, not just the first one. A FocusFlow
    /// recording keeps system audio and the microphone as separate tracks,
    /// and the narration is on the second of them — so taking the first
    /// track hands the recogniser the silence the screen was making while
    /// somebody talked over it.
    @discardableResult
    static func extractAudio(from asset: AVAsset, range: CMTimeRange, to url: URL) async throws -> Double {
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { throw CaptionError.noAudio }

        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = range
        // One mono channel at the rate speech recognition works in. Written
        // uncompressed: the piece is seconds long, lives in a temporary
        // directory, and re-encoding it would only cost quality and time.
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
        ]
        let mixed = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: settings)
        mixed.alwaysCopiesSampleData = false
        guard reader.canAdd(mixed) else { throw CaptionError.failed("this recording's audio could not be read.") }
        reader.add(mixed)

        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .wav)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else { throw CaptionError.failed("this recording's audio could not be written out.") }
        writer.add(input)
        guard reader.startReading(), writer.startWriting() else {
            throw CaptionError.failed(reader.error?.localizedDescription ?? writer.error?.localizedDescription ?? "the audio could not be separated.")
        }
        writer.startSession(atSourceTime: range.start)

        var peak = 0.0
        while reader.status == .reading {
            guard let buffer = mixed.copyNextSampleBuffer() else { break }
            if let block = CMSampleBufferGetDataBuffer(buffer) {
                var length = 0
                var pointer: UnsafeMutablePointer<Int8>?
                if CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil,
                                               totalLengthOut: &length, dataPointerOut: &pointer) == noErr,
                   let pointer {
                    pointer.withMemoryRebound(to: Int16.self, capacity: length / 2) { samples in
                        for index in stride(from: 0, to: length / 2, by: 7) {
                            let level = abs(Double(samples[index])) / 32768
                            if level > peak { peak = level }
                        }
                    }
                }
            }
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            guard input.append(buffer) else { break }
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw CaptionError.failed(writer.error?.localizedDescription ?? "the audio could not be separated.")
        }
        if reader.status == .failed {
            throw CaptionError.failed(reader.error?.localizedDescription ?? "the audio could not be read.")
        }
        return peak
    }

    private static func recognize(_ url: URL, recognizer: SFSpeechRecognizer, onDevice: Bool) async throws -> [CaptionWord] {
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        request.requiresOnDeviceRecognition = onDevice
        request.taskHint = .dictation
        if #available(macOS 13.0, *) { request.addsPunctuation = true }

        /// The recogniser answers on its own queue, possibly more than
        /// once, and a continuation may only be resumed once. It also has
        /// to be reachable from outside so a stalled piece, or a stopped
        /// generation, can call it off rather than waiting for ever.
        final class Attempt: @unchecked Sendable {
            private let lock = NSLock()
            private var finished = false
            private var task: SFSpeechRecognitionTask?
            func claim() -> Bool { lock.lock(); defer { lock.unlock() }; if finished { return false }; finished = true; return true }
            func hold(_ task: SFSpeechRecognitionTask) {
                lock.lock(); let over = finished; self.task = task; lock.unlock()
                if over { task.cancel() }
            }
            func stop() { lock.lock(); let task = self.task; lock.unlock(); task?.cancel() }
        }
        let attempt = Attempt()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = recognizer.recognitionTask(with: request) { result, error in
                    if let error {
                        guard attempt.claim() else { return }
                        continuation.resume(throwing: CaptionError.failed(error.localizedDescription))
                        return
                    }
                    guard let result, result.isFinal else { return }
                    guard attempt.claim() else { return }
                    continuation.resume(returning: result.bestTranscription.segments.compactMap { segment in
                        let text = segment.substring.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !text.isEmpty else { return nil }
                        return CaptionWord(text: text, start: segment.timestamp, duration: max(0.08, segment.duration))
                    })
                }
                attempt.hold(task)
                // A piece that has not answered long after it should have
                // is not going to. Calling it off produces an error the
                // panel can show, rather than a progress bar that never
                // moves and a Stop that stops nothing.
                DispatchQueue.global().asyncAfter(deadline: .now() + stall) { attempt.stop() }
            }
        } onCancel: {
            attempt.stop()
        }
    }
}
