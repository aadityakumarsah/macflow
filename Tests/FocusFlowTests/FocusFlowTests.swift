import AVFoundation
import AppKit
import CoreImage
import CoreText
import SwiftUI

final class FocusFlowTests {
    @MainActor func testNestedLayersAndRangeTiming() throws {
        let fast = EditSegment(kind: .speed, start: 2, duration: 4, intensity: 2, x: 0.5, y: 0.5)
        let slow = EditSegment(kind: .speed, start: 3, duration: 1, intensity: 0.5, x: 0.5, y: 0.5)
        let timing = PlaybackTimeMap(duration: 10, rate: 1, segments: [fast, slow])
        XCTAssertEqual(timing.outputDuration, 9.5, accuracy: 0.000001)
        XCTAssertEqual(timing.outputTime(for: 4), 4.5, accuracy: 0.000001)
        for frame in 0...600 {
            let source = Double(frame) / 60
            XCTAssertEqual(timing.sourceTime(for: timing.outputTime(for: source)), source, accuracy: 0.000001)
        }
        XCTAssertEqual(PlaybackTimeMap(duration: 10, rate: 2, segments: [fast, slow]).outputDuration, 4.75, accuracy: 0.000001)
        XCTAssertEqual(TimelineDrag.snapped(2.02, to: [1, 2, 4], tolerance: 0.03), 2)
        XCTAssertEqual(TimelineDrag.snapped(2.2, to: [1, 2, 4], tolerance: 0.03), 2.2)
        let model = EditorModel(restoreLatest: false)
        model.duration = 10; model.trimEnd = 10
        model.videoURL = URL(fileURLWithPath: "/tmp/layer-check-nonexistent.mp4")
        defer { model.videoURL = nil }
        model.applyThreeDPreset(.orbit)
        let parent = try XCTUnwrap(model.selectedSegment)
        model.addThreeDLayer(nested: true)
        let child = try XCTUnwrap(model.selectedSegment)
        XCTAssertEqual(model.segments[0], parent)
        XCTAssertTrue(child.start >= parent.start && child.end <= parent.end)
        model.beginPoseGesture(); model.editedPose = FramePose(pitch: 0.3, panX: 0.2, zoom: 1.2); model.endPoseGesture()
        let at = model.playhead
        let local = model.editedPose
        let combined = MotionEngine.stance(at: at, segments: model.segments).pose
        XCTAssertEqual(combined, MotionEngine.stance(at: at, segments: [parent]).pose.added(local))
        XCTAssertEqual(EffectLane.pack(model.segments).count, 2)
        model.addThreeDLayer(nested: true)
        XCTAssertEqual(model.segments.count, 3)
        XCTAssertEqual(EffectLane.pack(model.segments).count, 3)
        model.undo(); XCTAssertEqual(model.segments.count, 2)
        model.selectThreeDLayer(child.id)
        model.beginTimelineGesture()
        let heldIDs = model.heldTimelineLanes?.map { $0.segments.map(\.id) }
        model.updateSelected { $0.start = 5 }
        XCTAssertEqual(model.heldTimelineLanes?.map { $0.segments.map(\.id) }, heldIDs)
        model.endTimelineGesture()
        XCTAssertNil(model.heldTimelineLanes)
        model.undo()
        XCTAssertEqual(model.selectedSegment?.start, child.start)
        model.reversePosePath()
        XCTAssertEqual(model.segments[0], parent)
        model.speedSelectedRange(2)
        XCTAssertEqual(model.selectedSegment?.kind, .speed)
        XCTAssertEqual(model.selectedSegment?.start, child.start)
        XCTAssertEqual(model.selectedSegment?.duration, child.duration)
        XCTAssertLessThan(model.outputDuration, 10)
        let before = model.outputDuration
        model.updateSelected { $0.intensity = 0.5 }
        XCTAssertGreaterThan(model.outputDuration, before)
        XCTAssertEqual(model.segments[0], parent)
        let decoded = try JSONDecoder().decode([EditSegment].self, from: JSONEncoder().encode(model.segments))
        XCTAssertEqual(decoded, model.segments)
    }

    @MainActor func testEditablePosePath() throws {
        let a = FramePose(yaw: -0.3, panX: -0.2, zoom: 0.8)
        let b = FramePose(pitch: 0.4, yaw: 0.5, panX: 0.3, zoom: 1.2)
        let frames = [PoseKeyframe(time: 0, pose: a), PoseKeyframe(time: 1, pose: b)]
        XCTAssertEqual(PosePath.pose(at: 0, in: frames, curve: .smooth), a)
        XCTAssertEqual(PosePath.pose(at: 1, in: frames.reversed(), curve: .smooth), b)
        XCTAssertEqual(PosePath.pose(at: 0.5, in: frames, curve: .smooth), a.blended(to: b, 0.5))
        let model = EditorModel(restoreLatest: false)
        model.duration = 10; model.trimEnd = 10
        model.videoURL = URL(fileURLWithPath: "/tmp/path-check-nonexistent.mp4")
        defer { model.videoURL = nil }
        let other = EditSegment(kind: .zoom, start: 0, duration: 8, intensity: 1.5, x: 0.5, y: 0.5)
        var segment = EditSegment(kind: .perspective, start: 1, duration: 4, intensity: 1, x: 0.5, y: 0.5)
        segment.poseKeyframes = frames
        model.segments = [other, segment]; model.selectedSegmentID = segment.id
        model.seekPose(0.5)
        model.beginPoseGesture()
        model.editedPose = FramePose(yaw: 0.2)
        model.editedPose = FramePose(yaw: 0.4)
        model.endPoseGesture()
        XCTAssertEqual(model.selectedSegment?.poseKeyframes?.count, 3)
        XCTAssertEqual(model.segments[0], other)
        XCTAssertEqual(model.editedPose.yaw, 0.4, accuracy: 0.00001)
        model.undo()
        XCTAssertEqual(model.selectedSegment?.poseKeyframes, frames)
        model.redo()
        XCTAssertEqual(model.selectedSegment?.poseKeyframes?.count, 3)
        let point = try XCTUnwrap(model.currentPosePoint)
        model.beginPoseGesture(); model.movePosePoint(point.id, to: 0.75); model.endPoseGesture()
        XCTAssertEqual(model.playhead, 4, accuracy: 0.00001)
        model.removePosePoint()
        XCTAssertEqual(model.selectedSegment?.poseKeyframes?.count, 2)
        let original = try XCTUnwrap(model.selectedSegment)
        model.seekPose(0.37); model.splitSelected()
        for step in 0...100 {
            let time = original.start + original.duration * Double(step) / 100
            let before = MotionEngine.stance(at: time, segments: [original]).pose
            let after = MotionEngine.stance(at: time, segments: model.segments).pose
            XCTAssertEqual(before.yaw, after.yaw, accuracy: 0.000001)
            XCTAssertEqual(before.zoom, after.zoom, accuracy: 0.000001)
        }
        let encoded = try JSONEncoder().encode(model.segments)
        XCTAssertEqual(try JSONDecoder().decode([EditSegment].self, from: encoded), model.segments)
        model.seekPose(0.5); model.addPosePoint()
        let splitPoint = try XCTUnwrap(model.currentPosePoint)
        model.movePosePoint(splitPoint.id, to: -10)
        XCTAssertTrue((model.currentPosePoint?.time ?? -1) > 0)
        model.movePosePoint(splitPoint.id, to: 10)
        XCTAssertTrue((model.currentPosePoint?.time ?? 2) < 1)
        model.applyThreeDPreset(.orbit)
        XCTAssertNil(model.selectedSegment?.poseKeyframes)
    }

    @MainActor func testThreeDPresetWorkflowAndPreviewReuse() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FocusFlow-3D-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.mp4")
        try await makeFixture(at: source, camera: false)
        let model = EditorModel(restoreLatest: false)
        let previousRecording = UserDefaults.standard.string(forKey: "FocusFlow.lastRecording")
        defer {
            UserDefaults.standard.set(previousRecording, forKey: "FocusFlow.lastRecording")
            model.player.pause(); model.videoURL = nil
        }
        func settled() async throws {
            for _ in 0..<300 {
                if model.player.currentItem != nil && model.saveStatus == "All changes saved locally" { return }
                try await Task.sleep(for: .milliseconds(50))
            }
            throw NSError(domain: "FocusFlowChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: "3D preview did not settle: \(model.message ?? model.saveStatus)"])
        }
        model.open(url: source, metadata: .empty)
        try await settled()
        model.trimStart = 0.3; model.trimEnd = 1.8
        try await settled()
        let originalAsset = try XCTUnwrap(model.player.currentItem?.asset)
        model.playhead = 1.79
        model.applyThreeDPreset(.orbit)
        try await settled()
        let orbit = try XCTUnwrap(model.selectedSegment)
        XCTAssertEqual(orbit.start, 0.3, accuracy: 0.0001)
        XCTAssertLessThanOrEqual(orbit.end, model.trimEnd + 0.0001)
        XCTAssertEqual(orbit.posePreset, "orbit")
        XCTAssertTrue(model.player.currentItem?.asset === originalAsset)

        model.applyThreeDPreset(.showcase)
        XCTAssertEqual(model.segments.count, 1)
        XCTAssertEqual(model.selectedSegmentID, orbit.id)
        model.undo()
        XCTAssertEqual(model.selectedSegment?.posePreset, "orbit")
        model.redo()
        XCTAssertEqual(model.selectedSegment?.posePreset, "showcase")
        try await settled()

        // A structural edit followed immediately by a 3D edit must still
        // rebuild the media; cancelling the first task must not lose it.
        let beforeRateChange = try XCTUnwrap(model.player.currentItem?.asset)
        model.playbackRate = 2
        model.applyThreeDPreset(.drift)
        try await settled()
        XCTAssertTrue(model.player.currentItem?.asset !== beforeRateChange)
        let resizedDuration = try await model.player.currentItem!.asset.load(.duration).seconds
        XCTAssertEqual(resizedDuration, model.duration / 2, accuracy: 0.01)
        let reused = try XCTUnwrap(model.player.currentItem?.asset)
        model.updateSelected { $0.poseStrength = 0.35; $0.poseReversed = true }
        try await settled()
        XCTAssertTrue(model.player.currentItem?.asset === reused)
        let instruction = try XCTUnwrap(model.player.currentItem?.videoComposition?.instructions.first as? CompositionInstruction)
        XCTAssertEqual(instruction.settings.segments.first?.poseStrength, 0.35)
        XCTAssertEqual(instruction.settings.segments.first?.poseReversed, true)

        let saved = try Data(contentsOf: source.deletingPathExtension().appendingPathExtension("edits.json"))
        let restored = try JSONDecoder().decode(ProjectDocument.self, from: saved)
        XCTAssertEqual(restored.segments, model.segments)

        // Save the actual SwiftUI views for visual review at inspector width.
        let qa = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/qa")
        func snapshot<V: View>(_ view: V, name: String) throws {
            let hosting = NSHostingView(rootView: view.environmentObject(model).preferredColorScheme(.light))
            let window = NSWindow(contentRect: CGRect(origin: .zero, size: hosting.fittingSize), styleMask: .borderless, backing: .buffered, defer: false)
            window.contentView = hosting
            hosting.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: qa.appendingPathComponent(name))
        }
        try snapshot(ThreeDPresetPicker().background(AppTheme.panel), name: "3d-presets.png")
        try snapshot(SegmentInspector().frame(width: 290).background(AppTheme.panel), name: "3d-inspector.png")
        model.show3DCanvas = true
        try snapshot(Frame3DBar().frame(width: 420).background(AppTheme.panel), name: "3d-bar.png")

