//
//  AINarrativeProvider.swift
//  CodeEdit
//
//  AI 叙述层：只负责「把结构化摘要变成一句话叙述」，不参与分层与评分。
//
//  支持两种协议：
//  - OpenAI 兼容：POST {base}/chat/completions，SSE 增量在 choices[0].delta.content
//  - Anthropic：POST {base}/messages，SSE 增量在 content_block_delta.delta.text
//
//  两者都是 text/event-stream，差异只在请求体与增量字段，
//  因此共用 AIStreamRunner 的读取与生命周期管理，避免两套重复的流式代码。
//

import Foundation
import OSLog

// MARK: - 协议类型

/// 模型接入协议。OpenAI 兼容覆盖 OpenAI / DeepSeek / 通义 / Kimi / vLLM 等。
enum AIProviderKind: String, Codable, CaseIterable, Identifiable {
    case openAICompatible = "openai"
    case anthropic

    var id: String { rawValue }

    var title: String {
        switch self {
        case .openAICompatible: return "OpenAI 兼容"
        case .anthropic: return "Anthropic"
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .openAICompatible: return "https://api.openai.com/v1"
        case .anthropic: return "https://api.anthropic.com/v1"
        }
    }

    var defaultModel: String {
        switch self {
        case .openAICompatible: return "gpt-4o-mini"
        case .anthropic: return "claude-3-5-sonnet-latest"
        }
    }

    /// 端点路径，用于把用户填写的 baseURL 归一化。
    var endpointPath: String {
        switch self {
        case .openAICompatible: return "chat/completions"
        case .anthropic: return "messages"
        }
    }

    func makeProvider() -> AINarrativeProvider {
        switch self {
        case .openAICompatible: return OpenAICompatibleProvider()
        case .anthropic: return AnthropicProvider()
        }
    }
}

// MARK: - 错误

enum AINarrativeError: LocalizedError, Equatable {
    case notConfigured(String)
    case invalidURL(String)
    case invalidResponse
    case http(status: Int, message: String)
    case emptyResponse
    /// 流式返回了 200 但没有任何内容，附上非流式探测得到的真实原因。
    case emptyStream(String)
    /// 推理占满输出预算，正文一个字没出来。
    case budgetExhausted(Int)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .notConfigured(let detail): return detail
        case .invalidURL(let raw): return "地址无法解析：\(raw)"
        case .invalidResponse: return "服务端返回了非 HTTP 响应"
        case .http(let status, let message):
            switch status {
            case 401, 403: return "鉴权失败（\(status)）：请检查 API Key。\(message)"
            case 404: return "接口不存在（404）：请检查 Base URL 是否包含 /v1。\(message)"
            case 429: return "触发限流（429）：稍后重试或更换模型。\(message)"
            default: return "请求失败（\(status)）：\(message)"
            }
        case .emptyResponse: return "模型返回了空内容"
        case .budgetExhausted(let limit):
            return "模型把 \(limit) tokens 全用在推理上了，没有产出正文。已自动加大预算重试。"
        case .emptyStream(let detail):
            if detail.lowercased().contains("sensitive") {
                return "上游内容审核拦截了这次请求（\(detail)）。补丁里的敏感值已自动脱敏，"
                    + "若仍失败请改用其他模型。"
            }
            return "模型没有返回内容：\(detail)"
        case .cancelled: return "已取消"
        }
    }

    /// 把 URLSession 的原始错误翻译成可操作的提示。
    static func describe(_ error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost:
                return "连不上服务：若使用 cc-switch 代理，请确认 cc-switch 正在运行且端口一致"
            case .timedOut:
                return "请求超时，可在设置中调大「超时」"
            case .notConnectedToInternet:
                return "网络不可用"
            default:
                break
            }
        }
        return error.localizedDescription
    }
}

// MARK: - 请求

struct AINarrativeRequest: Sendable {
    let baseURL: String
    let model: String
    let apiKey: String
    let systemPrompt: String
    let userPrompt: String
    let maxTokens: Int
    let temperature: Double
    let timeout: TimeInterval
}

/// 实现都是无状态的 struct：允许跨线程并发调用，这是整仓建档提高吞吐的前提。
protocol AINarrativeProvider: Sendable {
    var kind: AIProviderKind { get }
    func stream(_ request: AINarrativeRequest) -> AsyncThrowingStream<String, Error>
    /// 组装好的请求，流式与非流式共用，避免两套 body 逻辑漂移。
    func urlRequest(for request: AINarrativeRequest) throws -> URLRequest
    /// 从非流式响应里取出正文。
    func text(from data: Data) -> String?
}

// MARK: - 共用的 SSE 读取

/// 单行解析结果。
enum AINarrativeStreamEvent {
    case text(String)
    case done
    case ignore
}

