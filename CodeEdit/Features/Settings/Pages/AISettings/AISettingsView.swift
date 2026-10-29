//
//  AISettingsView.swift
//  CodeEdit
//
//  AI 叙述的接入设置。
//
//  两条路径：
//  - 手动配置：直连 OpenAI 兼容服务或 Anthropic 官方，用自己的 Key；
//  - cc-switch 代理：指向本机 cc-switch 的 Anthropic 兼容端点，密钥由 cc-switch 注入，
//    切换 Provider 后自动跟随，本应用不接触任何凭据。
//
//  默认关闭——不填任何东西时，审查功能仍然是纯本地规则引擎。
//

import SwiftUI

struct AISettingsView: View {

    @StateObject private var store = AINarrativeStore.shared
    @State private var keyInput: String = ""
    @State private var showKey: Bool = false
    @State private var keySaveFailed: Bool = false
    @State private var testState: TestState = .idle
    @State private var health: CCSwitchBridge.Health?

    private enum TestState: Equatable {
        case idle
        case running
        case success(String)
        case failure(String)
    }

    var body: some View {
        SettingsForm {
            Section {
                Toggle(isOn: $store.configuration.isEnabled) {
                    Label {
                        Text("AI 叙述")
                        Text("""
                         在改动审查中为每次提交补一句中文说明。分层、风险信号与重要度始终由本地规则计算，\
                         模型只负责叙述，不参与评判。
                         """)
                        .font(.callout)
                    } icon: {
                        FeatureIcon(symbol: "sparkles", color: Color(.systemPurple), size: 26)
                    }
                }
                .controlSize(.large)
            }

            if store.configuration.isEnabled {
                endpointSection
                if store.configuration.mode == .manual {
                    protocolSection
                    credentialSection
                } else {
                    ccSwitchSection
                }
                parameterSection
                verifySection
            }
        }
        .onAppear(perform: appear)
        .onChange(of: store.configuration.provider) { _, _ in loadKey() }
        .onChange(of: store.configuration.mode) { _, mode in
            testState = .idle
            health = nil
            if mode == .ccSwitchProxy {
                Task { await checkHealth() }
            }
        }
    }

    // MARK: 接入方式

