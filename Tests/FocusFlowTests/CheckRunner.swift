import Foundation

// Standalone assertions keep the checks runnable with Apple's Command Line Tools,
// where the XCTest framework is not installed.
private let checkLock = NSLock()
private var failures: [String] = []
func XCTFail(_ message: String, file: StaticString = #filePath, line: UInt = #line) {
    checkLock.lock(); defer { checkLock.unlock() }
    failures.append("\(file):\(line): \(message)")
}
func XCTAssertTrue(_ value: Bool, file: StaticString = #filePath, line: UInt = #line) { if !value { XCTFail("Expected true", file: file, line: line) } }
func XCTAssertNil<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) { if value != nil { XCTFail("Expected nil", file: file, line: line) } }
func XCTAssertEqual<T: Equatable>(_ a: T, _ b: T, file: StaticString = #filePath, line: UInt = #line) { if a != b { XCTFail("\(a) != \(b)", file: file, line: line) } }
func XCTAssertEqual(_ a: Double, _ b: Double, accuracy: Double, file: StaticString = #filePath, line: UInt = #line) { if abs(a - b) > accuracy { XCTFail("\(a) != \(b) ± \(accuracy)", file: file, line: line) } }
func XCTAssertLessThan<T: Comparable>(_ a: T, _ b: T, file: StaticString = #filePath, line: UInt = #line) { if !(a < b) { XCTFail("\(a) is not less than \(b)", file: file, line: line) } }
func XCTAssertLessThanOrEqual<T: Comparable>(_ a: T, _ b: T, file: StaticString = #filePath, line: UInt = #line) { if !(a <= b) { XCTFail("\(a) is not at most \(b)", file: file, line: line) } }
func XCTAssertGreaterThan<T: Comparable>(_ a: T, _ b: T, file: StaticString = #filePath, line: UInt = #line) { if !(a > b) { XCTFail("\(a) is not greater than \(b)", file: file, line: line) } }
func XCTUnwrap<T>(_ value: T?) throws -> T { guard let value else { throw NSError(domain: "FocusFlowChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: "Expected non-nil value"]) }; return value }

@main struct CheckRunner {
    static func main() async {
        let tests = FocusFlowTests()
        do {
            print("Checking cursor and compatibility…")
            tests.testCursorStaysWithinBoundsAndDisappearsAcrossGaps()
            try tests.testLegacyProjectAndCaptureMetadataStillDecode()
            print("Checking crop, motion, and editable appearance…")
            try tests.testCropGeometryMotionAndPresentationRoundTrip()
            try tests.testRenderedCropChromeCursorAndMotion()
            print("Checking undo and browser bridge…")
            await tests.testUndoRedoAndSegmentBounds()
            try await tests.testBrowserBridgeRejectsUntrustedWritesAndServesResources()
            print("Checking backgrounds, export options, and project compatibility…")
            try tests.testCustomBackgroundKindsRenderDistinctly()
            tests.testExportResolutionScalesCanvasKeepingAspect()
            try tests.testProjectWithoutNewFieldsStillDecodes()
            print("Checking the updater…")
            try tests.testReleaseVersionOrdering()
            try tests.testReleaseParsingAcceptsGitHubDiskImagesOnly()
            try tests.testUpdateSwapReplacesBundleAndRestoresOnFailure()
            print("Rendering and validating MP4 exports…")
            try await tests.testRenderedExportTrimSpeedRegionalBlurAndCamera()
        } catch { XCTFail(error.localizedDescription) }
        if failures.isEmpty { print("PASS: 9 check groups — cursor, compatibility, crop/motion/persistence, rendered presentation, undo/bounds, browser bridge, backgrounds/export options, updater, real MP4 export.") }
        else { failures.forEach { print("FAIL: \($0)") }; exit(1) }
    }
}
