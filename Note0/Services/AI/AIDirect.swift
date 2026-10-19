import Foundation

/// A ready-made OpenAI-compatible AI service the student can pick.
enum AIProvider: String, CaseIterable, Identifiable {
    case openAI, dashScope, dashScopeIntl, openRouter, custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .openAI: return "OpenAI"
        case .dashScope: return L("通义千问（阿里云百炼·中国站）")
        case .dashScopeIntl: return L("通义千问（Alibaba Cloud 国际站）")
        case .openRouter: return "OpenRouter"
        case .custom: return L("其他（自填地址）")
        }
    }

    var baseURL: String {
        switch self {
        case .openAI: return "https://api.openai.com/v1"
        case .dashScope: return "https://dashscope.aliyuncs.com/compatible-mode/v1"
        case .dashScopeIntl: return "https://dashscope-intl.aliyuncs.com/compatible-mode/v1"
        case .openRouter: return "https://openrouter.ai/api/v1"
        case .custom: return ""
        }
    }

    /// A model that can read images (the AI is sent a picture of the page).
    var defaultModel: String {
        switch self {
        case .openAI: return "gpt-5-mini"
        case .dashScope, .dashScopeIntl: return "qwen-vl-max"
        case .openRouter: return "openai/gpt-5-mini"
        case .custom: return ""
        }
    }

    var keyHint: String {
        switch self {
        case .openAI: return "sk-…（platform.openai.com → API keys）"
        case .dashScope: return L("sk-…（百炼控制台 → API-KEY）")
        case .dashScopeIntl: return "sk-…（Model Studio → API Key）"
        case .openRouter: return "sk-or-…（openrouter.ai → Keys）"
        case .custom: return "API Key"
        }
    }
}

/// Where an OpenAI-compatible `/chat/completions` request goes.
struct AIEndpoint: Equatable {
    var baseURL: String
    var apiKey: String
    var model: String

    var chatURL: URL? {
        let base = AIConfig.normalizedBaseURL(baseURL)
        guard !base.isEmpty else { return nil }
        if base.hasSuffix("/chat/completions") { return URL(string: base) }
        return URL(string: base + "/chat/completions")
    }

    var isComplete: Bool { chatURL != nil && !apiKey.isEmpty && !model.isEmpty }
}

/// Connecting to an AI without a note0 account:
/// 1. the student's own API key (设置 → 使用自己的 AI Key), or
/// 2. a proxy built into the app (`Note0AIProxyURL` / `Note0AIProxyToken` /
///    `Note0AIProxyModel` in Info.plist), which keeps the real key on the
///    server. See `server/ai-proxy-worker.js`.
enum AIDirect {
    private static let enabledKey = "note0.ai.direct.enabled"
    private static let providerKey = "note0.ai.direct.provider"
    private static let baseURLKey = "note0.ai.direct.baseURL"
    private static let modelKey = "note0.ai.direct.model"
    private static let apiKeyKey = "note0.ai.direct.apiKey"

    private static func plist(_ key: String) -> String {
        ((Bundle.main.object(forInfoDictionaryKey: key) as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The proxy shipped with the app, if one is configured.
    static var builtIn: AIEndpoint? {
        let endpoint = AIEndpoint(
            baseURL: plist("Note0AIProxyURL"),
            apiKey: plist("Note0AIProxyToken"),
            model: plist("Note0AIProxyModel").isEmpty ? "gpt-5-mini" : plist("Note0AIProxyModel")
        )
        return endpoint.isComplete ? endpoint : nil
    }

    static var useOwnKey: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    static var provider: AIProvider {
        get { AIProvider(rawValue: UserDefaults.standard.string(forKey: providerKey) ?? "") ?? .openAI }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: providerKey) }
    }

    /// Only used for `.custom`; the presets have fixed addresses.
    static var customBaseURL: String {
        get { UserDefaults.standard.string(forKey: baseURLKey) ?? "" }
        set { UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: baseURLKey) }
    }

    /// Empty = the provider's default model.
    static var model: String {
        get { UserDefaults.standard.string(forKey: modelKey) ?? "" }
        set { UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: modelKey) }
    }

    /// API keys are plain ASCII; pasting can bring along spaces, line breaks,
    /// quotes or invisible characters that make the server answer 401.
    static func cleanedKey(_ raw: String) -> String {
        var key = String(String.UnicodeScalarView(raw.unicodeScalars.filter { $0.value >= 0x21 && $0.value <= 0x7E }))
        for prefix in ["Bearer", "bearer"] where key.hasPrefix(prefix) && key.count > prefix.count + 8 {
            key = String(key.dropFirst(prefix.count))
        }
        return key.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`“”‘’"))
    }

    /// Why a pasted key can't be right, or nil if it looks fine.
    static func keyProblem(_ key: String, provider: AIProvider) -> String? {
        if key.isEmpty { return L("请粘贴 API Key。") }
        if key.contains("@") { return L("这里要填 API Key（sk- 开头的一串字符），不是账号或邮箱。") }
        if key.count < 20 { return L("这个 Key 太短了（\(key.count) 位），可能没复制完整。") }
        if provider != .custom && !key.hasPrefix("sk-") {
            return L("API Key 一般以 sk- 开头。请到服务商后台的 API keys 页面复制。")
        }
        return nil
    }

    /// Shown with errors so the student can see which key was used.
    static var keyFingerprint: String {
        let key = apiKey
        guard !key.isEmpty else { return L("未填写") }
        return L("\(String(key.prefix(7)))…\(String(key.suffix(4)))（\(key.count) 位）")
    }

    static var apiKey: String {
        get { Keychain.read(apiKeyKey) ?? "" }
        set {
            let value = cleanedKey(newValue)
            Keychain.write(apiKeyKey, value.isEmpty ? nil : value)
        }
    }

    /// The student's own key, as an endpoint.
    static var ownEndpoint: AIEndpoint {
        let provider = self.provider
        return AIEndpoint(
            baseURL: provider == .custom ? customBaseURL : provider.baseURL,
            apiKey: apiKey,
            model: model.isEmpty ? provider.defaultModel : model
        )
    }

    /// What "问 AI" uses instead of the note0 account, if anything.
    static var active: AIEndpoint? {
        if useOwnKey { return ownEndpoint.isComplete ? ownEndpoint : nil }
        return builtIn
    }
}
