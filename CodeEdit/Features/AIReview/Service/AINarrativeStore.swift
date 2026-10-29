//
//  AINarrativeStore.swift
//  CodeEdit
//
//  AI 叙述层的配置：接入方式、协议、地址、模型、密钥。
//
//  两种接入方式：
//  - manual：直连某个 OpenAI 兼容服务或 Anthropic 官方，需要自己的 API Key；
//  - ccSwitchProxy：指向 cc-switch 的本地代理，密钥由 cc-switch 注入，不经过本应用。
//
//  手写 decode：新增字段必须 decodeIfPresent，否则旧配置整段解码失败、
//  被静默重置为默认值（这个坑在本项目里踩过一次）。
//

import Combine
import Foundation

// MARK: - 接入方式

enum AIConnectMode: String, Codable, CaseIterable, Identifiable {
    case manual
    case ccSwitchProxy

    var id: String { rawValue }

    var title: String {
        switch self {
        case .manual: return "手动配置"
        case .ccSwitchProxy: return "cc-switch 代理"
        }
    }
}

// MARK: - 配置

struct AINarrativeConfiguration: Codable, Equatable {
    var isEnabled: Bool = false
    var mode: AIConnectMode = .manual

    // 手动模式
    var provider: AIProviderKind = .openAICompatible
    var baseURL: String = AIProviderKind.openAICompatible.defaultBaseURL
    var model: String = AIProviderKind.openAICompatible.defaultModel

    // cc-switch 模式
    var ccSwitchPort: Int = CCSwitchBridge.defaultPort
    var ccSwitchModel: String = AINarrativeConfiguration.ccSwitchModels[0]

    // 生成参数
    var maxTokens: Int = 480
    var temperature: Double = 0.2
    var timeout: Double = 25
    /// 送进模型的 diff 字符上限。超出按「头 3/4 + 尾 1/4」截断。
    var diffCharacters: Int = 6000

    /// cc-switch 把请求里的档位别名翻译成真实模型，因此这里填的是「别名」而非真实模型名。
    static let ccSwitchModels = [
        "claude-sonnet-5",
        "claude-opus-5[1M]",
        "claude-haiku-5-5",
        "claude-fable-5[1M]"
    ]

    /// 数值参数的合法区间。
    ///
    /// 上游对 max_tokens 有自己的上限（某网关是 [1, 393216]），但叙述只要几十个字，
    /// 给一个远小于上游上限的区间就够用——更重要的是永远不要把 0 或天文数字发出去。
    enum Limits {
        static let maxTokens = 16...4096
        static let timeout: ClosedRange<Double> = 5...120
        static let temperature: ClosedRange<Double> = 0...1

        static let diffCharacterPresets = [2000, 4000, 6000, 12000, 20000]
    }

    /// 把越界值夹回合法区间。历史配置里可能存着 4000000 / 600000000 这种值。
    func normalized() -> AINarrativeConfiguration {
        var copy = self
        copy.maxTokens = min(max(maxTokens, Limits.maxTokens.lowerBound), Limits.maxTokens.upperBound)
        // 补丁上限吸附到最近的预设档：界面用 Picker 呈现，值必须能对上 tag。
        copy.diffCharacters = Limits.diffCharacterPresets.min {
            abs($0 - diffCharacters) < abs($1 - diffCharacters)
        } ?? 6000
        copy.timeout = min(max(timeout, Limits.timeout.lowerBound), Limits.timeout.upperBound)
        copy.temperature = min(
            max(temperature, Limits.temperature.lowerBound),
            Limits.temperature.upperBound
        )
        return copy
    }

    init() { }

    private enum CodingKeys: String, CodingKey {
        case isEnabled, mode, provider, baseURL, model
        case ccSwitchPort, ccSwitchModel
        case maxTokens, temperature, timeout, diffCharacters
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AINarrativeConfiguration()
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? defaults.isEnabled
        mode = try container.decodeIfPresent(AIConnectMode.self, forKey: .mode) ?? defaults.mode
        provider = try container.decodeIfPresent(AIProviderKind.self, forKey: .provider) ?? defaults.provider
        baseURL = try container.decodeIfPresent(String.self, forKey: .baseURL) ?? defaults.baseURL
        model = try container.decodeIfPresent(String.self, forKey: .model) ?? defaults.model
        ccSwitchPort = try container.decodeIfPresent(Int.self, forKey: .ccSwitchPort) ?? defaults.ccSwitchPort
        ccSwitchModel = try container.decodeIfPresent(String.self, forKey: .ccSwitchModel) ?? defaults.ccSwitchModel
        maxTokens = try container.decodeIfPresent(Int.self, forKey: .maxTokens) ?? defaults.maxTokens
        temperature = try container.decodeIfPresent(Double.self, forKey: .temperature) ?? defaults.temperature
        timeout = try container.decodeIfPresent(Double.self, forKey: .timeout) ?? defaults.timeout
        diffCharacters = try container.decodeIfPresent(
            Int.self, forKey: .diffCharacters
        ) ?? defaults.diffCharacters
    }
}

// MARK: - 存储

