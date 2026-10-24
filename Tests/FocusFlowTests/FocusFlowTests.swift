import AVFoundation
import AppKit
import CoreImage
import CoreText

final class FocusFlowTests {
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
        var settings = ExportSettings(background: .cream, canvasSize: CGSize(width: 640, height: 360), padding: 7, cornerRadius: 18, shadow: 20, segments: [], pointerSamples: [], clicks: [], keystrokes: [], cursorSize: 1, clickEffects: false, showKeystrokes: false, cameraURL: camera, showCamera: true, cameraSize: 0.25, cameraX: 0.83, cameraY: 0.75, cameraCornerRadius: 12, cameraShape: .circle)
        settings.trimStart = 0.4; settings.trimEnd = 1.6; settings.playbackRate = 2
        let clean = directory.appendingPathComponent("clean.mp4")
        try await VideoExporter.export(source: source, destination: clean, settings: settings) { _ in }
        let duration = try await AVURLAsset(url: clean).load(.duration).seconds
        XCTAssertEqual(duration, 0.6, accuracy: 0.06)
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
        settings.motion = MotionAppearance(entrance: .rise, duration: 1, fadeOut: true)
        settings.trimEnd = 2
        let start = pixels(try render(settings, 0)), end = pixels(try render(settings, 2))
        XCTAssertEqual(start, end)
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

        // The blurred backdrop derives from the frame, which is red here.
        let blurred = try corner(CustomBackground(kind: .blur, blurRadius: 20, dim: 0))
        XCTAssertGreaterThan(Int(blurred[0]), Int(blurred[2]))
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

        let previous = BrowserRecorderBridge.usesWebStudio
        BrowserRecorderBridge.usesWebStudio = true
        defer { BrowserRecorderBridge.usesWebStudio = previous }
        let webURL = try XCTUnwrap(bridge.sessionURL)
        XCTAssertTrue(webURL.absoluteString.hasPrefix(BrowserRecorderBridge.webStudioURL))
        XCTAssertTrue((webURL.fragment ?? "").contains("port="))
        XCTAssertTrue((webURL.fragment ?? "").hasPrefix(token))
        XCTAssertNil(webURL.query)
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
