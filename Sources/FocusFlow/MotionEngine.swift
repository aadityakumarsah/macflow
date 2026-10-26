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
    /// How long the camera takes to change its mind, in seconds.
    ///
    /// What the edit asks for at an instant is not what the frame does at
    /// that instant: the frame does the weighted average of what is asked
    /// for across a window around it. Averaging over time is a low-pass
    /// filter, so a step becomes a ramp and a corner becomes a curve, and
    /// the frame can no longer change speed abruptly however abruptly the
    /// thing it follows moves. That is what a dolly, a tripod head and a
    /// hand all do, and what was missing when a zoom punched in and a
    /// typing follow snapped from one stretch of a line to the next.
    ///
    /// The window is centred rather than trailing, so the frame also leans
    /// into a move slightly before it happens — an operator who knows the
    /// shot, rather than one chasing it — and no lag is introduced, which
    /// is what would leave the text behind.
    static let smoothing: Double = 0.36
    private static let smoothingTaps = 9

    /// Kinds that move the frame, and so decide whether anything is
    /// happening near a moment at all.
    private static func moves(_ segment: EditSegment) -> Bool {
        segment.kind == .zoom || segment.kind == .pan || segment.kind == .typing
    }

    /// Where the frame is looking: the smoothed camera, which is the one
    /// everything — preview, export, hit testing — must agree on.
    static func viewport(at time: Double, segments: [EditSegment], samples: [PointerSample], crop: ContentRegion) -> CGRect {
        let half = smoothing / 2
        let full = CGRect(x: 0, y: 0, width: 1, height: 1)
        // Nothing asks for anything anywhere near here, so the answer is the
        // whole frame exactly, not an average that rounds to it.
        guard segments.contains(where: { moves($0) && $0.end > time - half && $0.start < time + half }) else { return full }

        var x = 0.0, y = 0.0, width = 0.0, height = 0.0, total = 0.0
        for tap in 0..<smoothingTaps {
            let offset = (Double(tap) / Double(smoothingTaps - 1) - 0.5) * smoothing
            // A raised cosine: full weight in the middle, none at the edges,
            // so a segment arriving in the window eases in rather than
            // jolting the average as it crosses the boundary.
            let weight = 0.5 * (1 + cos(.pi * offset / half))
            guard weight > 0.0001 else { continue }
            let box = rawViewport(at: max(0, time + offset), segments: segments, samples: samples, crop: crop)
            x += Double(box.minX) * weight; y += Double(box.minY) * weight
            width += Double(box.width) * weight; height += Double(box.height) * weight
            total += weight
        }
        guard total > 0 else { return rawViewport(at: time, segments: segments, samples: samples, crop: crop) }
        // Averaging the origin and the size separately still averages the far
        // edge, so a viewport inside the frame stays inside it.
        return CGRect(x: x / total, y: y / total, width: width / total, height: height / total)
    }

    /// What the edit asks for at this exact instant, before smoothing.
    static func rawViewport(at time: Double, segments: [EditSegment], samples: [PointerSample], crop: ContentRegion) -> CGRect {
        let r = crop.bounded
        var weight = 0.0, zoomSum = 0.0, cx = 0.0, cy = 0.0
        for segment in segments where moves(segment) {
            let w = envelope(segment, time: time)
            guard w > 0 else { continue }
            var x = segment.x, y = segment.y
            var targetZoom = max(1, min(4, segment.intensity))
            if segment.tracksSelection == true {
                let region = selectionRegion(segment, at: time, samples: samples)
                x = region.midX; y = region.midY
                targetZoom = min(targetZoom, 0.86 / region.width, 0.72 / region.height)
                targetZoom = max(1.15, targetZoom)
            } else if segment.selectionStartTime != nil, let endX = segment.endX, let endY = segment.endY {
                // A fixed selection focus still stores the drag's starting
                // point so its highlight can grow with the actual selection.
                x = (x + endX) / 2; y = (y + endY) / 2
            } else if segment.kind == .typing {
                // Slides from where typing began toward where the caret has
                // reached. A caret advances a character per key, so the slide
                // is linear and finishes with the last keypress: the rest of
                // the segment is the hold, where the frame must sit still.
                // Easing it across the whole segment instead left the frame
                // behind the text for the first half of a run, ahead of it for
                // the second, and still drifting after typing had stopped.
                // endX carries the far end; the clamp below keeps the viewport
                // inside the frame whatever is asked for.
                let travelling = min(1, max(0.01, segment.travelFraction ?? 1)) * segment.duration
                let progress = min(1, max(0, (time - segment.start) / max(0.01, travelling)))
                let total = (segment.endX ?? x) - x
                x += MotionEngine.followedCaret(distance: total * progress,
                                                total: total,
                                                band: segment.followBand ?? 0,
                                                settle: segment.followSettle ?? 0.45,
                                                over: travelling,
                                                curve: segment.curve ?? .smooth)
                y = segment.endY ?? y
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
    /// Where the frame sits when the caret has travelled `distance`.
    ///
    /// Not on the caret. A frame that slides a little with every keystroke
    /// reads as drift rather than as a camera move, and it puts an estimated
    /// caret position — which is all this can ever be — under constant
    /// scrutiny. So the frame holds while the caret crosses a band of what is
    /// on screen, and when the caret reaches the edge of that band the frame
    /// catches up by one band, putting the caret back at the other side with
    /// the words just written still in view. Hold, move, hold: the way Apple's
    /// own Zoom follows the focus item, and the dead zone every follow camera
    /// has. A band of zero slides continuously, for anyone who wants that.
    ///
    /// `over` is how long the caret takes to cross the whole distance, which
    /// is what turns a catch-up in seconds into a share of a band.
    static func followedCaret(distance: Double, total: Double, band: Double,
                              settle: Double, over: Double, curve: MotionCurve) -> Double {
        guard band > 0.001, total > 0.001 else { return distance }
        // Seconds the caret spends crossing one band, and so how much of a
        // band the frame is still moving for.
        let bandTime = over * band / total
        let share = min(1, max(0.05, settle / max(0.01, bandTime)))
        // Half a band of grace first: the caret starts in the middle of the
        // frame, so it reaches the edge after half a band, and every band
        // thereafter.
        let bands = distance / band + 0.5
        let crossed = bands.rounded(.down)
        let through = bands - crossed
        let moved = max(0, crossed - 1 + curve.value(min(1, through / share)))
        return min(total, band * moved)
    }

    /// Whether this typing segment is still putting words down, as
    /// opposed to holding on what was written.
    static func writes(_ segment: EditSegment, at time: Double) -> Bool {
        guard segment.kind == .typing else { return false }
        let travelling = min(1, max(0.01, segment.travelFraction ?? 1)) * segment.duration
        return time >= segment.start && time <= segment.start + travelling
    }

    /// The range actually selected: from where the drag began to where the
    /// pointer has reached. Tight, unlike `selectionRegion`, which is the
    /// box the camera frames and so carries padding around it.
    static func selectedRange(_ segment: EditSegment, at time: Double, samples: [PointerSample]) -> CGRect {
        let first = CGPoint(x: min(1, max(0, segment.x)), y: min(1, max(0, segment.y)))
        let last = CGPoint(x: min(1, max(0, segment.endX ?? segment.x)), y: min(1, max(0, segment.endY ?? segment.y)))
        let start = segment.selectionStartTime ?? segment.start
        let end = max(start + 0.01, segment.selectionEndTime ?? segment.end)
        let clamped = min(end, max(start, time))
        let progress = MotionCurve.smooth.value((clamped - start) / (end - start))
        let fallback = CGPoint(x: first.x + (last.x - first.x) * progress,
                               y: first.y + (last.y - first.y) * progress)
        let tracked = CursorMotion.sample(at: clamped, samples: samples, smoothed: true)
        let current = CGPoint(x: tracked?.x ?? fallback.x, y: tracked?.y ?? fallback.y)
        return CGRect(x: min(first.x, current.x), y: min(first.y, current.y),
                      width: abs(current.x - first.x), height: abs(current.y - first.y))
    }

    /// Where the caret has reached inside a typing segment, and the line
    /// it is on, in frame coordinates.
    ///
    /// The frame follows this at a distance — it holds while the caret
    /// crosses a band and catches up afterwards — so the two are
    /// deliberately not the same point, and anything drawn where the
    /// writing is actually happening has to ask for this one.
    static func caret(_ segment: EditSegment, at time: Double) -> CGPoint? {
        guard segment.kind == .typing else { return nil }
        let travelling = min(1, max(0.01, segment.travelFraction ?? 1)) * segment.duration
        let progress = min(1, max(0, (time - segment.start) / max(0.01, travelling)))
        let total = (segment.endX ?? segment.x) - segment.x
        return CGPoint(x: segment.x + total * progress, y: segment.endY ?? segment.y)
    }

    /// How the frame is standing at this instant, and how it is softened.
    struct FrameStance: Equatable {
        var pose: FramePose = .neutral
        var blur: FrameBlur = .none
        var amount: Double = 0
        var angle: Double = 0
        var isNeutral: Bool { pose.isNeutral && (blur == .none || amount <= 0.01) }
    }

    /// The 3D camera effects standing on the timeline at this moment.
    ///
    /// A pose on the timeline is a move, not a place: it leans in over the
    /// segment's transition, travels while it holds, and comes back out —
    /// so the frame is never parked at an angle unless that is what was
    /// asked for. Several at once are each a departure from square, so they
    /// add.
    static func stance(at time: Double, segments: [EditSegment]) -> FrameStance {
        var stance = FrameStance()
        var strongest = 0.0
        for segment in segments where segment.kind == .perspective {
            let weight = envelope(segment, time: time)
            guard weight > 0, let target = segment.pose else { continue }
            // Travelling: from the far side of the pose, through it, out the
            // other side over the length of the segment.
            let through = segment.sweeps == false
                ? target
                : target.mirrored.blended(to: target, (segment.curve ?? .smooth).value((time - segment.start) / max(0.01, segment.duration)))
            stance.pose = stance.pose.added(through.weighted(weight))
            let amount = (segment.blurAmount ?? 0) * weight
            if let blur = segment.blur, blur != .none, amount > strongest {
                strongest = amount
                stance.blur = blur
                stance.amount = amount
                stance.angle = segment.blurAngle ?? 0
            }
        }
        return stance
    }

    /// Whether someone is typing at this moment, according to the edit.
    ///
    /// The pointer usually sits still beside the words going in, and the
    /// system only reports an I-beam while it happens to be over text — so a
    /// recording of someone typing shows an arrow resting in the middle of
    /// the frame doing nothing. While text is being written the cursor is a
    /// text cursor, whatever the pointer was over.
    static func isTyping(at time: Double, segments: [EditSegment]) -> Bool {
        segments.contains { segment in
            guard segment.kind == .typing else { return false }
            let writing = min(1, max(0.01, segment.travelFraction ?? 1)) * segment.duration
            return time >= segment.start && time <= segment.start + writing
        }
    }

    /// How long a zoom lingers after the click that caused it, how long it
    /// takes to settle at each end, and how far ahead of the click it
    /// starts. The hold is what decides when the frame starts pulling back,
    /// so it is the number to shorten for a quicker release.
    ///
    /// The transition is most of a second because a zoom that arrives in
    /// half of one reads as a jolt rather than as a camera moving: the
    /// distance is fixed by the click, so the only thing that makes it
    /// gentle is giving it longer. The lead keeps pace with it, so the
    /// frame is still all but settled by the moment of the click itself.
    static let clickZoomHold: Double = 1.3
    static let clickZoomTransition: Double = 0.85
    static let clickZoomLead: Double = 0.75

    /// Groups keypress times into runs separated by a pause.
    static func typingRuns(_ times: [Double], gap: Double) -> [[Double]] {
        var runs: [[Double]] = []
        var current: [Double] = []
        for time in times.sorted() {
            if let last = current.last, time - last > gap {
                runs.append(current); current = []
            }
            current.append(time)
        }
        if !current.isEmpty { runs.append(current) }
        return runs
    }

    /// The runs that are worth following — and so the runs that own their
    /// stretch of the timeline. One or two keys is a correction, not a passage
    /// of typing, and a run too short to carry a segment is left alone.
    static func followableRuns(_ typing: [TypingEvent], duration: Double, settings: TypingFollowSettings) -> [[Double]] {
        let times = typing.map(\.time).filter { $0 >= 0 && $0 < duration }
        return typingRuns(times, gap: settings.gap).filter { run in
            guard run.count >= 4, let first = run.first, let last = run.last else { return false }
            let start = max(0, first - 0.25)
            return min(duration - start, (last + settings.hold) - start) >= 0.5
        }
    }

    /// First and last keypress of each followed run. This is the stretch a
    /// click zoom must not sit inside; the hold that follows a run is
    /// deliberately excluded, so a click on Send still gets its own.
    ///
    /// With the follow switched off, no run owns anything and nothing is
    /// excluded — turning the effect off must not silently delete the click
    /// zooms it would have replaced.
    static func typingKeySpans(_ typing: [TypingEvent], duration: Double, settings: TypingFollowSettings) -> [(Double, Double)] {
        guard settings.enabled else { return [] }
        return followableRuns(typing, duration: duration, settings: settings).compactMap { run in
            guard let first = run.first, let last = run.last else { return nil }
            return (first - 0.3, last)
        }
    }

    /// Turns runs of typing into segments that follow the caret.
    ///
    /// Where typing happens is not reported by anything: the pointer usually
    /// sits still while someone types, and only the insertion point moves. So
    /// a run is anchored at the last click before it — which is where the
    /// caret was put — and travels right by an amount standing in for the
    /// characters since. It is an estimate of a position nothing measures,
    /// which is why how far it travels is adjustable and why the travel is
    /// capped rather than trusted.
    static func typingFollows(typing: [TypingEvent],
                              clicks: [RecordedClick],
                              samples: [PointerSample],
                              duration: Double,
                              settings: TypingFollowSettings) -> [EditSegment] {
        guard settings.enabled, !typing.isEmpty, duration > 0 else { return [] }
        // `.last` reads an order, so the clicks have to be in one: metadata
        // arrives in time order, but nothing in the type says so.
        let orderedClicks = clicks.sorted { $0.time < $1.time }

        var result: [EditSegment] = []
        for run in followableRuns(typing, duration: duration, settings: settings) {
            guard let first = run.first, let last = run.last else { continue }
            let start = max(0, first - 0.25)
            let length = min(duration - start, (last + settings.hold) - start)

            // Anchor: the last click before typing started, which is where the
            // caret was put, else where the pointer was. With neither there is
            // nothing to anchor to, and a guess would zoom somewhere arbitrary
            // for the length of the run, so the run is left alone.
            let anchorClick = orderedClicks.last { $0.time <= first + 0.1 }
            let anchorSample = CursorMotion.sample(at: first, samples: samples, smoothed: true)
            guard let anchorX = anchorClick?.x ?? anchorSample?.x,
                  let anchorY = anchorClick?.y ?? anchorSample?.y else { continue }

            // How far the caret has gone is measured by nothing, so it is
            // estimated from the number of keys. When the cap bites, the slide
            // reaches it at the key where it would have been reached and holds
            // there; stretching the capped distance across the whole run would
            // quietly change what travel per key means for a long passage.
            let perKey = max(0.0001, settings.advancePerKey)
            let travel = min(settings.maxTravel, Double(run.count) * perKey)
            let keysToCap = Int((travel / perKey).rounded(.up))
            let travelEnds = keysToCap < run.count ? run[max(1, keysToCap)] : last
            let zoom = max(1.05, min(4, settings.zoom))
            result.append(EditSegment(kind: .typing,
                                      start: start,
                                      duration: length,
                                      intensity: zoom,
                                      x: anchorX,
                                      y: anchorY,
                                      transition: 0.6,
                                      curve: settings.curve,
                                      endX: min(1, anchorX + travel),
                                      endY: anchorY,
                                      travelFraction: min(1, max(0.05, (travelEnds - start) / max(0.01, length))),
                                      // The band is a share of what is on
                                      // screen, which is what the zoom leaves
                                      // of the frame.
                                      followBand: max(0, settings.deadZone) / zoom,
                                      followSettle: max(0.05, settings.catchUp)))
        }
        return result
    }

    static func autoZooms(clicks: [RecordedClick], duration: Double) -> [EditSegment] {
        var result: [EditSegment] = []
        for click in clicks.sorted(by: { $0.time < $1.time }) where click.time >= 0 && click.time < duration {
            if let i = result.indices.last, click.time <= result[i].end + 0.5 {
                result[i].duration = min(duration, click.time + clickZoomHold) - result[i].start
            } else {
                let start = max(0, click.time - clickZoomLead)
                result.append(EditSegment(kind: .zoom, start: start, duration: min(duration - start, click.time + clickZoomHold - start), intensity: 1.65, x: click.x, y: click.y, followsCursor: true, transition: clickZoomTransition))
            }
        }
        return result
    }

    /// Build a restrained mix of motion from actual interactions. Text drags
    /// use the recorded I-beam and button state. Legacy captures without a
    /// button state cannot reliably distinguish a selection from hovering.
    static func autoEdits(clicks: [RecordedClick],
                          samples: [PointerSample],
                          duration: Double,
                          typing: [TypingEvent] = [],
                          typingFollow: TypingFollowSettings = TypingFollowSettings(),
                          selection: SelectionFocusSettings = SelectionFocusSettings()) -> [EditSegment] {
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
        // Clicks made *while* typing are dropped before any zoom is built from
        // them: one would drag the frame off the line being written. Filtering
        // the clicks rather than the zooms matters, because a click zoom starts
        // a little before its click — judging it by that start would also throw
        // away the click on Send, which is the point of the whole sequence.
        let typingSpans = typingKeySpans(typing, duration: duration, settings: typingFollow)
        let validClicks = clicks.filter { click in
            click.time >= 0 && click.time < duration &&
            !selections.contains { click.time >= $0.0.time - 0.18 && click.time <= $0.1.time + 0.1 } &&
            !typingSpans.contains { click.time >= $0.0 && click.time <= $0.1 }
        }.sorted { $0.time < $1.time }
        var result = autoZooms(clicks: validClicks, duration: duration)

        // Only zooms are generated automatically. Spotlights, outlines and
        // "Click" callouts used to be added to every third click, and a zoom
        // and spotlight to every text selection — unasked-for decoration that
        // made a plain recording look busy. They remain available by hand from
        // the effects rail, where they are a deliberate choice.
        // Selecting text is the plainest statement a recording makes about
        // what matters: this, here, is what I am talking about. So the
        // frame goes to it, and follows the range as it grows rather than
        // jumping to wherever the drag happened to finish — which is what
        // one steady zoom on the midpoint did, arriving before there was
        // anything selected to look at.
        for (first, last) in selections where selection.enabled {
            let span = max(0, last.time - first.time)
            guard span >= 0.2 else { continue }
            let start = max(0, first.time - 0.2)
            let length = min(duration - start, last.time + max(0.1, selection.hold) - start)
            guard length >= 0.4 else { continue }
            let depth = max(1.05, min(4, selection.zoom))
            if selection.tracks {
                result.append(EditSegment(kind: .zoom, start: start, duration: length, intensity: depth,
                                          x: first.x, y: first.y,
                                          transition: clickZoomTransition,
                                          endX: last.x, endY: last.y,
                                          tracksSelection: true,
                                          selectionStartTime: first.time,
                                          selectionEndTime: last.time))
            } else {
                result.append(EditSegment(kind: .zoom, start: start, duration: length, intensity: depth,
                                          x: first.x, y: first.y,
                                          transition: clickZoomTransition,
                                          endX: last.x, endY: last.y,
                                          selectionStartTime: first.time,
                                          selectionEndTime: last.time))
            }
        }

        let follows = typingFollows(typing: typing, clicks: clicks, samples: samples,
                                    duration: duration, settings: typingFollow)
        result.append(contentsOf: follows)
        return result.sorted { $0.start < $1.start }
    }
}
