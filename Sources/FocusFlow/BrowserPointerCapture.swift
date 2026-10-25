import AppKit
import CoreGraphics

/// Records pointer movement and clicks while a Chrome tab is being captured.
///
/// A tab recording arrives from the browser as pixels and nothing else: the
/// page doing the recording cannot see events in the tab it is capturing, so
/// without this a browser recording has no clicks, and the click-driven zooms
/// never appear.
///
/// The app can see the pointer, but only in screen coordinates — so the work
/// here is locating the tab's content area on screen. The browser reports the
/// captured size in pixels; Chrome's web content spans the full width of its
/// window and sits flush with the bottom, so that size plus the window's
/// bounds pins the rectangle down. The width is checked against the window as
/// a guard against mapping against the wrong window.
///
/// This is an approximation, and deliberately a conservative one: samples are
/// taken only while Chrome is frontmost and the pointer is inside the computed
/// content area, so a stray click in another app cannot invent a zoom.
@MainActor
final class BrowserPointerCapture {
    private(set) var clicks: [RecordedClick] = []
    private(set) var samples: [PointerSample] = []

    private var timer: Timer?
    private var start = Date()
    private var pausedTotal: TimeInterval = 0
    private var pausedSince: Date?
    private var lastButtonDown = false
    private var viewportPixels: CGSize = .zero
    private var cachedWindow: (frame: CGRect, scale: CGFloat, at: Date)?

    var isRunning: Bool { timer != nil }

    /// `pixels` is the captured surface size the browser reports, which for a
    /// tab capture is the page viewport in device pixels.
    func begin(viewportPixels pixels: CGSize) {
        stop()
        clicks = []
        samples = []
        pausedTotal = 0
        pausedSince = nil
        lastButtonDown = false
        cachedWindow = nil
        viewportPixels = pixels
        guard pixels.width > 0, pixels.height > 0 else { return }

        start = Date()
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Moves time zero to now, discarding anything already collected.
    ///
    /// `begin` runs when the page asks to start, but the browser's recorder
    /// starts after that round trip returns — so samples taken in between sit
    /// before the video's first frame and drag the cursor behind.
    func markRecordingStarted() {
        guard timer != nil else { return }
        start = Date()
        pausedTotal = 0
        clicks = []
        samples = []
        lastButtonDown = CGEventSource.buttonState(.combinedSessionState, button: .left)
    }

    func pause() {
        guard timer != nil, pausedSince == nil else { return }
        pausedSince = Date()
    }

    func resume() {
        guard let since = pausedSince else { return }
        pausedTotal += Date().timeIntervalSince(since)
        pausedSince = nil
        // The pointer may have moved while paused; do not draw a line through it.
        lastButtonDown = CGEventSource.buttonState(.combinedSessionState, button: .left)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        pausedSince = nil
    }

    /// Clears everything, for a session that ended without producing a video.
    func discard() {
        stop()
        clicks = []
        samples = []
    }

    // MARK: - Sampling

    private func sample() {
        guard timer != nil, pausedSince == nil, let event = CGEvent(source: nil) else { return }
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == BrowserPointerCapture.chromeBundleID else {
            // Keep the button state current so returning to Chrome mid-click
            // does not register as a fresh press.
            lastButtonDown = CGEventSource.buttonState(.combinedSessionState, button: .left)
            return
        }
        guard let viewport = contentArea() else { return }

        let location = event.location
        guard viewport.contains(location) else {
            lastButtonDown = CGEventSource.buttonState(.combinedSessionState, button: .left)
            return
        }

        // CGEvent locations and CGWindow bounds share a top-left origin, which
        // is also how segment coordinates are stored, so no flip is needed.
        let x = min(1, max(0, (location.x - viewport.minX) / max(viewport.width, 1)))
        let y = min(1, max(0, (location.y - viewport.minY) / max(viewport.height, 1)))
        let time = Date().timeIntervalSince(start) - pausedTotal
        guard time >= 0 else { return }

        let down = CGEventSource.buttonState(.combinedSessionState, button: .left)
        samples.append(PointerSample(time: time, x: x, y: y, shape: SystemCursorShape.current(), pressed: down))
        if down && !lastButtonDown {
            clicks.append(RecordedClick(time: time, x: x, y: y))
        }
        lastButtonDown = down
    }

    /// The on-screen rectangle of Chrome's web content, in CG screen space.
    private func contentArea() -> CGRect? {
        if let cached = cachedWindow, Date().timeIntervalSince(cached.at) < 0.25 {
            return viewport(in: cached.frame, scale: cached.scale)
        }
        guard let chrome = NSRunningApplication.runningApplications(
                withBundleIdentifier: BrowserPointerCapture.chromeBundleID).first else { return nil }
        let pid = chrome.processIdentifier

        guard let windows = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }

        // The list is front to back, so the first qualifying window is the one
        // in front — the one the person is working in.
        for info in windows {
            guard (info[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  let raw = info[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: raw as CFDictionary),
                  frame.width > 240, frame.height > 240 else { continue }

            let scale = BrowserPointerCapture.scale(for: frame)
            guard let area = viewport(in: frame, scale: scale) else { continue }
            cachedWindow = (frame, scale, Date())
            return area
        }
        return nil
    }

    private func viewport(in window: CGRect, scale: CGFloat) -> CGRect? {
        let width = viewportPixels.width / scale
        let height = viewportPixels.height / scale
        guard height > 0, height < window.height else { return nil }
        // Chrome's content spans the window's full width on macOS. A window
        // that does not match is a different window — a popup, or the picker.
        guard abs(width - window.width) <= 40 else { return nil }
        return CGRect(x: window.minX, y: window.maxY - height, width: window.width, height: height)
    }

    // MARK: - Helpers

    static let chromeBundleID = "com.google.Chrome"

    /// Backing scale of the display showing most of `frame`. CGWindow bounds
    /// are top-left origin, so screen frames are converted before comparing.
    private static func scale(for frame: CGRect) -> CGFloat {
        guard let primary = NSScreen.screens.first else { return 2 }
        let flipHeight = primary.frame.maxY
        var best: (screen: NSScreen, overlap: CGFloat)?
        for screen in NSScreen.screens {
            let converted = CGRect(x: screen.frame.minX,
                                   y: flipHeight - screen.frame.maxY,
                                   width: screen.frame.width,
                                   height: screen.frame.height)
            let overlap = converted.intersection(frame)
            let area = overlap.isNull ? 0 : overlap.width * overlap.height
            if area > (best?.overlap ?? 0) { best = (screen, area) }
        }
        return (best?.screen ?? primary).backingScaleFactor
    }
}
