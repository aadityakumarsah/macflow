import AppKit
import Foundation

/// A dotted release version, compared numerically rather than as text so
/// 0.10.0 sorts above 0.9.0.
struct SemanticVersion: Comparable, CustomStringConvertible {
    let parts: [Int]

    init?(_ raw: String) {
        // Release tags are written "v0.3.0"; bundles carry "0.3.0".
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }
        // Drop any pre-release or build suffix before splitting.
        text = String(text.prefix { $0.isNumber || $0 == "." })
        let fields = text.split(separator: ".", omittingEmptySubsequences: false)
        guard !fields.isEmpty else { return nil }
        var parsed: [Int] = []
        for field in fields {
            guard let value = Int(field), value >= 0 else { return nil }
            parsed.append(value)
        }
        guard !parsed.isEmpty else { return nil }
        parts = parsed
    }

    var description: String { parts.map(String.init).joined(separator: ".") }

    static func < (a: SemanticVersion, b: SemanticVersion) -> Bool {
        let count = max(a.parts.count, b.parts.count)
        for index in 0..<count {
            // A missing field is zero, so 0.3 and 0.3.0 compare equal.
            let left = index < a.parts.count ? a.parts[index] : 0
            let right = index < b.parts.count ? b.parts[index] : 0
            if left != right { return left < right }
        }
        return false
    }
}

struct AvailableRelease: Equatable {
    let version: SemanticVersion
    let downloadURL: URL
    let notes: String
    let pageURL: URL?

    static func == (a: AvailableRelease, b: AvailableRelease) -> Bool {
        a.version.description == b.version.description && a.downloadURL == b.downloadURL
    }

    /// Reads the fields the updater needs out of a GitHub release payload.
    static func parse(_ data: Data) -> AvailableRelease? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = root["tag_name"] as? String,
              let version = SemanticVersion(tag),
              let assets = root["assets"] as? [[String: Any]] else { return nil }

        let dmg = assets.compactMap { asset -> URL? in
            guard let name = asset["name"] as? String, name.hasSuffix(".dmg"),
                  let link = asset["browser_download_url"] as? String,
                  let url = URL(string: link) else { return nil }
            // Only accept assets served by GitHub over TLS.
            guard url.scheme == "https", let host = url.host,
                  host == "github.com" || host.hasSuffix(".github.com") || host.hasSuffix(".githubusercontent.com") else { return nil }
            return url
        }.first

        guard let downloadURL = dmg else { return nil }
        return AvailableRelease(
            version: version,
            downloadURL: downloadURL,
            notes: (root["body"] as? String) ?? "",
            pageURL: (root["html_url"] as? String).flatMap(URL.init(string:)))
    }
}

/// Checks GitHub Releases for a newer build and installs it in place.
///
/// A running bundle cannot overwrite itself, so installation hands off to a
/// short script that waits for this process to exit, swaps the bundle, and
/// launches the new copy.
@MainActor
final class Updater: ObservableObject {
    enum State: Equatable {
        case idle
        case checking
        case available(AvailableRelease)
        case downloading(Double)
        case installing
        case upToDate
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    /// Set when the user dismisses a banner, so it does not return until the
    /// next launch or an explicit check.
    @Published var dismissed = false

    /// How long to wait before looking again while the app stays open.
    static let recheckInterval: Double = 6 * 60 * 60

    private let feedURL = URL(string: "https://api.github.com/repos/aadityakumarsah/macflow/releases/latest")!
    private let bundleID = "app.focusflow.recorder"
    private var session: URLSession { .shared }

    var currentVersion: SemanticVersion {
        let raw = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        return SemanticVersion(raw) ?? SemanticVersion("0")!
    }

    var pendingRelease: AvailableRelease? {
        if case let .available(release) = state { return release }
        return nil
    }

    var isBusy: Bool {
        switch state {
        case .downloading, .installing, .checking: true
        default: false
        }
    }

