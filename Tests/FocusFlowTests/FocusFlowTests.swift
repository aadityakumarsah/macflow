import AVFoundation
import AppKit
import CoreImage
import CoreText

final class FocusFlowTests {
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

        // A text selection still earns one steady zoom, rather than a zoom and
        // a spotlight travelling across it together.
        let selectionZooms = edits.filter { $0.start > 8.5 }
        XCTAssertEqual(selectionZooms.count, 1)
        // And it does not pan: tracking is what made the frame travel.
        XCTAssertTrue(selectionZooms.allSatisfy { $0.tracksSelection != true })

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
        XCTAssertEqual(MotionEngine.viewport(at: 1, segments: [segment], samples: [], crop: crop), CGRect(x: 0, y: 0, width: 1, height: 1))
        XCTAssertEqual(MotionEngine.viewport(at: 5, segments: [segment], samples: [], crop: crop), CGRect(x: 0, y: 0, width: 1, height: 1))
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
        let source = CIImage(color: CIColor(red: 0.95, green: 0.95, blue: 0.95)).cropped(to: canvas)

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
        even.hold = 0.8
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

        // It arrives where the keys say, with the last key, and then holds.
        XCTAssertEqual(centre(5.48), 0.45 + Double(steady.count) * even.advancePerKey, accuracy: 0.01)
        XCTAssertEqual(centre(5.8), centre(5.48), accuracy: 0.0001)

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
        // Still at the start: the caret is crossing the first half-band.
        XCTAssertEqual(heldCentre(2.3), heldCentre(2.0), accuracy: 0.0005)
        // And it has moved by the end of the run, by about a whole band.
        let shifted = heldCentre(5.48) - heldCentre(2.0)
        XCTAssertGreaterThan(shifted, band * 0.8)
        XCTAssertLessThan(shifted, (held.endX ?? 0) - held.x + 0.0001)

        // Somewhere in the run there is a stretch where nothing moves at all,
        // which is the whole point of a dead zone.
        let steps = stride(from: 2.0, through: 5.48, by: 0.04).map(heldCentre)
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
