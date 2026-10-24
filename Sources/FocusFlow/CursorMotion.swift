import Foundation

/// Timestamp based interpolation is deterministic in preview and offline export.
enum CursorMotion {
    static func followPoint(at time: Double, samples: [PointerSample]) -> PointerSample? {
        guard !samples.isEmpty else { return nil }
        func heldPoint(_ time: Double) -> PointerSample {
            if let point = sample(at: time, samples: samples, smoothed: true) { return point }
            var low = 0, high = samples.count
            while low < high {
                let mid = (low + high) / 2
                if samples[mid].time <= time { low = mid + 1 } else { high = mid }
            }
            return samples[max(0, low - 1)]
        }
        var x = 0.0, y = 0.0, total = 0.0
        // A symmetric window anticipates travel; holding across gaps prevents the camera
        // snapping to its original anchor when the pointer leaves the captured area.
        for step in -5...5 {
            let offset = Double(step) * 0.08
            let point = heldPoint(time + offset)
            let weight = exp(-pow(offset / 0.18, 2) / 2)
            x += point.x * weight; y += point.y * weight; total += weight
        }
        return PointerSample(time: time, x: x / total, y: y / total)
    }
    static func sample(at time: Double, samples: [PointerSample], smoothed: Bool) -> PointerSample? {
        guard let first = samples.first, time >= first.time, let last = samples.last, time <= last.time + 0.15 else { return nil }
        var low = 0, high = samples.count
        while low < high {
            let mid = (low + high) / 2
            if samples[mid].time < time { low = mid + 1 } else { high = mid }
        }
        if low == 0 { return first }
        if low == samples.count { return last }
        let a = samples[low - 1], b = samples[low]
        guard b.time - a.time < 0.2 else { return nil } // Pointer outside the captured window.
        let t = max(0, min(1, (time - a.time) / max(0.001, b.time - a.time)))
        if !smoothed { return PointerSample(time: time, x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t, shape: a.shape) }
        let before = samples[max(0, low - 2)], after = samples[min(samples.count - 1, low + 1)]
        func cubic(_ p0: Double, _ p1: Double, _ p2: Double, _ p3: Double) -> Double {
            let t2 = t * t, t3 = t2 * t
            let value = 0.5 * ((2 * p1) + (-p0 + p2) * t + (2 * p0 - 5 * p1 + 4 * p2 - p3) * t2 + (-p0 + 3 * p1 - 3 * p2 + p3) * t3)
            return max(min(p1, p2), min(max(p1, p2), value))
        }
        return PointerSample(time: time, x: cubic(before.x, a.x, b.x, after.x), y: cubic(before.y, a.y, b.y, after.y), shape: a.shape)
    }
}
