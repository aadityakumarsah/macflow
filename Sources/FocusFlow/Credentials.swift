import Foundation
import Security

/// Providers FocusFlow can hold a key for.
///
/// Nothing in the app calls these yet; this is storage and validation only, so
/// the key is in place before any feature needs it.
enum AIProvider: String, CaseIterable, Identifiable, Codable {
    case anthropic, openai, gemini

    var id: String { rawValue }

    var title: String {
        switch self {
        case .anthropic: "Anthropic"
        case .openai: "OpenAI"
        case .gemini: "Google Gemini"
        }
    }

    var keyPrefix: String? {
        switch self {
        case .anthropic: "sk-ant-"
        case .openai: "sk-"
        case .gemini: nil
        }
    }

    var consoleURL: URL? {
        switch self {
        case .anthropic: URL(string: "https://console.anthropic.com/settings/keys")
        case .openai: URL(string: "https://platform.openai.com/api-keys")
        case .gemini: URL(string: "https://aistudio.google.com/app/apikey")
        }
    }

    /// Where a key is checked. A plain list call: cheap, read-only, and it
    /// fails clearly on a bad key.
    var verifyURL: URL? {
        switch self {
        case .anthropic: URL(string: "https://api.anthropic.com/v1/models?limit=1")
        case .openai: URL(string: "https://api.openai.com/v1/models")
        case .gemini: URL(string: "https://generativelanguage.googleapis.com/v1beta/models")
        }
    }

    func authorize(_ request: inout URLRequest, key: String) {
        switch self {
        case .anthropic:
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case .openai:
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        case .gemini:
            request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        }
    }

    /// A shape check before the network is touched, so an obviously wrong
    /// paste is reported immediately rather than as an auth failure.
    func looksPlausible(_ key: String) -> String? {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "Enter a key." }
        if trimmed.count < 20 { return "That key looks too short." }
        if trimmed.contains(" ") { return "That key contains a space — check the paste." }
        if let prefix = keyPrefix, !trimmed.hasPrefix(prefix) {
            return "\(title) keys start with \(prefix)"
        }
        return nil
    }
}

/// Keychain-backed storage for API keys.
///
/// Keys are never written to preferences or to a project file: those are plain
/// text on disk and get copied around with recordings.
enum Credentials {
    private static let service = "app.focusflow.recorder.ai"

    static func key(for provider: AIProvider) -> String? {
        var query = baseQuery(provider)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let text = String(data: data, encoding: .utf8),
              !text.isEmpty else { return nil }
        return text
    }

    @discardableResult
    static func store(_ key: String, for provider: AIProvider) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return remove(provider) }
        guard let data = trimmed.data(using: .utf8) else { return false }

        let query = baseQuery(provider)
        let attributes: [String: Any] = [kSecValueData as String: data]

        switch SecItemUpdate(query as CFDictionary, attributes as CFDictionary) {
        case errSecSuccess:
            return true
        case errSecItemNotFound:
            var insert = query
            insert[kSecValueData as String] = data
            // Needs the Mac unlocked, but never syncs to iCloud.
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
        default:
            return false
        }
    }

    @discardableResult
    static func remove(_ provider: AIProvider) -> Bool {
        let status = SecItemDelete(baseQuery(provider) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    static func hasKey(for provider: AIProvider) -> Bool { key(for: provider) != nil }

    private static func baseQuery(_ provider: AIProvider) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider.rawValue,
        ]
    }
}

/// Result of checking a key against its provider.
enum KeyCheck: Equatable {
    case untested
    case checking
    case valid(String)
    case invalid(String)
}

@MainActor
final class AISettings: ObservableObject {
    @Published var provider: AIProvider = .anthropic {
        didSet { draft = Credentials.key(for: provider) ?? ""; status = .untested }
    }
    @Published var draft: String = ""
    @Published var status: KeyCheck = .untested

    init() {
        draft = Credentials.key(for: provider) ?? ""
    }

    var storedProviders: [AIProvider] { AIProvider.allCases.filter(Credentials.hasKey) }

    func save() {
        if let complaint = provider.looksPlausible(draft) {
            status = .invalid(complaint)
            return
        }
        status = Credentials.store(draft, for: provider)
            ? .valid("Saved to your Keychain.")
            : .invalid("The Keychain refused to store that key.")
    }

    func forget() {
        Credentials.remove(provider)
        draft = ""
        status = .untested
    }

    /// Saves, then asks the provider whether the key works.
    func verify() async {
        if let complaint = provider.looksPlausible(draft) {
            status = .invalid(complaint)
            return
        }
        guard let url = provider.verifyURL else { status = .invalid("No check available."); return }
        status = .checking

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        provider.authorize(&request, key: draft.trimmingCharacters(in: .whitespacesAndNewlines))

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch code {
            case 200...299:
                Credentials.store(draft, for: provider)
                status = .valid("Key works. Saved to your Keychain.")
            case 401, 403:
                status = .invalid("\(provider.title) rejected that key.")
            case 429:
                status = .invalid("Rate limited — the key may be fine, try again shortly.")
            default:
                status = .invalid("\(provider.title) replied \(code).")
            }
        } catch {
            status = .invalid("Could not reach \(provider.title): \(error.localizedDescription)")
        }
    }
}
