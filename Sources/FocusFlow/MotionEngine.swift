import Foundation
import CoreGraphics

/// Pure, timestamp-based camera evaluation shared by preview, hit testing, and export.
enum MotionEngine {
    /// The focus box grows with the actual text drag, so the camera follows
    /// the selected range instead of chasing the pointer tip.
    static func selectionRegion(_ segment: EditSegment, at time: Double, samples: [PointerSample]) -> CGRect {
        let first = CGPoint(x: min(1, max(0, segment.x)), y: min(1, max(0, segment.y)))
        let last = CGPoint(x: min(1, max(0, segment.endX ?? segment.x)), y: min(1, max(0, segment.endY ?? segment.y)))
        let start = segment.selectionStartTime ?? segment.start
        let end = max(start + 0.01, segment.selectionEndTime ?? segment.end)
        let clampedTime = min(end, max(start, time))
        let progress = MotionCurve.smooth.value((clampedTime - start) / (end - start))
        let fallback = CGPoint(x: first.x + (last.x - first.x) * progress,
                               y: first.y + (last.y - first.y) * progress)
        let tracked = CursorMotion.sample(at: clampedTime, samples: samples, smoothed: true)
        let current = CGPoint(x: tracked?.x ?? fallback.x, y: tracked?.y ?? fallback.y)
        let width = min(0.88, max(0.14, abs(current.x - first.x) + 0.12))
        let height = min(0.72, max(0.12, abs(current.y - first.y) + 0.10))
        let centre = CGPoint(x: (first.x + current.x) / 2, y: (first.y + current.y) / 2)
        return CGRect(x: min(1 - width, max(0, centre.x - width / 2)),
                      y: min(1 - height, max(0, centre.y - height / 2)),
                      width: width, height: height)
    }

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
            var targetZoom = max(1, min(4, segment.intensity))
            if segment.tracksSelection == true {
                let region = selectionRegion(segment, at: time, samples: samples)
                x = region.midX; y = region.midY
                targetZoom = min(targetZoom, 0.86 / region.width, 0.72 / region.height)
                targetZoom = max(1.15, targetZoom)
            } else if segment.kind == .pan {
                let progress = (segment.curve ?? .smooth).value((time - segment.start) / max(0.01, segment.duration))
                x += ((segment.endX ?? 0.7) - x) * progress * 0.55
                y += ((segment.endY ?? 0.5) - y) * progress * 0.55
                targetZoom = min(targetZoom, 1.35)
            } else if segment.followsCursor == true, let pointer = CursorMotion.followPoint(at: time, samples: samples) {
                // Anchored at the click, not glued to the pointer. Following
                // it outright made the frame drift about for every small hand
                // movement, which reads as an aimless pan. The frame holds
                // still until the pointer leaves the middle of the viewport,
                // then eases only as far as it must to bring it back in.
                let span = 1 / max(1, min(4, segment.intensity))
                let slack = span * 0.22
                let dx = pointer.x - x
                let dy = pointer.y - y
                if abs(dx) > slack { x += (abs(dx) - slack) * (dx < 0 ? -1 : 1) }
                if abs(dy) > slack { y += (abs(dy) - slack) * (dy < 0 ? -1 : 1) }
            }
            weight += w; zoomSum += (targetZoom - 1) * w
            cx += ((x - r.x) / r.width) * w; cy += ((y - r.y) / r.height) * w
        }
        guard weight > 0 else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        let zoom = 1 + zoomSum / max(1, weight), size = 1 / zoom
        let x = min(1 - size, max(0, cx / weight - size / 2))
        let y = min(1 - size, max(0, cy / weight - size / 2))
        return CGRect(x: x, y: y, width: size, height: size)
    }
    /// How long a zoom lingers after the click that caused it, and how long
    /// it takes to settle at each end. The hold is what decides when the
    /// frame starts pulling back, so it is the number to shorten for a
    /// quicker release.
    static let clickZoomHold: Double = 1.15
    static let clickZoomTransition: Double = 0.6

    static func autoZooms(clicks: [RecordedClick], duration: Double) -> [EditSegment] {
        var result: [EditSegment] = []
        for click in clicks.sorted(by: { $0.time < $1.time }) where click.time >= 0 && click.time < duration {
            if let i = result.indices.last, click.time <= result[i].end + 0.5 {
                result[i].duration = min(duration, click.time + clickZoomHold) - result[i].start
            } else {
                let start = max(0, click.time - 0.6)
                result.append(EditSegment(kind: .zoom, start: start, duration: min(duration - start, click.time + clickZoomHold - start), intensity: 1.65, x: click.x, y: click.y, followsCursor: true, transition: clickZoomTransition))
            }
        }
        return result
    }

    /// Build a restrained mix of motion from actual interactions. Text drags
    /// use the recorded I-beam and button state. Legacy captures without a
    /// button state cannot reliably distinguish a selection from hovering.
    static func autoEdits(clicks: [RecordedClick], samples: [PointerSample], duration: Double) -> [EditSegment] {
        guard duration > 0 else { return [] }
        let ordered = samples.sorted { $0.time < $1.time }
        var selections: [(PointerSample, PointerSample)] = []
        var run: [PointerSample] = []
        func finishRun() {
            defer { run.removeAll(keepingCapacity: true) }
            guard let first = run.first, let last = run.last,
                  (0.12...2.5).contains(last.time - first.time) else { return }
            let horizontal = abs(last.x - first.x)
            let vertical = abs(last.y - first.y)
            guard horizontal > 0.045 || vertical > 0.035 else { return }
            selections.append((first, last))
        }
        for sample in ordered where sample.time < duration {
            let active = sample.shape == .text && sample.pressed == true
            if active && (run.isEmpty || sample.time - run.last!.time < 0.12) { run.append(sample) }
            else { finishRun(); if active { run = [sample] } }
        }
        finishRun()
        let validClicks = clicks.filter { click in
            click.time >= 0 && click.time < duration &&
            !selections.contains { click.time >= $0.0.time - 0.18 && click.time <= $0.1.time + 0.1 }
        }.sorted { $0.time < $1.time }
        var result = autoZooms(clicks: validClicks, duration: duration)

        // Only zooms are generated automatically. Spotlights, outlines and
        // "Click" callouts used to be added to every third click, and a zoom
        // and spotlight to every text selection — unasked-for decoration that
        // made a plain recording look busy. They remain available by hand from
        // the effects rail, where they are a deliberate choice.
        for (first, last) in selections {
            let span = max(0, last.time - first.time)
            // A selection still deserves a look, but one steady zoom rather
            // than a zoom and a spotlight tracking across it together.
            guard span >= 0.25 else { continue }
            let start = max(0, first.time - 0.2)
            let length = min(duration - start, last.time + 0.7 - start)
            guard length >= 0.4 else { continue }
            result.append(EditSegment(kind: .zoom, start: start, duration: length, intensity: 1.7,
                                      x: (first.x + last.x) / 2, y: (first.y + last.y) / 2,
                                      transition: clickZoomTransition))
        }

        return result.sorted { $0.start < $1.start }
    }
}
