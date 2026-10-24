import AppKit
import AVFoundation
import Combine
import ScreenCaptureKit
import SwiftUI

private enum CaptureMode: String, CaseIterable, Identifiable {
    case window = "Window"
    case display = "Display"
    case tab = "Chrome tab"
    var id: String { rawValue }
}

struct RecorderView: View {
    @EnvironmentObject private var model: EditorModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var recorder = ScreenRecorder()
    @StateObject private var cameraRecorder = CameraRecorder()
    @State private var includeAudio = true
    @State private var includeMicrophone = false
    @State private var includeCamera = false
    @State private var captureMode: CaptureMode = .window
    @State private var windows: [SCWindow] = []
    @State private var displays: [SCDisplay] = []
    @State private var selectedWindowID: CGWindowID?
    @State private var selectedDisplayID: CGDirectDisplayID?
    @State private var isLoadingSources = true
    @State private var permissionDenied = false
    @State private var inputMonitoringReady = false
    @State private var sourceError: String?
    @State private var completedURL: URL?
    @State private var completedMetadata = RecordingMetadata.empty
    @State private var isFinalizing = false
    @State private var isStarting = false
    @State private var sourcePreview: CGImage?
    @State private var previewError: String?
    @State private var previewRevision = 0
    @State private var frameRate = 60
    @State private var captureRegion = ContentRegion.full
    @State private var selectArea = false
    @State private var selectedCameraID = ""
    @State private var applications: [SCRunningApplication] = []
    private var sourceKey: String {
        let size: CGSize
        switch selectedTarget { case .window(let window): size = window.frame.size; case .display(let display): size = display.frame.size; case nil: size = .zero }
        return "\(captureMode.rawValue)-\(selectedWindowID ?? 0)-\(selectedDisplayID ?? 0)-\(size.width)-\(size.height)-\(recorder.isRecording)-\(previewRevision)"
    }

    private var microphoneSupported: Bool {
        if #available(macOS 15.0, *) { return true }
        return false
    }

    private var selectedTarget: CaptureTarget? {
        switch captureMode {
        case .tab: return nil
        case .window:
            guard let window = windows.first(where: { $0.windowID == selectedWindowID }) else { return nil }
            return .window(window)
        case .display:
            guard let display = displays.first(where: { $0.displayID == selectedDisplayID }) else { return nil }
            return .display(display)
        }
    }