        model.customizeThreeDPath()
        model.seekPose(0.5)
        model.beginPoseGesture(); model.editedPose = FramePose(pitch: 0.2, yaw: 0.3); model.endPoseGesture()
        try await settled()
        XCTAssertTrue(model.player.currentItem?.asset === reused)
        let pathSaved = try JSONDecoder().decode(ProjectDocument.self, from: Data(contentsOf: source.deletingPathExtension().appendingPathExtension("edits.json")))
        XCTAssertEqual(pathSaved.segments, model.segments)
        try snapshot(Frame3DBar().frame(width: 480), name: "3d-path.png")
        model.theatreMode = true
        try snapshot(PreviewArea().frame(width: 1100, height: 720), name: "3d-fullscreen.png")
        model.theatreMode = false
        model.previewThreeDMove()
        for _ in 0..<120 {
            if model.isPlaying { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertTrue(model.isPlaying)
        for _ in 0..<160 {
            if !model.isPlaying { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertTrue(!model.isPlaying)
        XCTAssertEqual(model.playhead, model.selectedSegment!.end, accuracy: 0.05)
        model.seekPose(0.3)
        let parentID = model.selectedSegmentID
        model.addThreeDLayer(nested: true)
        model.editedPose = FramePose(yaw: 0.15, zoom: 1.1)
        try await settled()
        XCTAssertTrue(model.player.currentItem?.asset === reused)
        try snapshot(Frame3DBar().frame(width: 480), name: "3d-layers.png")
        try snapshot(TimelineView().frame(width: 900), name: "3d-layer-timeline.png")
        model.speedSelectedRange(2)
        try await settled()
        XCTAssertTrue(model.player.currentItem?.asset !== reused)
        XCTAssertEqual(try await model.player.currentItem!.asset.load(.duration).seconds, model.timeMap.outputDuration, accuracy: 0.001)
        model.seek(to: 1)
        XCTAssertEqual(model.playhead, 1)
        try snapshot(SegmentInspector().frame(width: 290).background(AppTheme.panel), name: "range-speed.png")
        if let parentID { model.selectThreeDLayer(parentID) }
        model.theatreMode = true
        try snapshot(PreviewArea().frame(width: 1100, height: 720), name: "3d-fullscreen.png")
        model.theatreMode = false
    }

    func testThreeDPresetsRenderAndRoundTrip() throws {
        let renderer = FocusFlowCompositor(), context = CIContext()
        let canvas = CGRect(x: 0, y: 0, width: 400, height: 240)
        let source = CIImage.empty().applyingFilter("CICheckerboardGenerator", parameters: [
            "inputCenter": CIVector(x: 0, y: 0),
            "inputColor0": CIColor(red: 0.95, green: 0.95, blue: 0.95),
            "inputColor1": CIColor(red: 0.2, green: 0.2, blue: 0.2),
            "inputWidth": 12,
            "inputSharpness": 1,
        ]).cropped(to: canvas)
        var settings = ExportSettings(background: .graphite, canvasSize: canvas.size, padding: 12, cornerRadius: 10, shadow: 20, segments: [], pointerSamples: [], clicks: [], keystrokes: [], cursorSize: 1, clickEffects: false, showKeystrokes: false, cameraURL: nil, showCamera: false, cameraSize: 0.2, cameraX: 0.8, cameraY: 0.8, cameraCornerRadius: 0, cameraShape: .circle)
        settings.motion.ambientGraphics = false; settings.motion.automaticMotionBlur = false
        func frame() throws -> [UInt8] {
            pixels(try XCTUnwrap(context.createCGImage(renderer.renderFrame(source: source, time: 2.8, settings: settings), from: canvas)))
        }
        let plain = try frame()
        for preset in ThreeDPreset.allCases {
            var segment = EditSegment(kind: .perspective, start: 0, duration: 4, intensity: 1, x: 0.5, y: 0.5)
            preset.apply(to: &segment)
            XCTAssertEqual(MotionEngine.stance(at: 0, segments: [segment]).pose, .neutral)
            XCTAssertEqual(MotionEngine.stance(at: 4, segments: [segment]).pose, .neutral)
            let forward = MotionEngine.stance(at: 2.8, segments: [segment]).pose
            XCTAssertTrue(!forward.isNeutral)
            segment.poseReversed = true
            let backward = MotionEngine.stance(at: 2.8, segments: [segment]).pose
            XCTAssertEqual(backward.yaw, -forward.yaw, accuracy: 0.0001)
            XCTAssertEqual(backward.pitch, -forward.pitch, accuracy: 0.0001)
            XCTAssertEqual(backward.zoom, 2 - forward.zoom, accuracy: 0.0001)
            let decoded = try JSONDecoder().decode(EditSegment.self, from: JSONEncoder().encode(segment))
            XCTAssertEqual(decoded, segment)
            settings.segments = [segment]
            let drawn = try frame()
            XCTAssertGreaterThan(zip(plain, drawn).filter { abs(Int($0) - Int($1)) > 10 }.count, 100)
            segment.poseStrength = 0
            XCTAssertEqual(MotionEngine.stance(at: 2.8, segments: [segment]).pose, .neutral)
        }
    }

    /// The automatic pass produces zooms and nothing else.
    ///
    /// It used to add a spotlight, an outline or a "Click" callout to every
    /// third click, and a tracking zoom and spotlight to every text selection.
    /// That decorated a plain recording without being asked, so it is gone;
    /// those effects remain available by hand.
    func testAutomaticEditsProduceZoomsOnly() {
        let clicks = (0..<4).map { RecordedClick(time: Double($0) * 2 + 1, x: 0.3 + Double($0) * 0.1, y: 0.45) }
        var samples = clicks.map { PointerSample(time: $0.time + 0.8, x: $0.x + 0.08, y: $0.y, shape: .arrow) }
        samples += (0..<12).map { PointerSample(time: 9 + Double($0) * 0.035, x: 0.2 + Double($0) * 0.025, y: 0.3, shape: .text, pressed: true) }
        let edits = MotionEngine.autoEdits(clicks: clicks, samples: samples, duration: 12)

        XCTAssertTrue(!edits.isEmpty)
        XCTAssertTrue(edits.allSatisfy { $0.kind == .zoom })
        for unwanted in [SegmentKind.spotlight, .outline, .callout, .pan] {
            XCTAssertTrue(!edits.contains { $0.kind == unwanted })
        }

        // A text selection earns one zoom that follows the range as it is
        // dragged. It used to be a steady zoom on the midpoint of where
        // the drag finished, which arrived before there was anything
        // selected to look at — and before that a zoom and a spotlight
        // travelling across it together, which was the busy thing the
        // steady zoom was a retreat from. One tracking zoom, no spotlight.
        let selectionZooms = edits.filter { $0.start > 8.5 }
        XCTAssertEqual(selectionZooms.count, 1)
        XCTAssertTrue(selectionZooms.allSatisfy { $0.tracksSelection == true })
        XCTAssertTrue(selectionZooms.allSatisfy { $0.selectionStartTime != nil && $0.selectionEndTime != nil })

        // Switched off, a selection is left alone entirely.
        var ignored = SelectionFocusSettings(); ignored.enabled = false
        let withoutSelection = MotionEngine.autoEdits(clicks: clicks, samples: samples, duration: 12, selection: ignored)
        XCTAssertTrue(withoutSelection.allSatisfy { $0.start < 8.5 })

        // A fixed camera target still retains both ends and the timing of
        // the drag, so its highlight can reveal the selected text as it grows.
        var fixed = SelectionFocusSettings(); fixed.tracks = false
        let fixedEdits = MotionEngine.autoEdits(clicks: [], samples: samples, duration: 12, selection: fixed)
        let fixedSelection = fixedEdits.last!
        XCTAssertTrue(fixedSelection.tracksSelection != true)
        XCTAssertEqual(fixedSelection.x, samples[4].x, accuracy: 0.0001)
        XCTAssertEqual(fixedSelection.endX ?? 0, samples.last!.x, accuracy: 0.0001)
        XCTAssertTrue(fixedSelection.selectionStartTime != nil)
        XCTAssertTrue(fixedSelection.selectionEndTime != nil)

        XCTAssertTrue(edits.allSatisfy { $0.start >= 0 && $0.end <= 12 })

        // Hovering over text without pressing is not a selection.
        let hover = (0..<12).map { PointerSample(time: 1 + Double($0) * 0.035, x: 0.2 + Double($0) * 0.025, y: 0.3, shape: .text) }
        XCTAssertTrue(MotionEngine.autoEdits(clicks: [], samples: hover, duration: 3).isEmpty)
    }

    /// A click zoom holds its anchor through small pointer movement instead of
    /// drifting after it, which read as an aimless pan.
    func testClickZoomHoldsStillUntilThePointerLeavesTheFrame() {
        let zoom = EditSegment(kind: .zoom, start: 0, duration: 4, intensity: 2,
                               x: 0.5, y: 0.5, followsCursor: true, transition: 0.3)

        func viewport(pointerX: Double) -> CGRect {
            // A flat run of samples either side so smoothing settles on it.
            let samples = (0..<40).map { PointerSample(time: Double($0) * 0.05, x: pointerX, y: 0.5) }
            return MotionEngine.viewport(at: 1, segments: [zoom], samples: samples, crop: ContentRegion())
        }

        let anchored = viewport(pointerX: 0.5)
        // A small movement must not move the frame at all.
        let nudged = viewport(pointerX: 0.54)
        XCTAssertEqual(Double(nudged.midX), Double(anchored.midX), accuracy: 0.001)

        // A large one must, or the subject would leave the frame.
        let far = viewport(pointerX: 0.9)
        XCTAssertGreaterThan(Double(far.midX), Double(anchored.midX) + 0.05)

        // And it follows only as far as it must, never all the way.
        XCTAssertLessThan(Double(far.midX), 0.9)
    }

    func testCursorStaysWithinBoundsAndDisappearsAcrossGaps() {
        let points = [PointerSample(time: 0, x: 0, y: 0), PointerSample(time: 0.03, x: 1, y: 1), PointerSample(time: 0.06, x: 0, y: 0), PointerSample(time: 1, x: 0.5, y: 0.5)]
        for i in 0..<60 {
            let sample = CursorMotion.sample(at: Double(i) / 1000, samples: points, smoothed: true)!
            XCTAssertTrue((0...1).contains(sample.x)); XCTAssertTrue((0...1).contains(sample.y))
        }
        XCTAssertNil(CursorMotion.sample(at: 0.5, samples: points, smoothed: true))
        XCTAssertNil(CursorMotion.sample(at: 2, samples: points, smoothed: true))
    }

    func testLegacyProjectAndCaptureMetadataStillDecode() throws {
        let json = #"{"videoPath":"/tmp/video.mp4","segments":[{"id":"35B6D9BA-EFE6-4591-970B-2AB70EE2E182","kind":"blur","start":0,"duration":1,"intensity":2,"x":0.5,"y":0.5}],"background":"ocean","ratio":"Source","padding":7,"cornerRadius":18,"shadow":30,"cursorSize":1.2,"clickEffects":true}"#
        let project = try JSONDecoder().decode(ProjectDocument.self, from: Data(json.utf8))
        XCTAssertEqual(project.segments.first?.regionWidth, 0.3)
        XCTAssertNil(project.cameraShape)
        let metadata = try JSONDecoder().decode(RecordingMetadata.self, from: Data(#"{"clicks":[]}"#.utf8))
        XCTAssertTrue(metadata.pointerSamples.isEmpty)
    }

    @MainActor func testUndoRedoAndSegmentBounds() async {
        let model = EditorModel(restoreLatest: false)
        model.videoURL = URL(fileURLWithPath: "/tmp/nonexistent-focusflow-test.mp4")
        model.duration = 2; model.playhead = 1.9
        model.addSegment(.blur)
        XCTAssertLessThanOrEqual(model.segments[0].end, 2)
        model.updateSelected { $0.start = 10; $0.duration = 30; $0.width = 0.4; $0.x = 1 }
        XCTAssertLessThanOrEqual(model.segments[0].end, 2.001)
        XCTAssertEqual(model.segments[0].x, 0.8)
        model.deleteSelected(); XCTAssertEqual(model.segments.count, 0)
        model.undo(); XCTAssertEqual(model.segments.count, 1)
        model.redo(); XCTAssertEqual(model.segments.count, 0)
        model.videoURL = nil
    }

    @MainActor func testBrowserBridgeRejectsUntrustedWritesAndServesResources() async throws {
        let bridge = BrowserRecorderBridge(); try await bridge.launch(openInBrowser: false); defer { bridge.stop() }
        let session = try XCTUnwrap(bridge.sessionURL)
        var components = URLComponents(url: session, resolvingAgainstBaseURL: false)!; components.fragment = nil
        let base = components.url!
        let (page, response) = try await URLSession.shared.data(from: base)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertTrue(String(data: page, encoding: .utf8)!.contains("Choose a Chrome tab"))
        var request = URLRequest(url: base.appendingPathComponent("screen")); request.httpMethod = "POST"; request.httpBody = Data("invalid".utf8)
        request.setValue("http://evil.invalid", forHTTPHeaderField: "Origin")
        request.setValue(session.fragment, forHTTPHeaderField: "X-FocusFlow-Token")
        let captureID = UUID().uuidString
        request.setValue(captureID, forHTTPHeaderField: "X-FocusFlow-Capture")
        let (_, denied) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((denied as? HTTPURLResponse)?.statusCode, 403)
        request.setValue(String(base.absoluteString.dropLast()), forHTTPHeaderField: "Origin")
        request.url = base.appendingPathComponent("begin")
        let (_, begun) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((begun as? HTTPURLResponse)?.statusCode, 200)
        request.setValue(UUID().uuidString, forHTTPHeaderField: "X-FocusFlow-Capture")
        let (_, conflicting) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((conflicting as? HTTPURLResponse)?.statusCode, 409)
        request.setValue(captureID, forHTTPHeaderField: "X-FocusFlow-Capture")
        request.url = base.appendingPathComponent("screen")
        let (_, accepted) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((accepted as? HTTPURLResponse)?.statusCode, 200)
        request.url = base.appendingPathComponent("finish"); request.httpBody = Data("{}".utf8)
        let (_, invalidVideo) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((invalidVideo as? HTTPURLResponse)?.statusCode, 500)
    }

    func testRenderedExportTrimSpeedRegionalBlurAndCamera() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FocusFlow-QA-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.mp4"), camera = directory.appendingPathComponent("camera.mp4")
        try await makeFixture(at: source, camera: false); try await makeFixture(at: camera, camera: true)
        let music = directory.appendingPathComponent("music.caf")
        let audioFormat = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        let audioBuffer = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: 22_050)!
        audioBuffer.frameLength = 22_050
        for index in 0..<Int(audioBuffer.frameLength) {
            audioBuffer.floatChannelData![0][index] = Float(sin(Double(index) * 2 * .pi * 440 / 44_100) * 0.2)
        }
        let audioFile = try AVAudioFile(forWriting: music, settings: audioFormat.settings)
        try audioFile.write(from: audioBuffer)
        var settings = ExportSettings(background: .cream, canvasSize: CGSize(width: 640, height: 360), padding: 7, cornerRadius: 18, shadow: 20, segments: [], pointerSamples: [], clicks: [], keystrokes: [], cursorSize: 1, clickEffects: false, showKeystrokes: false, cameraURL: camera, showCamera: true, cameraSize: 0.25, cameraX: 0.83, cameraY: 0.75, cameraCornerRadius: 12, cameraShape: .circle)
        settings.trimStart = 0.4; settings.trimEnd = 1.6; settings.playbackRate = 2; settings.musicURL = music
        let clean = directory.appendingPathComponent("clean.mp4")
        try await VideoExporter.export(source: source, destination: clean, settings: settings) { _ in }
        let duration = try await AVURLAsset(url: clean).load(.duration).seconds
        XCTAssertEqual(duration, 0.6, accuracy: 0.06)
        let musicTracks = try await AVURLAsset(url: clean).loadTracks(withMediaType: .audio)
        XCTAssertGreaterThan(musicTracks.count, 0)
        let rangeFast = EditSegment(kind: .speed, start: 0.6, duration: 0.6, intensity: 2, x: 0.5, y: 0.5)
        let rangeSlow = EditSegment(kind: .speed, start: 0.9, duration: 0.1, intensity: 0.5, x: 0.5, y: 0.5)
        var parentMove = EditSegment(kind: .perspective, start: 0.4, duration: 1.2, intensity: 1, x: 0.5, y: 0.5)
        ThreeDPreset.slideLeft.apply(to: &parentMove)
        var nestedMove = EditSegment(kind: .perspective, start: 0.6, duration: 0.6, intensity: 1, x: 0.5, y: 0.5)
        nestedMove.poseKeyframes = [PoseKeyframe(time: 0, pose: .neutral), PoseKeyframe(time: 0.5, pose: FramePose(pitch: 0.2, zoom: 1.2)), PoseKeyframe(time: 1, pose: .neutral)]
        settings.playbackRate = 1
        settings.segments = [rangeFast, rangeSlow, parentMove, nestedMove]
        let timed = directory.appendingPathComponent("range-speed.mp4")
        try await VideoExporter.export(source: source, destination: timed, settings: settings) { _ in }
        // 0.6 s unchanged + 0.5 s at 2x + 0.1 s at 0.5x = 1.05 s.
        let timedAsset = AVURLAsset(url: timed)
        XCTAssertEqual(try await timedAsset.load(.duration).seconds, 1.05, accuracy: 0.04)
        XCTAssertGreaterThan(try await timedAsset.loadTracks(withMediaType: .audio).count, 0)
        let generator = AVAssetImageGenerator(asset: timedAsset)
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        let timedImage = try await generator.image(at: CMTime(seconds: 0.4, preferredTimescale: 600)).image
        XCTAssertEqual(timedImage.width, 640)
        XCTAssertGreaterThan(zip(pixels(try await frame(clean)), pixels(timedImage)).filter { abs(Int($0) - Int($1)) > 10 }.count, 100)
        settings.playbackRate = 2
        settings.segments = [EditSegment(kind: .blur, start: 0, duration: 2, intensity: 2, x: 0.35, y: 0.5, width: 0.25, height: 0.4)]
        let blurred = directory.appendingPathComponent("blurred.mp4")
        try await VideoExporter.export(source: source, destination: blurred, settings: settings) { _ in }
        let cleanImage = try await frame(clean), blurredImage = try await frame(blurred)
        XCTAssertEqual(blurredImage.width, 640); XCTAssertEqual(blurredImage.height, 360)
        let cleanPixels = pixels(cleanImage), blurredPixels = pixels(blurredImage)
        func difference(_ region: CGRect) -> Double {
            var total: Double = 0, count: Double = 0
            for y in Int(region.minY)..<Int(region.maxY) { for x in Int(region.minX)..<Int(region.maxX) {
                for c in 0..<3 { total += abs(Double(cleanPixels[(y * 640 + x) * 4 + c]) - Double(blurredPixels[(y * 640 + x) * 4 + c])); count += 1 }
            } }
            return total / count
        }
        XCTAssertGreaterThan(difference(CGRect(x: 185, y: 135, width: 70, height: 80)), 15)
        XCTAssertLessThan(difference(CGRect(x: 340, y: 120, width: 60, height: 80)), 7)
        // Round camera overlay remains red while screen is black/white.
        let center = (270 * 640 + 530) * 4
        XCTAssertGreaterThan(Int(blurredPixels[center]), Int(blurredPixels[center + 1]) + 80)
        let qa = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/qa")
        try FileManager.default.createDirectory(at: qa, withIntermediateDirectories: true)
        let bitmap = NSBitmapImageRep(cgImage: blurredImage)
        try bitmap.representation(using: .png, properties: [:])!.write(to: qa.appendingPathComponent("export-render.png"))
        try FileManager.default.copyItem(at: blurred, to: qa.appendingPathComponent("export-\(UUID().uuidString).mp4"))
        do {
            try await VideoExporter.export(source: source, destination: source, settings: settings) { _ in }
            XCTFail("Exporter must not overwrite source")
        } catch { XCTAssertTrue(FileManager.default.fileExists(atPath: source.path)) }

        // The sounds reach the composition, laid where the events were: a
        // track for each kind that has any, with the typing filled for as
        // long as the typing lasted and cut there rather than running on for
        // the length of the clip.
        var sounded = settings
        sounded.segments = []
        sounded.trimStart = 0; sounded.trimEnd = .greatestFiniteMagnitude
        sounded.playbackRate = 1; sounded.musicURL = nil
        sounded.clicks = [RecordedClick(time: 0.2, x: 0.5, y: 0.5)]
        sounded.typingEvents = (0..<13).map { TypingEvent(time: 0.3 + Double($0) * 0.1) }  // 0.30 … 1.50
        let (withSound, _, mix) = try await VideoExporter.composition(source: source, settings: sounded)
        let soundTracks = withSound.tracks(withMediaType: .audio)
        XCTAssertEqual(soundTracks.count, 2)
        // What is actually sounding, rather than the span the track covers:
        // a track that starts late carries an empty stretch before it.
        func sounding(_ track: AVCompositionTrack) -> Double {
            track.segments.filter { !$0.isEmpty }.reduce(0) { $0 + $1.timeMapping.target.duration.seconds }
        }
        let spans = soundTracks.map(sounding).sorted()
        // The click is the clip played once; the typing is the length of the
        // run, cut there rather than running on for the eight-second clip.
        XCTAssertEqual(spans[0], 0.84, accuracy: 0.12)
        XCTAssertEqual(spans[1], 1.2 + SoundTrack.tail, accuracy: 0.1)
        // And each track carries a volume of its own.
        XCTAssertEqual(mix?.inputParameters.count, 2)

        var silent = sounded
        silent.sounds = SoundSettings(typing: false, clicking: false, scrolling: false)
        let (quiet, _, _) = try await VideoExporter.composition(source: source, settings: silent)
        XCTAssertTrue(quiet.tracks(withMediaType: .audio).isEmpty)
    }

    func testCropGeometryMotionAndPresentationRoundTrip() throws {
        let crop = ContentRegion(x: 0.5, y: 0.2, width: 0.5, height: 0.8)
        let pixels = crop.pixelRect(in: CGSize(width: 1000, height: 600))
        XCTAssertEqual(pixels, CGRect(x: 500, y: 120, width: 500, height: 480))
        let layout = FrameLayout.make(canvas: CGRect(x: 0, y: 0, width: 1000, height: 600), sourceSize: pixels.size, padding: 7, frame: FrameAppearance())
        XCTAssertEqual(layout.content.width / layout.content.height, 500.0 / 480, accuracy: 0.00001)
        XCTAssertGreaterThan(layout.header.height, 0)
        XCTAssertLessThanOrEqual(layout.outer.maxY, 600)
        let segment = EditSegment(kind: .zoom, start: 1, duration: 4, intensity: 2, x: 0.9, y: 0.7, transition: 0.8)
        // Outside the smoothing window the frame is untouched. Inside it the
        // camera has already begun to lean into the move, which is the point
        // of a centred window — but barely, so a frame either side of the
        // segment is still all but the whole picture.
        let clear = CGRect(x: 0, y: 0, width: 1, height: 1)
        XCTAssertEqual(MotionEngine.viewport(at: 1 - MotionEngine.smoothing, segments: [segment], samples: [], crop: crop), clear)
        XCTAssertEqual(MotionEngine.viewport(at: 5 + MotionEngine.smoothing, segments: [segment], samples: [], crop: crop), clear)
        for edge in [1.0, 5.0] {
            let viewport = MotionEngine.viewport(at: edge, segments: [segment], samples: [], crop: crop)
            XCTAssertGreaterThan(Double(viewport.width), 0.99)
            XCTAssertLessThan(Double(viewport.width), 1)
        }
        var previous = CGRect(x: 0, y: 0, width: 1, height: 1)
        for frame in 0...360 {
            let viewport = MotionEngine.viewport(at: Double(frame) / 60, segments: [segment], samples: [], crop: crop)
            XCTAssertTrue(viewport.minX >= 0 && viewport.minY >= 0 && viewport.maxX <= 1.00001 && viewport.maxY <= 1.00001)
            XCTAssertLessThan(abs(viewport.minX - previous.minX), 0.04)
            XCTAssertLessThan(abs(viewport.width - previous.width), 0.04)
            previous = viewport
        }
        let points = [PointerSample(time: 0, x: 0.85, y: 0.8), PointerSample(time: 0.03, x: 0.85, y: 0.8), PointerSample(time: 3, x: 0.2, y: 0.1)]
        XCTAssertEqual(CursorMotion.followPoint(at: 1, samples: points)!.x, 0.85, accuracy: 0.0001)
        let auto = MotionEngine.autoZooms(clicks: [RecordedClick(time: 1, x: 0.4, y: 0.3), RecordedClick(time: 1.3, x: 0.5, y: 0.4), RecordedClick(time: 7, x: 0.2, y: 0.2)], duration: 8)
        XCTAssertEqual(auto.count, 2); XCTAssertEqual(auto[0].followsCursor, true); XCTAssertLessThanOrEqual(auto[1].end, 8)
        let frame = FrameAppearance(chrome: .dark, title: "Demo", barHeight: 64, trafficLights: false, lightSize: 18, crop: crop)
        let document = ProjectDocument(videoPath: "/tmp/source.mp4", segments: [segment], background: .ocean, ratio: .source, padding: 7, cornerRadius: 18, shadow: 20, cursorSize: 1.4, clickEffects: true, frameAppearance: frame, motionAppearance: MotionAppearance(entrance: .rise, duration: 1, fadeOut: true), cursorAppearance: CursorAppearance(style: .accent, accent: .violet, clickStyle: .pulse, sway: false))
        let restored = try JSONDecoder().decode(ProjectDocument.self, from: JSONEncoder().encode(document))
        XCTAssertEqual(restored.frameAppearance, document.frameAppearance)
        XCTAssertEqual(restored.motionAppearance, document.motionAppearance)
        XCTAssertEqual(restored.cursorAppearance, document.cursorAppearance)
        XCTAssertEqual(restored.segments, document.segments)
    }

    func testRenderedCropChromeCursorAndMotion() throws {
        let renderer = FocusFlowCompositor(), context = CIContext()
        let canvas = CGRect(x: 0, y: 0, width: 960, height: 600)
        let base = CIImage(color: CIColor(red: 0.04, green: 0.12, blue: 0.3)).cropped(to: canvas)
        let right = CIImage(color: CIColor(red: 0.16, green: 0.7, blue: 0.4)).cropped(to: CGRect(x: 480, y: 0, width: 480, height: 480)).composited(over: base)
        let toolbar = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 480, width: 960, height: 120)).composited(over: right)
        var settings = ExportSettings(background: .graphite, canvasSize: canvas.size, padding: 8, cornerRadius: 16, shadow: 20, segments: [], pointerSamples: [], clicks: [], keystrokes: [], cursorSize: 1.5, clickEffects: true, showKeystrokes: false, cameraURL: nil, showCamera: false, cameraSize: 0.2, cameraX: 0.8, cameraY: 0.8, cameraCornerRadius: 10, cameraShape: .circle)
        settings.frame = FrameAppearance(chrome: .light, title: "Editable window", barHeight: 80, lightSize: 24, crop: ContentRegion(x: 0.5, y: 0.2, width: 0.5, height: 0.8))
        let layout = FrameLayout.make(canvas: canvas, sourceSize: CGSize(width: 480, height: 480), padding: 8, frame: settings.frame)
        func render(_ settings: ExportSettings, _ time: Double = 1) throws -> CGImage {
            try XCTUnwrap(context.createCGImage(renderer.renderFrame(source: toolbar, time: time, settings: settings), from: canvas))
        }
        let clean = try render(settings), cleanPixels = pixels(clean)
        func rgb(_ data: [UInt8], _ x: CGFloat, _ y: CGFloat) -> [UInt8] {
            let offset = ((599 - Int(y)) * 960 + Int(x)) * 4; return Array(data[offset..<offset + 3])
        }
        let middle = rgb(cleanPixels, layout.content.midX, layout.content.midY)
        XCTAssertGreaterThan(Int(middle[1]), Int(middle[0]) + 60)
        let header = rgb(cleanPixels, layout.header.maxX - 10, layout.header.midY)
        XCTAssertGreaterThan(header[0], 220)
        // The same color reaches the top of the content: no original red toolbar remains.
        let topContent = rgb(cleanPixels, layout.content.midX, layout.content.maxY - 4)
        XCTAssertGreaterThan(Int(topContent[1]), Int(topContent[0]) + 60)
        settings.pointerSamples = (0...60).map { PointerSample(time: Double($0) / 30, x: 0.72, y: 0.5) }
        settings.clicks = [RecordedClick(time: 0.9, x: 0.72, y: 0.5)]
        settings.cursor = CursorAppearance(style: .light, accent: .blue, clickStyle: .ripple)
        let withCursor = pixels(try render(settings))
        XCTAssertTrue(withCursor != cleanPixels)
        settings.segments = [EditSegment(kind: .zoom, start: 0, duration: 2, intensity: 1.8, x: 0.72, y: 0.5)]
        let zoomed = pixels(try render(settings))
        XCTAssertEqual(rgb(zoomed, layout.header.maxX - 10, layout.header.midY), header)
        settings.motion = MotionAppearance(entrance: .rise, duration: 1, fadeOut: true, ambientGraphics: false)
        settings.trimEnd = 2
        let start = pixels(try render(settings, 0)), end = pixels(try render(settings, 2))
        XCTAssertTrue(start == end)
        XCTAssertTrue(start != zoomed)
        settings.motion = MotionAppearance()
        settings.segments = [EditSegment(kind: .spotlight, start: 0, duration: 2, intensity: 2, x: 0.72, y: 0.5, width: 0.2, height: 0.3), EditSegment(kind: .callout, start: 0, duration: 2, intensity: 1, x: 0.75, y: 0.8, text: "Click to explore")]
        let effects = try render(settings)
        XCTAssertTrue(pixels(effects) != withCursor)
        let qa = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/qa")
        try NSBitmapImageRep(cgImage: effects).representation(using: .png, properties: [:])!.write(to: qa.appendingPathComponent("presentation-render.png"))
        // Draw the exact production cursor at 3× for visual inspection.
        let cursor = RenderAssets.cursor(settings.cursor)!
        let cursorImage = try XCTUnwrap(context.createCGImage(cursor, from: cursor.extent))
        try NSBitmapImageRep(cgImage: cursorImage).representation(using: .png, properties: [:])!.write(to: qa.appendingPathComponent("cursor-render.png"))
    }

    func testEditableCursorSizeHighlightAndClickRendering() throws {
        let compositor = FocusFlowCompositor(), context = CIContext()
        let canvas = CGRect(x: 0, y: 0, width: 960, height: 540)
        let source = CIImage(color: CIColor(red: 0.2, green: 0.25, blue: 0.3)).cropped(to: canvas)
        func settings(size: Double = 2, clicks: Bool = false) -> ExportSettings {
            ExportSettings(background: .graphite, canvasSize: canvas.size, padding: 0, cornerRadius: 0, shadow: 0, segments: [], pointerSamples: [PointerSample(time: 0.95, x: 0.5, y: 0.5), PointerSample(time: 1.05, x: 0.5, y: 0.5)], clicks: [RecordedClick(time: 0.85, x: 0.5, y: 0.5)], keystrokes: [], cursorSize: size, clickEffects: clicks, showKeystrokes: false, cameraURL: nil, showCamera: false, cameraSize: 0.2, cameraX: 0.8, cameraY: 0.8, cameraCornerRadius: 0, cameraShape: .circle, cursorShadow: false)
        }
        func render(_ value: ExportSettings) throws -> [UInt8] {
            pixels(try XCTUnwrap(context.createCGImage(compositor.renderFrame(source: source, time: 1, settings: value), from: canvas)))
        }
        var hidden = settings(); hidden.showCursor = false
        let clean = try render(hidden)
        func changedPixels(_ image: [UInt8]) -> Int {
            var count = 0
            for i in stride(from: 0, to: image.count, by: 4) {
                let red = abs(Int(image[i]) - Int(clean[i]))
                let green = abs(Int(image[i + 1]) - Int(clean[i + 1]))
                let blue = abs(Int(image[i + 2]) - Int(clean[i + 2]))
                if red + green + blue > 12 { count += 1 }
            }
            return count
        }
        let small = try render(settings(size: 1)), large = try render(settings(size: 3))
        XCTAssertGreaterThan(changedPixels(large), changedPixels(small) * 4)
        var glow = settings(); glow.cursor.highlight = true
        glow.cursor.customAccent = RGBColor(r: 0.8, g: 0.2, b: 0.1)
        XCTAssertGreaterThan(changedPixels(try render(glow)), changedPixels(large))
        var transparent = settings(); transparent.cursor.opacity = 0
        XCTAssertEqual(try render(transparent), clean)
        let click = settings(clicks: true)
        var bigClick = click; bigClick.cursor.clickScale = 3
        XCTAssertGreaterThan(changedPixels(try render(bigClick)), changedPixels(try render(click)))
        for style in ClickStyle.allCases {
            var styled = click; styled.cursor.clickStyle = style
            XCTAssertTrue(try render(styled) != render(settings()))
        }
        var custom = glow.cursor
        custom.highlightSize = 2.5; custom.highlightOpacity = 0.4; custom.clickScale = 1.7; custom.opacity = 0.6
        XCTAssertEqual(try JSONDecoder().decode(CursorAppearance.self, from: JSONEncoder().encode(custom)), custom)
        let legacy = Data(#"{"textScale":1.6,"style":"macOS","accent":"Blue","clickStyle":"Ripple","sway":false}"#.utf8)
        let restored = try JSONDecoder().decode(CursorAppearance.self, from: legacy)
        XCTAssertNil(restored.customAccent)
        XCTAssertEqual(restored.highlight ?? false, false)
        XCTAssertEqual(restored.opacity ?? 1, 1)
    }

    func testPixelateAndOutlineRenderInsideSelectedRegion() throws {
        let canvas = CGRect(x: 0, y: 0, width: 640, height: 360)
        var source = CIImage(color: CIColor(red: 0.12, green: 0.16, blue: 0.24)).cropped(to: canvas)
        for x in stride(from: 0, to: 640, by: 12) {
            let stripe = CIImage(color: CIColor(red: 0.9, green: 0.75, blue: 0.2))
                .cropped(to: CGRect(x: x, y: 0, width: 6, height: 360))
            source = stripe.composited(over: source)
        }
        let compositor = FocusFlowCompositor(), context = CIContext()
        var settings = ExportSettings(background: .none, canvasSize: canvas.size, padding: 0, cornerRadius: 0, shadow: 0, segments: [], pointerSamples: [], clicks: [], keystrokes: [], cursorSize: 2, clickEffects: false, showKeystrokes: false, cameraURL: nil, showCamera: false, cameraSize: 0.2, cameraX: 0.8, cameraY: 0.8, cameraCornerRadius: 0, cameraShape: .circle)
        settings.frame = FrameAppearance(chrome: .none)
        func render() throws -> [UInt8] {
            pixels(try XCTUnwrap(context.createCGImage(compositor.renderFrame(source: source, time: 1, settings: settings), from: canvas)))
        }
        let clean = try render()
        settings.segments = [EditSegment(kind: .pixelate, start: 0, duration: 2, intensity: 3, x: 0.5, y: 0.5)]
        let pixelated = try render()
        XCTAssertTrue(pixelated != clean)
        settings.segments = [EditSegment(kind: .outline, start: 0, duration: 2, intensity: 2, x: 0.5, y: 0.5)]
        let outlined = try render()
        XCTAssertTrue(outlined != clean)
        XCTAssertTrue(outlined != pixelated)
        let encoded = try JSONEncoder().encode(settings.segments)
        XCTAssertEqual(try JSONDecoder().decode([EditSegment].self, from: encoded), settings.segments)
    }

    @MainActor func testCursorResetIsUndoable() {
        let model = EditorModel(restoreLatest: false)
        XCTAssertEqual(model.cursorSize, 1.25)
        model.videoURL = URL(fileURLWithPath: "/tmp/nonexistent-focusflow-cursor-test.mp4")
        model.duration = 2
        model.cursorSize = 2; model.showCursor = false
        model.cursorAppearance.highlight = true
        model.resetCursorSettings()
        XCTAssertEqual(model.cursorSize, 4)
        XCTAssertTrue(model.showCursor)
        XCTAssertEqual(model.cursorAppearance.highlight, false)
        model.undo()
        XCTAssertEqual(model.cursorSize, 2)
        XCTAssertEqual(model.showCursor, false)
        XCTAssertEqual(model.cursorAppearance.highlight, true)
        model.redo()
        XCTAssertEqual(model.cursorSize, 4)
        XCTAssertTrue(model.showCursor)
        // Cancel pending preview work for the intentionally nonexistent test video.
        model.videoURL = nil
    }

    @MainActor func testRecordedCursorNeverGetsSecondOverlay() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("FocusFlow-cursor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let video = folder.appendingPathComponent("screen.mp4")
        try await makeFixture(at: video, camera: false)
        var metadata = RecordingMetadata(clicks: [], pointerSamples: [PointerSample(time: 0.5, x: 0.5, y: 0.5)], keystrokes: [], sourceWidth: 320, sourceHeight: 180, sourceName: "Chrome tab")
        metadata.embeddedCursor = true
        let model = EditorModel(restoreLatest: false)
        model.open(url: video, metadata: metadata)
        for _ in 0..<80 where model.isPreparingPreview { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertEqual(model.recordingMetadata.embeddedCursor, true)
        XCTAssertEqual(model.showCursor, false)
        model.showCursor = true
        XCTAssertEqual(model.settings().showCursor, false)
        model.videoURL = nil
    }

    private func frame(_ url: URL) async throws -> CGImage {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url)); generator.appliesPreferredTrackTransform = true
        return try await generator.image(at: CMTime(seconds: 0.2, preferredTimescale: 600)).image
    }
    /// Each background kind must actually reach the canvas, and the corners
    /// are the safest place to look: the recording is inset by the padding, so
    /// whatever is there came from the background generator.
    func testCustomBackgroundKindsRenderDistinctly() throws {
        let renderer = FocusFlowCompositor(), context = CIContext()
        let canvas = CGRect(x: 0, y: 0, width: 480, height: 270)
        let source = CIImage(color: CIColor(red: 0.95, green: 0.2, blue: 0.1)).cropped(to: CGRect(x: 0, y: 0, width: 480, height: 270))

        var settings = ExportSettings(background: .graphite, canvasSize: canvas.size, padding: 12, cornerRadius: 10, shadow: 0, segments: [], pointerSamples: [], clicks: [], keystrokes: [], cursorSize: 1, clickEffects: false, showKeystrokes: false, cameraURL: nil, showCamera: false, cameraSize: 0.2, cameraX: 0.8, cameraY: 0.8, cameraCornerRadius: 10, cameraShape: .circle)
        settings.showCursor = false

        func corner(_ background: CustomBackground) throws -> [UInt8] {
            settings.customBackground = background
            let image = try XCTUnwrap(context.createCGImage(renderer.renderFrame(source: source, time: 0, settings: settings), from: canvas))
            let data = pixels(image)
            // Top-left corner, inside the padding band.
            return Array(data[0..<3])
        }

        // A solid blue background must land blue in the corner.
        let solid = try corner(CustomBackground(kind: .solid, top: RGBColor(r: 0, g: 0.2, b: 0.9)))
        XCTAssertGreaterThan(Int(solid[2]), 150)
        XCTAssertLessThan(Int(solid[0]), 90)

        // A different solid must differ from the first.
        let otherSolid = try corner(CustomBackground(kind: .solid, top: RGBColor(r: 0.9, g: 0.85, b: 0)))
        XCTAssertGreaterThan(abs(Int(otherSolid[2]) - Int(solid[2])), 60)

        // A gradient between two colours must not match either endpoint
        // everywhere — the two opposite corners should differ.
        settings.customBackground = CustomBackground(kind: .gradient, top: RGBColor(r: 1, g: 0, b: 0), bottom: RGBColor(r: 0, g: 0, b: 1), angle: 0)
        let gradientImage = try XCTUnwrap(context.createCGImage(renderer.renderFrame(source: source, time: 0, settings: settings), from: canvas))
        let gradientPixels = pixels(gradientImage)
        let leftRed = Int(gradientPixels[0])
        let rightOffset = (480 - 1) * 4
        let rightRed = Int(gradientPixels[rightOffset])
        XCTAssertGreaterThan(abs(leftRed - rightRed), 60)

        // A missing image file must fall back to the gradient, not a black
        // frame, so a moved file does not look like a broken render.
        let missing = try corner(CustomBackground(kind: .image, top: RGBColor(r: 0, g: 0.9, b: 0.3), bottom: RGBColor(r: 0, g: 0.9, b: 0.3), imagePath: "/nonexistent/background.png"))
        XCTAssertGreaterThan(Int(missing[1]), 110)

        // Included artwork must resolve from the app bundle and reach the renderer.
        for artwork in BuiltInBackground.allCases {
            XCTAssertTrue(artwork.url.map { FileManager.default.fileExists(atPath: $0.path) } ?? false)
        }
        let supplied = try FileManager.default.contentsOfDirectory(atPath: "public")
            .filter { $0.hasPrefix("bg") && $0.hasSuffix(".png") }
        XCTAssertEqual(Set(BuiltInBackground.allCases.map { "\($0.rawValue).png" }), Set(supplied))
        let bundled = try corner(CustomBackground(kind: .image, imagePath: BuiltInBackground.bloom.reference))
        XCTAssertTrue(bundled != solid)
        settings.customBackground = CustomBackground(kind: .preset, imagePath: BuiltInBackground.classic.reference)
        let imagePreset = try XCTUnwrap(context.createCGImage(renderer.renderFrame(source: source, time: 0, settings: settings), from: canvas))
        let imagePresetCorner = Array(pixels(imagePreset)[0..<3])
        XCTAssertTrue(imagePresetCorner != otherSolid)

        // The blurred backdrop derives from the frame, which is red here.
        let blurred = try corner(CustomBackground(kind: .blur, blurRadius: 20, dim: 0))
        XCTAssertGreaterThan(Int(blurred[0]), Int(blurred[2]))
    }

    func testAutomaticMotionBlurChangesMovingZoomFrames() throws {
        let renderer = FocusFlowCompositor(), context = CIContext()
        let canvas = CGRect(x: 0, y: 0, width: 480, height: 270)
        let bars = (0..<60).reduce(CIImage(color: .black).cropped(to: canvas)) { image, index in
            CIImage(color: index.isMultiple(of: 2) ? .white : .black)
                .cropped(to: CGRect(x: index * 8, y: 0, width: 8, height: 270)).composited(over: image)
        }
        var settings = ExportSettings(background: .none, canvasSize: canvas.size, padding: 0, cornerRadius: 0, shadow: 0,
            segments: [EditSegment(kind: .zoom, start: 0.5, duration: 2, intensity: 2, x: 0.7, y: 0.5, transition: 0.8)],
            pointerSamples: [], clicks: [], keystrokes: [], cursorSize: 1, clickEffects: false, showKeystrokes: false,
            cameraURL: nil, showCamera: false, cameraSize: 0.2, cameraX: 0.8, cameraY: 0.8, cameraCornerRadius: 0, cameraShape: .circle)
        settings.showCursor = false
        settings.motion.automaticMotionBlur = false
        let sharp = try XCTUnwrap(context.createCGImage(renderer.renderFrame(source: bars, time: 0.75, settings: settings), from: canvas))
        settings.motion.automaticMotionBlur = true
        settings.motion.motionBlurStrength = 1
        let softened = try XCTUnwrap(context.createCGImage(renderer.renderFrame(source: bars, time: 0.75, settings: settings), from: canvas))
        let before = pixels(sharp), after = pixels(softened)
        let difference = stride(from: 0, to: before.count, by: 4).reduce(0.0) { $0 + abs(Double(before[$1]) - Double(after[$1])) }
        XCTAssertGreaterThan(difference / Double(before.count / 4), 1)
    }

    /// Export resolution scales the composed canvas, keeps its aspect, and
    /// yields even dimensions — H.264 rejects odd ones.
    func testExportResolutionScalesCanvasKeepingAspect() {
        let landscape = CGSize(width: 1920, height: 1080)
        var options = ExportOptions()

        options.resolution = .source
        XCTAssertEqual(options.canvas(from: landscape), landscape)

        options.resolution = .p720
        let small = options.canvas(from: landscape)
        XCTAssertEqual(small.width, 1280)
        XCTAssertEqual(small.height, 720)

        options.resolution = .p2160
        let large = options.canvas(from: landscape)
        XCTAssertEqual(large.width, 3840)
        XCTAssertEqual(large.height, 2160)

        // Portrait and an awkward aspect must still come out even.
        options.resolution = .p1080
        let portrait = options.canvas(from: CGSize(width: 1080, height: 1920))
        XCTAssertEqual(portrait.height, 1920)
        XCTAssertEqual(Int(portrait.width) % 2, 0)

        let odd = options.canvas(from: CGSize(width: 1001, height: 667))
        XCTAssertEqual(Int(odd.width) % 2, 0)
        XCTAssertEqual(Int(odd.height) % 2, 0)
        XCTAssertEqual(Double(odd.width / odd.height), 1001.0 / 667.0, accuracy: 0.01)
    }

    /// A project written before custom backgrounds and export options existed
    /// must still decode, defaulting rather than failing.
    func testProjectWithoutNewFieldsStillDecodes() throws {
        let legacy = """
        {"videoPath":"/tmp/a.mp4","segments":[],"background":"ocean","ratio":"16:9",
         "padding":7,"cornerRadius":18,"shadow":20,"cursorSize":1,"clickEffects":true}
        """
        let document = try JSONDecoder().decode(ProjectDocument.self, from: Data(legacy.utf8))
        XCTAssertNil(document.customBackground)
        XCTAssertNil(document.exportOptions)
        XCTAssertEqual(document.background, .ocean)

        // And a round trip with them set must preserve them.
        var written = document
        written.customBackground = CustomBackground(kind: .gradient, top: RGBColor(r: 0.2, g: 0.4, b: 0.6), angle: 90)
        written.exportOptions = ExportOptions(format: .mov, resolution: .p1440, frameRate: .fps60)
        let restored = try JSONDecoder().decode(ProjectDocument.self, from: JSONEncoder().encode(written))
        XCTAssertEqual(restored.customBackground, written.customBackground)
        XCTAssertEqual(restored.exportOptions, written.exportOptions)
    }

    /// Version ordering decides whether an update is offered at all, so the
    /// awkward cases matter: a numeric 10 beating 9, equal-but-shorter
    /// strings, and the "v" that release tags carry but bundles do not.
    func testReleaseVersionOrdering() throws {
        func v(_ text: String) throws -> SemanticVersion { try XCTUnwrap(SemanticVersion(text)) }

        XCTAssertTrue(try v("0.4.0") > v("0.3.0"))
        XCTAssertTrue(try v("v0.4.0") > v("0.3.9"))
        // Text ordering would put 0.10.0 below 0.9.0; numeric ordering must not.
        XCTAssertTrue(try v("0.10.0") > v("0.9.0"))
        XCTAssertTrue(try v("1.0.0") > v("0.99.99"))
        // A missing field counts as zero, so these are equal, not newer.
        XCTAssertTrue(try !(v("0.3") > v("0.3.0")))
        XCTAssertTrue(try !(v("0.3.0") > v("0.3")))
        // Never offer a downgrade or a re-install of the same build.
        XCTAssertTrue(try !(v("0.3.0") > v("0.3.0")))
        XCTAssertTrue(try !(v("0.2.9") > v("0.3.0")))

        XCTAssertNil(SemanticVersion("not-a-version"))
        XCTAssertNil(SemanticVersion(""))
        XCTAssertEqual(try v("v1.2.3").description, "1.2.3")
    }

    /// The updater must take the disk image out of a real release payload, and
    /// refuse one that points somewhere other than GitHub.
    func testReleaseParsingAcceptsGitHubDiskImagesOnly() throws {
        let good = """
        {"tag_name":"v0.4.0","body":"Notes here","html_url":"https://github.com/a/b/releases/tag/v0.4.0",
         "assets":[{"name":"notes.txt","browser_download_url":"https://github.com/a/b/x.txt"},
                   {"name":"FocusFlow-0.4.0.dmg","browser_download_url":"https://github.com/a/b/releases/download/v0.4.0/FocusFlow-0.4.0.dmg"}]}
        """
        let release = try XCTUnwrap(AvailableRelease.parse(Data(good.utf8)))
        XCTAssertEqual(release.version.description, "0.4.0")
        XCTAssertEqual(release.downloadURL.lastPathComponent, "FocusFlow-0.4.0.dmg")
        XCTAssertEqual(release.notes, "Notes here")

        // An asset hosted off GitHub must be ignored, leaving nothing to install.
        let offsite = """
        {"tag_name":"v0.5.0","assets":[{"name":"FocusFlow.dmg","browser_download_url":"https://elsewhere.example/FocusFlow.dmg"}]}
        """
        XCTAssertNil(AvailableRelease.parse(Data(offsite.utf8)))

        // Plain HTTP must be refused too.
        let insecure = """
        {"tag_name":"v0.5.0","assets":[{"name":"FocusFlow.dmg","browser_download_url":"http://github.com/a/b/FocusFlow.dmg"}]}
        """
        XCTAssertNil(AvailableRelease.parse(Data(insecure.utf8)))

        // A release with no disk image is not installable.
        let noDMG = """
        {"tag_name":"v0.5.0","assets":[{"name":"src.zip","browser_download_url":"https://github.com/a/b/src.zip"}]}
        """
        XCTAssertNil(AvailableRelease.parse(Data(noDMG.utf8)))
        XCTAssertNil(AvailableRelease.parse(Data("{}".utf8)))
    }

    /// The swap helper replaces the user's installed app, so it is run for
    /// real here against stand-in bundles: it must put the new build in place,
    /// and — more importantly — must leave the old one working if it cannot.
    func testUpdateSwapReplacesBundleAndRestoresOnFailure() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("swap-check-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }

        func makeBundle(at url: URL, marker: String) throws {
            try fm.createDirectory(at: url.appendingPathComponent("Contents"), withIntermediateDirectories: true)
            try marker.write(to: url.appendingPathComponent("Contents/marker.txt"), atomically: true, encoding: .utf8)
        }
        func marker(_ url: URL) -> String? {
            try? String(contentsOf: url.appendingPathComponent("Contents/marker.txt"), encoding: .utf8)
        }

        // --- the ordinary path: new build replaces old ---
        let work = root.appendingPathComponent("work")
        let incoming = root.appendingPathComponent("mount/FocusFlow.app")
        let target = root.appendingPathComponent("Applications/FocusFlow.app")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        try makeBundle(at: incoming, marker: "new")
        try makeBundle(at: target, marker: "old")

        // pid 1 is alive and never exits, so use this process's own pid after
        // it would already have passed: pid 0 is not a real process to wait on.
        let script = Updater.swapScript(pid: 999999, work: work.path, incoming: incoming.path,
                                        target: target.path, mount: root.appendingPathComponent("mount").path)
        let scriptURL = work.appendingPathComponent("swap.sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)

        // `open` is not meaningful in a test, so neutralise it with a stub
        // earlier on PATH; everything else runs for real.
        let stubs = root.appendingPathComponent("stubs")
        try fm.createDirectory(at: stubs, withIntermediateDirectories: true)
        for tool in ["open", "hdiutil"] {
            let stub = stubs.appendingPathComponent(tool)
            try "#!/bin/bash\nexit 0\n".write(to: stub, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        }

        func runSwap() throws -> Int32 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [scriptURL.path]
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = stubs.path + ":" + (env["PATH"] ?? "/usr/bin:/bin")
            process.environment = env
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        }

        XCTAssertEqual(try runSwap(), 0)
        XCTAssertEqual(marker(target), "new")
        // The helper cleans up after itself.
        XCTAssertTrue(!fm.fileExists(atPath: work.path))

        // --- the failure path: staging works, but putting the new bundle
        // in place does not. This is the branch that must put the old app
        // back; reaching it needs the second `mv` to fail specifically, so
        // `mv` is stubbed to fail on its second call.
        let work2 = root.appendingPathComponent("work2")
        try fm.createDirectory(at: work2, withIntermediateDirectories: true)
        try makeBundle(at: target, marker: "old-again")

        let counter = root.appendingPathComponent("mv-calls")
        let mvStub = stubs.appendingPathComponent("mv")
        try """
        #!/bin/bash
        count=$(cat "\(counter.path)" 2>/dev/null || echo 0)
        count=$((count + 1))
        echo "$count" > "\(counter.path)"
        # Fail only the call that moves the new bundle into place; the
        # restore that follows it must be allowed to succeed.
        if [ "$count" -eq 2 ]; then exit 1; fi
        exec /bin/mv "$@"
        """.write(to: mvStub, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: mvStub.path)

        let script2 = Updater.swapScript(pid: 999999, work: work2.path,
                                         incoming: incoming.path,
                                         target: target.path,
                                         mount: root.appendingPathComponent("mount").path)
        let scriptURL2 = work2.appendingPathComponent("swap.sh")
        try script2.write(to: scriptURL2, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptURL2.path]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = stubs.path + ":" + (env["PATH"] ?? "/usr/bin:/bin")
        process.environment = env
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()

        // The installed app must survive a failed update untouched — this is
        // the whole point: a broken update must not leave the user with no app.
        XCTAssertTrue(fm.fileExists(atPath: target.path))
        XCTAssertEqual(marker(target), "old-again")
    }

    /// The studio page can now be served from the web, which means the local
    /// bridge has to accept a cross-origin POST — but only from the hosts the
    /// studio is published on, and still only with a valid session token.
    @MainActor func testBridgeAcceptsWebStudioOriginOnly() async throws {
        let bridge = BrowserRecorderBridge()
        try await bridge.launch(openInBrowser: false)
        defer { bridge.stop() }

        let session = try XCTUnwrap(bridge.sessionURL)
        var components = URLComponents(url: session, resolvingAgainstBaseURL: false)!
        components.fragment = nil
        let base = components.url!
        let token = try XCTUnwrap(session.fragment).split(separator: "&").first.map(String.init) ?? ""
        let web = try XCTUnwrap(BrowserRecorderBridge.webStudioOrigins.first)

        func request(_ path: String, method: String, origin: String, token: String?, capture: String) -> URLRequest {
            var request = URLRequest(url: base.appendingPathComponent(path))
            request.httpMethod = method
            request.setValue(origin, forHTTPHeaderField: "Origin")
            if let token { request.setValue(token, forHTTPHeaderField: "X-FocusFlow-Token") }
            request.setValue(capture, forHTTPHeaderField: "X-FocusFlow-Capture")
            if method == "POST" { request.httpBody = Data() }
            return request
        }

        // A preflight carries no token, so it must be answered on origin alone.
        let (_, preflight) = try await URLSession.shared.data(
            for: request("begin", method: "OPTIONS", origin: web, token: nil, capture: UUID().uuidString))
        let preflightResponse = try XCTUnwrap(preflight as? HTTPURLResponse)
        XCTAssertEqual(preflightResponse.statusCode, 204)
        // Echoed back exactly, never "*", so no other site is covered by it.
        XCTAssertEqual(preflightResponse.value(forHTTPHeaderField: "Access-Control-Allow-Origin"), web)
        XCTAssertTrue((preflightResponse.value(forHTTPHeaderField: "Access-Control-Allow-Headers") ?? "")
            .localizedCaseInsensitiveContains("X-FocusFlow-Token"))

        // Chrome blocks a public page from reaching loopback unless the
        // preflight consents, so a PNA request must be answered in kind.
        var pna = request("begin", method: "OPTIONS", origin: web, token: nil, capture: UUID().uuidString)
        pna.setValue("true", forHTTPHeaderField: "Access-Control-Request-Private-Network")
        let (_, pnaResponse) = try await URLSession.shared.data(for: pna)
        XCTAssertEqual((pnaResponse as? HTTPURLResponse)?.statusCode, 204)
        XCTAssertEqual((pnaResponse as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Access-Control-Allow-Private-Network"), "true")

        // A preflight from anywhere else is refused outright.
        let (_, hostile) = try await URLSession.shared.data(
            for: request("begin", method: "OPTIONS", origin: "https://evil.invalid", token: nil, capture: UUID().uuidString))
        XCTAssertEqual((hostile as? HTTPURLResponse)?.statusCode, 403)
        XCTAssertNil((hostile as? HTTPURLResponse)?.value(forHTTPHeaderField: "Access-Control-Allow-Origin"))

        // The real POST from the published studio, with the session token.
        let capture = UUID().uuidString
        let (_, accepted) = try await URLSession.shared.data(
            for: request("begin", method: "POST", origin: web, token: token, capture: capture))
        let acceptedResponse = try XCTUnwrap(accepted as? HTTPURLResponse)
        XCTAssertEqual(acceptedResponse.statusCode, 200)
        XCTAssertEqual(acceptedResponse.value(forHTTPHeaderField: "Access-Control-Allow-Origin"), web)

        // The token remains the thing that matters: the right origin without
        // it gets nowhere, which is what protects a casual visitor to the site.
        let (_, noToken) = try await URLSession.shared.data(
            for: request("begin", method: "POST", origin: web, token: "not-the-token", capture: UUID().uuidString))
        XCTAssertEqual((noToken as? HTTPURLResponse)?.statusCode, 403)

        // And a valid token from an unlisted origin is still refused, so a
        // leaked token alone does not open the bridge to any page.
        let (_, wrongOrigin) = try await URLSession.shared.data(
            for: request("begin", method: "POST", origin: "https://evil.invalid", token: token, capture: UUID().uuidString))
        XCTAssertEqual((wrongOrigin as? HTTPURLResponse)?.statusCode, 403)

        // The launch URL differs by mode: served locally it needs only the
        // token, but the hosted page cannot infer the port from its own
        // origin, so the port travels in the fragment — never the query, which
        // a web server would see.
        let localURL = try XCTUnwrap(bridge.sessionURL)
        XCTAssertTrue(localURL.absoluteString.hasPrefix("http://127.0.0.1:"))
        XCTAssertTrue(!(localURL.fragment ?? "").contains("port="))

        try await bridge.launch(openInBrowser: false, hosted: true)
        let webURL = try XCTUnwrap(bridge.sessionURL)
        XCTAssertTrue(webURL.absoluteString.hasPrefix(BrowserRecorderBridge.webStudioURL))
        XCTAssertTrue((webURL.fragment ?? "").contains("port="))
        XCTAssertTrue((webURL.fragment ?? "").hasPrefix(token))
        XCTAssertNil(webURL.query)
        // The public site's URL handoff must force the bundled loopback
        // studio even when the user normally prefers the hosted version.
        let previousPreference = BrowserRecorderBridge.usesWebStudio
        BrowserRecorderBridge.usesWebStudio = true
        defer { BrowserRecorderBridge.usesWebStudio = previousPreference }
        try await bridge.launch(openInBrowser: false, hosted: false)
        let handoffURL = try XCTUnwrap(bridge.sessionURL)
        XCTAssertTrue(handoffURL.absoluteString.hasPrefix("http://127.0.0.1:"))
        XCTAssertTrue(!(handoffURL.fragment ?? "").contains("port="))
    }

    /// Keys go to the Keychain, so the round trip and the shape checks that
    /// run before any network call are worth pinning down.
    func testAPIKeyStorageAndValidation() throws {
        // Shape checks catch an obviously wrong paste without a network call.
        XCTAssertNil(AIProvider.anthropic.looksPlausible("sk-ant-" + String(repeating: "x", count: 40)))
        XCTAssertNil(AIProvider.openai.looksPlausible("sk-" + String(repeating: "x", count: 40)))
        // Gemini keys have no fixed prefix, so only length and spacing apply.
        XCTAssertNil(AIProvider.gemini.looksPlausible(String(repeating: "x", count: 39)))

        XCTAssertTrue(AIProvider.anthropic.looksPlausible("") != nil)
        XCTAssertTrue(AIProvider.anthropic.looksPlausible("short") != nil)
        // A wrong-provider key must be caught rather than sent off and rejected.
        XCTAssertTrue(AIProvider.anthropic.looksPlausible("sk-" + String(repeating: "x", count: 40)) != nil)
        // A pasted key with a stray space is a common copy error.
        XCTAssertTrue(AIProvider.openai.looksPlausible("sk-" + String(repeating: "x", count: 20) + " tail") != nil)

        // Round trip through the Keychain, on a provider left clean after.
        let provider = AIProvider.gemini
        let existing = Credentials.key(for: provider)
        defer {
            if let existing { Credentials.store(existing, for: provider) } else { Credentials.remove(provider) }
        }

        let secret = "focusflow-test-" + UUID().uuidString
        XCTAssertTrue(Credentials.store(secret, for: provider))
        XCTAssertEqual(Credentials.key(for: provider), secret)
        XCTAssertTrue(Credentials.hasKey(for: provider))

        // Storing again must replace rather than duplicate.
        let second = "focusflow-test-" + UUID().uuidString
        XCTAssertTrue(Credentials.store(second, for: provider))
        XCTAssertEqual(Credentials.key(for: provider), second)

        // Surrounding whitespace is a paste artefact, not part of the key.
        XCTAssertTrue(Credentials.store("  \(second)  ", for: provider))
        XCTAssertEqual(Credentials.key(for: provider), second)

        XCTAssertTrue(Credentials.remove(provider))
        XCTAssertNil(Credentials.key(for: provider))
        XCTAssertTrue(!Credentials.hasKey(for: provider))
        // Removing what is not there is not an error.
        XCTAssertTrue(Credentials.remove(provider))

        // Each provider is stored separately.
        XCTAssertTrue(Credentials.store("alpha-key-alpha-key-alpha", for: .openai))
        XCTAssertTrue(Credentials.store("beta-key-beta-key-beta-ke", for: .gemini))
        XCTAssertEqual(Credentials.key(for: .openai), "alpha-key-alpha-key-alpha")
        XCTAssertEqual(Credentials.key(for: .gemini), "beta-key-beta-key-beta-ke")
        Credentials.remove(.openai)
        XCTAssertEqual(Credentials.key(for: .gemini), "beta-key-beta-key-beta-ke")
        Credentials.remove(.gemini)
    }

    /// The split button used to stay enabled while doing nothing, which reads
    /// as broken. Its guard and the button's condition must be the same test.
    @MainActor func testSplitIsOfferedOnlyWhenItCanAct() {
        let model = EditorModel()
        model.duration = 10
        model.trimEnd = 10
        model.segments = [EditSegment(kind: .zoom, start: 2, duration: 4, intensity: 1.5, x: 0.5, y: 0.5)]
        model.selectedSegmentID = model.segments[0].id

        // Playhead outside the segment: not offered, and does nothing if called.
        model.playhead = 0.5
        XCTAssertTrue(!model.canSplitSelected)
        model.splitSelected()
        XCTAssertEqual(model.segments.count, 1)

        // Hard against an edge is still no room to split.
        model.playhead = 2.05
        XCTAssertTrue(!model.canSplitSelected)
        model.splitSelected()
        XCTAssertEqual(model.segments.count, 1)

        // Inside, with room either side.
        model.playhead = 4
        XCTAssertTrue(model.canSplitSelected)
        model.splitSelected()
        XCTAssertEqual(model.segments.count, 2)

        // Nothing selected is nothing to split.
        model.selectedSegmentID = nil
        XCTAssertTrue(!model.canSplitSelected)

        // Where the video starts and ends, dragged to a time rather than
        // taken from the playhead. Each end stops short of the other, and
        // neither leaves the recording.
        model.resetTrim()
        model.setTrimStart(to: 3.5)
        XCTAssertEqual(model.trimStart, 3.5, accuracy: 0.0001)
        XCTAssertEqual(model.outputDuration, 6.5, accuracy: 0.0001)
        model.setTrimEnd(to: 7)
        XCTAssertEqual(model.trimEnd, 7, accuracy: 0.0001)

        // Dragged past each other, or off either end.
        model.setTrimStart(to: 9)
        XCTAssertEqual(model.trimStart, 6.9, accuracy: 0.0001)
        model.setTrimEnd(to: 0)
        XCTAssertEqual(model.trimEnd, 7, accuracy: 0.0001)
        model.setTrimStart(to: -4)
        XCTAssertEqual(model.trimStart, 0, accuracy: 0.0001)
        model.setTrimEnd(to: 99)
        XCTAssertEqual(model.trimEnd, 10, accuracy: 0.0001)

        // The buttons are the same thing from the playhead.
        model.playhead = 2
        model.setTrimStart()
        XCTAssertEqual(model.trimStart, 2, accuracy: 0.0001)
        model.resetTrim()
        XCTAssertEqual(model.trimStart, 0, accuracy: 0.0001)
        XCTAssertEqual(model.trimEnd, 10, accuracy: 0.0001)
    }

    /// Dragging an effect along the timeline, and by its ends. The sums were
    /// measured against the block itself, which moves with the drag, so a
    /// block jumped once and then stuck wherever the pointer had got to.
    func testTimelineDragFollowsThePointer() {
        let segment = EditSegment(kind: .zoom, start: 4, duration: 2, intensity: 1.6, x: 0.5, y: 0.5)
        let duration = 20.0

        // Picked up two thirds of the way along and carried: the point under
        // the pointer stays under the pointer, however far it travels.
        let grab = 1.3
        for pointer in stride(from: 1.4, through: 18.0, by: 0.7) {
            let start = TimelineDrag.moved(origin: segment, pointer: pointer, grabbedAt: grab, duration: duration)
            XCTAssertEqual(start, pointer - grab, accuracy: 0.0001)
        }

        // It cannot be carried out of the recording at either end.
        XCTAssertEqual(TimelineDrag.moved(origin: segment, pointer: 0, grabbedAt: grab, duration: duration), 0, accuracy: 0.0001)
        XCTAssertEqual(TimelineDrag.moved(origin: segment, pointer: 40, grabbedAt: grab, duration: duration), 18, accuracy: 0.0001)

        // Dragged by the front: the edge goes to the pointer, the back stays.
        let front = TimelineDrag.resized(origin: segment, leading: true, pointer: 2.5, duration: duration)
        XCTAssertEqual(front.start, 2.5, accuracy: 0.0001)
        XCTAssertEqual(front.start + front.length, segment.end, accuracy: 0.0001)

        // Dragged by the back: the front stays, the length follows.
        let back = TimelineDrag.resized(origin: segment, leading: false, pointer: 9, duration: duration)
        XCTAssertEqual(back.start, 4, accuracy: 0.0001)
        XCTAssertEqual(back.length, 5, accuracy: 0.0001)

        // Neither end can be pushed through the other, or off the recording.
        let crossed = TimelineDrag.resized(origin: segment, leading: true, pointer: 12, duration: duration)
        XCTAssertEqual(crossed.start, segment.end - 0.1, accuracy: 0.0001)
        XCTAssertGreaterThan(crossed.length, 0.09)
        let backwards = TimelineDrag.resized(origin: segment, leading: false, pointer: 1, duration: duration)
        XCTAssertGreaterThan(backwards.length, 0.09)
        let beforeStart = TimelineDrag.resized(origin: segment, leading: true, pointer: -5, duration: duration)
        XCTAssertEqual(beforeStart.start, 0, accuracy: 0.0001)
        let pastEnd = TimelineDrag.resized(origin: segment, leading: false, pointer: 99, duration: duration)
        XCTAssertEqual(pastEnd.start + pastEnd.length, duration, accuracy: 0.0001)

        // A press on the video track is one thing or the other, decided where
        // it lands: near an end it moves that end, anywhere else it scrubs.
        // One gesture, so there is nothing for two to disagree about.
        func press(_ x: Double, from: Double = 4, to: Double = 16) -> TimelineDrag.Grab {
            TimelineDrag.grab(at: x, trimStart: from, trimEnd: to, duration: 20, width: 400, radius: 13)
        }
        XCTAssertEqual(press(80), .start)            // the start sits at 80
        XCTAssertEqual(press(88), .start)            // and a little to its right
        XCTAssertEqual(press(320), .end)             // the end sits at 320
        XCTAssertEqual(press(200), .scrub)           // the middle is a scrub
        XCTAssertEqual(press(110), .scrub)           // past the grab radius
        // Where the two are on top of each other, the nearer one wins and
        // neither is ambiguous.
        XCTAssertEqual(press(100, from: 5, to: 5.4), .start)
        XCTAssertEqual(press(112, from: 5, to: 5.4), .end)
        // Nothing to grab on an empty timeline.
        XCTAssertEqual(TimelineDrag.grab(at: 40, trimStart: 0, trimEnd: 0, duration: 0, width: 400, radius: 13), .scrub)
    }

    /// A custom ratio has to produce the shape asked for, at a sane pixel
    /// count, with even dimensions — and never a degenerate canvas.
    func testCustomAspectRatioGeometry() {
        func canvas(_ w: Double, _ h: Double) -> CGSize {
            CanvasRatio.custom.size(for: CGSize(width: 1920, height: 1080),
                                    custom: CGSize(width: w, height: h))
        }

        // Ultra-wide: capped on the long side, aspect preserved.
        let wide = canvas(21, 9)
        XCTAssertEqual(wide.width, 1920)
        XCTAssertEqual(Double(wide.width / wide.height), 21.0 / 9.0, accuracy: 0.01)

        // Tall: the limit applies to the height instead.
        let tall = canvas(4, 5)
        XCTAssertEqual(tall.height, 1920)
        XCTAssertEqual(Double(tall.width / tall.height), 4.0 / 5.0, accuracy: 0.01)

        // Square sits at the limit both ways.
        let square = canvas(1, 1)
        XCTAssertEqual(square.width, 1920)
        XCTAssertEqual(square.height, 1920)

        // Decimal cinema ratios must work, not just whole numbers.
        let cinema = canvas(2.39, 1)
        XCTAssertEqual(Double(cinema.width / cinema.height), 2.39, accuracy: 0.01)

        // Every result must be even — H.264 rejects odd dimensions.
        for (w, h) in [(21.0, 9.0), (4.0, 5.0), (2.39, 1.0), (3.0, 2.0), (1.0, 3.7), (16.0, 10.0)] {
            let size = canvas(w, h)
            XCTAssertEqual(Int(size.width) % 2, 0)
            XCTAssertEqual(Int(size.height) % 2, 0)
            XCTAssertGreaterThan(size.width, 0)
            XCTAssertGreaterThan(size.height, 0)
        }

        // A nonsense ratio must fall back rather than produce a zero canvas.
        for bad in [CGSize(width: 0, height: 10), CGSize(width: 10, height: 0), CGSize(width: -4, height: 3)] {
            let size = CanvasRatio.custom.size(for: CGSize(width: 1920, height: 1080), custom: bad)
            XCTAssertGreaterThan(size.width, 0)
            XCTAssertGreaterThan(size.height, 0)
        }
        let missing = CanvasRatio.custom.size(for: CGSize(width: 1920, height: 1080), custom: nil)
        XCTAssertGreaterThan(missing.width, 0)
        XCTAssertGreaterThan(missing.height, 0)

        // The fixed ratios must be untouched by the new case.
        XCTAssertEqual(CanvasRatio.portrait.size(for: .zero), CGSize(width: 1080, height: 1920))
        XCTAssertEqual(CanvasRatio.square.size(for: .zero), CGSize(width: 1080, height: 1080))
        XCTAssertEqual(CanvasRatio.classic.size(for: .zero), CGSize(width: 1440, height: 1080))

        // And a project written before custom ratios existed still decodes.
        let legacy = """
        {"videoPath":"/tmp/a.mp4","segments":[],"background":"ocean","ratio":"9:16",
         "padding":7,"cornerRadius":18,"shadow":20,"cursorSize":1,"clickEffects":true}
        """
        let document = try? JSONDecoder().decode(ProjectDocument.self, from: Data(legacy.utf8))
        XCTAssertEqual(document?.ratio, .portrait)
        XCTAssertNil(document?.customRatioWidth)
    }

    /// Each grade must actually change the frame, in the direction its name
    /// promises, and must leave the background behind the frame alone.
    func testColourGradesAlterTheFrameOnly() throws {
        let renderer = FocusFlowCompositor(), context = CIContext()
        let canvas = CGRect(x: 0, y: 0, width: 480, height: 270)
        // A mid saturated colour so saturation and tint both show.
        let source = CIImage(color: CIColor(red: 0.6, green: 0.35, blue: 0.3)).cropped(to: canvas)

        var settings = ExportSettings(background: .graphite, canvasSize: canvas.size, padding: 12, cornerRadius: 0, shadow: 0, segments: [], pointerSamples: [], clicks: [], keystrokes: [], cursorSize: 1, clickEffects: false, showKeystrokes: false, cameraURL: nil, showCamera: false, cameraSize: 0.2, cameraX: 0.8, cameraY: 0.8, cameraCornerRadius: 10, cameraShape: .circle)
        settings.showCursor = false
        settings.customBackground = CustomBackground(kind: .solid, top: RGBColor(r: 0, g: 1, b: 0))

        func render(_ grade: GradeSettings) throws -> [UInt8] {
            settings.grade = grade
            let image = try XCTUnwrap(context.createCGImage(renderer.renderFrame(source: source, time: 0, settings: settings), from: canvas))
            return pixels(image)
        }

        // Centre of the frame, well inside the padding.
        func centre(_ data: [UInt8]) -> [Int] {
            let offset = ((270 / 2) * 480 + 240) * 4
            return [Int(data[offset]), Int(data[offset + 1]), Int(data[offset + 2])]
        }
        // Top-left corner is background, which the grade must not touch.
        func corner(_ data: [UInt8]) -> [Int] { [Int(data[0]), Int(data[1]), Int(data[2])] }

        let plain = try render(GradeSettings())
        let plainCentre = centre(plain), plainCorner = corner(plain)
        // The background is the solid green we asked for.
        XCTAssertGreaterThan(plainCorner[1], 180)

        // Noir strips colour: the channels converge.
        let noir = try render(GradeSettings(grade: .noir))
        let n = centre(noir)
        XCTAssertLessThan(abs(n[0] - n[1]) + abs(n[1] - n[2]), 24)
        // And it leaves the background alone.
        XCTAssertEqual(corner(noir), plainCorner)

        // Vivid pushes saturation the other way: channels spread further apart.
        let vivid = centre(try render(GradeSettings(grade: .vivid)))
        let plainSpread = abs(plainCentre[0] - plainCentre[2])
        XCTAssertGreaterThan(abs(vivid[0] - vivid[2]), plainSpread)

        // Frost and Golden pull in opposite directions on blue vs red.
        let frost = centre(try render(GradeSettings(grade: .frost)))
        let golden = centre(try render(GradeSettings(grade: .golden)))
        XCTAssertGreaterThan(frost[2] - golden[2], 6)

        // Exposure lifts, and its absence does not.
        let bright = centre(try render(GradeSettings(grade: .none, exposure: 1.2)))
        XCTAssertGreaterThan(bright[0], plainCentre[0])
        let dark = centre(try render(GradeSettings(grade: .none, exposure: -1.2)))
        XCTAssertLessThan(dark[0], plainCentre[0])

        // A vignette darkens the frame's edge relative to its middle.
        let vignetted = try render(GradeSettings(grade: .none, vignette: 1))
        let edgeOffset = ((270 / 2) * 480 + 40) * 4
        let edge = Int(vignetted[edgeOffset])
        XCTAssertLessThan(edge, centre(vignetted)[0])

        // An identity grade must be a true no-op.
        XCTAssertTrue(GradeSettings().isIdentity)
        XCTAssertTrue(!GradeSettings(grade: .noir).isIdentity)
        XCTAssertEqual(centre(try render(GradeSettings())), plainCentre)
    }

    /// Every bundled background must resolve to a real, decodable file, and a
    /// reference saved by an older build must still find it now the files are
    /// JPEG rather than PNG.
    func testBundledBackgroundsResolveAndDecode() throws {
        XCTAssertTrue(!BuiltInBackground.allCases.isEmpty)
        for background in BuiltInBackground.allCases {
            let url = try XCTUnwrap(background.url)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
            // Decodable, not merely present.
            XCTAssertTrue(CIImage(contentsOf: url) != nil)

            // The reference stored in projects still spells ".png".
            let resolved = try XCTUnwrap(BuiltInBackground.url(for: background.reference))
            XCTAssertEqual(resolved, url)
            // And the current spelling resolves too.
            let asJPEG = try XCTUnwrap(BuiltInBackground.url(for: "builtin:\(background.rawValue).jpg"))
            XCTAssertEqual(asJPEG, url)
        }
        XCTAssertNil(BuiltInBackground.url(for: "builtin:not-a-background.png"))
        XCTAssertNil(BuiltInBackground.url(for: "/some/local/file.png"))
    }

    /// Scroll blur has to come from the frames themselves, because a scroll
    /// moves the page while the viewport stays put — the camera path cannot
    /// see it. So: moving content must soften, still content must not.
    func testScrollBlurSoftensMovingContentOnly() throws {
        let renderer = FocusFlowCompositor(), context = CIContext()
        let canvas = CGRect(x: 0, y: 0, width: 320, height: 240)

        // A hard horizontal edge, which is what a scroll smears.
        func striped(offsetY: CGFloat) -> CIImage {
            let dark = CIImage(color: CIColor(red: 0.05, green: 0.05, blue: 0.05)).cropped(to: canvas)
            let band = CIImage(color: CIColor(red: 0.95, green: 0.95, blue: 0.95))
                .cropped(to: CGRect(x: 0, y: 120 + offsetY, width: 320, height: 60))
            return band.composited(over: dark)
        }

        var settings = ExportSettings(background: .graphite, canvasSize: canvas.size, padding: 0, cornerRadius: 0, shadow: 0, segments: [], pointerSamples: [], clicks: [], keystrokes: [], cursorSize: 1, clickEffects: false, showKeystrokes: false, cameraURL: nil, showCamera: false, cameraSize: 0.2, cameraX: 0.8, cameraY: 0.8, cameraCornerRadius: 10, cameraShape: .circle)
        settings.showCursor = false
        settings.motion.ambientGraphics = false
        settings.motion.automaticMotionBlur = false
        settings.motion.scrollBlur = true
        settings.motion.scrollBlurStrength = 1

        /// Feeds frames through the compositor's own blending path in order.
        func run(offsets: [CGFloat], settings: ExportSettings) throws -> [UInt8] {
            let compositor = FocusFlowCompositor()
            var last: CIImage = striped(offsetY: 0)
            for (index, offset) in offsets.enumerated() {
                let blended = compositor.blendForTesting(striped(offsetY: offset),
                                                         at: Double(index) / 30.0,
                                                         settings: settings)
                last = blended
            }
            let image = try XCTUnwrap(context.createCGImage(last, from: canvas))
            return pixels(image)
        }

        // How many rows are neither black nor white — the smeared edge.
        func transitional(_ data: [UInt8]) -> Int {
            var count = 0
            for row in 0..<240 {
                let v = Int(data[(row * 320 + 160) * 4])
                if v > 40 && v < 215 { count += 1 }
            }
            return count
        }

        // Content moving 12px per frame.
        let moving = try run(offsets: [0, 12, 24, 36], settings: settings)
        // The same content, standing still.
        let still = try run(offsets: [0, 0, 0, 0], settings: settings)

        XCTAssertGreaterThan(transitional(moving), transitional(still) + 4)

        // Turned off, moving content must be as crisp as still content.
        var off = settings
        off.motion.scrollBlur = false
        let movingUnblurred = try run(offsets: [0, 12, 24, 36], settings: off)
        XCTAssertLessThan(transitional(movingUnblurred), transitional(moving))

        // Strength must actually scale it.
        var weak = settings
        weak.motion.scrollBlurStrength = 0.15
        let gentle = try run(offsets: [0, 12, 24, 36], settings: weak)
        XCTAssertLessThanOrEqual(transitional(gentle), transitional(moving))

        // Where the recording says the wheel turned, the shutter opens; a
        // frame of the recording mixed into another frame of it is a ghost
        // over text that was sharp, and it is not spent anywhere else.
        var reported = settings
        reported.scrollEvents = (0..<4).map { ScrollEvent(time: Double($0) / 30) }
        XCTAssertGreaterThan(transitional(try run(offsets: [0, 12, 24, 36], settings: reported)),
                             transitional(still) + 4)
        var elsewhere = settings
        elsewhere.scrollEvents = [ScrollEvent(time: 5)]
        XCTAssertLessThan(transitional(try run(offsets: [0, 12, 24, 36], settings: elsewhere)),
                          transitional(moving))

        // A jump in time is a seek: the previous frame is unrelated and must
        // not be smeared into this one.
        let compositor = FocusFlowCompositor()
        _ = compositor.blendForTesting(striped(offsetY: 0), at: 0, settings: settings)
        let afterSeek = compositor.blendForTesting(striped(offsetY: 60), at: 9, settings: settings)
        let seekPixels = pixels(try XCTUnwrap(context.createCGImage(afterSeek, from: canvas)))
        XCTAssertLessThan(transitional(seekPixels), transitional(moving))
    }

    /// Each 3D move must actually displace the frame, in its own way, settle
    /// when it is done, and cost nothing when switched off.
    func testCameraMovesTiltAndSettle() throws {
        let renderer = FocusFlowCompositor(), context = CIContext()
        let canvas = CGRect(x: 0, y: 0, width: 400, height: 240)
        var source = CIImage(color: CIColor(red: 0.95, green: 0.95, blue: 0.95)).cropped(to: canvas)

        var settings = ExportSettings(background: .graphite, canvasSize: canvas.size, padding: 6, cornerRadius: 0, shadow: 0, segments: [], pointerSamples: [], clicks: [], keystrokes: [], cursorSize: 1, clickEffects: false, showKeystrokes: false, cameraURL: nil, showCamera: false, cameraSize: 0.2, cameraX: 0.8, cameraY: 0.8, cameraCornerRadius: 10, cameraShape: .circle)
        settings.showCursor = false
        settings.motion.ambientGraphics = false
        settings.motion.scrollBlur = false
        settings.trimStart = 0
        settings.trimEnd = 8
        settings.customBackground = CustomBackground(kind: .solid, top: RGBColor(r: 0, g: 0, b: 0))

        func frame(_ time: Double) throws -> [UInt8] {
            let image = try XCTUnwrap(context.createCGImage(renderer.renderFrame(source: source, time: time, settings: settings), from: canvas))
            return pixels(image)
        }
        /// How many pixels along a row belong to the frame rather than the
        /// black background — a cheap read of where the frame's edges are.
        func litInRow(_ data: [UInt8], row: Int) -> Int {
            var count = 0
            for column in 0..<400 where Int(data[(row * 400 + column) * 4]) > 110 { count += 1 }
            return count
        }

        settings.cameraMove = CameraMoveSettings(move: .none)
        let flatTop = litInRow(try frame(0.3), row: 30)
        let flatBottom = litInRow(try frame(0.3), row: 210)
        // Square to the viewer, so top and bottom are the same width.
        XCTAssertEqual(flatTop, flatBottom)

        // Glide leans, so one end of the frame is narrower than the other.
        settings.cameraMove = CameraMoveSettings(move: .glide, tilt: 1, amount: 0.5, focusBlur: 0, duration: 4, holds: false)
        let glideTop = litInRow(try frame(0.3), row: 30)
        let glideBottom = litInRow(try frame(0.3), row: 210)
        XCTAssertTrue(glideTop != glideBottom || glideBottom != flatBottom)

        // Unfold starts leaning and ends square.
        settings.cameraMove = CameraMoveSettings(move: .unfold, tilt: 1, amount: 0.5, focusBlur: 0, duration: 2, holds: false)
        let openingEarly = litInRow(try frame(0.05), row: 120)
        let openedLate = litInRow(try frame(1.98), row: 120)
        XCTAssertTrue(openingEarly != openedLate)

        // Pull back starts larger than it finishes.
        settings.cameraMove = CameraMoveSettings(move: .pullBack, tilt: 0.3, amount: 1, focusBlur: 0, duration: 2, holds: false)
        let close = litInRow(try frame(0.05), row: 120)
        let far = litInRow(try frame(1.95), row: 120)
        XCTAssertGreaterThan(close, far)

        // Once settled it must match the untouched frame, not drift.
        settings.cameraMove = CameraMoveSettings(move: .unfold, tilt: 1, amount: 0.5, focusBlur: 0, duration: 1, holds: false)
        let settled = litInRow(try frame(5), row: 120)
        settings.cameraMove = CameraMoveSettings(move: .none)
        XCTAssertEqual(settled, litInRow(try frame(5), row: 120))

        XCTAssertTrue(!CameraMoveSettings().isActive)
        XCTAssertTrue(CameraMoveSettings(move: .glide).isActive)

        // Spreading across the clip is the default, because a move that
        // played once from the start left the frame untouched everywhere
        // else — choosing one and looking at the middle showed nothing.
        XCTAssertTrue(CameraMoveSettings().holds)
        settings.cameraMove = CameraMoveSettings(move: .glide, tilt: 1, amount: 0.5, focusBlur: 0)
        let spreadEarly = litInRow(try frame(0.3), row: 30)
        let spreadLate = litInRow(try frame(7.6), row: 30)
        // Still leaning late in the clip, where a one-shot would have settled.
        XCTAssertTrue(spreadEarly != flatTop || spreadLate != flatTop)
        settings.cameraMove = CameraMoveSettings(move: .none)
        XCTAssertEqual(litInRow(try frame(7.6), row: 30), flatTop)

        // Focus blur must soften the edge that recedes, not the near one.
        // Glide leans its right edge away, so that side should be the soft one.
        settings.cameraMove = CameraMoveSettings(move: .glide, tilt: 1, amount: 0, focusBlur: 1, duration: 4, holds: false)
        let focused = try frame(0.3)
        func edgeSharpness(_ data: [UInt8], column: Int) -> Int {
            // Largest jump between neighbouring rows down a column: a sharp
            // boundary gives a big one, a blurred boundary a small one.
            var largest = 0
            for row in 1..<239 {
                let a = Int(data[(row * 400 + column) * 4])
                let b = Int(data[((row + 1) * 400 + column) * 4])
                largest = max(largest, abs(a - b))
            }
            return largest
        }
        XCTAssertGreaterThan(edgeSharpness(focused, column: 40), edgeSharpness(focused, column: 360))

        // Static poses now move the recording inside its fixed opening.
        // A patterned source makes the internal motion visible in pixels.
        source = CIImage.empty().applyingFilter("CICheckerboardGenerator", parameters: [
            "inputCenter": CIVector(x: 0, y: 0),
            "inputColor0": CIColor(red: 0.95, green: 0.95, blue: 0.95),
            "inputColor1": CIColor(red: 0.12, green: 0.12, blue: 0.12),
            "inputWidth": 8,
            "inputSharpness": 1,
        ]).cropped(to: canvas)
        func picture(_ place: (inout CameraMoveSettings) -> Void) throws -> [UInt8] {
            var move = CameraMoveSettings(move: .none, focusBlur: 0)
            move.blur = .none
            place(&move)
            settings.cameraMove = move
            return try frame(0.3)
        }
        let squarePicture = try picture { _ in }
        func differs(_ place: (inout CameraMoveSettings) -> Void) throws -> Bool {
            let image = try picture(place)
            var total = 0.0
            for index in stride(from: 0, to: image.count, by: 41) {
                total += abs(Double(image[index]) - Double(squarePicture[index]))
            }
            return total / Double(image.count / 41) > 0.5
        }
        XCTAssertTrue(try differs { $0.pitch = 1 })
        XCTAssertTrue(try differs { $0.pitch = -1 })
        XCTAssertTrue(try differs { $0.yaw = 1 })
        XCTAssertTrue(try differs { $0.roll = 0.6 })
        XCTAssertTrue(try differs { $0.panY = 0.5 })
        XCTAssertTrue(try differs { $0.panX = 0.5 })
        XCTAssertTrue(try differs { $0.zoom = 1.5 })
        // And standing it square again is the frame it started as.
        XCTAssertTrue(!(try differs { $0.zoom = 1 }))

        // Each blur softens, and none of them is the same picture as another.
        func blurred(_ style: FrameBlur) throws -> [UInt8] {
            var move = CameraMoveSettings(move: .none, focusBlur: 1)
            move.blur = style
            move.yaw = 0.6                       // a lean, so depth has an axis
            settings.cameraMove = move
            return try frame(0.3)
        }
        let plain = try blurred(.none)
        var seen: [[UInt8]] = [plain]
        for style in [FrameBlur.depth, .radial, .directional, .tiltShift] {
            let image = try blurred(style)
            func difference(_ other: [UInt8]) -> Double {
                var total = 0.0
                for index in stride(from: 0, to: image.count, by: 41) { total += abs(Double(image[index]) - Double(other[index])) }
                return total / Double(image.count / 41)
            }
            if difference(plain) < 0.4 { XCTFail("\(style.rawValue) blur left the frame untouched") }
            for earlier in seen where difference(earlier) < 0.4 {
                XCTFail("\(style.rawValue) blur renders the same as another style")
            }
            seen.append(image)
        }

        // A tilt shift's sharp band is sharper than the ground above it.
        var band = CameraMoveSettings(move: .none, focusBlur: 1)
        band.blur = .tiltShift
        band.blurFocus = 0.5
        band.blurBand = 0.2
        settings.cameraMove = band
        let shifted = try frame(0.3)
        func rowDetail(_ data: [UInt8], row: Int) -> Int {
            var largest = 0
            for column in 1..<399 {
                let a = Int(data[(row * 400 + column) * 4]), b = Int(data[(row * 400 + column + 1) * 4])
                largest = max(largest, abs(a - b))
            }
            return largest
        }
        XCTAssertGreaterThan(rowDetail(shifted, row: 120), rowDetail(shifted, row: 20))

        // A 3D camera laid on the timeline is a move for a few seconds, not
        // a place the frame is parked: square before it, leaning during it,
        // square again after.
        settings.cameraMove = CameraMoveSettings(move: .none, focusBlur: 0)
        settings.cameraMove.blur = .none
        var lean = EditSegment(kind: .perspective, start: 2, duration: 3, intensity: 1,
                               x: 0.5, y: 0.5, transition: 0.6, curve: .smooth)
        lean.pose = FramePose(pitch: 0.5, yaw: 0.6, zoom: 1.1)
        lean.sweeps = false
        settings.segments = [lean]
        let before = try frame(0.5), during = try frame(3.5), after = try frame(7.5)
        func apart(_ a: [UInt8], _ b: [UInt8]) -> Double {
            var total = 0.0
            for index in stride(from: 0, to: a.count, by: 41) { total += abs(Double(a[index]) - Double(b[index])) }
            return total / Double(a.count / 41)
        }
        XCTAssertGreaterThan(apart(before, during), 1)
        XCTAssertLessThan(apart(before, after), 0.5)

        // It animates rather than snapping: part way into the lean-in the
        // frame is somewhere between square and the full pose.
        let easing = try frame(2.3)
        XCTAssertGreaterThan(apart(before, easing), 0.3)
        XCTAssertGreaterThan(apart(during, easing), 0.3)

        // Sweeping travels through the pose, so the two halves differ.
        var swept = lean
        swept.sweeps = true
        settings.segments = [swept]
        XCTAssertGreaterThan(apart(try frame(2.6), try frame(4.4)), 1)

        // And the stance it is all built on: neutral outside, leaning inside.
        XCTAssertTrue(MotionEngine.stance(at: 0.5, segments: [lean]).isNeutral)
        XCTAssertTrue(!MotionEngine.stance(at: 3.5, segments: [lean]).isNeutral)
        XCTAssertTrue(MotionEngine.stance(at: 9, segments: [lean]).isNeutral)
        // Two at once are both departures from square, so they add.
        var second = lean
        second.pose = FramePose(yaw: 0.2)
        let both = MotionEngine.stance(at: 3.5, segments: [lean, second]).pose
        XCTAssertGreaterThan(both.yaw, MotionEngine.stance(at: 3.5, segments: [lean]).pose.yaw)
        settings.segments = []

        // A project written before any of this still opens, and gets the
        // defaults rather than a failure.
        let legacyMove = Data("{\"move\":\"Glide across\",\"tilt\":0.8,\"amount\":0.4,\"focusBlur\":0.2,\"duration\":3,\"curve\":\"Silky\",\"holds\":true}".utf8)
        let restored = try JSONDecoder().decode(CameraMoveSettings.self, from: legacyMove)
        XCTAssertEqual(restored.move, .glide)
        XCTAssertEqual(restored.tilt, 0.8, accuracy: 0.0001)
        XCTAssertEqual(restored.zoom, 1, accuracy: 0.0001)
        XCTAssertEqual(restored.blur, .depth)
        XCTAssertTrue(!restored.isPlaced)
    }

    /// Typing follow has to find runs of typing, anchor each at the insertion
    /// point, travel right with the keys, stay inside the frame, and leave a
    /// recording with no typing completely alone.
    func testTypingFollowTracksRunsAndStaysInFrame() {
        var settings = TypingFollowSettings()
        settings.gap = 1.0
        settings.advancePerKey = 0.01
        settings.maxTravel = 0.4

        // Two bursts, well apart, with a click before each.
        let firstRun = (0..<20).map { TypingEvent(time: 2 + Double($0) * 0.12) }
        let secondRun = (0..<12).map { TypingEvent(time: 9 + Double($0) * 0.12) }
        let clicks = [RecordedClick(time: 1.6, x: 0.22, y: 0.4),
                      RecordedClick(time: 8.7, x: 0.3, y: 0.7)]
        let samples = (0..<80).map { PointerSample(time: Double($0) * 0.2, x: 0.5, y: 0.5) }

        let follows = MotionEngine.typingFollows(typing: firstRun + secondRun, clicks: clicks,
                                                 samples: samples, duration: 14, settings: settings)
        XCTAssertEqual(follows.count, 2)
        XCTAssertTrue(follows.allSatisfy { $0.kind == .typing })
        guard follows.count == 2 else { XCTFail("expected two typing runs"); return }

        // Anchored where the caret was put, not where the pointer sat.
        XCTAssertEqual(follows[0].x, 0.22, accuracy: 0.001)
        XCTAssertEqual(follows[0].y, 0.4, accuracy: 0.001)
        XCTAssertEqual(follows[1].y, 0.7, accuracy: 0.001)

        // Travels rightward, further for the longer burst.
        XCTAssertGreaterThan(follows[0].endX ?? 0, follows[0].x)
        XCTAssertGreaterThan((follows[0].endX ?? 0) - follows[0].x,
                             (follows[1].endX ?? 0) - follows[1].x)

        // Travel is capped, so a very long passage cannot run off the edge.
        var capped = settings
        capped.maxTravel = 0.1
        let long = (0..<400).map { TypingEvent(time: 1 + Double($0) * 0.05) }
        let cappedFollows = MotionEngine.typingFollows(typing: long, clicks: clicks, samples: samples,
                                                      duration: 40, settings: capped)
        XCTAssertTrue(cappedFollows.allSatisfy { ($0.endX ?? 0) - $0.x <= 0.1001 })
        XCTAssertTrue(cappedFollows.allSatisfy { ($0.endX ?? 0) <= 1 })

        // Whatever is asked for, the rendered viewport stays inside the frame.
        for follow in cappedFollows + follows {
            for step in 0...10 {
                let time = follow.start + follow.duration * Double(step) / 10
                let box = MotionEngine.viewport(at: time, segments: [follow], samples: samples, crop: ContentRegion())
                XCTAssertTrue(box.minX >= -0.0001 && box.maxX <= 1.0001)
                XCTAssertTrue(box.minY >= -0.0001 && box.maxY <= 1.0001)
            }
        }

        // The frame actually moves across the run, rather than sitting still.
        let follow = follows[0]
        let early = MotionEngine.viewport(at: follow.start + 0.3, segments: [follow], samples: samples, crop: ContentRegion())
        let late = MotionEngine.viewport(at: follow.end - 0.3, segments: [follow], samples: samples, crop: ContentRegion())
        XCTAssertGreaterThan(Double(late.midX), Double(early.midX))
        // And it is zoomed in while doing so.
        XCTAssertLessThan(Double(late.width), 1)

        // The slide keeps pace with the keys. Easing it across the segment
        // instead left the frame behind the text through the first half of a
        // run and ahead of it through the second, and kept it drifting after
        // the typing had stopped — so: equal stretches of typing move the
        // frame by equal amounts, and the hold does not move it at all.
        var even = TypingFollowSettings()
        even.gap = 1.0
        // Long enough that the frame settles, holds, and is observed
        // holding before the zoom starts releasing: the camera is smoothed
        // over a window, so a hold shorter than one is never still.
        even.hold = 1.6
        even.advancePerKey = 0.008
        even.maxTravel = 0.5
        even.deadZone = 0          // continuous, which is what this part measures
        let steady = (0..<30).map { TypingEvent(time: 2 + Double($0) * 0.12) }   // 2.00 … 5.48
        let middle = [RecordedClick(time: 1.8, x: 0.45, y: 0.5)]
        guard let run = MotionEngine.typingFollows(typing: steady, clicks: middle, samples: samples,
                                                   duration: 12, settings: even).first else {
            XCTFail("a steady run of typing produced no follow"); return
        }
        func centre(_ time: Double) -> Double {
            Double(MotionEngine.viewport(at: time, segments: [run], samples: samples,
                                         crop: ContentRegion()).midX)
        }
        let typed = 5.48 - 2.0
        let firstQuarter = centre(2 + typed * 0.25) - centre(2)
        let thirdQuarter = centre(2 + typed * 0.75) - centre(2 + typed * 0.5)
        XCTAssertGreaterThan(firstQuarter, 0.01)
        XCTAssertEqual(firstQuarter, thirdQuarter, accuracy: firstQuarter * 0.2)

        // It arrives where the keys say, around the last key, and then
        // holds. "Around": the camera is smoothed over a window centred on
        // each moment, so it is still settling into the last fraction of
        // the travel as the last key goes in, and is done a window later.
        XCTAssertEqual(centre(5.48), 0.45 + Double(steady.count) * even.advancePerKey, accuracy: 0.01)
        let settled = 5.48 + MotionEngine.smoothing
        XCTAssertEqual(centre(settled), 0.45 + Double(steady.count) * even.advancePerKey, accuracy: 0.001)
        XCTAssertEqual(centre(settled + 0.4), centre(settled), accuracy: 0.0001)

        // With a dead zone — the default, and how a camera follows anything —
        // the frame does not creep. It holds while the caret crosses the band,
        // catches up in one move, and holds again, and it never runs past the
        // distance the keys account for.
        var zoned = even
        zoned.deadZone = 0.5
        zoned.catchUp = 0.4
        guard let held = MotionEngine.typingFollows(typing: steady, clicks: middle, samples: samples,
                                                    duration: 12, settings: zoned).first,
              let band = held.followBand else {
            XCTFail("a dead-zone run produced no follow"); return
        }
        func heldCentre(_ time: Double) -> Double {
            Double(MotionEngine.viewport(at: time, segments: [held], samples: samples,
                                         crop: ContentRegion()).midX)
        }
        // Still through the first half-band, once the lean-in has settled:
        // zooming towards an anchor left of centre moves the frame left,
        // and that is the zoom arriving, not the caret being followed.
        XCTAssertEqual(heldCentre(3.0), heldCentre(2.6), accuracy: 0.0005)
        // And it has moved by the end of the run, by about a whole band.
        let shifted = heldCentre(5.48) - heldCentre(2.0)
        XCTAssertGreaterThan(shifted, band * 0.8)
        XCTAssertLessThan(shifted, (held.endX ?? 0) - held.x + 0.0001)

        // Somewhere in the run there is a stretch where nothing moves at all,
        // which is the whole point of a dead zone.
        let steps = stride(from: 2.6, through: 5.48, by: 0.04).map(heldCentre)
        let still = zip(steps, steps.dropFirst()).filter { abs($0.1 - $0.0) < 0.0002 }.count
        if still < steps.count / 3 {
            XCTFail("the frame crept along with the typing instead of holding and catching up")
        }
        // It never runs backwards.
        if zip(steps, steps.dropFirst()).contains(where: { $0.1 < $0.0 - 0.0002 }) {
            XCTFail("the frame moved backwards during a run of typing")
        }

        // Capped, the slide stops where the cap is reached rather than being
        // stretched thin across the whole run: travel per key means the same
        // thing for a long passage as for a short one.
        var tight = even
        tight.maxTravel = 0.08                                  // reached after 10 keys
        guard let clipped = MotionEngine.typingFollows(typing: steady, clicks: middle, samples: samples,
                                                       duration: 12, settings: tight).first,
              let fraction = clipped.travelFraction else {
            XCTFail("a capped run produced no follow"); return
        }
        XCTAssertLessThan(fraction, 0.5)
        let atCap = clipped.start + fraction * clipped.duration
        XCTAssertEqual(atCap, 2 + 10 * 0.12, accuracy: 0.2)

        // A couple of stray keys is a correction, not a passage of typing.
        let stray = [TypingEvent(time: 3), TypingEvent(time: 3.1)]
        XCTAssertTrue(MotionEngine.typingFollows(typing: stray, clicks: clicks, samples: samples,
                                                 duration: 10, settings: settings).isEmpty)

        // Switched off, or with nothing typed, it produces nothing.
        var disabled = settings
        disabled.enabled = false
        XCTAssertTrue(MotionEngine.typingFollows(typing: firstRun, clicks: clicks, samples: samples,
                                                 duration: 14, settings: disabled).isEmpty)
        XCTAssertTrue(MotionEngine.typingFollows(typing: [], clicks: clicks, samples: samples,
                                                 duration: 14, settings: settings).isEmpty)

        // In the full automatic pass, a typing run owns its stretch: no click
        // zoom is left inside it to fight the slide.
        let edits = MotionEngine.autoEdits(clicks: clicks + [RecordedClick(time: 2.5, x: 0.5, y: 0.5)],
                                           samples: samples, duration: 14,
                                           typing: firstRun + secondRun, typingFollow: settings)
        let typingSpans = edits.filter { $0.kind == .typing }
        XCTAssertEqual(typingSpans.count, 2)
        for span in typingSpans {
            XCTAssertTrue(!edits.contains { $0.kind == .zoom && $0.start >= span.start - 0.3 && $0.start <= span.end })
        }
    }

    /// Sounds are laid under what the recording saw happen, and the cursor
    /// reads as a text cursor while text is being written.
    func testSoundsAndTextCursorFollowTheRecording() throws {
        let clicks = [RecordedClick(time: 0.5, x: 0.2, y: 0.2),
                      RecordedClick(time: 4.0, x: 0.6, y: 0.6)]
        let typing = (0..<24).map { TypingEvent(time: 1 + Double($0) * 0.12) }   // 1.00 … 3.76
        let scrolling = (0..<10).map { ScrollEvent(time: 6 + Double($0) * 0.1) } // 6.00 … 6.90
        let settings = SoundSettings()

        let cues = SoundTrack.cues(clicks: clicks, typing: typing, scrolling: scrolling,
                                   duration: 10, settings: settings)
        XCTAssertEqual(cues.filter { $0.kind == .clicking }.count, 2)
        XCTAssertEqual(cues.filter { $0.kind == .typing }.count, 1)
        XCTAssertEqual(cues.filter { $0.kind == .scrolling }.count, 1)
        // In order, so they can be laid down without shoving each other along.
        XCTAssertEqual(cues.map(\.start), cues.map(\.start).sorted())

        // A run covers the typing and stops with it; a click is a single hit.
        guard let run = cues.first(where: { $0.kind == .typing }),
              let hit = cues.first(where: { $0.kind == .clicking }) else {
            XCTFail("the recording's typing and clicks produced no cues"); return
        }
        XCTAssertEqual(run.start, 1, accuracy: 0.001)
        XCTAssertEqual(run.end, 3.76 + SoundTrack.tail, accuracy: 0.001)
        XCTAssertTrue(run.fills)
        XCTAssertTrue(!hit.fills)

        // Nothing is laid under a kind that is switched off.
        var quiet = settings
        quiet.typing = false; quiet.scrolling = false
        let remaining = SoundTrack.cues(clicks: clicks, typing: typing, scrolling: scrolling,
                                        duration: 10, settings: quiet)
        XCTAssertTrue(remaining.allSatisfy { $0.kind == .clicking })
        XCTAssertTrue(SoundTrack.cues(clicks: [], typing: [], scrolling: [], duration: 10, settings: settings).isEmpty)

        // Every clip is bundled, or there is nothing to play.
        for kind in SoundKind.allCases {
            if kind.url == nil { XCTFail("the \(kind.rawValue) sound is missing from the bundle") }
        }

        // The cursor is a text cursor while the writing happens, and back to
        // whatever the pointer was over once the frame is only holding.
        let follow = MotionEngine.typingFollows(typing: typing, clicks: clicks,
                                                samples: [PointerSample(time: 0, x: 0.3, y: 0.3),
                                                          PointerSample(time: 10, x: 0.3, y: 0.3)],
                                                duration: 10, settings: TypingFollowSettings())
        guard let segment = follow.first else { XCTFail("no typing segment to read a cursor from"); return }
        XCTAssertTrue(MotionEngine.isTyping(at: 2.0, segments: follow))
        XCTAssertTrue(!MotionEngine.isTyping(at: segment.end - 0.05, segments: follow))
        XCTAssertTrue(!MotionEngine.isTyping(at: 5.0, segments: follow))
        XCTAssertTrue(!MotionEngine.isTyping(at: 2.0, segments: [EditSegment(kind: .zoom, start: 0, duration: 9, intensity: 2, x: 0.5, y: 0.5)]))

        // Scroll events and sound settings survive a round trip.
        var metadata = RecordingMetadata(clicks: clicks, pointerSamples: [], keystrokes: [],
                                         sourceWidth: 100, sourceHeight: 100, sourceName: "test")
        metadata.scrollEvents = scrolling
        let restored = try JSONDecoder().decode(RecordingMetadata.self, from: JSONEncoder().encode(metadata))
        XCTAssertEqual(restored.scrollEvents?.count, scrolling.count)
    }

    /// Spotlight is off the menu, and typing follow has to be reachable from
    /// a browser recording — it captured no keypresses at all, which is why
    /// the effect never appeared for one.
    func testSpotlightIsRetiredAndTypingReachesBrowserRecordings() {
        // Not offered any more.
        XCTAssertTrue(!SegmentKind.availableCases.contains(.spotlight))
        // But still decodes and renders, so older projects keep working.
        XCTAssertTrue(SegmentKind.allCases.contains(.spotlight))
        let legacy = """
        {"id":"\(UUID().uuidString)","kind":"spotlight","start":1,"duration":2,"intensity":1.2,"x":0.4,"y":0.5}
        """
        XCTAssertTrue((try? JSONDecoder().decode(EditSegment.self, from: Data(legacy.utf8))) != nil)

        // Still on the menu, since these were not the complaint.
        for kept in [SegmentKind.zoom, .typing, .outline, .callout, .blur, .pixelate] {
            XCTAssertTrue(SegmentKind.availableCases.contains(kept))
        }

        // A recording whose metadata carries typing events must produce a
        // follow regardless of where those events came from.
        let typing = (0..<16).map { TypingEvent(time: 1 + Double($0) * 0.1) }
        var metadata = RecordingMetadata(clicks: [RecordedClick(time: 0.8, x: 0.25, y: 0.5)],
                                         pointerSamples: [PointerSample(time: 0, x: 0.5, y: 0.5)],
                                         keystrokes: [], sourceWidth: 1920, sourceHeight: 1080,
                                         sourceName: "Chrome tab")
        metadata.typingEvents = typing
        let edits = MotionEngine.autoEdits(clicks: metadata.clicks, samples: metadata.pointerSamples,
                                           duration: 10, typing: metadata.typingEvents ?? [],
                                           typingFollow: TypingFollowSettings())
        XCTAssertTrue(edits.contains { $0.kind == .typing })

        // And metadata carrying none produces none, rather than inventing one.
        let none = MotionEngine.autoEdits(clicks: metadata.clicks, samples: metadata.pointerSamples,
                                          duration: 10, typing: [], typingFollow: TypingFollowSettings())
        XCTAssertTrue(!none.contains { $0.kind == .typing })

        // Typing events survive a metadata round trip, or a reopened
        // recording would silently lose its follows.
        let restored = try? JSONDecoder().decode(RecordingMetadata.self, from: JSONEncoder().encode(metadata))
        XCTAssertEqual(restored?.typingEvents?.count, typing.count)
    }

    /// The toolbar badge and the Settings button both read the updater's
    /// state, so that state has to mean what they assume.
    @MainActor func testUpdaterStateDrivesTheVisibleControls() {
        let updater = Updater()

        // Nothing waiting, so nothing to badge and nothing to install.
        XCTAssertNil(updater.pendingRelease)
        XCTAssertTrue(!updater.isBusy)

        let release = AvailableRelease(
            version: SemanticVersion("9.9.9")!,
            downloadURL: URL(string: "https://github.com/a/b/releases/download/v9.9.9/FocusFlow-9.9.9.dmg")!,
            notes: "",
            pageURL: nil)

        updater.applyStateForTesting(.available(release))
        XCTAssertEqual(updater.pendingRelease?.version.description, "9.9.9")
        XCTAssertTrue(!updater.isBusy)

        // Dismissing hides the bar but must not discard the offer, or the
        // toolbar badge and the install button would vanish with it.
        updater.dismissed = true
        XCTAssertEqual(updater.pendingRelease?.version.description, "9.9.9")

        // Busy states must disable the controls rather than allow a second run.
        for busy in [Updater.State.checking, .downloading(0.4), .installing] {
            updater.applyStateForTesting(busy)
            XCTAssertTrue(updater.isBusy)
            XCTAssertNil(updater.pendingRelease)
        }

        // A reported outcome clears back to idle when dismissed.
        updater.applyStateForTesting(.failed("nope"))
        XCTAssertTrue(!updater.isBusy)
        updater.clearStatus()
        XCTAssertNil(updater.pendingRelease)

        updater.applyStateForTesting(.upToDate)
        updater.clearStatus()
        XCTAssertNil(updater.pendingRelease)
    }

    /// The sequence that matters: type a message, then click Send. The typing
    /// must be followed, and the click on Send must keep its own zoom and
    /// ripple — it was being deleted as though it were part of the typing.
    func testClickAfterTypingKeepsItsOwnZoom() {
        var settings = TypingFollowSettings()
        settings.gap = 1.1
        settings.hold = 0.7

        // Typing from 1.0 to 2.8, then Send clicked at 3.1 — inside the hold.
        let typing = (0..<16).map { TypingEvent(time: 1 + Double($0) * 0.12) }
        let caret = RecordedClick(time: 0.8, x: 0.2, y: 0.55)
        let send = RecordedClick(time: 3.1, x: 0.78, y: 0.82)
        let samples = (0..<60).map { PointerSample(time: Double($0) * 0.1, x: 0.5, y: 0.5) }

        let edits = MotionEngine.autoEdits(clicks: [caret, send], samples: samples, duration: 8,
                                           typing: typing, typingFollow: settings)

        // The typing is followed.
        let follows = edits.filter { $0.kind == .typing }
        XCTAssertEqual(follows.count, 1)

        // And Send kept a zoom of its own, aimed at the button.
        let sendZooms = edits.filter { $0.kind == .zoom && $0.start > 2.0 }
        XCTAssertEqual(sendZooms.count, 1)
        if let sendZoom = sendZooms.first {
            XCTAssertEqual(sendZoom.x, 0.78, accuracy: 0.001)
            XCTAssertEqual(sendZoom.y, 0.82, accuracy: 0.001)
            // It starts around the click, so the frame is there when it lands.
            XCTAssertLessThan(sendZoom.start, 3.1)
            XCTAssertGreaterThan(sendZoom.end, 3.1)
        } else {
            XCTFail("the click on Send lost its zoom")
        }

        // A click in the middle of the typing is still dropped: that one would
        // drag the frame away from the line being written.
        let interrupting = RecordedClick(time: 1.9, x: 0.6, y: 0.3)
        let withInterrupt = MotionEngine.autoEdits(clicks: [caret, interrupting, send], samples: samples,
                                                   duration: 8, typing: typing, typingFollow: settings)
        XCTAssertTrue(!withInterrupt.contains { $0.kind == .zoom && abs($0.x - 0.6) < 0.01 })
        // While Send survives alongside it.
        XCTAssertTrue(withInterrupt.contains { $0.kind == .zoom && abs($0.x - 0.78) < 0.01 })

        // Switched off, the typing owns nothing: a click made while typing
        // keeps the zoom it would have had, rather than being deleted for a
        // follow that is never built. Late enough in the run to be a zoom of
        // its own rather than an extension of the one before it.
        let late = RecordedClick(time: 2.6, x: 0.62, y: 0.3)
        let followed = MotionEngine.autoEdits(clicks: [caret, late, send], samples: samples,
                                              duration: 8, typing: typing, typingFollow: settings)
        XCTAssertTrue(!followed.contains { $0.kind == .zoom && abs($0.x - 0.62) < 0.01 })

        var off = settings
        off.enabled = false
        let withoutFollow = MotionEngine.autoEdits(clicks: [caret, late, send], samples: samples,
                                                   duration: 8, typing: typing, typingFollow: off)
        XCTAssertTrue(!withoutFollow.contains { $0.kind == .typing })
        if !withoutFollow.contains(where: { $0.kind == .zoom && abs($0.x - 0.62) < 0.01 }) {
            XCTFail("turning the follow off deleted the click zoom it was meant to replace")
        }
        XCTAssertTrue(MotionEngine.typingKeySpans(typing, duration: 8, settings: off).isEmpty)

        // The span that excludes clicks must end at the last keypress, not at
        // the end of the hold.
        let spans = MotionEngine.typingKeySpans(typing, duration: 8, settings: settings)
        XCTAssertEqual(spans.count, 1)
        if let span = spans.first {
            XCTAssertLessThan(span.1, 3.1)
        } else {
            XCTFail("no typing span was produced")
        }
    }

    /// Every move the camera makes is smoothed over a window, so it can
    /// never change speed abruptly however abruptly the thing it follows
    /// does. This is what the complaint "it slides too fast, with no smooth
    /// motion, and the text is left behind" was about: the frame left and
    /// arrived at full tilt, and the words did not travel with it.
    func testCameraSmoothsEveryMoveItMakes() {
        let step = 1.0 / 60

        func path(_ segment: EditSegment, samples: [PointerSample], smoothed: Bool) -> [Double] {
            stride(from: segment.start, through: segment.end, by: step).map { time in
                let box = smoothed
                    ? MotionEngine.viewport(at: time, segments: [segment], samples: samples, crop: ContentRegion())
                    : MotionEngine.rawViewport(at: time, segments: [segment], samples: samples, crop: ContentRegion())
                return Double(box.midX)
            }
        }
        func speeds(_ path: [Double]) -> [Double] { zip(path, path.dropFirst()).map { $1 - $0 } }
        /// The largest change of speed between one frame and the next: how
        /// hard the camera is yanked.
        func jolt(_ path: [Double]) -> Double {
            let speed = speeds(path)
            return zip(speed, speed.dropFirst()).map { abs($1 - $0) }.max() ?? 0
        }

        // A click zoom that holds its anchor until the pointer leaves the
        // middle of the frame, with the pointer crossing that edge at a
        // steady pace. The raw camera stands still and then sets off at the
        // pointer's speed, which is a jolt; the smoothed one does not.
        let follow = EditSegment(kind: .zoom, start: 0, duration: 3, intensity: 2,
                                 x: 0.5, y: 0.5, followsCursor: true, transition: 0.3)
        let travelling = (0...180).map { PointerSample(time: Double($0) * step, x: 0.5 + Double($0) * step * 0.3, y: 0.5) }
        let rawFollow = path(follow, samples: travelling, smoothed: false)
        let smoothFollow = path(follow, samples: travelling, smoothed: true)
        XCTAssertGreaterThan(jolt(rawFollow), 0)
        XCTAssertLessThan(jolt(smoothFollow), jolt(rawFollow) / 2)

        // A run of typing with a wide dead zone: the frame holds, then
        // catches up by a whole band. Smoothed, it covers the same ground
        // without ever reaching the speed the raw camera does.
        var typing = TypingFollowSettings()
        typing.gap = 1.0
        typing.advancePerKey = 0.012
        typing.maxTravel = 0.6
        typing.deadZone = 0.5
        typing.catchUp = 0.3
        let keys = (0..<60).map { TypingEvent(time: 1 + Double($0) * 0.1) }
        guard let run = MotionEngine.typingFollows(typing: keys, clicks: [RecordedClick(time: 0.8, x: 0.2, y: 0.5)],
                                                   samples: [], duration: 14, settings: typing).first else {
            XCTFail("a run of typing produced no follow"); return
        }
        let rawRun = path(run, samples: [], smoothed: false)
        let smoothRun = path(run, samples: [], smoothed: true)
        // The travel itself, with neither the lean-in nor the release:
        // zooming towards an anchor left of centre carries the frame left,
        // and letting the zoom go carries it back, and neither is the
        // caret being followed.
        let travel = stride(from: run.start + 1, to: run.end - (run.transition ?? 0.6) - MotionEngine.smoothing, by: step)
            .map { Double(MotionEngine.viewport(at: $0, segments: [run], samples: [], crop: ContentRegion()).midX) }
        // The same journey…
        XCTAssertEqual(smoothRun.last! - smoothRun.first!, rawRun.last! - rawRun.first!, accuracy: 0.02)
        // …taken more gently, and without ever running backwards.
        XCTAssertLessThan(speeds(smoothRun).map(abs).max()!, speeds(rawRun).map(abs).max()!)
        XCTAssertLessThan(jolt(smoothRun), jolt(rawRun))
        XCTAssertTrue(speeds(travel).allSatisfy { $0 > -0.0002 })

        // And where nothing is asked for, nothing happens: a smoothed
        // camera must not drift the frame about on its own.
        XCTAssertEqual(MotionEngine.viewport(at: 20, segments: [run], samples: [], crop: ContentRegion()),
                       CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    /// The export is the recording: its pixels, and a rate no lower than
    /// the one it was captured at.
    func testExportKeepsTheRecordingsResolutionAndRate() {
        let uhd = CGSize(width: 3840, height: 2160), hd = CGSize(width: 1920, height: 1080)

        // Source keeps what was captured, rather than capping it at 1080p
        // and throwing the detail away before anything is composed.
        XCTAssertEqual(CanvasRatio.source.size(for: uhd), uhd)
        XCTAssertEqual(CanvasRatio.source.size(for: CGSize(width: 1280, height: 720)), CGSize(width: 1280, height: 720))
        // A named ratio takes its pixels from the recording too.
        XCTAssertEqual(CanvasRatio.landscape.size(for: uhd), uhd)
        // A portrait canvas is as tall as the recording is wide: the ratio
        // keeps its shape, and its long side is the recording's long side.
        let portrait = CanvasRatio.portrait.size(for: uhd)
        XCTAssertEqual(portrait.height, 3840)
        XCTAssertEqual(Double(portrait.width / portrait.height), 9.0 / 16, accuracy: 0.01)
        // A small recording still composes onto a canvas worth sharing.
        XCTAssertEqual(CanvasRatio.landscape.size(for: CGSize(width: 640, height: 360)), hd)
        // Odd captures still come out even — H.264 rejects odd dimensions.
        let odd = CanvasRatio.source.size(for: CGSize(width: 1023, height: 769))
        XCTAssertEqual(Int(odd.width) % 2, 0)
        XCTAssertEqual(Int(odd.height) % 2, 0)

        func bitrate(canvas: CGSize, fps: Int, source: CGSize, rate: Double) -> Double {
            let settings = VideoExporter.videoSettings(canvas: canvas, frameRate: fps, source: source, sourceDataRate: rate)
            let compression = settings[AVVideoCompressionPropertiesKey] as? [String: Any]
            return Double(compression?[AVVideoAverageBitRateKey] as? Int ?? 0)
        }
        // Exported at the size it was recorded, nothing is spared.
        XCTAssertGreaterThan(bitrate(canvas: uhd, fps: 60, source: uhd, rate: 60_000_000), 60_000_000)
        // A thriftily encoded recording still gets what the canvas needs.
        XCTAssertGreaterThan(bitrate(canvas: hd, fps: 30, source: hd, rate: 2_000_000), 8_000_000)
        // Exported smaller, the match scales with the pixels rather than
        // spending a 4K rate on a 1080p file.
        XCTAssertLessThan(bitrate(canvas: hd, fps: 30, source: uhd, rate: 80_000_000),
                          bitrate(canvas: uhd, fps: 30, source: uhd, rate: 80_000_000))
        // A wastefully encoded source is matched only as far as the point
        // where more bits stop showing, rather than all the way.
        XCTAssertLessThan(bitrate(canvas: hd, fps: 30, source: hd, rate: 100_000_000), 50_000_000)
        // Nothing is unbounded.
        XCTAssertLessThanOrEqual(bitrate(canvas: uhd, fps: 60, source: uhd, rate: 800_000_000), 240_000_000)

        // The file is the canvas, exactly.
        let settings = VideoExporter.videoSettings(canvas: hd, frameRate: 30, source: hd, sourceDataRate: 10_000_000)
        XCTAssertEqual(settings[AVVideoWidthKey] as? Int, 1920)
        XCTAssertEqual(settings[AVVideoHeightKey] as? Int, 1080)
    }

    /// The frame and a feature inside it follow the same move, with a small
    /// extra content offset for parallax.
    func testThreeDHandlesSitOnTheRenderedFrame() throws {
        // Square to the viewer, the map leaves every point where it was.
        let canvas = CGRect(x: 0, y: 0, width: 400, height: 240)
        let identity = ProjectiveMap(canvas, to: FrameQuad.rect(canvas))
        XCTAssertEqual(Double(identity(CGPoint(x: 137, y: 61)).x), 137, accuracy: 0.001)
        XCTAssertEqual(Double(identity(CGPoint(x: 137, y: 61)).y), 61, accuracy: 0.001)

        let renderer = FocusFlowCompositor(), context = CIContext()
        let marker = CGRect(x: 120, y: 100, width: 14, height: 14)
        let source = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: marker)
            .composited(over: CIImage(color: CIColor(red: 0.95, green: 0.95, blue: 0.95)).cropped(to: canvas))
        var settings = ExportSettings(background: .graphite, canvasSize: canvas.size, padding: 6, cornerRadius: 0, shadow: 0, segments: [], pointerSamples: [], clicks: [], keystrokes: [], cursorSize: 1, clickEffects: false, showKeystrokes: false, cameraURL: nil, showCamera: false, cameraSize: 0.2, cameraX: 0.8, cameraY: 0.8, cameraCornerRadius: 0, cameraShape: .circle)
        settings.showCursor = false
        settings.motion.ambientGraphics = false
        settings.motion.scrollBlur = false
        settings.motion.automaticMotionBlur = false
        settings.trimStart = 0; settings.trimEnd = 8
        settings.customBackground = CustomBackground(kind: .solid, top: RGBColor(r: 0, g: 0, b: 0))

        /// The lit window bounds and the red feature inside the content.
        func rendered(at time: Double = 1) throws -> (bounds: CGRect, point: CGPoint) {
            let image = try XCTUnwrap(context.createCGImage(renderer.renderFrame(source: source, time: time, settings: settings), from: canvas))
            let data = pixels(image)
            var minX = 400.0, maxX = 0.0, minRow = 240.0, maxRow = 0.0
            var redX = 0.0, redY = 0.0, redCount = 0.0
            for row in 0..<240 { for column in 0..<400 {
                let index = (row * 400 + column) * 4
                if Int(data[index]) > 110 {
                    minX = min(minX, Double(column)); maxX = max(maxX, Double(column))
                    minRow = min(minRow, Double(row)); maxRow = max(maxRow, Double(row))
                }
                if data[index] > 170 && data[index + 1] < 90 && data[index + 2] < 90 {
                    redX += Double(column); redY += Double(240 - row)
                    redCount += 1
                }
            } }
            XCTAssertGreaterThan(redCount, 20)
            return (CGRect(x: minX, y: 240 - maxRow, width: maxX - minX, height: maxRow - minRow),
                    CGPoint(x: redX / redCount, y: redY / redCount))
        }

        let flat = try rendered()
        var move = CameraMoveSettings()
        move.yaw = 0.5; move.pitch = 0.25; move.zoom = 0.9
        move.blur = .none
        settings.cameraMove = move
        let leaning = try rendered()
        let layout = FrameLayout.make(canvas: canvas, sourceSize: canvas.size,
                                      padding: 6, frame: settings.frame)
        let outer = move.pose.projection(of: canvas, canvas: canvas, lean: move.pose.lean())
        let outerMap = ProjectiveMap(canvas, to: outer)
        let frameCorners = outerMap.quad(of: layout.outer).corners
        XCTAssertEqual(Double(leaning.bounds.minX), Double(frameCorners.map(\.x).min()!), accuracy: 3)
        XCTAssertEqual(Double(leaning.bounds.maxX), Double(frameCorners.map(\.x).max()!), accuracy: 3)
        XCTAssertEqual(Double(leaning.bounds.minY), Double(frameCorners.map(\.y).min()!), accuracy: 3)
        XCTAssertEqual(Double(leaning.bounds.maxY), Double(frameCorners.map(\.y).max()!), accuracy: 3)
        XCTAssertGreaterThan(abs(leaning.bounds.minX - flat.bounds.minX), 5)

        let start = CGPoint(x: layout.content.minX + marker.midX / canvas.width * layout.content.width,
                            y: layout.content.minY + marker.midY / canvas.height * layout.content.height)
        let innerPose = move.pose.weighted(FramePose.contentParallax)
        let inner = innerPose.projection(of: layout.content, canvas: layout.content,
                                          lean: innerPose.lean())
        let expected = outerMap(ProjectiveMap(layout.content, to: inner)(start))
        XCTAssertEqual(leaning.point.x, expected.x, accuracy: 3)
        XCTAssertEqual(leaning.point.y, expected.y, accuracy: 3)
        XCTAssertGreaterThan(hypot(leaning.point.x - flat.point.x,
                                   leaning.point.y - flat.point.y), 5)
        let frameOnly = outerMap(start)
        XCTAssertGreaterThan(hypot(leaning.point.x - frameOnly.x,
                                   leaning.point.y - frameOnly.y), 1)

        settings.cameraMove = CameraMoveSettings()
        var animated = EditSegment(kind: .perspective, start: 2, duration: 3,
                                   intensity: 1, x: 0.5, y: 0.5, transition: 0.5)
        animated.pose = move.pose
        animated.sweeps = false
        settings.segments = [animated]
        let before = try rendered(at: 0.5), middle = try rendered(at: 3.5), after = try rendered(at: 7.5)
        XCTAssertGreaterThan(abs(middle.bounds.minX - before.bounds.minX), 5)
        XCTAssertGreaterThan(hypot(middle.point.x - before.point.x,
                                   middle.point.y - before.point.y), 5)
        XCTAssertEqual(after.bounds.minX, before.bounds.minX, accuracy: 1)
        XCTAssertEqual(after.point.x, before.point.x, accuracy: 1)
        XCTAssertEqual(after.point.y, before.point.y, accuracy: 1)
        settings.segments = []

        // At steep angles, visible points inside the moving frame should
        // still contain the recording rather than a transparent wedge.
        for pose in [FramePose(pitch: 1, yaw: 1), FramePose(pitch: -1, yaw: -1),
                     FramePose(panX: 1, panY: 1), FramePose(zoom: 0.6),
                     FramePose(pitch: 0.7, yaw: -0.8, roll: 0.7)] {
            settings.cameraMove = CameraMoveSettings()
            settings.cameraMove.pitch = pose.pitch
            settings.cameraMove.yaw = pose.yaw
            settings.cameraMove.roll = pose.roll
            settings.cameraMove.panX = pose.panX
            settings.cameraMove.panY = pose.panY
            settings.cameraMove.zoom = pose.zoom
            let image = try XCTUnwrap(context.createCGImage(renderer.renderFrame(source: source, time: 1, settings: settings), from: canvas))
            let data = pixels(image)
            let projected = ProjectiveMap(canvas, to: pose.projection(of: canvas, canvas: canvas,
                                                                       lean: pose.lean()))
            let opening = layout.content.insetBy(dx: layout.content.width * 0.08,
                                                  dy: layout.content.height * 0.08)
            for point in FrameQuad.rect(opening).corners {
                let mapped = projected(point)
                let x = Int(mapped.x), y = Int(mapped.y)
                guard x >= 0, x < 400, y >= 0, y < 240 else { continue }
                let row = 239 - y
                XCTAssertGreaterThan(Int(data[(row * 400 + x) * 4]), 100)
            }
        }
    }

    /// A frame put into perspective must not come back softened. Depth of
    /// field used to be the default, so the first lean anyone tried blurred
    /// the whole picture — the thing they had leaned in order to see.
    func testLeaningTheFrameKeepsItSharp() throws {
        // Nothing is blurred unless it is asked for.
        XCTAssertEqual(CameraMoveSettings().blur, .none)
        XCTAssertEqual(CameraMoveSettings().focusBlur, 0, accuracy: 0.0001)
        XCTAssertTrue(!CameraMoveSettings().hasStandaloneBlur)
        var leaned = CameraMoveSettings(); leaned.yaw = 0.5
        XCTAssertTrue(leaned.isActive && !leaned.hasStandaloneBlur)

        let renderer = FocusFlowCompositor(), context = CIContext()
        let canvas = CGRect(x: 0, y: 0, width: 480, height: 270)
        // Fine vertical bars: what a page of text does to a resample.
        let bars = (0..<60).reduce(CIImage(color: .black).cropped(to: canvas)) { image, index in
            CIImage(color: index.isMultiple(of: 2) ? .white : CIColor(red: 0.1, green: 0.1, blue: 0.1))
                .cropped(to: CGRect(x: index * 8, y: 0, width: 8, height: 270)).composited(over: image)
        }
        var settings = ExportSettings(background: .graphite, canvasSize: canvas.size, padding: 0, cornerRadius: 0, shadow: 0, segments: [], pointerSamples: [], clicks: [], keystrokes: [], cursorSize: 1, clickEffects: false, showKeystrokes: false, cameraURL: nil, showCamera: false, cameraSize: 0.2, cameraX: 0.8, cameraY: 0.8, cameraCornerRadius: 0, cameraShape: .circle)
        settings.showCursor = false
        settings.motion.ambientGraphics = false
        settings.motion.scrollBlur = false
        settings.motion.automaticMotionBlur = false
        settings.trimStart = 0; settings.trimEnd = 8

        /// Total contrast between neighbouring pixels along a row: how much
        /// of the bar pattern survived.
        func detail(_ move: CameraMoveSettings) throws -> Double {
            settings.cameraMove = move
            let image = try XCTUnwrap(context.createCGImage(renderer.renderFrame(source: bars, time: 1, settings: settings), from: canvas))
            let data = pixels(image)
            var total = 0.0
            for row in [90, 135, 180] {
                for column in 120..<360 {
                    let a = Int(data[(row * 480 + column) * 4])
                    let b = Int(data[(row * 480 + column + 1) * 4])
                    total += Double(abs(a - b))
                }
            }
            return total
        }

        var depth = leaned; depth.blur = .depth; depth.focusBlur = 1
        let sharp = try detail(leaned), softened = try detail(depth)
        XCTAssertGreaterThan(sharp, softened * 1.5)

        // And the warp's own softness is taken back out, so a leaning frame
        // keeps most of the detail a square one has.
        var blunt = leaned; blunt.crisp = false
        XCTAssertGreaterThan(sharp, try detail(blunt))
        XCTAssertGreaterThan(sharp, try detail(CameraMoveSettings()) * 0.5)
    }

    /// A wash follows the range while text is selected, without extending
    /// beyond the part of the drag that has happened yet.
    func testSelectionIsDrawnWhereItHappens() throws {
        let renderer = FocusFlowCompositor(), context = CIContext()
        let canvas = CGRect(x: 0, y: 0, width: 400, height: 240)
        let page = CIImage(color: CIColor(red: 0.96, green: 0.96, blue: 0.96)).cropped(to: canvas)
        var settings = ExportSettings(background: .graphite, canvasSize: canvas.size, padding: 0, cornerRadius: 0, shadow: 0, segments: [], pointerSamples: [], clicks: [], keystrokes: [], cursorSize: 1, clickEffects: false, showKeystrokes: false, cameraURL: nil, showCamera: false, cameraSize: 0.2, cameraX: 0.8, cameraY: 0.8, cameraCornerRadius: 0, cameraShape: .circle)
        settings.showCursor = false
        settings.motion.ambientGraphics = false
        settings.motion.scrollBlur = false
        settings.motion.automaticMotionBlur = false
        settings.trimStart = 0; settings.trimEnd = 8

        func frame() throws -> [UInt8] {
            let image = try XCTUnwrap(context.createCGImage(renderer.renderFrame(source: page, time: 1, settings: settings), from: canvas))
            return pixels(image)
        }
        /// How blue a patch is against a grey page — the accent is blue by
        /// default, so this is "the graphic is here".
        func accented(_ data: [UInt8], rows: ClosedRange<Int>, columns: ClosedRange<Int>) -> Double {
            var total = 0.0, count = 0.0
            for row in rows { for column in columns {
                let index = (row * 400 + column) * 4
                total += Double(data[index + 2]) - Double(data[index]); count += 1
            } }
            return total / max(1, count)
        }

        // A selection is washed over the range the drag has covered.
        let drag = EditSegment(kind: .zoom, start: 0, duration: 2, intensity: 1, x: 0.25, y: 0.5,
                               transition: 0.4, endX: 0.7, endY: 0.5,
                               tracksSelection: true, selectionStartTime: 0.2, selectionEndTime: 1.8)
        settings.segments = [drag]
        let selected = try frame()
        settings.selectionFocus.highlight = false
        let unselected = try frame()
        XCTAssertGreaterThan(accented(selected, rows: 110...130, columns: 110...170),
                             accented(unselected, rows: 110...130, columns: 110...170) + 8)
        // Past where the drag has reached at this moment, nothing is washed.
        XCTAssertEqual(accented(selected, rows: 110...130, columns: 330...380),
                       accented(unselected, rows: 110...130, columns: 330...380), accuracy: 1)

        // And the camera follows the range rather than jumping to the end.
        var tracking = drag; tracking.intensity = 2
        let early = MotionEngine.viewport(at: 0.5, segments: [tracking], samples: [], crop: ContentRegion())
        let late = MotionEngine.viewport(at: 1.6, segments: [tracking], samples: [], crop: ContentRegion())
        XCTAssertGreaterThan(Double(late.midX), Double(early.midX) + 0.02)
    }

    /// A ring or a dot marks the point itself, where an arrow hangs down
    /// and to the right of it, and someone's own artwork is used when they
    /// have chosen some.
    func testCursorMarksAndCustomArtwork() throws {
        let renderer = FocusFlowCompositor(), context = CIContext()
        let canvas = CGRect(x: 0, y: 0, width: 400, height: 240)
        let page = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: canvas)
        var settings = ExportSettings(background: .graphite, canvasSize: canvas.size, padding: 0, cornerRadius: 0, shadow: 0, segments: [], pointerSamples: (0...20).map { PointerSample(time: Double($0) * 0.1, x: 0.5, y: 0.5) }, clicks: [], keystrokes: [], cursorSize: 3, clickEffects: false, showKeystrokes: false, cameraURL: nil, showCamera: false, cameraSize: 0.2, cameraX: 0.8, cameraY: 0.8, cameraCornerRadius: 0, cameraShape: .circle)
        settings.motion.ambientGraphics = false
        settings.motion.scrollBlur = false
        settings.motion.automaticMotionBlur = false
        settings.cursorShadow = false
        settings.trimStart = 0; settings.trimEnd = 8

        func frame() throws -> [UInt8] {
            let image = try XCTUnwrap(context.createCGImage(renderer.renderFrame(source: page, time: 1, settings: settings), from: canvas))
            return pixels(image)
        }
        /// How far a patch departs from the flat grey page.
        func marked(_ data: [UInt8], rows: ClosedRange<Int>, columns: ClosedRange<Int>) -> Double {
            var total = 0.0, count = 0.0
            for row in rows { for column in columns {
                let index = (row * 400 + column) * 4
                for channel in 0..<3 { total += abs(Double(data[index + channel]) - 127) }
                count += 3
            } }
            return total / max(1, count)
        }

        // The pointer sits at the middle of the frame: (200, 120).
        settings.cursor.style = .light
        let arrow = try frame()
        // An arrow hangs below its tip and nothing is above it.
        XCTAssertGreaterThan(marked(arrow, rows: 124...140, columns: 200...214), 8)
        XCTAssertLessThan(marked(arrow, rows: 96...112, columns: 186...200), 2)

        settings.cursor.style = .ring
        let ring = try frame()
        // A ring is drawn around the point, above it as much as below.
        XCTAssertGreaterThan(marked(ring, rows: 100...115, columns: 190...210), 6)
        XCTAssertGreaterThan(marked(ring, rows: 125...140, columns: 190...210), 6)

        settings.cursor.style = .dot
        XCTAssertGreaterThan(marked(try frame(), rows: 112...128, columns: 192...208), 10)

        // Someone's own artwork, in place of all of it.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FocusFlow-cursor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let artwork = directory.appendingPathComponent("pointer.png")
        let drawn = NSImage(size: NSSize(width: 40, height: 40))
        drawn.lockFocus()
        NSColor(calibratedRed: 1, green: 0, blue: 0, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: 40, height: 40).fill()
        drawn.unlockFocus()
        try NSBitmapImageRep(data: drawn.tiffRepresentation!)!.representation(using: .png, properties: [:])!.write(to: artwork)

        settings.cursor.style = .custom
        settings.cursor.customImagePath = artwork.path
        let custom = try frame()
        // A solid red square hanging from the point it points at.
        let index = (130 * 400 + 210) * 4
        XCTAssertGreaterThan(Int(custom[index]), Int(custom[index + 2]) + 80)

        // With nothing chosen it falls back rather than drawing nothing.
        settings.cursor.customImagePath = nil
        XCTAssertGreaterThan(marked(try frame(), rows: 120...140, columns: 200...215), 4)
    }

    /// A project saved against older defaults is read as what it would be
    /// saved as today, so a fix to a default reaches the recordings people
    /// already have rather than only new ones.
    func testOlderProjectsAreBroughtUpToTodaysDefaults() throws {
        let json = """
        {"videoPath":"/tmp/v.mp4","segments":[
          {"id":"35B6D9BA-EFE6-4591-970B-2AB70EE2E182","kind":"typing","start":1,"duration":4,"intensity":1.9,"x":0.2,"y":0.5,"followBand":0.236,"followSettle":0.45},
          {"id":"45B6D9BA-EFE6-4591-970B-2AB70EE2E183","kind":"perspective","start":1,"duration":3,"intensity":2,"x":0.5,"y":0.5,"blur":"Depth of field","blurAmount":0.35}],
         "background":"ocean","ratio":"Source","padding":7,"cornerRadius":18,"shadow":30,"cursorSize":1.2,"clickEffects":true,
         "cameraMove":{"move":"None","tilt":0.55,"amount":0.5,"focusBlur":0.35,"duration":2.6,"curve":"Silky","holds":true,"blur":"Depth of field","yaw":0.4},
         "typingFollow":{"enabled":true,"zoom":1.9,"advancePerKey":0.011,"maxTravel":0.42,"deadZone":0.45,"catchUp":0.45,"gap":1.1,"hold":0.7,"curve":"Silky"}}
        """
        let old = try JSONDecoder().decode(ProjectDocument.self, from: Data(json.utf8))
        // As written: depth of field on a lean, and a fast follow.
        XCTAssertEqual(old.cameraMove?.blur, .depth)
        XCTAssertEqual(old.typingFollow?.catchUp ?? 0, 0.45, accuracy: 0.0001)

        let now = old.migrated()
        XCTAssertEqual(now.schema, ProjectDocument.schemaVersion)
        XCTAssertEqual(now.cameraMove?.blur, FrameBlur.none)
        XCTAssertEqual(now.cameraMove?.focusBlur ?? 1, 0, accuracy: 0.0001)
        // The lean itself is untouched: it was a choice.
        XCTAssertEqual(now.cameraMove?.yaw ?? 0, 0.4, accuracy: 0.0001)
        XCTAssertEqual(now.typingFollow?.catchUp ?? 0, TypingFollowSettings().catchUp, accuracy: 0.0001)
        XCTAssertEqual(now.typingFollow?.deadZone ?? 0, TypingFollowSettings().deadZone, accuracy: 0.0001)
        // And the segments already built, which is where the frame
        // actually takes its pace and its blur from.
        let typing = try XCTUnwrap(now.segments.first { $0.kind == .typing })
        XCTAssertEqual(typing.followSettle ?? 0, TypingFollowSettings().catchUp, accuracy: 0.0001)
        XCTAssertLessThan(typing.followBand ?? 1, 0.236)
        let lean = try XCTUnwrap(now.segments.first { $0.kind == .perspective })
        XCTAssertEqual(lean.blur, FrameBlur.none)

        // Run twice, it changes nothing further, and a value somebody
        // actually chose is never moved.
        var chosen = now
        chosen.typingFollow?.catchUp = 0.3
        chosen.schema = nil
        XCTAssertEqual(chosen.migrated().typingFollow?.catchUp ?? 0, 0.3, accuracy: 0.0001)
        XCTAssertEqual(now.migrated().typingFollow?.catchUp ?? 0, TypingFollowSettings().catchUp, accuracy: 0.0001)
    }

    /// The poses the keyboard and the quick buttons reach for.
    func testQuickPosesAndNudging() {
        XCTAssertEqual(CameraMoveSettings.quickPoses.first?.pose, .neutral)
        XCTAssertEqual(Set(CameraMoveSettings.quickPoses.map(\.key)).count, CameraMoveSettings.quickPoses.count)
        XCTAssertTrue(CameraMoveSettings.quickPoses.allSatisfy { $0.pose == $0.pose.clamped })

        // Nudging cannot walk the frame out of what the renderer accepts.
        var pose = FramePose(pitch: 3, yaw: -4, roll: 9, panX: 2, panY: -2, zoom: 12)
        pose = pose.clamped
        XCTAssertEqual(pose.pitch, 1, accuracy: 0.0001)
        XCTAssertEqual(pose.yaw, -1, accuracy: 0.0001)
        XCTAssertEqual(pose.zoom, 1.8, accuracy: 0.0001)

        // Shift snaps to a step, so a lean can be exactly a quarter turn.
        let snapped = FramePose(pitch: 0.237, yaw: -0.481, zoom: 1.113).snapped()
        XCTAssertEqual(snapped.pitch, 0.25, accuracy: 0.0001)
        XCTAssertEqual(snapped.yaw, -0.5, accuracy: 0.0001)
        XCTAssertEqual(snapped.zoom, 1.1, accuracy: 0.0001)
    }

    /// A Mac's screen is reported in points and recorded in pixels, and
    /// those are not the same number on any Mac made in the last decade.
    func testCaptureUsesEveryPixelTheScreenHas() {
        // A 14-inch MacBook Pro's built-in display.
        let retina = ScreenRecorder.capturePixels(points: CGSize(width: 1512, height: 982), scale: 2)
        XCTAssertEqual(retina, CGSize(width: 3024, height: 1964))
        // An external display at one pixel per point is unchanged.
        XCTAssertEqual(ScreenRecorder.capturePixels(points: CGSize(width: 2560, height: 1440), scale: 1),
                       CGSize(width: 2560, height: 1440))
        // Odd results are nudged even; H.264 will not take them otherwise.
        let odd = ScreenRecorder.capturePixels(points: CGSize(width: 801, height: 507), scale: 1)
        XCTAssertEqual(odd.width.truncatingRemainder(dividingBy: 2), 0)
        XCTAssertEqual(odd.height.truncatingRemainder(dividingBy: 2), 0)
        // A scale that was never reported must not collapse the capture.
        XCTAssertEqual(ScreenRecorder.capturePixels(points: CGSize(width: 1440, height: 900), scale: 0),
                       CGSize(width: 1440, height: 900))

        func rate(_ settings: [String: Any]) -> Int {
            ((settings[AVVideoCompressionPropertiesKey] as? [String: Any])?[AVVideoAverageBitRateKey] as? Int) ?? 0
        }
        let hd30 = ScreenRecorder.captureSettings(width: 1920, height: 1080, frameRate: 30)
        let hd60 = ScreenRecorder.captureSettings(width: 1920, height: 1080, frameRate: 60)
        let retina60 = ScreenRecorder.captureSettings(width: 3024, height: 1964, frameRate: 60)
        // Twice the frames, and four times the pixels, each cost bits —
        // the flat per-pixel figure this replaced charged for neither.
        XCTAssertGreaterThan(rate(hd60), rate(hd30))
        XCTAssertGreaterThan(rate(retina60), rate(hd60) * 2)
        XCTAssertEqual(hd60[AVVideoWidthKey] as? Int, 1920)
        XCTAssertEqual(hd60[AVVideoCodecKey] as? AVVideoCodecType, .h264)
        // Beyond H.264's reach the encoder would simply refuse.
        XCTAssertEqual(ScreenRecorder.captureSettings(width: 6016, height: 3384, frameRate: 60)[AVVideoCodecKey] as? AVVideoCodecType, .hevc)
    }

    /// Recognised words become lines that can be read: split where a
    /// sentence or a breath ends, never overlapping, never silently
    /// dropping a word.
    func testCaptionsBreakIntoReadableLines() throws {
        func word(_ text: String, _ start: Double, _ duration: Double = 0.3) -> CaptionWord {
            CaptionWord(text: text, start: start, duration: duration)
        }
        let spoken = [
            word("Today", 0.2), word("we", 0.6), word("are", 0.9), word("recording.", 1.2),
            word("Then", 3.0), word("we", 3.3), word("edit", 3.6), word("it", 3.9),
            word("and", 4.2), word("we", 4.5), word("publish", 4.8), word("it", 5.1),
        ]
        let cues = CaptionBuilder.cues(from: spoken, wordsPerLine: 7)
        XCTAssertGreaterThan(cues.count, 2)
        // The full stop ends a line, and the pause after it starts the next.
        XCTAssertEqual(cues[0].text, "Today we are recording.")
        XCTAssertEqual(cues[1].start, 3.0, accuracy: 0.0001)
        // Nothing overlaps, and the words all survive.
        for pair in zip(cues, cues.dropFirst()) { XCTAssertLessThanOrEqual(pair.0.end, pair.1.start + 0.0001) }
        XCTAssertEqual(cues.flatMap { $0.text.split(separator: " ") }.count, spoken.count)
        // A line is held past its last word so it can be finished reading.
        XCTAssertGreaterThan(cues[0].end, 1.5)
        // No line may fill the screen, however long the sentence runs.
        let chatter = (0..<40).map { word("word\($0)", Double($0) * 0.25) }
        XCTAssertTrue(CaptionBuilder.cues(from: chatter, wordsPerLine: 4).allSatisfy { $0.text.split(separator: " ").count <= 4 })
        // Re-splitting is done from the words, without listening again.
        let reflowed = CaptionBuilder.reflow(cues, wordsPerLine: 3)
        XCTAssertTrue(reflowed.allSatisfy { $0.text.split(separator: " ").count <= 3 })
        XCTAssertEqual(reflowed.flatMap { $0.text.split(separator: " ") }.count, spoken.count)

        // Recognised timings stand while the line is the recognised one.
        XCTAssertEqual(cues[0].timedWords.map(\.start), [0.2, 0.6, 0.9, 1.2])
        // Rewritten, they are shared out rather than pointing at the wrong word.
        var edited = cues[0]; edited.text = "Today we are filming"
        let shared = edited.timedWords
        XCTAssertEqual(shared.count, 4)
        XCTAssertEqual(shared[0].start, edited.start, accuracy: 0.0001)
        XCTAssertEqual(shared.last!.end, edited.end, accuracy: 0.001)
        for pair in zip(shared, shared.dropFirst()) { XCTAssertEqual(pair.0.end, pair.1.start, accuracy: 0.0001) }

        // A subtitle file carries the same lines, stamped as SubRip wants.
        let srt = CaptionBuilder.srt(Array(cues.prefix(1)))
        XCTAssertTrue(srt.hasPrefix("1\n00:00:00,200 --> "))
        XCTAssertTrue(srt.contains("Today we are recording."))
        XCTAssertTrue(CaptionBuilder.vtt(cues).hasPrefix("WEBVTT"))
        XCTAssertTrue(CaptionBuilder.srt(Array(cues.prefix(1)), casing: .upper).contains("TODAY WE ARE RECORDING."))
    }

    /// The caption is drawn where it was asked for, in the colour it was
    /// asked for, and only while its line is on.
    @MainActor func testCaptionsAreDrawnOverTheFinishedFrame() throws {
        let renderer = FocusFlowCompositor(), context = CIContext()
        let canvas = CGRect(x: 0, y: 0, width: 480, height: 270)
        let page = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: canvas)
        var settings = ExportSettings(background: .graphite, canvasSize: canvas.size, padding: 0, cornerRadius: 0, shadow: 0, segments: [], pointerSamples: [], clicks: [], keystrokes: [], cursorSize: 1, clickEffects: false, showKeystrokes: false, cameraURL: nil, showCamera: false, cameraSize: 0.2, cameraX: 0.8, cameraY: 0.8, cameraCornerRadius: 0, cameraShape: .circle)
        settings.showCursor = false
        settings.motion.ambientGraphics = false
        settings.motion.scrollBlur = false
        settings.motion.automaticMotionBlur = false
        settings.trimStart = 0; settings.trimEnd = 8

        var captions = CaptionSettings()
        captions.enabled = true
        captions.animation = .none
        captions.backdrop = .none
        captions.shadow = 0
        captions.size = 0.1
        captions.cues = [CaptionCue(start: 1, duration: 2, text: "Hello there", words: [
            CaptionWord(text: "Hello", start: 1, duration: 0.9),
            CaptionWord(text: "there", start: 1.9, duration: 1.1),
        ])]
        settings.captions = captions

        func frame(_ time: Double) throws -> [UInt8] {
            pixels(try XCTUnwrap(context.createCGImage(renderer.renderFrame(source: page, time: time, settings: settings), from: canvas)))
        }
        /// How far a band of rows departs from the flat grey page.
        func ink(_ data: [UInt8], rows: ClosedRange<Int>) -> Double {
            var total = 0.0
            for row in rows { for column in 0..<480 {
                let index = (row * 480 + column) * 4
                for channel in 0..<3 { total += abs(Double(data[index + channel]) - 127) }
            } }
            return total / Double(rows.count * 480 * 3)
        }
        // Rows are counted from the top of the bitmap, so the lower part
        // of the picture is the higher row numbers.
        let lower = 200...265, upper = 5...70

        let during = try frame(2)
        XCTAssertGreaterThan(ink(during, rows: lower), 2)
        // Before the line is due, and after it has gone, the page is clean.
        let before = try frame(0.5)
        XCTAssertLessThan(ink(before, rows: lower), 0.2)
        XCTAssertLessThan(ink(try frame(4), rows: lower), 0.2)
        // Switched off, nothing is drawn even while the line is current.
        settings.captions.enabled = false
        XCTAssertLessThan(ink(try frame(2), rows: lower), 0.2)
        settings.captions.enabled = true

        // Placed at the top, the words move with it.
        settings.captions.placement = .top
        let top = try frame(2)
        XCTAssertGreaterThan(ink(top, rows: upper), 2)
        XCTAssertLessThan(ink(top, rows: lower), 0.2)
        settings.captions.placement = .bottom

        // The text colour is the text colour.
        settings.captions.textColor = RGBColor(r: 1, g: 0.1, b: 0.1)
        let red = try frame(2)
        func warmth(_ data: [UInt8]) -> Double {
            var total = 0.0
            for row in lower { for column in 0..<480 {
                let index = (row * 480 + column) * 4
                total += Double(data[index]) - Double(data[index + 2])
            } }
            return total
        }
        XCTAssertGreaterThan(warmth(red), warmth(during) + 1000)
        settings.captions.textColor = RGBColor(r: 1, g: 1, b: 1)

        // A panel behind the words darkens the band they sit in.
        func brightness(_ data: [UInt8]) -> Double {
            var total = 0.0
            for row in lower { for column in 0..<480 {
                let index = (row * 480 + column) * 4
                total += Double(data[index]) + Double(data[index + 1]) + Double(data[index + 2])
            } }
            return total / Double(lower.count * 480 * 3)
        }
        settings.captions.backdrop = .pill
        settings.captions.backdropOpacity = 0.9
        XCTAssertLessThan(brightness(try frame(2)), brightness(during) - 5)
        settings.captions.backdrop = .none

        // Fading in means the first instant is fainter than the middle.
        settings.captions.animation = .fade
        XCTAssertLessThan(ink(try frame(1.01), rows: lower), ink(during, rows: lower))
        XCTAssertEqual(ink(try frame(2), rows: lower), ink(during, rows: lower), accuracy: 0.001)

        // Word by word, the accent lands on a different word as it plays.
        settings.captions.animation = .karaoke
        settings.captions.highlightFill = true
        settings.captions.highlightColor = RGBColor(r: 0, g: 0.9, b: 0.2)
        func greenest(_ data: [UInt8]) -> Int {
            var best = -1.0, column = 0
            for candidate in 0..<480 {
                var total = 0.0
                for row in lower {
                    let index = (row * 480 + candidate) * 4
                    total += Double(data[index + 1]) - Double(data[index])
                }
                if total > best { best = total; column = candidate }
            }
            return column
        }
        XCTAssertLessThan(greenest(try frame(1.3)), greenest(try frame(2.4)))

        // Typewriter writes the line out: less of it early than late.
        settings.captions.animation = .typewriter
        XCTAssertLessThan(ink(try frame(1.1), rows: lower), ink(try frame(2.6), rows: lower))

        // A line too long for one row wraps instead of running off the canvas.
        settings.captions.animation = .none
        settings.captions.size = 0.07
        settings.captions.maxWidth = 0.6
        settings.captions.cues = [CaptionCue(start: 1, duration: 2, text: "A much longer line of narration than will fit across one row of this canvas")]
        let wrapped = try XCTUnwrap(CaptionRenderer.render(cue: settings.captions.cues[0], at: 2, settings: settings.captions, accent: CGColor(gray: 1, alpha: 1), canvas: canvas))
        XCTAssertLessThanOrEqual(wrapped.box.width, canvas.width)
        XCTAssertGreaterThan(wrapped.box.height, canvas.height * 0.07 * 1.5)
        XCTAssertEqual(wrapped.box.midX, canvas.midX, accuracy: 1)
        XCTAssertGreaterThan(ink(try frame(2), rows: lower), 1)
    }

    /// Captions survive a project round trip, follow the trim and the
    /// speed on the way out, and a project written before they existed
    /// still opens.
    @MainActor func testCaptionsPersistAndFollowTheEdit() throws {
        let model = EditorModel(restoreLatest: false)
        model.duration = 20; model.trimEnd = 20
        model.videoURL = URL(fileURLWithPath: "/tmp/caption-check-nonexistent.mp4")
        defer { model.videoURL = nil }

        var captions = CaptionSettings()
        captions.enabled = true
        captions.fontName = "Helvetica"
        captions.cues = [
            CaptionCue(start: 1, duration: 2, text: "First line"),
            CaptionCue(start: 5, duration: 2, text: "Second line"),
            CaptionCue(start: 15, duration: 2, text: "Last line"),
        ]
        model.captions = captions

        // What the renderer is handed is what the panel is showing.
        XCTAssertEqual(model.settings().captions.cues.count, 3)
        XCTAssertEqual(model.settings().captions.fontName, "Helvetica")

        // Trimming drops what falls outside it and rebases the rest, and a
        // speed range moves the later lines with the picture.
        model.trimStart = 4
        model.trimEnd = 12
        let trimmed = model.exportableCues()
        XCTAssertEqual(trimmed.count, 1)
        XCTAssertEqual(trimmed[0].text, "Second line")
        XCTAssertEqual(trimmed[0].start, 1, accuracy: 0.0001)
        model.segments = [EditSegment(kind: .speed, start: 4, duration: 1, intensity: 2, x: 0.5, y: 0.5)]
        XCTAssertEqual(model.exportableCues()[0].start, 0.5, accuracy: 0.0001)

        // A preset changes the look and leaves the words alone.
        model.trimStart = 0; model.trimEnd = 20; model.segments = []
        // Edits within a moment of each other are one history step, which
        // in a test is all of them. End the group so the preset is its own.
        model.endPoseGesture()
        model.applyCaptionPreset(.shorts)
        XCTAssertEqual(model.captions.casing, .upper)
        XCTAssertEqual(model.captions.animation, .karaoke)
        XCTAssertEqual(model.captions.cues.map(\.text), ["First line", "Second line", "Last line"])
        XCTAssertEqual(model.captions.fontName, "Helvetica")
        // And it is one step back, like every other edit.
        model.undo()
        XCTAssertEqual(model.captions.casing, .spoken)

        // Editing a line, and adding one at the playhead.
        let first = try XCTUnwrap(model.captions.cues.first)
        model.updateCaptionCue(first.id) { $0.text = "Rewritten" }
        XCTAssertEqual(model.captions.cues.first?.text, "Rewritten")
        model.playhead = 9
        model.addCaptionCue()
        XCTAssertEqual(model.captions.cues.count, 4)
        XCTAssertEqual(model.captions.cues.map(\.start), model.captions.cues.map(\.start).sorted())
        model.removeCaptionCue(first.id)
        XCTAssertEqual(model.captions.cues.count, 3)

        // Written out, read back.
        let encoded = try JSONEncoder().encode(model.captions)
        XCTAssertEqual(try JSONDecoder().decode(CaptionSettings.self, from: encoded), model.captions)

        // A project saved before captions existed opens without them.
        let older = """
        {"videoPath":"/tmp/x.mp4","segments":[],"background":"aurora","ratio":"Source","padding":7,
         "cornerRadius":18,"shadow":30,"cursorSize":1.25,"clickEffects":true}
        """
        let document = try JSONDecoder().decode(ProjectDocument.self, from: Data(older.utf8)).migrated()
        XCTAssertNil(document.captions)
        XCTAssertEqual(CaptionSettings().enabled, false)
        XCTAssertEqual(CaptionSettings().isVisible, false)
    }

    /// Recognition is done a piece at a time, and a piece is a real audio
    /// file cut out of the recording. If that cut fails there is nothing
    /// to listen to, and the whole feature is silent for no visible reason.
    func testCaptionAudioIsSlicedOutOfTheRecording() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("focusflow-caption-audio-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("spoken.m4a")
        try await makeSpokenFixture(at: source, seconds: 8)

        let asset = AVURLAsset(url: source)
        let slice = directory.appendingPathComponent("piece.wav")
        let peak = try await CaptionTranscriber.extractAudio(from: asset, range: CMTimeRange(
            start: CMTime(seconds: 3, preferredTimescale: 600),
            duration: CMTime(seconds: 2, preferredTimescale: 600)), to: slice)

        let cut = AVURLAsset(url: slice)
        XCTAssertEqual(try await cut.load(.duration).seconds, 2, accuracy: 0.2)
        XCTAssertEqual(try await cut.loadTracks(withMediaType: .audio).count, 1)
        XCTAssertTrue(try await cut.load(.isPlayable))
        XCTAssertGreaterThan(peak, 0.1)

        // A FocusFlow recording keeps system audio and the microphone as
        // two tracks, and the narration is on the second one. Reading only
        // the first handed the recogniser the silence the screen was
        // making while somebody talked over it — which is a recording that
        // produces no captions at all and no useful reason why.
        let twoTrack = directory.appendingPathComponent("narrated.mp4")
        try await makeTwoTrackFixture(at: twoTrack, seconds: 6)
        let narrated = AVURLAsset(url: twoTrack)
        XCTAssertEqual(try await narrated.loadTracks(withMediaType: .audio).count, 2)
        let both = directory.appendingPathComponent("both.wav")
        let mixedPeak = try await CaptionTranscriber.extractAudio(from: narrated, range: CMTimeRange(
            start: .zero, duration: CMTime(seconds: 5, preferredTimescale: 600)), to: both)
        XCTAssertGreaterThan(mixedPeak, 0.1)
        XCTAssertGreaterThan(try await loudest(of: both), 0.1)
        XCTAssertEqual(try await AVURLAsset(url: both).loadTracks(withMediaType: .audio).count, 1)

        // Silence is told apart from speech that was not recognised, so the
        // panel can name the actual problem.
        let quiet = directory.appendingPathComponent("quiet.mp4")
        try await makeTwoTrackFixture(at: quiet, seconds: 4, narration: false)
        let quietPiece = directory.appendingPathComponent("quiet.wav")
        let quietPeak = try await CaptionTranscriber.extractAudio(from: AVURLAsset(url: quiet), range: CMTimeRange(
            start: .zero, duration: CMTime(seconds: 3, preferredTimescale: 600)), to: quietPiece)
        XCTAssertLessThan(quietPeak, CaptionTranscriber.silence)

        // The pieces overlap, so a word spoken across a join is heard whole
        // and the repeat is dropped when they are stitched back together.
        XCTAssertGreaterThan(CaptionTranscriber.overlap, 0.5)
        XCTAssertGreaterThan(CaptionTranscriber.chunk, CaptionTranscriber.overlap * 4)
        XCTAssertTrue(CaptionTranscriber.supportedLanguages.contains { $0.identifier == "en-US" })

        // A recording with nothing to hear says so rather than failing late.
        let silentPicture = directory.appendingPathComponent("picture.mp4")
        try await makeFixture(at: silentPicture, camera: false)
        do {
            _ = try await CaptionTranscriber.words(in: silentPicture, language: "en-US") { _ in }
            XCTFail("A recording with no audio should refuse before asking for permission")
        } catch let error as CaptionError {
            guard case .noAudio = error else { return XCTFail("Expected the no-audio refusal, got \(error)") }
        }
    }

    /// The loudest sample in a file, as a share of full scale.
    private func loudest(of url: URL) async throws -> Double {
        let asset = AVURLAsset(url: url)
        let track = try await XCTUnwrap(asset.loadTracks(withMediaType: .audio).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false])
        reader.add(output)
        reader.startReading()
        var peak = 0.0
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            var length = 0
            var pointer: UnsafeMutablePointer<Int8>?
            guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil,
                                              totalLengthOut: &length, dataPointerOut: &pointer) == noErr,
                  let pointer else { continue }
            pointer.withMemoryRebound(to: Int16.self, capacity: length / 2) { samples in
                for index in 0..<(length / 2) {
                    peak = max(peak, abs(Double(samples[index])) / 32768)
                }
            }
        }
        return peak
    }

