//
//  CCSwitchBridge.swift
//  CodeEdit
//
//  接入 cc-switch 的本地代理。
//
//  为什么走代理而不直连 cc-switch 的数据库：
//  - 代理是 127.0.0.1 上的 Anthropic 兼容端点，密钥由 cc-switch 自己注入，
//    所以我们不需要读取、也不需要保存用户的任何密钥；
//  - 应用在沙盒里读不到 ~/.cc-switch 与 ~/.claude，但访问本机回环端口不需要任何权限；
//  - 用户在 cc-switch 里切换 Provider 后，这边自动跟随，不存在配置漂移。
//
//  路径：cc-switch 代理服务 /v1/messages（/messages 会 404），
//  因此 baseURL 取 http://127.0.0.1:<port>/v1，交由 AINarrativeEndpoint 补 /messages。
//

import Foundation

enum CCSwitchBridge {

    /// cc-switch 默认端口。
    static let defaultPort = 15721

    /// 代理不校验本地凭据，占位即可；不写入钥匙串，也不出现在任何配置里。
    static let placeholderKey = "cc-switch-local"

    enum Health: Equatable {
        case running
        case unreachable(String)

        var isRunning: Bool {
            if case .running = self { return true }
            return false
        }
    }

    static func baseURL(port: Int) -> String {
        "http://127.0.0.1:\(port)/v1"
    }

    // MARK: 健康检查

    static func check(port: Int, timeout: TimeInterval = 4) async -> Health {
        guard let url = URL(string: "http://127.0.0.1:\(port)/health") else {
            return .unreachable("端口无效")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                return .unreachable("端口 \(port) 返回 HTTP \(code)")
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  json["status"] as? String == "healthy" else {
                return .unreachable("端口 \(port) 有服务，但不是 cc-switch")
            }
            return .running
        } catch {
            return .unreachable("cc-switch 未运行（\(port) 无响应）")
        }
    }

    // MARK: 实际路由探测

    /// 发一个 1 token 的请求，读回代理实际路由到的模型名。
    ///
    /// 这一步很关键：cc-switch 会把 `claude-sonnet-5` 这类档位别名翻译成真实模型，
    /// 只有回读响应里的 model 才能确认请求真的落到了预期的 Provider 上。
    static func resolveModel(
        port: Int,
        model: String,
        timeout: TimeInterval = 20
    ) async -> Result<String, Error> {
        guard let url = URL(string: "http://127.0.0.1:\(port)/v1/messages") else {
            return .failure(AINarrativeError.invalidURL(baseURL(port: port)))
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(placeholderKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 1,
            "messages": [["role": "user", "content": "ping"]]
        ]
        guard let payload = try? JSONSerialization.data(withJSONObject: body) else {
            return .failure(AINarrativeError.invalidResponse)
        }
        request.httpBody = payload

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard code == 200 else {
                let text = String(data: data, encoding: .utf8) ?? ""
                return .failure(AINarrativeError.http(status: code, message: String(text.prefix(300))))
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let resolved = json["model"] as? String else {
                return .failure(AINarrativeError.emptyResponse)
            }
            return .success(resolved)
        } catch {
            return .failure(error)
        }
    }
}
