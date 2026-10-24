import Foundation
import CoreGraphics

/// Pure, timestamp-based camera evaluation shared by preview, hit testing, and export.
enum MotionEngine {
    static func envelope(_ segment: EditSegment, time: Double) -> Double {
        guard time > segment.start, time < segment.end, segment.duration > 0 else { return 0 }
        let edge = min(max(0.05, segment.transition ?? 0.7), segment.duration / 2)
        let ramp = min((time - segment.start) / edge, (segment.end - time) / edge)
        return (segment.curve ?? .smooth).value(ramp)
    }
    static func viewport(at time: Double, segments: [EditSegment], samples: [PointerSample], crop: ContentRegion) -> CGRect {
        let r = crop.bounded
        var weight = 0.0, zoomSum = 0.0, cx = 0.0, cy = 0.0
        for segment in segments where segment.kind == .zoom || segment.kind == .pan {
            let w = envelope(segment, time: time)
            guard w > 0 else { continue }
            var x = segment.x, y = segment.y
            if segment.kind == .pan {
                let progress = (segment.curve ?? .smooth).value((time - segment.start) / max(0.01, segment.duration))
                x += ((segment.endX ?? 0.7) - x) * progress
                y += ((segment.endY ?? 0.5) - y) * progress
            } else if segment.followsCursor == true, let pointer = CursorMotion.followPoint(at: time, samples: samples) {
                x = pointer.x; y = pointer.y
            }
            weight += w; zoomSum += (max(1, min(4, segment.intensity)) - 1) * w
            cx += ((x - r.x) / r.width) * w; cy += ((y - r.y) / r.height) * w
        }
        guard weight > 0 else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        let zoom = 1 + zoomSum / max(1, weight), size = 1 / zoom
        let x = min(1 - size, max(0, cx / weight - size / 2))
        let y = min(1 - size, max(0, cy / weight - size / 2))
        return CGRect(x: x, y: y, width: size, height: size)
    }
    static func autoZooms(clicks: [RecordedClick], duration: Double) -> [EditSegment] {
        var result: [EditSegment] = []
        for click in clicks.sorted(by: { $0.time < $1.time }) where click.time >= 0 && click.time < duration {
            if let i = result.indices.last, click.time <= result[i].end + 0.5 {
                result[i].duration = min(duration, click.time + 1.45) - result[i].start
            } else {
                let start = max(0, click.time - 0.6)
                result.append(EditSegment(kind: .zoom, start: start, duration: min(duration - start, click.time + 1.45 - start), intensity: 1.65, x: click.x, y: click.y, followsCursor: true, transition: 0.7))
            }
        }
        return result
    }

    /// Build a restrained mix of motion from actual interactions. Text drags
    /// use the recorded I-beam and button state. Legacy captures without a
    /// button state cannot reliably distinguish a selection from hovering.
    static func autoEdits(clicks: [RecordedClick], samples: [PointerSample], duration: Double) -> [EditSegment] {
        guard duration > 0 else { return [] }
        var result = autoZooms(clicks: clicks, duration: duration)
        let ordered = samples.sorted { $0.time < $1.time }
        let validClicks = clicks.filter { $0.time >= 0 && $0.time < duration }.sorted { $0.time < $1.time }
        for (index, click) in validClicks.enumerated() {
            let start = max(0, click.time - 0.12)
            let length = min(duration - start, 1.15)
            guard length >= 0.2 else { continue }
            switch index % 3 {
            case 0:
                result.append(EditSegment(kind: .spotlight, start: start, duration: length, intensity: 1.3,
                                          x: click.x, y: click.y, width: 0.30, height: 0.22, transition: 0.28))
            case 1:
                result.append(EditSegment(kind: .outline, start: start, duration: length, intensity: 1.2,
                                          x: click.x, y: click.y, width: 0.22, height: 0.16, transition: 0.24))
            default:
                result.append(EditSegment(kind: .callout, start: start, duration: length, intensity: 0.85,
                                          x: click.x, y: min(0.94, click.y + 0.13), transition: 0.25, text: "Click"))
            }
        }
        var run: [PointerSample] = []
        func finishRun() {
            defer { run.removeAll(keepingCapacity: true) }
            guard let first = run.first, let last = run.last, last.time - first.time >= 0.12,
                  last.time - first.time <= 2.5 else { return }
            let minX = run.map(\.x).min()!, maxX = run.map(\.x).max()!
            let minY = run.map(\.y).min()!, maxY = run.map(\.y).max()!
            guard maxX - minX > 0.045 || maxY - minY > 0.035 else { return }
            let start = max(0, first.time - 0.12)
            let length = min(duration - start, max(0.65, last.time - first.time + 0.7))
            guard length >= 0.2 else { return }
            let width = min(0.9, max(0.12, maxX - minX + 0.055))
            let height = min(0.7, max(0.065, maxY - minY + 0.04))
            let x = min(1 - width / 2, max(width / 2, (minX + maxX) / 2))
            let y = min(1 - height / 2, max(height / 2, (minY + maxY) / 2))
            result.append(EditSegment(kind: .outline, start: start, duration: length, intensity: 1.3,
                                      x: x, y: y, width: width, height: height, transition: 0.25))
            result.append(EditSegment(kind: .spotlight, start: start, duration: length, intensity: 0.75,
                                      x: x, y: y, width: width, height: height, transition: 0.32))
        }
        for sample in ordered where sample.time < duration {
            let isText = sample.shape == .text
            let active = sample.pressed == true
            if isText && active && (run.isEmpty || sample.time - run.last!.time < 0.12) { run.append(sample) }
            else { finishRun(); if isText && active { run = [sample] } }
        }
        finishRun()
        return result.sorted { $0.start < $1.start }
    }
}