    /// Returns the banner to nothing, after a one-off status message.
    func clearStatus() {
        switch state {
        case .failed, .upToDate: state = .idle
        default: break
        }
        dismissed = true
    }

    // MARK: - Checking

    func check(userInitiated: Bool) async {
        if isBusy { return }
        // A background re-check must not clear a banner already on screen.
        if !userInitiated, case .available = state { return }
        if userInitiated { dismissed = false }
        state = .checking
        do {
            var request = URLRequest(url: feedURL)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("FocusFlow", forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 15
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw UpdateError.message("The update service is unavailable right now.")
            }
            guard let release = AvailableRelease.parse(data) else {
                throw UpdateError.message("That release does not include a disk image.")
            }
            guard release.version > currentVersion else {
                state = .upToDate
                return
            }
            state = .available(release)
        } catch {
            // A silent check must not interrupt; only a requested one reports.
            state = userInitiated ? .failed(friendly(error)) : .idle
        }
    }

    // MARK: - Installing

    func install(_ release: AvailableRelease) {
        guard !isBusy else { return }
        Task { await performInstall(release) }
    }

    private func performInstall(_ release: AvailableRelease) async {
        state = .downloading(0)
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("focusflow-update-\(UUID().uuidString)")
        var mounted: URL?

        func cleanUp() {
            if let mounted { _ = try? Updater.run("/usr/bin/hdiutil", ["detach", mounted.path, "-quiet"]) }
            try? FileManager.default.removeItem(at: work)
        }

        do {
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

            let target = Bundle.main.bundleURL
            try verifyWritable(target)

            let dmg = work.appendingPathComponent("FocusFlow.dmg")
            try await download(release.downloadURL, to: dmg)

            state = .installing
            let mount = work.appendingPathComponent("mnt")
            try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
            try Updater.run("/usr/bin/hdiutil",
                            ["attach", dmg.path, "-nobrowse", "-readonly", "-mountpoint", mount.path, "-quiet"])
            mounted = mount

            let incoming = mount.appendingPathComponent("FocusFlow.app")
            try verify(incoming, isNewerThan: currentVersion)

            try swap(incoming: incoming, target: target, work: work, mount: mount)
            // swap() terminates the app; nothing after this runs on success.
        } catch {
            cleanUp()
            state = .failed(friendly(error))
        }
    }

    private func download(_ url: URL, to destination: URL) async throws {
        // A download task, not a byte sequence. `URLSession.bytes` yields one
        // byte per iteration, which for a disk image of this size is millions
        // of awaits — and because this type is @MainActor, every one of them
        // ran on the main thread and locked the interface while updating.
        let reporter = DownloadProgress { [weak self] fraction in
            Task { @MainActor in
                guard let self else { return }
                if case .downloading = self.state { self.state = .downloading(min(0.99, fraction)) }
            }
        }

        let (temporary, response) = try await session.download(from: url, delegate: reporter)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            try? FileManager.default.removeItem(at: temporary)
            throw UpdateError.message("The download could not be completed.")
        }

        // The async download API hands back a file it expects us to move.
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporary, to: destination)

