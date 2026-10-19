import SwiftUI

/// Sign in / sign up, written for students: one email, one password, one
/// button. Server address and model are tucked away under "高级设置".
struct AccountForm: View {
    enum Mode: String, CaseIterable, Identifiable {
        case signIn, signUp
        var id: String { rawValue }
        var title: String { self == .signIn ? L("登录") : L("注册新账号") }
    }

    /// Called after a successful sign-in or sign-up.
    var onSignedIn: () -> Void = {}

    @State private var mode: Mode = .signIn
    @State private var email = AIConfig.signedInEmail ?? ""
    @State private var password = ""
    @State private var isWorking = false
    @State private var message: String?
    @FocusState private var focusedField: Field?

    private enum Field { case email, password }

    private var trimmedEmail: String { email.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSubmit: Bool {
        !isWorking && trimmedEmail.contains("@") && password.count >= (mode == .signUp ? 8 : 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .onChange(of: mode) { _, _ in message = nil }

            VStack(spacing: 0) {
                TextField(L("邮箱"), text: $email)
                    .keyboardType(.emailAddress)
                    .textContentType(.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focusedField, equals: .email)
                    .submitLabel(.next)
                    .onSubmit { focusedField = .password }
                    .padding(12)
                Divider()
                SecureField(mode == .signUp ? L("设置密码（至少 8 位）") : L("密码"), text: $password)
                    .textContentType(mode == .signUp ? .newPassword : .password)
                    .focused($focusedField, equals: .password)
                    .submitLabel(.go)
                    .onSubmit { if canSubmit { Task { await submit() } } }
                    .padding(12)
            }
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))

            if let message {
                Label(message, systemImage: "exclamationmark.circle")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            Button {
                Task { await submit() }
            } label: {
                HStack {
                    Spacer()
                    if isWorking {
                        ProgressView().tint(.white)
                    } else {
                        Text(mode == .signIn ? L("登录") : L("注册并登录"))
                            .fontWeight(.semibold)
                    }
                    Spacer()
                }
                .frame(height: 44)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canSubmit)

            Text(mode == .signIn
                 ? L("和 note0 网页版是同一个账号。没有账号？点上面的“注册新账号”。")
                 : L("注册后就能直接使用 AI 讲解、整理和出题。"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func submit() async {
        guard canSubmit else { return }
        isWorking = true
        message = nil
        defer { isWorking = false }
        do {
            switch mode {
            case .signIn: try await AIClient.signIn(email: trimmedEmail, password: password)
            case .signUp: try await AIClient.signUp(email: trimmedEmail, password: password)
            }
            password = ""
            onSignedIn()
        } catch {
            message = AIClient.describe(error)
        }
    }
}

/// The account screen opened from the bookshelf.
struct AISettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var signedInEmail = AIConfig.isSignedIn ? AIConfig.signedInEmail : nil
    @State private var showAdvanced = false
    @State private var customServer = AIConfig.customBaseURL
    @State private var model = AIConfig.model
    @State private var useOwnKey = AIDirect.useOwnKey
    @State private var showDeleteConfirmation = false
    @State private var isDeletingAccount = false
    @State private var deleteError: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header

                    if AIDirect.builtIn != nil && !useOwnKey {
                        Label(L("AI 已经连好，不登录也能直接用"), systemImage: "checkmark.seal.fill")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.green)
                    }

                    OwnKeySettings(useOwnKey: $useOwnKey)

                    if let signedInEmail {
                        signedInCard(email: signedInEmail)
                    } else if !useOwnKey && AIDirect.builtIn == nil {
                        AccountForm {
                            signedInEmail = AIConfig.signedInEmail ?? L("已登录")
                        }
                    }

                    DisclosureGroup(L("note0 服务器设置"), isExpanded: $showAdvanced) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(L("一般不需要改，留空就是默认服务器。只有自己部署了 note0 后端时才填写。"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            LabeledContent(L("服务器")) {
                                TextField(AIConfig.defaultBaseURL, text: $customServer)
                                    .keyboardType(.URL)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .multilineTextAlignment(.trailing)
                            }
                            LabeledContent(L("AI 模型")) {
                                TextField(AIConfig.defaultModel, text: $model)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .multilineTextAlignment(.trailing)
                            }
                        }
                        .padding(.top, 8)
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }
                .padding(24)
                .frame(maxWidth: 480)
                .frame(maxWidth: .infinity)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("完成")) {
                        saveAdvanced()
                        dismiss()
                    }
                }
            }
            .onChange(of: customServer) { _, _ in saveAdvanced() }
            .onChange(of: model) { _, _ in saveAdvanced() }
            .confirmationDialog(L("永久删除 note0 账号？"), isPresented: $showDeleteConfirmation) {
                Button(L("删除账号"), role: .destructive) {
                    Task { await deleteAccount() }
                }
            } message: {
                Text(L("服务器上的账号及关联数据将被永久删除，无法撤销。此 iPad 上的笔记不会删除。"))
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: "sparkles")
                .font(.system(size: 30))
                .foregroundStyle(.tint)
            Text(L("账号与 AI"))
                .font(.title2.weight(.bold))
            Text(L("写笔记不需要登录。连上 AI 后可以框选笔记让 AI 讲解、整理要点、出复习题。"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private func signedInCard(email: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(email).font(.headline)
                    Text(L("已登录，可以使用 AI")).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(L("退出登录"), role: .destructive) {
                    AIConfig.signOut()
                    signedInEmail = nil
                }
                .buttonStyle(.bordered)
            }
            Button(L("删除账号"), role: .destructive) { showDeleteConfirmation = true }
                .disabled(isDeletingAccount)
            if isDeletingAccount { ProgressView(L("正在删除账号…")) }
            if let deleteError {
                Text(deleteError).font(.footnote).foregroundStyle(.red)
            }
        }
        .padding(14)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    /// Keeps the user signed in if the server declines the deletion request.
    private func deleteAccount() async {
        isDeletingAccount = true
        deleteError = nil
        defer { isDeletingAccount = false }
        do {
            try await AIClient.deleteAccount()
            signedInEmail = nil
        } catch {
            deleteError = AIClient.describe(error)
        }
    }

    private func saveAdvanced() {
        AIConfig.customBaseURL = customServer
        AIConfig.model = model
    }
}