    /// A recording shaped like FocusFlow's own: a picture, a silent system
    /// audio track, and the microphone second.
    private func makeTwoTrackFixture(at url: URL, seconds: Double, narration: Bool = true) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let picture = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 160, AVVideoHeightKey: 90])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: picture, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: 160, kCVPixelBufferHeightKey as String: 90,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true])
        writer.add(picture)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64_000]
        let system = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        let microphone = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        writer.add(system); writer.add(microphone)
        writer.startWriting(); writer.startSession(atSourceTime: .zero)

        // The writer throttles an input that has run ahead of the others,
        // so filling the tracks one after another deadlocks on the first.
        async let spoken: Void = fill(system, seconds: seconds, amplitude: 0)
        async let narrated: Void = fill(microphone, seconds: seconds, amplitude: narration ? 0.35 : 0)
        let context = CGContext(data: nil, width: 160, height: 90, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)!
        context.setFillColor(CGColor(gray: 0.5, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 160, height: 90))
        let still = context.makeImage()!
        for frame in 0..<Int(seconds * 10) {
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
            let pixels = try XCTUnwrap(buffer)
            CVPixelBufferLockBaseAddress(pixels, [])
            let target = CGContext(data: CVPixelBufferGetBaseAddress(pixels), width: 160, height: 90,
                                   bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixels),
                                   space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)!
            target.draw(still, in: CGRect(x: 0, y: 0, width: 160, height: 90))
            CVPixelBufferUnlockBaseAddress(pixels, [])
            while !picture.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            XCTAssertTrue(adaptor.append(pixels, withPresentationTime: CMTime(value: Int64(frame), timescale: 10)))
        }
        picture.markAsFinished()
        try await spoken
        try await narrated
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)
    }

    /// Writes a tone, or silence, into an audio input.
    private func fill(_ input: AVAssetWriterInput, seconds: Double, amplitude: Double) async throws {
        let rate = 44_100.0, block = 4_410
        var description = AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 4,
            mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        var format: CMFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &description, layoutSize: 0,
                                       layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil,
                                       formatDescriptionOut: &format)
        let shape = try XCTUnwrap(format)
        var written = 0
        let total = Int(seconds * rate)
        while written < total {
            let count = min(block, total - written)
            var samples = [Float](repeating: 0, count: count)
            if amplitude > 0 {
                for index in 0..<count {
                    samples[index] = Float(sin(Double(written + index) * 2 * .pi * 300 / rate) * amplitude)
                }
            }
            var buffer: CMBlockBuffer?
            let bytes = count * 4
            CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: bytes,
                blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
                dataLength: bytes, flags: 0, blockBufferOut: &buffer)
            let holder = try XCTUnwrap(buffer)
            _ = samples.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: holder, offsetIntoDestination: 0, dataLength: bytes) }
            var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(rate)),
                presentationTimeStamp: CMTime(value: CMTimeValue(written), timescale: CMTimeScale(rate)),
                decodeTimeStamp: .invalid)
            var sample: CMSampleBuffer?
            CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: holder, formatDescription: shape,
                sampleCount: count, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                sampleSizeEntryCount: 1, sampleSizeArray: [4], sampleBufferOut: &sample)
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            XCTAssertTrue(input.append(try XCTUnwrap(sample)))
            written += count
        }
        input.markAsFinished()
    }

    /// A few seconds of tone, written as a real AAC file.
    private func makeSpokenFixture(at url: URL, seconds: Double) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000,
        ])
        input.expectsMediaDataInRealTime = false
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let rate = 44_100.0, block = 4_410
        var format: CMFormatDescription?
        var description = AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 4,
            mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &description,
                                       layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
                                       extensions: nil, formatDescriptionOut: &format)
        let shape = try XCTUnwrap(format)
        var written = 0
        let total = Int(seconds * rate)
        while written < total {
            let count = min(block, total - written)
            var samples = [Float](repeating: 0, count: count)
            for index in 0..<count {
                samples[index] = Float(sin(Double(written + index) * 2 * .pi * 220 / rate) * 0.3)
            }
            var buffer: CMBlockBuffer?
            let bytes = count * 4
            CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
                blockLength: bytes, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
                offsetToData: 0, dataLength: bytes, flags: 0, blockBufferOut: &buffer)
            let block = try XCTUnwrap(buffer)
            _ = samples.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes) }
            var sample: CMSampleBuffer?
            var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(rate)),
                                            presentationTimeStamp: CMTime(value: CMTimeValue(written), timescale: CMTimeScale(rate)),
                                            decodeTimeStamp: .invalid)
            CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: shape,
                                      sampleCount: count, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                      sampleSizeEntryCount: 1, sampleSizeArray: [4], sampleBufferOut: &sample)
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            XCTAssertTrue(input.append(try XCTUnwrap(sample)))
            written += count
        }
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)
    }

    private func pixels(_ image: CGImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        bytes.withUnsafeMutableBytes { storage in
            let context = CGContext(data: storage.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes
    }
    private func makeFixture(at url: URL, camera: Bool) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 180])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB, kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 180, kCVPixelBufferCGImageCompatibilityKey as String: true, kCVPixelBufferCGBitmapContextCompatibilityKey as String: true])
        writer.add(input); writer.startWriting(); writer.startSession(atSourceTime: .zero)
        for frame in 0..<60 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            var buffer: CVPixelBuffer?; CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
            let image = buffer!; CVPixelBufferLockBaseAddress(image, [])
            let context = CGContext(data: CVPixelBufferGetBaseAddress(image), width: 320, height: 180, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(image), space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)!
            for x in stride(from: 0, to: 320, by: 4) {
                context.setFillColor(camera ? CGColor(red: 0.9, green: 0.1, blue: 0.1, alpha: 1) : CGColor(gray: (x / 4).isMultiple(of: 2) ? 0.05 : 0.95, alpha: 1))
                context.fill(CGRect(x: x, y: 0, width: 4, height: 180))
            }
            CVPixelBufferUnlockBaseAddress(image, [])
            XCTAssertTrue(adaptor.append(image, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)))
        }
        input.markAsFinished(); await writer.finishWriting(); XCTAssertEqual(writer.status, .completed)
    }
}