enum AIStreamRunner {
    static let logger = Logger(subsystem: "app.qiyide.Qiyide", category: "AIReview")

    /// 打开请求并按 SSE 逐行解析。`decode` 只做单行到事件的映射，协议差异全部收敛在这里。
    static func open(
        _ urlRequest: URLRequest,
        decode: @escaping (String) -> AINarrativeStreamEvent
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var producedText = false
                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: urlRequest)
                    guard let http = response as? HTTPURLResponse else {
                        throw AINarrativeError.invalidResponse
                    }
                    guard (200..<300).contains(http.statusCode) else {
                        throw AINarrativeError.http(
                            status: http.statusCode,
                            message: await briefErrorBody(bytes)
                        )
                    }
                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        switch decode(line) {
                        case .text(let chunk):
                            producedText = true
                            continuation.yield(chunk)
                        case .done:
                            continuation.finish()
                            return
                        case .ignore:
                            continue
                        }
                    }
                    // 空流：某些网关把上游错误（如内容审核 502）吞成 200 + 空 body，
                    // 这时用一次非流式请求把真实原因取回来，否则只能报「空内容」。
                    if !producedText && !Task.isCancelled, let detail = await diagnose(urlRequest) {
                        continuation.finish(throwing: AINarrativeError.emptyStream(detail))
                        return
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: AINarrativeError.cancelled)
                } catch {
                    logger.error("模型请求失败：\(error.localizedDescription, privacy: .public)")
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// 用同一个请求体改成非流式再发一次，把被网关吞掉的真实错误捞出来。
    ///
    /// 实测：某些网关遇到上游内容审核拒绝时，流式返回 200 + 空 body，
    /// 非流式才回 502 与 `sensitive contain:[...]` 的具体原因。
    private static func diagnose(_ urlRequest: URLRequest) async -> String? {
        guard let body = urlRequest.httpBody,
              var json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return nil
        }
        json["stream"] = false
        guard let probeBody = try? JSONSerialization.data(withJSONObject: json) else { return nil }

        var probe = urlRequest
        probe.httpBody = probeBody
        probe.setValue("application/json", forHTTPHeaderField: "Accept")
        probe.timeoutInterval = min(max(urlRequest.timeoutInterval, 10), 60)

        guard let (data, response) = try? await URLSession.shared.data(for: probe) else { return nil }
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        let text = (String(data: data, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if status >= 300 {
            return "HTTP \(status) \(String(text.prefix(240)))"
        }
        return text.isEmpty ? "上游返回空响应（HTTP \(status)）" : String(text.prefix(240))
    }

    /// 非 2xx 时把响应体前 600 字符取出来，供错误提示使用。
    private static func briefErrorBody(_ bytes: URLSession.AsyncBytes) async -> String {        var body = ""
        do {
            for try await line in bytes.lines {
                body += line
                if body.count > 600 { break }
            }
        } catch {
            return ""
        }
        return body.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `data:` 前缀后的 JSON 负载。
    static func payload(_ line: String) -> String? {
        guard line.hasPrefix("data:") else { return nil }
        let trimmed = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func json(_ payload: String) -> [String: Any]? {
        guard let data = payload.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

// MARK: - URL 归一化

enum AINarrativeEndpoint {
    /// 允许用户填 `https://host/v1`、`https://host/v1/` 或直接填完整端点。
    static func resolve(baseURL: String, kind: AIProviderKind) throws -> URL {
        var raw = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { throw AINarrativeError.invalidURL(baseURL) }
        while raw.hasSuffix("/") { raw.removeLast() }
        if !raw.hasSuffix(kind.endpointPath) {
            raw += "/" + kind.endpointPath
        }
        guard let url = URL(string: raw), url.scheme != nil, url.host != nil else {
            throw AINarrativeError.invalidURL(baseURL)
        }
        return url
    }
}

// MARK: - OpenAI 兼容

struct OpenAICompatibleProvider: AINarrativeProvider {
    let kind: AIProviderKind = .openAICompatible

    func stream(_ request: AINarrativeRequest) -> AsyncThrowingStream<String, Error> {
        do {
            return AIStreamRunner.open(try urlRequest(for: request), decode: Self.decode)
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
    }

    func text(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = object["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            return nil
        }
        return content
    }

    func urlRequest(for request: AINarrativeRequest) throws -> URLRequest {
        var urlRequest = URLRequest(url: try AINarrativeEndpoint.resolve(
            baseURL: request.baseURL,
            kind: kind
        ))
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = request.timeout
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(request.apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")

        let body: [String: Any] = [
            "model": request.model,
            "stream": true,
            "max_tokens": request.maxTokens,
            "temperature": request.temperature,
            "messages": [
                ["role": "system", "content": request.systemPrompt],
                ["role": "user", "content": request.userPrompt]
            ]
        ]
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
        return urlRequest
    }

    static func decode(_ line: String) -> AINarrativeStreamEvent {
        guard let payload = AIStreamRunner.payload(line) else { return .ignore }
        if payload == "[DONE]" { return .done }
        guard let object = AIStreamRunner.json(payload) else { return .ignore }
        guard let choices = object["choices"] as? [[String: Any]],
              let delta = choices.first?["delta"] as? [String: Any],
              let content = delta["content"] as? String else {
            return .ignore
        }
        return content.isEmpty ? .ignore : .text(content)
    }
}

// MARK: - Anthropic

struct AnthropicProvider: AINarrativeProvider {
    let kind: AIProviderKind = .anthropic
    /// 版本号需要显式声明，否则服务端返回 400。
    private let apiVersion = "2023-06-01"

    func stream(_ request: AINarrativeRequest) -> AsyncThrowingStream<String, Error> {
        do {
            return AIStreamRunner.open(try urlRequest(for: request), decode: Self.decode)
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
    }

    func text(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let blocks = object["content"] as? [[String: Any]] else {
            return nil
        }
        let text = blocks
            .filter { ($0["type"] as? String) == "text" }
            .compactMap { $0["text"] as? String }
            .joined()
        return text.isEmpty ? nil : text
    }

    func urlRequest(for request: AINarrativeRequest) throws -> URLRequest {
        var urlRequest = URLRequest(url: try AINarrativeEndpoint.resolve(
            baseURL: request.baseURL,
            kind: kind
        ))
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = request.timeout
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(request.apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")

        // Anthropic 把 system 放在顶层，messages 只接受 user / assistant。
        let body: [String: Any] = [
            "model": request.model,
            "stream": true,
            "max_tokens": request.maxTokens,
            "temperature": request.temperature,
            "system": request.systemPrompt,
            "messages": [
                ["role": "user", "content": request.userPrompt]
            ]
        ]
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
        return urlRequest
    }

    static func decode(_ line: String) -> AINarrativeStreamEvent {
        guard let payload = AIStreamRunner.payload(line) else { return .ignore }
        guard let object = AIStreamRunner.json(payload) else { return .ignore }
        switch object["type"] as? String {
        case "content_block_delta":
            guard let delta = object["delta"] as? [String: Any],
                  let text = delta["text"] as? String else { return .ignore }
            return text.isEmpty ? .ignore : .text(text)
        case "message_stop":
            return .done
        default:
            return .ignore
        }
    }
}

// MARK: - 一次性请求

extension AINarrativeProvider {
    /// 取回完整响应，不做流式。
    ///
    /// 结构化输出（要求模型返回 JSON）必须用这条路径：流式一旦在中途被网关掐断，
    /// 拿到的就是半截 JSON，既无法解析也无法判断是模型写错还是连接断了。
    /// 一次性请求要么完整成功，要么明确失败，重试语义清晰。
    func complete(_ request: AINarrativeRequest) async throws -> String {
        var urlRequest = try urlRequest(for: request)
        guard let body = urlRequest.httpBody,
              var json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw AINarrativeError.invalidResponse
        }
        json["stream"] = false
        guard let rebuilt = try? JSONSerialization.data(withJSONObject: json) else {
            throw AINarrativeError.invalidResponse
        }
        urlRequest.httpBody = rebuilt
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else {
            throw AINarrativeError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let raw = String(data: data, encoding: .utf8) ?? ""
            throw AINarrativeError.http(status: http.statusCode, message: String(raw.prefix(300)))
        }
        if let content = text(from: data), !content.isEmpty {
            return content
        }
        // 空正文多半是预算被推理吃掉，单独识别出来，便于上层加大预算重试。
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           (object["stop_reason"] as? String) == "max_tokens" {
            throw AINarrativeError.budgetExhausted(request.maxTokens)
        }
        let raw = String(data: data, encoding: .utf8) ?? ""
        throw AINarrativeError.emptyStream("HTTP \(http.statusCode) \(raw.prefix(200))")
    }
}


extension AINarrativeRequest {
    /// 复制一份并替换用户提示词。整仓建档按批拼装内容，需要保留 system / 模型 / 超时。
    func withUserPrompt(_ prompt: String) -> AINarrativeRequest {
        AINarrativeRequest(
            baseURL: baseURL,
            model: model,
            apiKey: apiKey,
            systemPrompt: systemPrompt,
            userPrompt: prompt,
            maxTokens: maxTokens,
            temperature: temperature,
            timeout: timeout
        )
    }

    /// 复制一份并替换输出预算，用于结构化输出这种需要更大余量的场景。
    func withMaxTokens(_ value: Int) -> AINarrativeRequest {
        AINarrativeRequest(
            baseURL: baseURL,
            model: model,
            apiKey: apiKey,
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            maxTokens: value,
            temperature: temperature,
            timeout: timeout
        )
    }
}
