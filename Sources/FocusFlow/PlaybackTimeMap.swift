import Foundation

/// Source-time editing keeps every effect, cursor cue and camera frame aligned.
/// Compile speed ranges once, then map playback timestamps with binary search.
struct PlaybackTimeMap {
    struct Span {
        let sourceStart: Double
        let sourceEnd: Double
        let outputStart: Double
        let rate: Double
        var outputEnd: Double { outputStart + (sourceEnd - sourceStart) / rate }
    }
    let spans: [Span]
    let sourceDuration: Double
    var outputDuration: Double { spans.last?.outputEnd ?? 0 }

    init(duration: Double, rate: Double, segments: [EditSegment]) {
        let sourceDuration = duration.isFinite ? max(0, duration) : 0
        self.sourceDuration = sourceDuration
        let global = rate.isFinite ? max(0.25, min(3, rate)) : 1
        let ranges = segments.filter { $0.kind == .speed && $0.start.isFinite && $0.duration.isFinite && $0.duration > 0 }
        let edges = Set([0, sourceDuration] + ranges.flatMap {
            [max(0, min(sourceDuration, $0.start)), max(0, min(sourceDuration, $0.end))]
        }).sorted()
        var result: [Span] = []
        var output = 0.0
        for (start, end) in zip(edges, edges.dropFirst()) where end > start {
            // Most recently added range wins in an overlap; speeds never multiply accidentally.
            let local = ranges.last { $0.start <= start && $0.end > start }?.intensity ?? 1
            let speed = global * (local.isFinite ? max(0.25, min(4, local)) : 1)
            result.append(Span(sourceStart: start, sourceEnd: end, outputStart: output, rate: speed))
            output += (end - start) / speed
        }
        spans = result
    }

    func outputTime(for source: Double) -> Double {
        let t = max(0, min(sourceDuration, source))
        guard let span = span(at: t, output: false) else { return 0 }
        return span.outputStart + (t - span.sourceStart) / span.rate
    }
    func sourceTime(for output: Double) -> Double {
        let t = max(0, min(outputDuration, output))
        guard let span = span(at: t, output: true) else { return 0 }
        return span.sourceStart + (t - span.outputStart) * span.rate
    }
    private func span(at time: Double, output: Bool) -> Span? {
        guard !spans.isEmpty else { return nil }
        var low = 0, high = spans.count
        while low < high {
            let middle = (low + high) / 2
            let start = output ? spans[middle].outputStart : spans[middle].sourceStart
            if start <= time { low = middle + 1 } else { high = middle }
        }
        return spans[max(0, low - 1)]
    }
}