    var body: some View {
        VStack(spacing: 18) {
            HStack {
                AppIconMark(size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(completedURL != nil ? "Recording ready" : recorder.isRecording ? "Recording" : "New recording").font(.title2.bold())
                    Text(completedURL != nil ? "Click Done to open the editable project" : recorder.isRecording ? recorder.sourceName : "Choose your source. Preview it. Press record.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).font(.title2).foregroundStyle(.secondary).disabled(recorder.isRecording || isStarting || isFinalizing)
            }

            if completedURL != nil {
                completionStatus
            } else if recorder.isRecording {
                recordingStatus
            } else {
                Picker("Capture", selection: $captureMode) {
                    ForEach(CaptureMode.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).disabled(isStarting)
                if captureMode == .tab {
                    BrowserCaptureCard(bridge: model.browserRecorder)
                } else {
                    HStack(alignment: .top, spacing: 14) {
                        sourceList.frame(width: 260).disabled(isStarting)
                        VStack(spacing: 10) {
                            ZStack {
                                livePreview(image: sourcePreview)
                                if selectArea, let sourcePreview {
                                    CropSelectionView(image: sourcePreview, region: $captureRegion).padding(6)
                                }
                            }.frame(height: 225)
                            HStack {
                                Toggle("Select area", isOn: $selectArea).toggleStyle(.checkbox)
                                Spacer()
                                if selectArea { Button("Reset") { captureRegion = .full } }
                            }.font(.caption)
                            Text(selectArea ? "Drag around the pane to record. Only this area is saved." : "Select area to exclude toolbars or record one side of a window.")
                                .font(.caption2).foregroundStyle(.secondary)
                            HStack {
                                Label("Source preview", systemImage: "eye")
                                Spacer()
                                Picker("Quality", selection: $frameRate) { Text("30 fps").tag(30); Text("60 fps").tag(60) }.labelsHidden().frame(width: 100)
                            }.font(.caption).foregroundStyle(.secondary)
                            if let previewError {
                                HStack {
                                    Text(previewError).font(.caption2).foregroundStyle(.secondary)
                                    Button("Retry") { previewRevision += 1 }.font(.caption)
                                }
                            }
                            if includeCamera {
                                Picker("Camera", selection: $selectedCameraID) {
                                    Text("Default camera").tag("")
                                    ForEach(cameraRecorder.devices, id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
                                }.font(.caption)
                            }
                        }.frame(maxWidth: .infinity)
                    }
                }

            }

            if completedURL == nil && captureMode != .tab {
                HStack(spacing: 10) {
                    CaptureOptionToggle(title: "System audio", icon: "speaker.wave.2.fill", isOn: $includeAudio)
                    CaptureOptionToggle(title: "Microphone", icon: "mic.fill", isOn: $includeMicrophone, enabled: microphoneSupported)
                    CaptureOptionToggle(title: "Camera", icon: "video.fill", isOn: $includeCamera)
                }
                .disabled(recorder.isRecording || isStarting || isFinalizing)
            }
            HStack(spacing: 18) {
                Label("Auto zoom", systemImage: "plus.magnifyingglass")
                Label("Cursor", systemImage: "cursorarrow.motionlines")
                Label("Shortcuts", systemImage: "keyboard")
            }.font(.caption).foregroundStyle(AppTheme.green).opacity(captureMode == .tab ? 0 : 1)
            .onChange(of: includeCamera) { _, enabled in
                guard enabled else { cameraRecorder.shutdown(); return }
                Task {
                    do { try await cameraRecorder.prepare(deviceID: selectedCameraID.isEmpty ? nil : selectedCameraID); if !includeCamera { cameraRecorder.shutdown() } }
                    catch { includeCamera = false; model.message = error.localizedDescription }
                }
            }
            .onChange(of: includeMicrophone) { _, enabled in
                guard enabled else { return }
                Task {
                    let granted: Bool
                    switch AVCaptureDevice.authorizationStatus(for: .audio) {
                    case .authorized: granted = true
                    case .notDetermined: granted = await AVCaptureDevice.requestAccess(for: .audio)
                    default: granted = false
                    }
                    if !granted {
                        includeMicrophone = false
                        model.message = "Allow Microphone access for FocusFlow in System Settings → Privacy & Security → Microphone."
                    }
                }
            }
            if !inputMonitoringReady && !recorder.isRecording && captureMode != .tab {
                HStack {
                    Label("Input Monitoring enables click zooms and keystrokes. Screen recording still works without it.", systemImage: "exclamationmark.triangle.fill")
                    Spacer()
                    Button("Open Settings") { openInputMonitoringSettings() }.buttonStyle(.link)
                }.font(.caption).foregroundStyle(.orange)
            }

            if let error = recorder.errorMessage { Text(error).foregroundStyle(.red).font(.caption) }

            if captureMode != .tab || completedURL != nil {
            Button(action: recordAction) {
                if isFinalizing || isStarting {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(.vertical, 8)
                } else {
                    Label(completedURL != nil ? "Done — open editor" : recorder.isRecording ? "Stop recording" : "Start recording", systemImage: completedURL != nil ? "checkmark.circle.fill" : recorder.isRecording ? "stop.fill" : "record.circle")
                    .frame(maxWidth: .infinity).padding(.vertical, 8)
                }
            }
            .buttonStyle(.plain).padding(.vertical, 5)
            .background(recorder.isRecording ? Color.red : AppTheme.green, in: RoundedRectangle(cornerRadius: 10))
            .foregroundStyle(.white).fontWeight(.bold)
            .disabled(isFinalizing || isStarting || (includeCamera && !cameraRecorder.isReady && !recorder.isRecording && completedURL == nil) || (completedURL == nil && !recorder.isRecording && (selectedTarget == nil || (selectArea && (sourcePreview == nil || previewError != nil)))))
            }
        }
        .padding(24).frame(width: 880, height: 720).background(AppTheme.panel)
        .interactiveDismissDisabled(recorder.isRecording || isStarting || isFinalizing)
        .task { await loadSources(requestIfNeeded: true) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            guard !recorder.isRecording, completedURL == nil else { return }
            Task { await loadSources(requestIfNeeded: false) }
        }
        .onDisappear { cameraRecorder.shutdown() }
        .task(id: sourceKey) { await refreshPreview() }
        .onChange(of: selectedWindowID) { _, _ in captureRegion = .full }
        .onChange(of: selectedDisplayID) { _, _ in captureRegion = .full }
        .onChange(of: selectedCameraID) { _, _ in
            guard includeCamera else { return }
            Task { do { try await cameraRecorder.prepare(deviceID: selectedCameraID.isEmpty ? nil : selectedCameraID) } catch { model.message = error.localizedDescription } }
        }
        .onChange(of: captureMode) { _, mode in captureRegion = .full; if mode == .tab { includeCamera = false; cameraRecorder.shutdown() } }
    }

    private var recordingStatus: some View {
        VStack(spacing: 12) {
            livePreview(image: recorder.previewImage).frame(height: 320)
            HStack {
                Label("LIVE", systemImage: "record.circle.fill").foregroundStyle(.red)
                Text(recorder.sourceName).lineLimit(1)
                Spacer()
                Text(format(recorder.elapsed)).monospacedDigit().fontWeight(.semibold)
            }.font(.caption)
            Text("This is the source being recorded. FocusFlow’s own windows are excluded from display captures.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func livePreview(image: CGImage?) -> some View {
        ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: 14).fill(Color(hex: 0x191D2B))
            if let image {
                Image(decorative: image, scale: 1).resizable().scaledToFit().padding(6).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "rectangle.inset.filled.on.rectangle").font(.system(size: 30))
                    Text(selectedTarget == nil ? "Select a source to preview" : "Preparing live preview…").font(.caption)
                }.foregroundStyle(.white.opacity(0.7)).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if includeCamera && cameraRecorder.isReady {
                CameraPreview(session: cameraRecorder.session).frame(width: 100, height: 100)
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white, lineWidth: 2)).padding(14)
            }
        }.clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private func refreshPreview() async {
        sourcePreview = nil; previewError = nil
        guard !recorder.isRecording, let target = selectedTarget, captureMode != .tab else { return }
        let filter: SCContentFilter
        let size: CGSize
        switch target {
        case .window(let window): filter = SCContentFilter(desktopIndependentWindow: window); size = window.frame.size
        case .display(let display): filter = SCContentFilter(display: display, excludingApplications: applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }, exceptingWindows: []); size = display.frame.size
        }
        let config = SCStreamConfiguration(); config.width = 800; config.height = max(2, Int(800 * size.height / max(1, size.width)))
        config.showsCursor = true; config.ignoreShadowsSingleWindow = true; config.scalesToFit = true
        while !Task.isCancelled && !recorder.isRecording {
            do {
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                try Task.checkCancellation(); sourcePreview = image; previewError = nil
                try await Task.sleep(for: .milliseconds(700))
            } catch is CancellationError { return } catch { sourcePreview = nil; previewError = "Preview unavailable: \(error.localizedDescription)"; return }
        }
    }

    private var completionStatus: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 58)).foregroundStyle(AppTheme.green)
            Text("Saved to Movies/FocusFlow").font(.title3.bold())
            Text("Automatic click zooms, cursor movement, keystrokes, and the separate camera layer are ready to edit.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 430)
        }
        .frame(maxWidth: .infinity).frame(height: 390)
        .background(AppTheme.elevated, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(AppTheme.line))
    }

    @ViewBuilder private var sourceList: some View {
        if isLoadingSources {
            ZStack { RoundedRectangle(cornerRadius: 14).fill(AppTheme.elevated); ProgressView("Finding windows…") }.frame(height: 330)
        } else if permissionDenied {
            ZStack {
                RoundedRectangle(cornerRadius: 14).fill(AppTheme.elevated)
                VStack(spacing: 14) {
                    Image(systemName: "rectangle.badge.exclamationmark").font(.system(size: 38)).foregroundStyle(.orange)
                    Text("Screen access is not available yet").font(.headline)
                    Text(sourceError ?? "Confirm FocusFlow is enabled in Screen & System Audio Recording, then check again.").font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 390)
                    HStack {
                        Button("Open Settings") { openScreenRecordingSettings() }
                        Button("Check Again") { Task { await loadSources(requestIfNeeded: true) } }.buttonStyle(.borderedProminent).tint(AppTheme.green)
                    }
                }
            }.frame(height: 330)
        } else if (captureMode == .window && windows.isEmpty) || (captureMode == .display && displays.isEmpty) {
            ContentUnavailableView("No capture sources found", systemImage: "macwindow.badge.plus", description: Text("Open the window you want to record, then click Check Again."))
                .frame(height: 330).background(AppTheme.elevated, in: RoundedRectangle(cornerRadius: 14))
        } else {
            ScrollView {
                LazyVStack(spacing: 8) {
                    if captureMode == .window {
                        ForEach(windows, id: \.windowID) { window in
                            SourceRow(title: window.title ?? "Untitled window", subtitle: "\(window.owningApplication?.applicationName ?? "Application") · \(Int(window.frame.width)) × \(Int(window.frame.height))", icon: "macwindow", selected: selectedWindowID == window.windowID) {
                                selectedWindowID = window.windowID
                            }
                        }
                    } else {
                        ForEach(Array(displays.enumerated()), id: \.element.displayID) { index, display in
                            SourceRow(title: "Display \(index + 1)", subtitle: "\(display.width) × \(display.height)", icon: "display", selected: selectedDisplayID == display.displayID) {
                                selectedDisplayID = display.displayID
                            }
                        }
                    }
                }.padding(10)
            }
            .frame(height: 330).background(AppTheme.elevated, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(AppTheme.line))
        }
    }

    private func loadSources(requestIfNeeded: Bool) async {
        isLoadingSources = true
        sourceError = nil
        inputMonitoringReady = CGPreflightListenEventAccess()
        if requestIfNeeded && !CGPreflightScreenCaptureAccess() {
            _ = CGRequestScreenCaptureAccess()
        }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            permissionDenied = false
            displays = content.displays
            applications = content.applications
            if !displays.contains(where: { $0.displayID == selectedDisplayID }) { selectedDisplayID = displays.first?.displayID }
            windows = content.windows.filter { window in
                guard window.windowLayer == 0, let owner = window.owningApplication, !owner.bundleIdentifier.isEmpty,
                      owner.bundleIdentifier != Bundle.main.bundleIdentifier,
                      let title = window.title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
                return window.frame.width >= 240 && window.frame.height >= 160
            }.sorted { ($0.owningApplication?.applicationName ?? "") < ($1.owningApplication?.applicationName ?? "") }
            if selectedWindowID == nil { selectedWindowID = windows.first?.windowID }
        } catch {
            permissionDenied = true
            windows = []
            displays = []
            sourceError = error.localizedDescription
        }
        isLoadingSources = false
    }

    private func openScreenRecordingSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        NSWorkspace.shared.open(url)
    }

    private func openInputMonitoringSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") else { return }
        NSWorkspace.shared.open(url)
    }

    private func recordAction() {
        Task {
            if let completedURL {
                model.open(url: completedURL, metadata: completedMetadata)
                model.message = nil
                dismiss()
            } else if recorder.isRecording {
                isFinalizing = true
                do {
                    let url = try await recorder.stop()
                    let cameraURL = await cameraRecorder.stop()
                    cameraRecorder.shutdown()
                    let metadata = RecordingMetadata(clicks: recorder.clicks, pointerSamples: recorder.pointerSamples, keystrokes: recorder.keystrokes, sourceWidth: recorder.sourceSize.width, sourceHeight: recorder.sourceSize.height, sourceName: recorder.sourceName, cameraFileName: cameraURL?.lastPathComponent, cameraTimeOffset: recorder.firstFrameDate.flatMap { start in cameraRecorder.recordingStartedAt.map { start.timeIntervalSince($0) } }, sourcePointWidth: recorder.sourcePointSize.width, sourcePointHeight: recorder.sourcePointSize.height)
                    self.completedURL = url
                    self.completedMetadata = metadata
                    do { try await model.library.register(url, metadata: metadata) }
                    catch { model.message = "The recording is safe, but its edit metadata could not be saved: \(error.localizedDescription)" }
                } catch {
                    _ = await cameraRecorder.stop()
                    model.message = error.localizedDescription
                }
                isFinalizing = false
            } else {
                isStarting = true
                defer { isStarting = false }
                if !inputMonitoringReady {
                    inputMonitoringReady = CGRequestListenEventAccess()
                }
                do {
                    if includeCamera {
                        try await cameraRecorder.prepare(deviceID: selectedCameraID.isEmpty ? nil : selectedCameraID)
                        try cameraRecorder.start()
                    }
                    try await recorder.start(target: selectedTarget, region: selectArea ? captureRegion : .full, capturesAudio: includeAudio, capturesMicrophone: includeMicrophone, frameRate: frameRate)
                } catch {
                    if let failedCameraURL = await cameraRecorder.stop() {
                        try? FileManager.default.removeItem(at: failedCameraURL)
                    }
                    model.message = error.localizedDescription
                }
            }
        }
    }

    private func format(_ seconds: Double) -> String {
        String(format: "%02d:%02d.%01d", Int(seconds) / 60, Int(seconds) % 60, Int(seconds * 10) % 10)
    }
}