        let size = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int) ?? 0
        guard (size ?? 0) > 0 else { throw UpdateError.message("The download was empty.") }
        state = .downloading(1)
    }

    /// Refuses anything that is not a genuine, newer FocusFlow bundle.
    private func verify(_ bundle: URL, isNewerThan current: SemanticVersion) throws {
        guard FileManager.default.fileExists(atPath: bundle.path) else {
            throw UpdateError.message("The disk image does not contain FocusFlow.")
        }
        guard let incoming = Bundle(url: bundle),
              let identifier = incoming.bundleIdentifier,
              identifier == bundleID else {
            throw UpdateError.message("That disk image is not FocusFlow.")
        }
        let raw = incoming.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        guard let version = SemanticVersion(raw), version > current else {
            throw UpdateError.message("The downloaded copy is not newer than this one.")
        }
        // Ad-hoc signed, so there is no team to check — but the signature must
        // still be intact, which catches a truncated or tampered download.
        try Updater.run("/usr/bin/codesign", ["--verify", "--deep", bundle.path])
    }

    private func verifyWritable(_ target: URL) throws {
        let parent = target.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path),
              FileManager.default.isWritableFile(atPath: target.path) else {
            throw UpdateError.message(
                "FocusFlow cannot update itself in \(parent.path). Move it to your Applications folder and try again.")
        }
        // Running from inside a read-only disk image is the common case here.
        if target.path.hasPrefix("/Volumes/") {
            throw UpdateError.message("Drag FocusFlow into Applications before updating.")
        }
    }

    /// Writes a helper that waits for this process to exit, swaps the bundle,
    /// and relaunches. The app cannot do this itself while it is running.
    /// Builds the helper that waits for this process to exit, swaps the
    /// bundle, and relaunches. Pure text so it can be exercised directly.
    nonisolated static func swapScript(pid: Int32, work: String, incoming: String, target: String, mount: String) -> String {
        """
        #!/bin/bash
        # Wait for FocusFlow to quit before touching its bundle.
        for _ in $(seq 1 300); do
            kill -0 \(pid) 2>/dev/null || break
            sleep 0.1
        done

        staged="\(work)/FocusFlow.app"
        rm -rf "$staged"
        if ! cp -R "\(incoming)" "$staged"; then
            hdiutil detach "\(mount)" -quiet 2>/dev/null
            open "\(target)"
            exit 1
        fi
        hdiutil detach "\(mount)" -quiet 2>/dev/null

        # Keep the old copy until the new one is in place, so a failure part
        # way through still leaves a working app behind.
        backup="\(work)/previous.app"
        rm -rf "$backup"
        if mv "\(target)" "$backup" 2>/dev/null; then
            if mv "$staged" "\(target)" 2>/dev/null; then
                rm -rf "$backup"
            else
                mv "$backup" "\(target)"
                open "\(target)"
                rm -rf "\(work)"
                exit 1
            fi
        else
            open "\(target)"
            rm -rf "\(work)"
            exit 1
        fi

        xattr -cr "\(target)" 2>/dev/null
        open "\(target)"
        rm -rf "\(work)"
        """
    }

    private func swap(incoming: URL, target: URL, work: URL, mount: URL) throws {
        let script = work.appendingPathComponent("swap.sh")
        let body = Updater.swapScript(pid: ProcessInfo.processInfo.processIdentifier,
                                      work: work.path,
                                      incoming: incoming.path,
                                      target: target.path,
                                      mount: mount.path)
        try body.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path]
        // Detach, or the helper dies with the app it is waiting on.
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()

        NSApplication.shared.terminate(nil)
    }

    // MARK: - Helpers

    enum UpdateError: LocalizedError {
        case message(String)
        var errorDescription: String? { if case let .message(text) = self { text } else { nil } }
    }

    @discardableResult
    nonisolated static func run(_ launchPath: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: data, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw UpdateError.message(output.isEmpty ? "\(launchPath) failed." : output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return output
    }

    private func friendly(_ error: Error) -> String {
        if let update = error as? UpdateError, let text = update.errorDescription { return text }
        if (error as NSError).domain == NSURLErrorDomain {
            return "FocusFlow could not reach GitHub. Check your connection and try again."
        }
        return error.localizedDescription
    }
}

/// Reports download progress. URLSession calls this on its own queue, which is
/// the point: the transfer must not be driven from the main thread.
private final class DownloadProgress: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let report: (Double) -> Void

    init(_ report: @escaping (Double) -> Void) {
        self.report = report
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        report(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    /// Required by the protocol. The async `download(from:delegate:)` call
    /// returns the file itself, so there is nothing to do here.
    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {}
}