    private var endpointSection: some View {
        Section {
            Picker("接入方式", selection: $store.configuration.mode) {
                ForEach(AIConnectMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        } header: {
            Text("接入方式")
        } footer: {
            Text(store.configuration.mode == .ccSwitchProxy
                 ? "跟随 cc-switch 当前 Provider，切 Provider 不用回来改配置。"
                 : "直连模型服务，需要自己填 Base URL 与 API Key。")
                .font(.callout)
        }
    }

    // MARK: 手动：协议

    private var protocolSection: some View {
        Section {
            Picker("协议", selection: providerBinding) {
                ForEach(AIProviderKind.allCases) { kind in
                    Text(kind.title).tag(kind)
                }
            }
            .pickerStyle(.segmented)

            TextField("Base URL", text: $store.configuration.baseURL)
                .font(.system(size: 12, design: .monospaced))
            TextField("模型", text: $store.configuration.model)
                .font(.system(size: 12, design: .monospaced))
        } header: {
            Text("协议")
        } footer: {
            Text(manualHint)
                .font(.callout)
        }
    }

    private var manualHint: String {
        switch store.configuration.provider {
        case .openAICompatible:
            return "填到 /v1 即可，会自动拼接 /chat/completions。也可对接 DeepSeek、通义、Kimi 或自建 vLLM。"
        case .anthropic:
            return "填到 /v1 即可，会自动拼接 /messages，并附带 anthropic-version 头。"
        }
    }

    private var providerBinding: Binding<AIProviderKind> {
        Binding(
            get: { store.configuration.provider },
            set: { store.switchProvider(to: $0) }
        )
    }

    // MARK: 手动：凭据

    private var credentialSection: some View {
        Section {
            HStack(spacing: 8) {
                Group {
                    if showKey {
                        TextField("API Key", text: $keyInput)
                    } else {
                        SecureField("API Key", text: $keyInput)
                    }
                }
                .font(.system(size: 12, design: .monospaced))

                Button(showKey ? "隐藏" : "显示") { showKey.toggle() }
                    .buttonStyle(.link)
                    .font(.system(size: 11))

                Button("保存") { saveKey() }
                    .controlSize(.small)
            }

            if keySaveFailed {
                Label("无法写入钥匙串，请检查签名与沙盒权限", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            } else if store.hasAPIKey(for: store.configuration.provider) {
                Label("已保存在钥匙串", systemImage: "lock.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("凭据")
        } footer: {
            Text("密钥只写入系统钥匙串，不落在 settings.json 或任何可同步的文件里。")
                .font(.callout)
        }
    }

    // MARK: cc-switch

    private var ccSwitchSection: some View {
        Section {
            HStack(spacing: 8) {
                Text("端口")
                TextField("", value: $store.configuration.ccSwitchPort, format: .number)
                    .frame(width: 70)
                    .multilineTextAlignment(.trailing)
                Button("检测") { Task { await checkHealth() } }
                    .controlSize(.small)
                healthLabel
                Spacer()
            }

            HStack(spacing: 8) {
                Text("模型档位")
                TextField("", text: $store.configuration.ccSwitchModel)
                    .font(.system(size: 12, design: .monospaced))
                Menu("常用") {
                    ForEach(AINarrativeConfiguration.ccSwitchModels, id: \.self) { alias in
                        Button(alias) { store.configuration.ccSwitchModel = alias }
                    }
                }
                .menuStyle(.borderlessButton)
                .frame(width: 60)
            }
        } header: {
            Text("cc-switch 本地代理")
        } footer: {
            Text("""
             cc-switch 会把档位别名（如 claude-sonnet-5）翻译成当前 Provider 的真实模型，\
             所以在 cc-switch 里换 Provider 之后，这里不需要改任何东西。\
             密钥由 cc-switch 注入，本应用既不读取也不保存。
             """)
            .font(.callout)
        }
    }

    @ViewBuilder
    private var healthLabel: some View {
        switch health {
        case .none:
            EmptyView()
        case .running:
            Label("在线", systemImage: "checkmark.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.green)
        case .unreachable(let message):
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private func checkHealth() async {
        health = await CCSwitchBridge.check(port: store.configuration.ccSwitchPort)
    }

    // MARK: 生成参数

    private var parameterSection: some View {
        Section {
            HStack {
                Text("输出上限")
                Spacer()
                Stepper(
                    value: $store.configuration.maxTokens,
                    in: AINarrativeConfiguration.Limits.maxTokens,
                    step: 16
                ) {
                    Text("\(store.configuration.maxTokens) tokens")
                        .monospacedDigit()
                }
                .frame(width: 200)
            }
            HStack {
                Text("送模型的补丁上限")
                Spacer()
                Picker("", selection: $store.configuration.diffCharacters) {
                    ForEach(AINarrativeConfiguration.Limits.diffCharacterPresets, id: \.self) { value in
                        Text("\(value) 字符").tag(value)
                    }
                }
                .labelsHidden()
                .frame(width: 140)
            }
            HStack {
                Text("超时")
                Spacer()
                Stepper(
                    value: $store.configuration.timeout,
                    in: AINarrativeConfiguration.Limits.timeout,
                    step: 5
                ) {
                    Text("\(Int(store.configuration.timeout)) 秒")
                        .monospacedDigit()
                }
                .frame(width: 200)
            }
        } header: {
            Text("生成参数")
        } footer: {
            Text("补丁超出上限时按「头 3/4 + 尾 1/4」截断，并不会把整个仓库送出去。")
                .font(.callout)
        }
    }

    // MARK: 连接测试

    private var verifySection: some View {
        Section {
            HStack(spacing: 10) {
                Button("测试连接") {
                    Task { await test() }
                }
                .controlSize(.small)
                .disabled(testState == .running)

                switch testState {
                case .idle:
                    EmptyView()
                case .running:
                    ProgressView().scaleEffect(0.45).frame(width: 12, height: 12)
                case .success(let detail):
                    Label(detail, systemImage: "checkmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.green)
                        .lineLimit(2)
                case .failure(let message):
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
            }
        } footer: {
            Text(store.configuration.mode == .ccSwitchProxy
                 ? "测试会经 cc-switch 发一次 1 token 请求，并回读实际路由到的模型名。"
                 : "测试会发送一次极短请求，可能产生少量费用。")
                .font(.callout)
        }
    }

    private func test() async {
        testState = .running
        if store.configuration.mode == .ccSwitchProxy {
            await testProxy()
        } else {
            await testManual()
        }
    }

    private func testProxy() async {
        let port = store.configuration.ccSwitchPort
        health = await CCSwitchBridge.check(port: port)
        guard case .running = health else {
            if case .unreachable(let message) = health {
                testState = .failure(message)
            } else {
                testState = .failure("cc-switch 代理不可用")
            }
            return
        }
        let result = await CCSwitchBridge.resolveModel(
            port: port,
            model: store.configuration.ccSwitchModel
        )
        switch result {
        case .success(let resolved):
            testState = .success("已连通 · 实际模型 \(resolved)")
        case .failure(let error):
            testState = .failure(AINarrativeError.describe(error))
        }
    }

    private func testManual() async {
        guard let provider = store.makeProvider(),
              let request = store.makeRequest(system: "只回复 OK。", user: "ping") else {
            testState = .failure(store.blockedReason ?? "配置不完整")
            return
        }
        var received = ""
        do {
            for try await chunk in provider.stream(request) {
                received += chunk
                if received.count > 40 { break }
            }
            testState = received.isEmpty ? .failure("连接成功但返回内容为空") : .success("连接正常")
        } catch {
            testState = .failure(AINarrativeError.describe(error))
        }
    }

    // MARK: 生命周期

    private func appear() {
        loadKey()
        if store.configuration.isEnabled && store.configuration.mode == .ccSwitchProxy {
            Task { await checkHealth() }
        }
    }

    private func loadKey() {
        keyInput = store.apiKey(for: store.configuration.provider)
        keySaveFailed = false
        testState = .idle
    }

    private func saveKey() {
        keySaveFailed = !store.saveAPIKey(keyInput, for: store.configuration.provider)
        testState = .idle
    }
}