private struct CaptureOptionToggle: View {
    let title: String
    let icon: String
    @Binding var isOn: Bool
    var enabled = true

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(isOn ? AppTheme.green : .secondary)
            Text(title).font(.caption.weight(.medium))
            Spacer(minLength: 4)
            Toggle("", isOn: $isOn).labelsHidden().toggleStyle(.switch).controlSize(.small)
        }
        .padding(.horizontal, 11).padding(.vertical, 9)
        .frame(maxWidth: .infinity)
        .background(AppTheme.elevated, in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(AppTheme.line))
        .opacity(enabled ? 1 : 0.5)
        .disabled(!enabled)
        .help(enabled ? title : "Requires macOS 15 or newer")
    }
}

private struct SourceRow: View {
    let title: String, subtitle: String, icon: String
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.title3).frame(width: 28).foregroundStyle(selected ? AppTheme.green : .secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Image(systemName: selected ? "checkmark.circle.fill" : "circle").foregroundStyle(selected ? AppTheme.green : Color.secondary)
            }.padding(11)
        }.buttonStyle(.plain)
        .background(selected ? AppTheme.green.opacity(0.1) : AppTheme.elevated, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected ? AppTheme.green.opacity(0.7) : AppTheme.line))
    }
}


private struct BrowserCaptureCard: View {
    @ObservedObject var bridge: BrowserRecorderBridge
    @State private var opening = false
    @State private var error: String?
    @State private var useWeb = BrowserRecorderBridge.usesWebStudio
    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "globe").font(.system(size: 42, weight: .light)).foregroundStyle(AppTheme.green)
            Text("One tab. Your full attention.").font(.title2.weight(.semibold))
            Text("Choose a specific Chrome tab with Chrome’s sharing picker. See your screen and camera live, pause when needed, then send the recording straight to this editor.")
                .multilineTextAlignment(.center).font(.callout).foregroundStyle(.secondary).frame(maxWidth: 540)
            HStack(spacing: 10) {
                Button(opening ? "Opening…" : bridge.isActive ? "Reopen tab studio ↗" : "Open Chrome tab studio ↗") {
                    opening = true
                    Task {
                        do { try await bridge.launch() } catch { self.error = error.localizedDescription }
                        opening = false
                    }
                }.buttonStyle(.borderedProminent).tint(AppTheme.green).disabled(opening)

                // Without this the session runs until the app quits, which
                // also leaves the mode below permanently locked.
                if bridge.isActive {
                    Button("End session") { bridge.stop(); error = nil }
                        .buttonStyle(.bordered)
                        .help("Closes the local recording session. The page in Chrome stops being able to save.")
                }
            }
            Text(error ?? bridge.status).font(.caption).foregroundStyle(.secondary)

            Toggle("Open the web studio instead", isOn: $useWeb)
                .font(.caption)
                .toggleStyle(.checkbox)
                .disabled(bridge.isActive)
                .onChange(of: useWeb) { _, value in BrowserRecorderBridge.usesWebStudio = value }
                .overlay(alignment: .trailing) {
                    if bridge.isActive {
                        Text("End the session to change this")
                            .font(.caption2).foregroundStyle(.tertiary).offset(x: 190)
                    }
                }
                .help("Loads the studio from the FocusFlow website instead of this app. The recording still goes straight to your Mac, but the page itself is fetched over the network.")

            Text(useWeb
                 ? "Keep FocusFlow open while recording. The page loads from the web; the video goes straight to your Mac."
                 : "Keep FocusFlow open while recording. Everything, including the page, stays on your Mac.")
                .font(.caption2).foregroundStyle(.tertiary).multilineTextAlignment(.center)
        }.frame(maxWidth: .infinity).frame(height: 360).background(AppTheme.elevated, in: RoundedRectangle(cornerRadius: 16))
    }
}
