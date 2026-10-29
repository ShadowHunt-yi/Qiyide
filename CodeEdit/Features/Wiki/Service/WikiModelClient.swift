//
//  WikiModelClient.swift
//  CodeEdit
//
//  整仓建档的模型调用层：让「一批文件」「一个模块」成为可并发的独立单元。
//
//  为什么单开这个文件：
//  WikiCurationRunner 是 @MainActor 的，直接在它里面起 TaskGroup 仍会回到主线程排队，
//  并发是假的。这里的方法全部 nonisolated，只依赖传入的 AINarrativeRequest 与
//  AIProviderKind（都是 Sendable），因此可以真正跑在协作线程池上。
//
//  重试策略也放在这里，保持单一职责：
//  - 预算不足（推理吃光 token）→ 加大预算重试；
//  - 429 / 5xx / 超时 → 指数退避重试；
//  - 401 / 403 / 404 → 立即失败，重试没有意义。
//

import Foundation

// MARK: - 单文件理解

struct WikiBatchJob: Sendable {
    let id: String
    let kind: AIProviderKind
    let request: AINarrativeRequest
    /// 本批包含的文件相对路径。
    let paths: [String]
    /// 已经由缓存命中的结论：不发请求，直接并回结果。
    var cached: [RepoFileInsight] = []
}

struct WikiBatchOutcome: Sendable {
    let id: String
    let paths: [String]
    let insights: [RepoFileInsight]
    /// 是否真正调用了模型（缓存命中时为 false，用于统计省钱效果）。
    let usedModel: Bool
    let error: String?
    let elapsed: TimeInterval

    var isSuccess: Bool { error == nil }
}

// MARK: - 模块联系

struct WikiRelationSpec: Sendable {
    let kind: String
    let target: String
}

struct WikiModuleDraftPayload: Sendable {
    let responsibility: String
    let relations: [WikiRelationSpec]
    let decisions: [String]
    let rules: [String]
}

struct WikiRelateJob: Sendable {
    let module: String
    let kind: AIProviderKind
    let request: AINarrativeRequest
}

struct WikiRelateOutcome: Sendable {
    let module: String
    let payload: WikiModuleDraftPayload?
    let error: String?
}

// MARK: - 客户端

enum WikiModelClient {

    /// 结构化输出的预算梯度。推理模型会把预算全花在思考上，第一次给足容易空正文。
    static let budgetLadder = [3072, 4096]

    // MARK: 并发调度

    /// 并发执行一批理解任务。
    static func run(
        _ jobs: [WikiBatchJob],
        concurrency: Int,
        onOutcome: (@Sendable (WikiBatchOutcome) -> Void)? = nil
    ) async -> [WikiBatchOutcome] {
        await schedule(jobs, concurrency: concurrency, onResult: onOutcome) { await execute($0) }
    }

    /// 并发执行一批模块联系任务。
    static func runRelate(
        _ jobs: [WikiRelateJob],
        concurrency: Int,
        onOutcome: (@Sendable (WikiRelateOutcome) -> Void)? = nil
    ) async -> [WikiRelateOutcome] {
        await schedule(jobs, concurrency: concurrency, onResult: onOutcome) { await executeRelate($0) }
    }

    /// 固定并发度的调度器。
    ///
    /// TaskGroup 本身不限并发，一次把 70 个任务全丢进去会同时打 70 个请求，
    /// 本地代理立刻 429。这里用「窗口」方式维持恰好 limit 个在飞。
    /// `onResult` 每完成一项回调一次：调用方据此实时落盘与更新进度。
    /// 之前要等整组返回，几十批跑完之前界面和磁盘都毫无变化。
    private static func schedule<Job: Sendable, Result: Sendable>(
        _ jobs: [Job],
        concurrency: Int,
        onResult: (@Sendable (Result) -> Void)? = nil,
        work: @escaping @Sendable (Job) async -> Result
    ) async -> [Result] {
        guard !jobs.isEmpty else { return [] }
        let limit = max(1, concurrency)

        return await withTaskGroup(of: Result.self) { group in
            var iterator = jobs.makeIterator()
            var results: [Result] = []
            var active = 0

            while active < limit, let job = iterator.next() {
                group.addTask { await work(job) }
                active += 1
            }
            while let result = await group.next() {
                results.append(result)
                onResult?(result)
                if let next = iterator.next() {
                    group.addTask { await work(next) }
                }
            }
            return results
        }
    }

    // MARK: 执行：理解文件

