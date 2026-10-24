import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            AISettingsPane()
                .tabItem { Label("AI", systemImage: "sparkles") }
            CaptureSettingsPane()
                .tabItem { Label("Capture", systemImage: "record.circle") }
        }
        .frame(width: 560, height: 420)
    }
}

private struct AISettingsPane: View {
    @StateObject private var settings = AISettings()
    @State private var revealed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("API keys")
                .font(.system(size: 13, weight: .semibold))

            Text("Keys are stored in your macOS Keychain, never in preferences or project files. Nothing in FocusFlow calls these yet — this is here so the key is in place before the features that use it are.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Picker("Provider", selection: $settings.provider) {
                ForEach(AIProvider.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            HStack(spacing: 8) {
                Group {
                    if revealed {
                        TextField("Paste your key", text: $settings.draft)
                    } else {
                        SecureField("Paste your key", text: $settings.draft)
                    }
                }
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .onSubmit { settings.save() }

                Button {
                    revealed.toggle()
                } label: {
                    Image(systemName: revealed ? "eye.slash" : "eye")
                }
                .buttonStyle(.borderless)
                .help(revealed ? "Hide the key" : "Show the key")
            }

            HStack(spacing: 10) {
                Button("Save") { settings.save() }
                    .disabled(settings.draft.isEmpty)

                Button("Save and test") { Task { await settings.verify() } }
                    .buttonStyle(.borderedProminent)
                    .tint(AppTheme.green)
                    .disabled(settings.draft.isEmpty || settings.status == .checking)

                Button("Forget") { settings.forget() }
                    .disabled(!Credentials.hasKey(for: settings.provider))

                Spacer()

                if let console = settings.provider.consoleURL {
                    Link("Get a key ↗", destination: console).font(.caption)
                }
            }

            statusLine

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Stored keys").font(.caption.weight(.semibold))
                if settings.storedProviders.isEmpty {
                    Text("None yet.").font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(settings.storedProviders) { provider in
                        HStack(spacing: 6) {
                            Image(systemName: "key.fill").font(.caption2).foregroundStyle(AppTheme.green)
                            Text(provider.title).font(.caption)
                        }
                    }
                }
            }

            Spacer()
        }
        .padding(22)
    }

    @ViewBuilder
    private var statusLine: some View {
        switch settings.status {
        case .untested:
            Text(Credentials.hasKey(for: settings.provider)
                 ? "A key is stored for \(settings.provider.title)."
                 : "No key stored for \(settings.provider.title).")
                .font(.caption).foregroundStyle(.secondary)
        case .checking:
            HStack(spacing: 7) {
                ProgressView().controlSize(.small)
                Text("Checking with \(settings.provider.title)…").font(.caption).foregroundStyle(.secondary)
            }
        case let .valid(message):
            Label(message, systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(AppTheme.green)
        case let .invalid(message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct CaptureSettingsPane: View {
    @State private var useWeb = BrowserRecorderBridge.usesWebStudio

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Chrome tab studio")
                .font(.system(size: 13, weight: .semibold))

            Toggle("Open the web studio instead of the built-in one", isOn: $useWeb)
                .onChange(of: useWeb) { _, value in BrowserRecorderBridge.usesWebStudio = value }

            Text(useWeb
                 ? "The studio page is loaded from \(BrowserRecorderBridge.webStudioURL). Your recording still goes only to this Mac — the difference is that the page's code comes from the network rather than the app bundle."
                 : "FocusFlow serves the studio page itself, so nothing touches the network.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            Text("Click zooms in tab recordings")
                .font(.system(size: 13, weight: .semibold))

            Text("A page cannot see pointer events in the tab it is capturing, so FocusFlow follows the pointer itself while Chrome records, and builds the zooms from that. It samples only while Chrome is frontmost and the pointer is over the captured page, so a click elsewhere cannot invent a zoom. Input Monitoring permission is required.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()
        }
        .padding(22)
    }
}
