import Foundation
import AppKit

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
func XCTAssertNotEqual<T: Equatable>(_ a: T, _ b: T, file: StaticString = #filePath, line: UInt = #line) { if a == b { XCTFail("\(a) == \(b), expected them to differ", file: file, line: line) } }
func XCTAssertEqual(_ a: Double, _ b: Double, accuracy: Double, file: StaticString = #filePath, line: UInt = #line) { if abs(a - b) > accuracy { XCTFail("\(a) != \(b) ± \(accuracy)", file: file, line: line) } }
func XCTAssertLessThan<T: Comparable>(_ a: T, _ b: T, file: StaticString = #filePath, line: UInt = #line) { if !(a < b) { XCTFail("\(a) is not less than \(b)", file: file, line: line) } }
func XCTAssertLessThanOrEqual<T: Comparable>(_ a: T, _ b: T, file: StaticString = #filePath, line: UInt = #line) { if !(a <= b) { XCTFail("\(a) is not at most \(b)", file: file, line: line) } }
func XCTAssertGreaterThan<T: Comparable>(_ a: T, _ b: T, file: StaticString = #filePath, line: UInt = #line) { if !(a > b) { XCTFail("\(a) is not greater than \(b)", file: file, line: line) } }
func XCTUnwrap<T>(_ value: T?) throws -> T { guard let value else { throw NSError(domain: "FocusFlowChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: "Expected non-nil value"]) }; return value }

@main struct CheckRunner {
    static func main() async {
        // System cursor artwork requires an initialized AppKit application.
        _ = NSApplication.shared
        let tests = FocusFlowTests()
        do {
            print("Checking cursor and compatibility…")
            tests.testCursorStaysWithinBoundsAndDisappearsAcrossGaps()
            try tests.testEditableCursorSizeHighlightAndClickRendering()
            tests.testAutomaticEditsProduceZoomsOnly()
            tests.testClickZoomHoldsStillUntilThePointerLeavesTheFrame()
            tests.testTypingFollowTracksRunsAndStaysInFrame()
            tests.testSpotlightIsRetiredAndTypingReachesBrowserRecordings()
            tests.testClickAfterTypingKeepsItsOwnZoom()
            try tests.testSoundsAndTextCursorFollowTheRecording()
            try tests.testPixelateAndOutlineRenderInsideSelectedRegion()
            await tests.testCursorResetIsUndoable()
            try await tests.testRecordedCursorNeverGetsSecondOverlay()
            try tests.testLegacyProjectAndCaptureMetadataStillDecode()
            print("Checking crop, motion, and editable appearance…")
            try tests.testCropGeometryMotionAndPresentationRoundTrip()
            try tests.testRenderedCropChromeCursorAndMotion()
            print("Checking undo and browser bridge…")
            await tests.testUndoRedoAndSegmentBounds()
            try await tests.testBrowserBridgeRejectsUntrustedWritesAndServesResources()
            try await tests.testBridgeAcceptsWebStudioOriginOnly()
            print("Checking backgrounds, export options, and project compatibility…")
            try tests.testCustomBackgroundKindsRenderDistinctly()
            try tests.testAutomaticMotionBlurChangesMovingZoomFrames()
            tests.testExportResolutionScalesCanvasKeepingAspect()
            try tests.testProjectWithoutNewFieldsStillDecodes()
            print("Checking the updater…")
            try tests.testReleaseVersionOrdering()
            await tests.testUpdaterStateDrivesTheVisibleControls()
            try tests.testReleaseParsingAcceptsGitHubDiskImagesOnly()
            try tests.testUpdateSwapReplacesBundleAndRestoresOnFailure()
            print("Checking key storage and editor controls…")
            try tests.testAPIKeyStorageAndValidation()
            await tests.testSplitIsOfferedOnlyWhenItCanAct()
            tests.testCustomAspectRatioGeometry()
            tests.testTimelineDragFollowsThePointer()
            try tests.testBundledBackgroundsResolveAndDecode()
            try tests.testColourGradesAlterTheFrameOnly()
            try tests.testScrollBlurSoftensMovingContentOnly()
            try tests.testCameraMovesTiltAndSettle()
            print("Checking smoothing, output quality, and the 3D handles…")
            tests.testCameraSmoothsEveryMoveItMakes()
            tests.testExportKeepsTheRecordingsResolutionAndRate()
            try tests.testThreeDHandlesSitOnTheRenderedFrame()
            try tests.testLeaningTheFrameKeepsItSharp()
            tests.testQuickPosesAndNudging()
            try tests.testThreeDPresetsRenderAndRoundTrip()
            try await tests.testNestedLayersAndRangeTiming()
            try await tests.testEditablePosePath()
            try await tests.testThreeDPresetWorkflowAndPreviewReuse()
            try tests.testOlderProjectsAreBroughtUpToTodaysDefaults()
            print("Checking capture resolution and captions…")
            tests.testCaptureUsesEveryPixelTheScreenHas()
            try tests.testCaptionsBreakIntoReadableLines()
            try await tests.testCaptionsAreDrawnOverTheFinishedFrame()
            try await tests.testCaptionsPersistAndFollowTheEdit()
            try await tests.testCaptionAudioIsSlicedOutOfTheRecording()
            print("Checking the selection and cursor graphics…")
            try tests.testSelectionIsDrawnWhereItHappens()
            try tests.testCursorMarksAndCustomArtwork()
            print("Rendering and validating MP4 exports…")
            try await tests.testRenderedExportTrimSpeedRegionalBlurAndCamera()
        } catch { XCTFail(error.localizedDescription) }
        if failures.isEmpty { print("PASS: 13 check groups — cursor, compatibility, crop/motion/persistence, rendered presentation, undo/bounds, browser bridge, backgrounds/export options, updater, keys/editor controls, smoothing/output quality/3D handles, capture resolution/captions, selection/cursor graphics, real MP4 export.") }
        else { failures.forEach { print("FAIL: \($0)") }; exit(1) }
    }
}
