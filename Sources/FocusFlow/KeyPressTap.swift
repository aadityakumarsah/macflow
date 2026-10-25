import AppKit
import ApplicationServices
import CoreGraphics

/// Notices that a key was pressed, or the wheel turned, for as long as a
/// recording lasts.
///
/// This is a listen-only event tap rather than an `NSEvent` global monitor.
/// A global monitor delivers *key* events only to a process trusted for
/// Accessibility — control of the whole machine, far more than noticing that
/// a key went down, and a permission this app needs for nothing else. A tap
/// asks instead for Input Monitoring, which is the permission the recorder
/// already explains and requests. The two were mismatched: a Mac that had
/// granted Input Monitoring and refused Accessibility recorded no keypresses
/// at all, so typing was never followed, and the recorder reported the
/// permission it checks as present the whole time.
///
/// Nothing is modified or swallowed — every event is passed straight back.
/// A machine that granted Accessibility instead keeps working through the
/// global monitor, which is the fallback when no tap can be made.
final class KeyPressTap {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var fallbackMonitor: Any?
    private let handler: (NSEvent) -> Void
    private let scrollHandler: ((NSEvent) -> Void)?

    /// Whether keypresses can be captured at all. Either permission will do,
    /// which is why both are asked about.
    static var isPermitted: Bool { CGPreflightListenEventAccess() || AXIsProcessTrusted() }

    init(handler: @escaping (NSEvent) -> Void, onScroll: ((NSEvent) -> Void)? = nil) {
        self.handler = handler
        self.scrollHandler = onScroll
        var mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        if onScroll != nil { mask |= CGEventMask(1 << CGEventType.scrollWheel.rawValue) }

        let callback: CGEventTapCallBack = { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            Unmanaged<KeyPressTap>.fromOpaque(context).takeUnretainedValue().receive(type, event)
            return Unmanaged.passUnretained(event)
        }
        if let tap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                       place: .tailAppendEventTap,
                                       options: .listenOnly,
                                       eventsOfInterest: mask,
                                       callback: callback,
                                       userInfo: Unmanaged.passUnretained(self).toOpaque()) {
            self.tap = tap
            source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
        } else {
            // No Input Monitoring. An Accessibility-trusted Mac still reports
            // keys this way; an untrusted one silently reports none, which is
            // what the recorder's warning is for.
            var kinds: NSEvent.EventTypeMask = [.keyDown]
            if onScroll != nil { kinds.insert(.scrollWheel) }
            fallbackMonitor = NSEvent.addGlobalMonitorForEvents(matching: kinds) { [weak self] event in
                guard let self else { return }
                if event.type == .scrollWheel { self.scrollHandler?(event) } else { self.handler(event) }
            }
        }
    }

    /// Delivered on the main run loop: the source is attached to it.
    private func receive(_ type: CGEventType, _ event: CGEvent) {
        // A tap the system switches off — because the callback was slow, or
        // because of user input — stays off until it is switched back on, and
        // the rest of the recording would capture nothing.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        guard let received = NSEvent(cgEvent: event) else { return }
        switch type {
        case .keyDown: handler(received)
        case .scrollWheel: scrollHandler?(received)
        default: return
        }
    }

    func invalidate() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let fallbackMonitor { NSEvent.removeMonitor(fallbackMonitor) }
        tap = nil
        source = nil
        fallbackMonitor = nil
    }

    deinit { invalidate() }
}
