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
    var sources: [WikiSourceSnapshot] = []
    var pipelineKey: String = ""
}

enum WikiModelStop: Sendable {
    case budget, cancelled
    static func classify(_ error: Error) -> Self? {
        if case WikiGenerationError.requestLimit = error { return .budget }
        if error is CancellationError { return .cancelled }
        return nil
    }
}

struct WikiBatchOutcome: Sendable {
    let id: String
    let paths: [String]
    let insights: [RepoFileInsight]
    /// 是否真正调用了模型（缓存命中时为 false，用于统计省钱效果）。
    let usedModel: Bool
    let error: String?
    let elapsed: TimeInterval
    var sources: [WikiSourceSnapshot] = []
    var pipelineKey: String = ""
    var attempts: Int = 0
    var stop: WikiModelStop?

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
    var provenance: WikiGenerationProvenance?
    var scopePaths: [String] = []
    var basisDigest: String = ""
}

struct WikiRelateOutcome: Sendable {
    let module: String
    let payload: WikiModuleDraftPayload?
    let error: String?
    var noKnowledgeReason: String?
    var attempts: Int = 0
    var stop: WikiModelStop?
}

private actor WikiAttemptCount {
    private(set) var value = 0
    func increment() { value += 1 }
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
        onAttempt: (@Sendable (Int, Int) async throws -> Void)? = nil,
        complete: Completion? = nil,
        onOutcome: (@Sendable (WikiBatchOutcome) async -> Void)? = nil
    ) async -> [WikiBatchOutcome] {
        await schedule(jobs, concurrency: concurrency, onResult: onOutcome) { await execute($0, onAttempt: onAttempt, complete: complete) }
    }

    /// 并发执行一批模块联系任务。
    static func runRelate(
        _ jobs: [WikiRelateJob],
        concurrency: Int,
        onAttempt: (@Sendable (Int, Int) async throws -> Void)? = nil,
        complete: Completion? = nil,
        onOutcome: (@Sendable (WikiRelateOutcome) async -> Void)? = nil
    ) async -> [WikiRelateOutcome] {
        await schedule(jobs, concurrency: concurrency, onResult: onOutcome) { await executeRelate($0, onAttempt: onAttempt, complete: complete) }
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
        onResult: (@Sendable (Result) async -> Void)? = nil,
        work: @escaping @Sendable (Job) async -> Result
    ) async -> [Result] {
        guard !jobs.isEmpty else { return [] }
        let limit = max(1, concurrency)

        return await withTaskGroup(of: Result.self) { group in
            var iterator = jobs.makeIterator()
            var results: [Result] = []
            var active = 0

            while !Task.isCancelled, active < limit, let job = iterator.next() {
                group.addTask { await work(job) }
                active += 1
            }
            while let result = await group.next() {
                results.append(result)
                await onResult?(result)
                if Task.isCancelled { group.cancelAll(); continue }
                if let next = iterator.next() {
                    group.addTask { await work(next) }
                }
            }
            return results
        }
    }

    // MARK: 执行：理解文件

    typealias Completion = @Sendable (AINarrativeRequest) async throws -> String

    /// 非完整输出可以保留有效文件，但不能把整批算成功；越界/重复路径整批拒绝。
    static func parseFiles(_ object: [String: Any], requested: [String]) throws -> (insights: [RepoFileInsight], missing: [String]) {
        guard Set(requested).count == requested.count,
              let items = object["files"] as? [[String: Any]], items.count <= requested.count else {
            throw WikiGenerationError.invalidOutput("files 数组缺失或文件数量不合法")
        }
        let allowed = Set(requested)
        var seen = Set<String>()
        var insights: [RepoFileInsight] = []
        for item in items {
            guard let path = item["path"] as? String, allowed.contains(path), seen.insert(path).inserted else {
                throw WikiGenerationError.invalidOutput("返回了未请求或重复的文件路径")
            }
            guard item["status"] == nil || item["status"] is String else {
                throw WikiGenerationError.invalidOutput("文件状态不是字符串")
            }
            let status = item["status"] as? String ?? "observed"
            guard status == "observed" || status == "skip" else {
                throw WikiGenerationError.invalidOutput("未知文件状态")
            }
            let purpose = WikiEntry.canonicalBody(item["purpose"] as? String ?? "")
            let reason = WikiEntry.canonicalBody(item["reason"] as? String ?? "")
            guard (status == "skip" && !reason.isEmpty) || (status == "observed" && !purpose.isEmpty) else {
                throw WikiGenerationError.invalidOutput("文件职责或不记录理由为空")
            }
            guard item["keyPoints"] == nil || item["keyPoints"] is [String] else {
                throw WikiGenerationError.invalidOutput("keyPoints 不是字符串数组")
            }
            let points = (item["keyPoints"] as? [String] ?? []).map(WikiEntry.canonicalBody).filter { !$0.isEmpty }
            guard purpose.count <= 2_000, reason.count <= 2_000, points.count <= 3,
                  points.allSatisfy({ $0.count <= 2_000 }) else {
                throw WikiGenerationError.invalidOutput("文件结论超出输出预算")
            }
            var insight = RepoFileInsight(path: path, purpose: purpose, keyPoints: points)
            if status == "skip" { insight.noKnowledgeReason = reason }
            insights.append(insight)
        }
        return (insights, requested.filter { !seen.contains($0) })
    }

    static func execute(
        _ job: WikiBatchJob, onAttempt: (@Sendable (Int, Int) async throws -> Void)? = nil,
        complete: Completion? = nil, budgets: [Int] = budgetLadder
    ) async -> WikiBatchOutcome {
        let started = Date()
        let counter = WikiAttemptCount()
        if job.paths.isEmpty {
            return .init(id: job.id, paths: [], insights: job.cached, usedModel: false,
                         error: nil, elapsed: 0, sources: job.sources, pipelineKey: job.pipelineKey)
        }
        do {
            let object = try await callJSON(kind: job.kind, request: job.request, budgets: budgets, onAttempt: { attempt, total in
                try await onAttempt?(attempt, total)
                await counter.increment()
            }, complete: complete)
            let parsed = try parseFiles(object, requested: job.paths)
            let receipts = Dictionary(job.sources.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
            let insights = parsed.insights.map { original in
                var insight = original
                insight.sourceDigest = receipts[insight.path]?.digest
                insight.pipelineKey = job.pipelineKey
                return insight
            }
            let attempts = await counter.value
            return .init(id: job.id, paths: job.paths, insights: job.cached + insights, usedModel: attempts > 0,
                         error: parsed.missing.isEmpty ? nil : "缺少 \(parsed.missing.count) 个文件：" + parsed.missing.joined(separator: "、"),
                         elapsed: Date().timeIntervalSince(started), sources: job.sources,
                         pipelineKey: job.pipelineKey, attempts: attempts)
        } catch {
            let attempts = await counter.value
            return .init(id: job.id, paths: job.paths, insights: job.cached, usedModel: attempts > 0,
                         error: error.localizedDescription, elapsed: Date().timeIntervalSince(started),
                         sources: job.sources, pipelineKey: job.pipelineKey, attempts: attempts,
                         stop: WikiModelStop.classify(error))
        }
    }

    // MARK: 执行：模块联系

    static func executeRelate(
        _ job: WikiRelateJob, onAttempt: (@Sendable (Int, Int) async throws -> Void)? = nil,
        complete: Completion? = nil, budgets: [Int] = budgetLadder
    ) async -> WikiRelateOutcome {
        let counter = WikiAttemptCount()
        do {
            let object = try await callJSON(kind: job.kind, request: job.request, budgets: budgets, onAttempt: { attempt, total in
                try await onAttempt?(attempt, total)
                await counter.increment()
            }, complete: complete)
            guard object["action"] == nil || object["action"] is String else {
                throw WikiGenerationError.invalidOutput("模块动作不是字符串")
            }
            if let action = object["action"] as? String {
                guard action == "create" || action == "skip" else { throw WikiGenerationError.invalidOutput("未知模块动作") }
                if action == "skip" {
                    let reason = WikiEntry.canonicalBody(object["reason"] as? String ?? "")
                    guard !reason.isEmpty, reason.count <= 2_000 else { throw WikiGenerationError.invalidOutput("缺少无需记录的理由") }
                    return .init(module: job.module, payload: nil, error: nil, noKnowledgeReason: reason, attempts: await counter.value)
                }
            }
            let responsibility = WikiEntry.canonicalBody(object["responsibility"] as? String ?? "")
            guard !responsibility.isEmpty, responsibility.count <= 6_000,
                  object["decisions"] == nil || object["decisions"] is [String],
                  object["rules"] == nil || object["rules"] is [String] else {
                throw WikiGenerationError.invalidOutput("模块职责或数组未通过校验")
            }
            let decisions = (object["decisions"] as? [String] ?? []).map(WikiEntry.canonicalBody).filter { !$0.isEmpty }
            let rules = (object["rules"] as? [String] ?? []).map(WikiEntry.canonicalBody).filter { !$0.isEmpty }
            guard decisions.count <= 12, rules.count <= 12,
                  (decisions + rules).allSatisfy({ $0.count <= 3_000 }) else {
                throw WikiGenerationError.invalidOutput("模块结论超出输出预算")
            }
            return .init(module: job.module, payload: .init(responsibility: responsibility, relations: [],
                         decisions: decisions, rules: rules), error: nil, attempts: await counter.value)
        } catch {
            return .init(module: job.module, payload: nil, error: error.localizedDescription,
                         attempts: await counter.value, stop: WikiModelStop.classify(error))
        }
    }

    // MARK: 单次请求（含预算梯度与退避）

    /// 发一次结构化请求并解析 JSON。失败时按错误类型决定是否继续重试。
    static func callJSON(
        kind: AIProviderKind,
        request: AINarrativeRequest,
        budgets: [Int] = budgetLadder,
        onAttempt: (@Sendable (Int, Int) async throws -> Void)? = nil,
        complete: Completion? = nil
    ) async throws -> [String: Any] {
        let provider = kind.makeProvider()
        var lastError: Error = AINarrativeError.emptyResponse

        for (attempt, budget) in budgets.enumerated() {
            if attempt > 0 {
                // 退避 1.5s → 3s，给网关一点恢复时间。
                let delay = UInt64(1_500_000_000) * UInt64(attempt)
                try await Task.sleep(nanoseconds: delay)
            }
            try Task.checkCancellation()
            try await onAttempt?(attempt + 1, budgets.count)
            try Task.checkCancellation()

            do {
                // 超时由 `AINarrativeHTTP.session` 的 timeoutIntervalForResource 兜底。
                // 这里不再自己包一层 withTimeout：结构化并发在抛超时之后仍会等
                // 那个挂住的请求结束，反而变成「超时了还卡着」。
                let prepared = request.withMaxTokens(budget)
                let raw: String
                if let complete { raw = try await complete(prepared) }
                else { raw = try await provider.complete(prepared) }
                try Task.checkCancellation()
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
        if error is CancellationError || error is WikiGenerationError { return false }
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