    static func execute(_ job: WikiBatchJob) async -> WikiBatchOutcome {
        let started = Date()
        defer { _ = started }

        // 全部命中缓存：一次请求都不发。
        if job.paths.isEmpty {
            return WikiBatchOutcome(
                id: job.id, paths: [], insights: job.cached,
                usedModel: false, error: nil, elapsed: 0
            )
        }

        do {
            let object = try await callJSON(kind: job.kind, request: job.request)
            guard let items = object["files"] as? [[String: Any]] else {
                return WikiBatchOutcome(
                    id: job.id, paths: job.paths, insights: job.cached,
                    usedModel: true, error: "模型返回缺少 files 字段",
                    elapsed: Date().timeIntervalSince(started)
                )
            }
            let insights = items.compactMap { item -> RepoFileInsight? in
                guard let path = item["path"] as? String, !path.isEmpty else { return nil }
                let purpose = (item["purpose"] as? String ?? "").trimmingCharacters(in: .whitespaces)
                guard !purpose.isEmpty else { return nil }
                let points = (item["keyPoints"] as? [String] ?? []).filter { !$0.isEmpty }
                return RepoFileInsight(path: path, purpose: purpose, keyPoints: points)
            }
            return WikiBatchOutcome(
                id: job.id,
                paths: job.paths,
                insights: job.cached + insights,
                usedModel: true,
                error: insights.isEmpty ? "模型没有解析出任何文件的职责" : nil,
                elapsed: Date().timeIntervalSince(started)
            )
        } catch {
            return WikiBatchOutcome(
                id: job.id, paths: job.paths, insights: job.cached,
                usedModel: true, error: AINarrativeError.describe(error),
                elapsed: Date().timeIntervalSince(started)
            )
        }
    }

    // MARK: 执行：模块联系

    static func executeRelate(_ job: WikiRelateJob) async -> WikiRelateOutcome {
        do {
            let object = try await callJSON(kind: job.kind, request: job.request)
            let responsibility = (object["responsibility"] as? String ?? "")
                .trimmingCharacters(in: .whitespaces)
            guard !responsibility.isEmpty else {
                return WikiRelateOutcome(module: job.module, payload: nil, error: "模型没有给出模块职责")
            }
            let relations = (object["relations"] as? [[String: Any]] ?? []).compactMap { item -> WikiRelationSpec? in
                guard let target = item["target"] as? String, !target.isEmpty else { return nil }
                let kind = (item["kind"] as? String ?? "").trimmingCharacters(in: .whitespaces)
                return WikiRelationSpec(kind: kind.isEmpty ? "相关" : kind, target: target)
            }
            let decisions = (object["decisions"] as? [String] ?? []).filter { !$0.isEmpty }
            let rules = (object["rules"] as? [String] ?? []).filter { !$0.isEmpty }
            return WikiRelateOutcome(
                module: job.module,
                payload: WikiModuleDraftPayload(
                    responsibility: responsibility,
                    relations: relations,
                    decisions: decisions,
                    rules: rules
                ),
                error: nil
            )
        } catch {
            return WikiRelateOutcome(
                module: job.module,
                payload: nil,
                error: AINarrativeError.describe(error)
            )
        }
    }

    // MARK: 单次请求（含预算梯度与退避）

    /// 发一次结构化请求并解析 JSON。失败时按错误类型决定是否继续重试。
    static func callJSON(
        kind: AIProviderKind,
        request: AINarrativeRequest,
        budgets: [Int] = budgetLadder
    ) async throws -> [String: Any] {
        let provider = kind.makeProvider()
        var lastError: Error = AINarrativeError.emptyResponse

        for (attempt, budget) in budgets.enumerated() {
            if attempt > 0 {
                // 退避 1.5s → 3s，给网关一点恢复时间。
                let delay = UInt64(1_500_000_000) * UInt64(attempt)
                try? await Task.sleep(nanoseconds: delay)
            }
            if Task.isCancelled { throw AINarrativeError.cancelled }

            do {
                let raw = try await provider.complete(request.withMaxTokens(budget))
                guard let object = parseJSON(raw) else {
                    lastError = WikiCuratorError.invalidResponse(String(raw.prefix(120)))
                    continue
                }
                return object
            } catch {
                lastError = error
                guard isRetryable(error) else { throw error }
            }
        }
        throw lastError
    }

    /// 配置错误重试没有意义，直接放弃这一批，让上层尽早暴露问题。
    static func isRetryable(_ error: Error) -> Bool {
        if let error = error as? AINarrativeError {
            switch error {
            case .http(let status, _):
                return status == 429 || (500..<600).contains(status)
            case .invalidURL, .notConfigured, .cancelled:
                return false
            default:
                return true
            }
        }
        if let error = error as? URLError {
            switch error.code {
            case .timedOut, .networkConnectionLost, .cannotConnectToHost,
                 .notConnectedToInternet, .dnsLookupFailed:
                return true
            default:
                return false
            }
        }
        return true
    }

    /// 从模型输出里抠出第一个 JSON 对象。
    static func parseJSON(_ raw: String) -> [String: Any]? {
        guard let start = raw.firstIndex(of: "{"),
              let end = raw.lastIndex(of: "}"),
              start < end,
              let data = String(raw[start...end]).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }
}
