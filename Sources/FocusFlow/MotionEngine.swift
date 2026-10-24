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
}
