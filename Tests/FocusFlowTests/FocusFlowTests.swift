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
