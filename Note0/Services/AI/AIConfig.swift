import Foundation
import Security

/// Server address, chosen model and sign-in tokens.
enum AIConfig {
    /// Builds 23–24 stored the server under "note0.ai.baseURL"; that value is
    /// deliberately ignored now so an old or mistyped entry can't break sign-in.
    private static let customBaseURLKey = "note0.ai.customBaseURL"
    private static let modelKey = "note0.ai.model"
    static let defaultModel = "gpt-5.4-mini"
    /// Used when Info.plist has no `Note0APIBaseURL`.
    static let builtInBaseURL = "https://api.dim0.net"

    /// The note0 server students use; nothing to type.
    static var defaultBaseURL: String {
        let fromPlist = normalizedBaseURL((Bundle.main.object(forInfoDictionaryKey: "Note0APIBaseURL") as? String) ?? "")
        return fromPlist.isEmpty ? builtInBaseURL : fromPlist
    }

    /// Only set from "高级设置" for a self-hosted backend; empty = default.
    static var customBaseURL: String {
        get { UserDefaults.standard.string(forKey: customBaseURLKey) ?? "" }
        set {
            let value = normalizedBaseURL(newValue)
            if value.isEmpty || value == defaultBaseURL {
                UserDefaults.standard.removeObject(forKey: customBaseURLKey)
            } else {
                UserDefaults.standard.set(value, forKey: customBaseURLKey)
            }
        }
    }

    /// The server actually used.
    static var baseURL: String {
        customBaseURL.isEmpty ? defaultBaseURL : customBaseURL
    }

    static var model: String {
        get { UserDefaults.standard.string(forKey: modelKey).flatMap { $0.isEmpty ? nil : $0 } ?? defaultModel }
        set { UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespaces), forKey: modelKey) }
    }

    /// Adds https:// when missing (http:// for local hosts) and drops a trailing slash.
    static func normalizedBaseURL(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return "" }
        while value.hasSuffix("/") { value.removeLast() }
        if value.lowercased().hasPrefix("http://") || value.lowercased().hasPrefix("https://") { return value }
        let host = value.split(separator: "/").first.map(String.init) ?? value
        let isLocal = host.hasPrefix("localhost") || host.hasPrefix("127.") || host.hasPrefix("192.168.")
            || host.hasPrefix("10.") || host.hasSuffix(".local")
        return (isLocal ? "http://" : "https://") + value
    }

    static var accessToken: String? {
        get { Keychain.read("note0.accessToken") }
        set { Keychain.write("note0.accessToken", newValue) }
    }

    static var refreshToken: String? {
        get { Keychain.read("note0.refreshToken") }
        set { Keychain.write("note0.refreshToken", newValue) }
    }

    static var signedInEmail: String? {
        get { UserDefaults.standard.string(forKey: "note0.ai.email") }
        set { UserDefaults.standard.set(newValue, forKey: "note0.ai.email") }
    }

    static var isSignedIn: Bool { accessToken != nil && !baseURL.isEmpty }

    /// "问 AI" can run: own key / built-in proxy, or a note0 account.
    static var isReady: Bool { AIDirect.active != nil || isSignedIn }

    static func signOut() {
        accessToken = nil
        refreshToken = nil
        signedInEmail = nil
    }
}

/// Minimal generic-password Keychain wrapper for the auth tokens.
enum Keychain {
    static func read(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ key: String, _ value: String?) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
        guard let value, let data = value.data(using: .utf8) else { return }
        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(attributes as CFDictionary, nil)
    }
}

enum AIError: LocalizedError {
    case notConfigured
    case notSignedIn
    case server(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .notConfigured: return L("AI 还没有连接：请在“账号与 AI”里登录，或填写自己的 API Key。")
        case .notSignedIn: return L("请先登录 note0 账号。")
        case .server(let message): return message
        case .invalidResponse: return L("服务器返回了无法识别的内容。")
        }
    }
}
