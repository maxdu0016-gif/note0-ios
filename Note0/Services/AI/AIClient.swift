import Foundation

/// Network calls: note0 account (`/users/signin`, `/users/refresh`, `/ai/llm/stream`)
/// and OpenAI-compatible `/chat/completions` (own key or built-in proxy).
enum AIClient {
    static func signIn(email: String, password: String) async throws {
        guard let base = URL(string: AIConfig.baseURL), !AIConfig.baseURL.isEmpty else { throw AIError.notConfigured }
        var request = URLRequest(url: base.appendingPathComponent("users/signin"))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formEncoded(["username": email, "password": password]).data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        try storeTokens(from: data, response: response, fallbackMessage: L("邮箱或密码不正确。"))
        AIConfig.signedInEmail = email
    }

    /// Creates an account and signs in (the backend returns tokens right away).
    static func signUp(email: String, password: String) async throws {
        guard let base = URL(string: AIConfig.baseURL), !AIConfig.baseURL.isEmpty else { throw AIError.notConfigured }
        var request = URLRequest(url: base.appendingPathComponent("users/signup"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let name = email.split(separator: "@").first.map(String.init) ?? email
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "email": email, "password": password, "name": name, "username": email,
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        try storeTokens(from: data, response: response, fallbackMessage: L("注册失败，请稍后再试。"))
        AIConfig.signedInEmail = email
    }

    /// Permanently removes the signed-in account on the configured backend.
    static func deleteAccount() async throws {
        guard !AIConfig.baseURL.isEmpty, let url = URL(string: AIConfig.baseURL + "/users/") else {
            throw AIError.notConfigured
        }
        guard AIConfig.accessToken != nil else { throw AIError.notSignedIn }

        func send() async throws -> (Data, URLResponse) {
            guard let token = AIConfig.accessToken else { throw AIError.notSignedIn }
            var request = URLRequest(url: url)
            request.httpMethod = "DELETE"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            return try await URLSession.shared.data(for: request)
        }

        var (data, response) = try await send()
        if (response as? HTTPURLResponse)?.statusCode == 401 {
            try await refreshTokens()
            (data, response) = try await send()
        }
        guard let status = (response as? HTTPURLResponse)?.statusCode,
              (200..<300).contains(status) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw AIError.server(errorMessage(from: data, status: status))
        }
        AIConfig.signOut()
    }

    /// Plain-language text for errors a student may see.
    static func describe(_ error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost:
                return L("没有网络连接，请检查网络后再试。")
            case .timedOut:
                return L("连接超时，请稍后再试。")
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                return L("暂时连不上 note0 服务器，请稍后再试。")
            default:
                return L("网络出错了，请稍后再试。")
            }
        }
        return error.localizedDescription
    }

    /// Turns the backend's English messages into ones a student understands.
    static func friendly(_ raw: String) -> String {
        let lower = raw.lowercased()
        if lower.contains("incorrect username or password") { return L("邮箱或密码不正确。") }
        if lower.contains("error when creating user") { return L("这个邮箱可能已经注册过了，可以直接登录。") }
        if lower.contains("not available on your plan") { return L("当前账号的套餐不能使用这个 AI 模型。") }
        if lower.contains("token") && (lower.contains("invalid") || lower.contains("expired") || lower.contains("revoked")) {
            return L("登录已过期，请重新登录。")
        }
        if lower.contains("not configured") || lower.contains("no model available") { return L("AI 服务暂时不可用，请稍后再试。") }
        return raw
    }

    /// Streams the answer; `onDelta` receives text chunks on the main actor.
    /// Streams a reply to a full message list, over whichever connection is set up.
    static func chat(messages: [[String: Any]], onDelta: @escaping @MainActor (String) -> Void) async throws {
        if let endpoint = AIDirect.active {
            try await streamChat(endpoint: endpoint, messages: messages, onDelta: onDelta)
            return
        }
        let body: [String: Any] = [
            "model": AIConfig.model,
            "messages": messages,
        ]
        let payload = try JSONSerialization.data(withJSONObject: body)

        var (bytes, response) = try await streamRequest(payload: payload)
        if (response as? HTTPURLResponse)?.statusCode == 401 {
            try await refreshTokens()
            (bytes, response) = try await streamRequest(payload: payload)
        }
        guard let http = response as? HTTPURLResponse else { throw AIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            var errorData = Data()
            for try await byte in bytes { errorData.append(byte) }
            if http.statusCode == 401 { throw AIError.notSignedIn }
            throw AIError.server(errorMessage(from: errorData, status: http.statusCode))
        }
        for try await line in bytes.lines {
            if let text = AIPrompt.deltaText(fromLine: line) {
                await onDelta(text)
            }
        }
    }

    /// Streams from any OpenAI-compatible `/chat/completions`.
    static func streamChat(endpoint: AIEndpoint, messages: [[String: Any]], onDelta: @escaping @MainActor (String) -> Void) async throws {
        guard let url = endpoint.chatURL, !endpoint.apiKey.isEmpty else { throw AIError.notConfigured }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(endpoint.apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": endpoint.model,
            "messages": messages,
            "stream": true,
        ])
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw AIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            var errorData = Data()
            for try await byte in bytes { errorData.append(byte) }
            throw AIError.server(directErrorMessage(from: errorData, status: http.statusCode))
        }
        var received = false
        for try await line in bytes.lines {
            if line.hasPrefix("data: [DONE]") { break }
            if let text = AIPrompt.sseDeltaText(fromLine: line) {
                received = true
                await onDelta(text)
            }
        }
        if !received { throw AIError.server(L("AI 没有返回内容，请检查模型名称是否正确、是否支持看图。")) }
    }

    /// Sends one tiny text-only question to check address, key and model.
    @MainActor
    static func testConnection(_ endpoint: AIEndpoint) async throws -> String {
        var reply = ""
        let messages: [[String: Any]] = [["role": "user", "content": L("请只回复四个字：连接成功")]]
        try await streamChat(endpoint: endpoint, messages: messages) { reply += $0 }
        return reply
    }

    /// Plain-Chinese errors for OpenAI-style `{"error":{"message":…}}` replies.
    static func directErrorMessage(from data: Data, status: Int) -> String {
        var detail = ""
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let error = object["error"] as? [String: Any], let message = error["message"] as? String {
                detail = message
            } else if let message = object["message"] as? String {
                detail = message
            } else if let message = object["detail"] as? String {
                detail = message
            }
        }
        let lower = detail.lowercased()
        switch status {
        case 401:
            // Name the likely cause; the server's own words help tell which.
            var message = L("API Key 被服务商拒绝（401）。请检查：Key 是否复制完整、是否已被删除或过期、上面选的服务商是否和 Key 对应")
            if lower.contains("incorrect api key") || lower.contains("invalid api") || lower.contains("invalid_api_key") {
                message = L("API Key 不正确（401）。请重新复制完整的 Key，并确认上面选的服务商和 Key 对应")
            }
            if lower.contains("dashscope") || lower.contains("api-key") {
                message += L("。通义千问的 Key 分中国站和国际站，两边不能混用，换一个试试")
            }
            if AIDirect.useOwnKey { message += L("。\n当前用的 Key：") + AIDirect.keyFingerprint }
            return message + "。" + (detail.isEmpty ? "" : L("\n服务商原话：") + detail)
        case 402: return L("账户余额不足（402），请先充值。")
        case 403: return L("没有权限使用这个模型（403）。") + (detail.isEmpty ? "" : "\n" + detail)
        case 404: return L("找不到这个地址或模型（404），请检查服务地址和模型名称。") + (detail.isEmpty ? "" : "\n" + detail)
        case 429:
            if lower.contains("quota") || lower.contains("billing") || lower.contains("balance") {
                return L("额度已用完或还没开通付费（429），请到服务商后台充值。")
            }
            return L("请求太频繁（429），请稍后再试。")
        default:
            if lower.contains("image") || lower.contains("vision") || lower.contains("multimodal") {
                return L("这个模型不支持看图，请换一个能看图的模型（如 gpt-5-mini、qwen-vl-max）。")
            }
            let prefix = status >= 500 ? L("AI 服务出错了（\(status)）") : L("请求失败（\(status)）")
            return detail.isEmpty ? prefix + "。" : prefix + "：" + detail
        }
    }

    private static func streamRequest(payload: Data) async throws -> (URLSession.AsyncBytes, URLResponse) {
        guard let base = URL(string: AIConfig.baseURL), !AIConfig.baseURL.isEmpty else { throw AIError.notConfigured }
        guard let token = AIConfig.accessToken else { throw AIError.notSignedIn }
        var request = URLRequest(url: base.appendingPathComponent("ai/llm/stream"))
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Run-Id")
        request.httpBody = payload
        return try await URLSession.shared.bytes(for: request)
    }

    private static func refreshTokens() async throws {
        guard let base = URL(string: AIConfig.baseURL), let refresh = AIConfig.refreshToken else { throw AIError.notSignedIn }
        var request = URLRequest(url: base.appendingPathComponent("users/refresh"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["refresh_token": refresh])
        let (data, response) = try await URLSession.shared.data(for: request)
        do {
            try storeTokens(from: data, response: response, fallbackMessage: L("登录已过期，请重新登录。"))
        } catch {
            AIConfig.signOut()
            throw AIError.notSignedIn
        }
    }

    static func storeTokens(from data: Data, response: URLResponse, fallbackMessage: String) throws {
        let tokens = try parseTokens(from: data, response: response, fallbackMessage: fallbackMessage)
        AIConfig.accessToken = tokens.access
        if let refresh = tokens.refresh { AIConfig.refreshToken = refresh }
    }

    /// Parses `{"status":"success","data":{"token":{access_token, refresh_token}}}`.
    static func parseTokens(from data: Data, response: URLResponse, fallbackMessage: String) throws -> (access: String, refresh: String?) {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = object["data"] as? [String: Any],
              let token = payload["token"] as? [String: Any],
              let access = token["access_token"] as? String else {
            throw AIError.server(status == 0 ? fallbackMessage : errorMessage(from: data, status: status, fallback: fallbackMessage))
        }
        return (access, token["refresh_token"] as? String)
    }

    static func errorMessage(from data: Data, status: Int, fallback: String? = nil) -> String {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let detail = object["detail"] as? String { return friendly(detail) }
            if let message = object["message"] as? String { return friendly(message) }
        }
        switch status {
        case 401: return fallback ?? L("登录已过期，请重新登录。")
        case 403: return L("当前账号的套餐不能使用这个 AI 模型。")
        case 429: return L("请求太频繁或额度已用完，请稍后再试。")
        case 500...599: return L("服务器出错了（\(status)），请稍后再试。")
        default: return fallback ?? L("请求失败（\(status)）。")
        }
    }

    static func formEncoded(_ fields: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return fields
            .sorted { $0.key < $1.key }
            .map { key, value in
                "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
            }
            .joined(separator: "&")
    }
}