/// "使用自己的 AI Key": any OpenAI-compatible service, no note0 account needed.
struct OwnKeySettings: View {
    @Binding var useOwnKey: Bool

    @State private var provider = AIDirect.provider
    @State private var customBaseURL = AIDirect.customBaseURL
    /// What is being typed or pasted; only saved when "保存" is tapped, so
    /// re-focusing the field or AutoFill can never overwrite a working key.
    @State private var newKey = ""
    @State private var editingKey = AIDirect.apiKey.isEmpty
    @State private var keyMessage: String?
    @State private var savedKey = AIDirect.apiKey
    @State private var model = AIDirect.model
    @State private var isTesting = false
    @State private var testResult: (ok: Bool, text: String)?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(isOn: $useOwnKey) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("使用自己的 AI Key")).font(.headline)
                    Text(L("填 OpenAI、通义千问等服务的 API Key，不需要 note0 账号"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            if useOwnKey {
                Picker(L("服务商"), selection: $provider) {
                    ForEach(AIProvider.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.menu)

                VStack(spacing: 0) {
                    if provider == .custom {
                        TextField(L("服务地址，如 https://example.com/v1"), text: $customBaseURL)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .padding(12)
                        Divider()
                    }
                    if editingKey {
                        HStack(spacing: 8) {
                            TextField(provider.keyHint, text: $newKey)
                                .textContentType(.oneTimeCode)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .font(.callout.monospaced())
                                .privacySensitive()
                            if !savedKey.isEmpty {
                                Button(L("取消")) {
                                    newKey = ""
                                    keyMessage = nil
                                    editingKey = false
                                }
                                .buttonStyle(.borderless)
                            }
                            Button(L("保存"), action: saveKey)
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                                .disabled(newKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                        .padding(12)
                    } else {
                        HStack {
                            Text(L("API Key：\(String(savedKey.prefix(7)))…\(String(savedKey.suffix(4)))（\(savedKey.count) 位）"))
                                .font(.callout.monospaced())
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button(L("更换")) {
                                newKey = ""
                                editingKey = true
                            }
                            .buttonStyle(.borderless)
                        }
                        .padding(12)
                    }
                    Divider()
                    TextField(L("模型（留空用 \(provider.defaultModel.isEmpty ? L("服务商默认") : provider.defaultModel)）"), text: $model)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .padding(12)
                }
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))

                if let keyMessage {
                    Label(keyMessage, systemImage: "exclamationmark.circle")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }

                HStack {
                    Button {
                        Task { await test() }
                    } label: {
                        if isTesting {
                            ProgressView()
                        } else {
                            Label(L("测试连接"), systemImage: "bolt.horizontal")
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(isTesting || !AIDirect.ownEndpoint.isComplete)

                    if let testResult {
                        Label(testResult.text, systemImage: testResult.ok ? "checkmark.circle.fill" : "exclamationmark.circle")
                            .font(.footnote)
                            .foregroundStyle(testResult.ok ? .green : .red)
                    }
                }

                Text(L("Key 只保存在这台 iPad 的钥匙串里。AI 会收到你框选区域的截图，所以模型要能看图。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(Color(.secondarySystemBackground).opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
        .onChange(of: useOwnKey) { _, value in AIDirect.useOwnKey = value }
        .onChange(of: provider) { _, value in AIDirect.provider = value; testResult = nil }
        .onChange(of: customBaseURL) { _, value in AIDirect.customBaseURL = value; testResult = nil }
        .onChange(of: model) { _, value in AIDirect.model = value; testResult = nil }
    }

    private func saveKey() {
        let key = AIDirect.cleanedKey(newKey)
        if let problem = AIDirect.keyProblem(key, provider: provider) {
            keyMessage = problem
            return
        }
        AIDirect.apiKey = key
        savedKey = AIDirect.apiKey
        newKey = ""
        keyMessage = nil
        editingKey = false
        testResult = nil
        // Pick the matching service for keys that say where they are from.
        if key.hasPrefix("sk-or-") { provider = .openRouter }
        else if key.hasPrefix("sk-proj-") || key.hasPrefix("sk-svcacct-") { provider = .openAI }
        Task { await test() }
    }

    private func test() async {
        isTesting = true
        defer { isTesting = false }
        do {
            let reply = try await AIClient.testConnection(AIDirect.ownEndpoint)
            testResult = (true, L("连接成功：") + String(reply.prefix(20)))
        } catch {
            testResult = (false, AIClient.describe(error))
        }
    }
}