@MainActor
final class AINarrativeStore: ObservableObject {

    static let shared = AINarrativeStore()

    /// 用户可调的配置。改动即落盘，无需额外保存按钮。
    @Published var configuration: AINarrativeConfiguration {
        didSet { persist() }
    }

    private let defaultsKey = "aiReview.narrative.config.v1"
    private let keychain = CodeEditKeychain(keyPrefix: "qiyide.aiReview")
    private var cachedKeys: [AIProviderKind: String] = [:]

    private init() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode(AINarrativeConfiguration.self, from: data) {
            // 历史配置可能存着越界数值，载入时先夹一次，界面显示的也就是可用值。
            let safe = decoded.normalized()
            configuration = safe
            if safe != decoded {
                // 顺手把脏值写回干净版本，避免下次又被读进来。
                persist()
            }
        } else {
            configuration = AINarrativeConfiguration()
        }
    }

    // MARK: 密钥（仅手动模式需要）

    func apiKey(for kind: AIProviderKind) -> String {
        if let cached = cachedKeys[kind] { return cached }
        let value = keychain.get("key.\(kind.rawValue)") ?? ""
        cachedKeys[kind] = value
        return value
    }

    @discardableResult
    func saveAPIKey(_ key: String, for kind: AIProviderKind) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            keychain.delete("key.\(kind.rawValue)")
            cachedKeys[kind] = ""
            return true
        }
        let ok = keychain.set(trimmed, forKey: "key.\(kind.rawValue)")
        if ok { cachedKeys[kind] = trimmed }
        return ok
    }

    func hasAPIKey(for kind: AIProviderKind) -> Bool {
        !apiKey(for: kind).isEmpty
    }

    // MARK: 可用性

    var isReady: Bool {
        blockedReason == nil
    }

    /// 未就绪时给出具体原因，供界面直接展示。
    var blockedReason: String? {
        guard configuration.isEnabled else { return "未开启 AI 叙述" }
        switch configuration.mode {
        case .manual:
            if configuration.baseURL.trimmingCharacters(in: .whitespaces).isEmpty { return "未填写 Base URL" }
            if configuration.model.trimmingCharacters(in: .whitespaces).isEmpty { return "未填写模型名" }
            if !hasAPIKey(for: configuration.provider) {
                return "\(configuration.provider.title) 的 API Key 未设置"
            }
            return nil
        case .ccSwitchProxy:
            guard (1...65535).contains(configuration.ccSwitchPort) else { return "cc-switch 端口无效" }
            if configuration.ccSwitchModel.trimmingCharacters(in: .whitespaces).isEmpty {
                return "未选择 cc-switch 模型档位"
            }
            // 代理本身不校验 key，因此这里不要求填写任何凭据。
            return nil
        }
    }

    /// 当前接入的模型标识，用于在生成内容上留痕。
    var providerLabel: String {
        switch configuration.mode {
        case .manual: return "\(configuration.provider.rawValue):\(configuration.model)"
        case .ccSwitchProxy: return "cc-switch:\(configuration.ccSwitchModel)"
        }
    }

    // MARK: 组装请求

    /// 切换协议时，把仍是「另一协议默认值」的地址与模型同步过去，避免手动改两遍。
    func switchProvider(to kind: AIProviderKind) {
        let old = configuration.provider
        guard old != kind else { return }
        if configuration.baseURL == old.defaultBaseURL || configuration.baseURL.isEmpty {
            configuration.baseURL = kind.defaultBaseURL
        }
        if configuration.model == old.defaultModel || configuration.model.isEmpty {
            configuration.model = kind.defaultModel
        }
        configuration.provider = kind
    }

    func makeProvider() -> AINarrativeProvider? {
        guard isReady else { return nil }
        return configuration.mode == .ccSwitchProxy
            ? AnthropicProvider()
            : configuration.provider.makeProvider()
    }

    func makeRequest(system: String, user: String) -> AINarrativeRequest? {
        guard isReady else { return nil }
        let endpoint = resolvedEndpoint()
        // 无论配置里存着什么，发出去的数值一定在合法区间内。
        let safe = configuration.normalized()
        return AINarrativeRequest(
            baseURL: endpoint.baseURL,
            model: endpoint.model,
            apiKey: endpoint.apiKey,
            systemPrompt: system,
            userPrompt: user,
            maxTokens: safe.maxTokens,
            temperature: safe.temperature,
            timeout: safe.timeout
        )
    }

    /// 当前生效的地址、模型与凭据。cc-switch 模式下凭据是占位符。
    func resolvedEndpoint() -> (baseURL: String, model: String, apiKey: String) {
        switch configuration.mode {
        case .manual:
            return (
                configuration.baseURL,
                configuration.model,
                apiKey(for: configuration.provider)
            )
        case .ccSwitchProxy:
            return (
                CCSwitchBridge.baseURL(port: configuration.ccSwitchPort),
                configuration.ccSwitchModel,
                CCSwitchBridge.placeholderKey
            )
        }
    }

    // MARK: 落盘

    private func persist() {
        let safe = configuration.normalized()
        guard let data = try? JSONEncoder().encode(safe) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}
