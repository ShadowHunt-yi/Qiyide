//
//  WikiCurationRunner.swift
//  CodeEdit
//
//  整仓建档的执行器：一个脱离窗口生命周期的长任务。
//
//  为什么从「任务」改成「执行器」：
//  第一版的 start() 只跑一轮，任务又挂在窗口的 @StateObject 上——
//  于是 734 个文件要人工点 13 次，且中途关窗就前功尽弃。这不是交互问题，是结构问题。
//
//  现在分三层：
//  - 本类：单例，持有 job 与 while 循环，窗口只做订阅者；
//  - WikiModelClient：nonisolated，负责真正并发的模型调用与重试；
//  - WikiInsightStore / WikiCurationJob：跨轮、跨重启的状态。
//
//  轮次预算从「60 个文件」改为「240 个文件 + 总调用上限 + 总时长上限」，
//  三者任一触发就收尾，剩下的下一轮继续——所以「跑不完」不再是常态。
//

import AppKit
import Foundation

@MainActor
final class WikiCurationRunner: ObservableObject {

    static let shared = WikiCurationRunner()

    // MARK: 阶段

    enum Stage: String, CaseIterable, Identifiable {
        case scan
        case understand
        case relate
        case write

        var id: String { rawValue }

        var title: String {
            switch self {
            case .scan: return "分辨重要性"
            case .understand: return "理解文件"
            case .relate: return "理解联系"
            case .write: return "输出知识库"
            }
        }

        var detail: String {
            switch self {
            case .scan: return "按规模、入口、变更频率、是否测试等规则排序，选出真正值得读的文件"
            case .understand: return "分批并发阅读文件片段，写出每个文件的职责与要点；已读过的直接复用"
            case .relate: return "以模块为单位推断依赖、边界与约定，并参考已完成模块的结论"
            case .write: return "把模块结论落成待确认的知识草稿，重复建档时整块替换而非追加"
            }
        }
    }

    // MARK: 参数

    struct Options: Sendable {
        /// 整仓模式：按轮循环直到没有待处理，或触发安全阀。
        var wholeRepo = true
        /// 单轮最多处理多少个文件。这是容量的主要旋钮。
        var filesPerRound = 240
        /// 单批文件数上限（与字符预算共同生效）。
        var maxFilesPerBatch = 10
        /// 单批字符预算。
        var maxCharsPerBatch = 24_000
        /// 并发请求数。本地代理背后是单家 Provider，开太大会直接 429。
        var concurrency = 3
        /// 整个 job 的调用次数上限，防止跑飞。
        var maxCallsTotal = 800
        /// 整个 job 的时长上限（分钟）。
        var maxMinutes = 40

        static let standard = Options()

        /// 保守档：成本优先，适合先验证产出质量。
        static let conservative = Options(
            wholeRepo: true,
            filesPerRound: 60,
            maxFilesPerBatch: 6,
            maxCharsPerBatch: 16_000,
            concurrency: 2,
            maxCallsTotal: 200,
            maxMinutes: 20
        )
    }

    // MARK: 对外状态

    @Published private(set) var isRunning = false
    @Published private(set) var isPaused = false
    @Published private(set) var stage: Stage = .scan
    @Published private(set) var detail = ""
    @Published private(set) var progress: Double = 0
    @Published private(set) var finishedSummary: String?
    @Published private(set) var errorMessage: String?
    @Published private(set) var log: [String] = []

    @Published private(set) var totalCandidates = 0
    @Published private(set) var alreadyProcessed = 0
    @Published private(set) var remainingAfterRun = 0
    @Published private(set) var currentRound = 0
    @Published private(set) var cacheHits = 0
    @Published private(set) var job = WikiCurationJob()
    @Published private(set) var root: URL?
    /// 依赖图的概览文案，面板上直接显示。
    @Published private(set) var graphSummary = ""

    static let defaultMaxFiles = 16
    static let defaultMaxModules = 8
    /// 单轮文件预算的默认值，界面上要用它算「约几轮」。
    static let defaultFilesPerRound = 240

    // MARK: 内部

    private var task: Task<Void, Never>?
    private var store: WikiStore?
    private var options = Options.standard
    private var dependencyGraph: WikiDependencyGraph?
    // 轮内实时状态：让进度能随每一批落盘，而不是等整组跑完。
    private var activeInsights = WikiInsightStore()
    private var activeResolved: [String: RepoFileInsight] = [:]
    private var understoodCount = 0
    private var totalBatches = 0
    private var doneBatches = 0
    private var consumedBatches: Set<String> = []
    private var startedAt = Date()

    // MARK: 生命周期入口

    /// 开始或继续一个 job。
    ///
    /// 单例持有任务，窗口只是订阅者：关掉知识库窗口不会中断建档。
    func start(root: URL, store: WikiStore, options: Options = .standard) {
        guard !isRunning else { return }
        guard AINarrativeStore.shared.isReady else {
            errorMessage = AINarrativeStore.shared.blockedReason ?? "模型未配置"
            return
        }

        self.root = root
        self.store = store
        self.options = options
        startedAt = Date()

        isRunning = true
        isPaused = false
        errorMessage = nil
        finishedSummary = nil
        log = []
        progress = 0
        stage = .scan
        cacheHits = 0

        // 续跑：job 里保留着轮次、调用数、模块摘要与失败队列。
        var loaded = WikiCurationJob.load(root: root)
        if loaded.status == .running {
            append("上次建档是异常退出（停在第 \(loaded.round) 轮），从这里继续")
        } else if loaded.round > 0 {
            append("继续已有建档：已完成 \(loaded.round) 轮、\(loaded.callsUsed) 次调用")
        }
        loaded.status = .running
        loaded.startedAt = loaded.startedAt == 0 ? Date().timeIntervalSince1970 : loaded.startedAt
        loaded.updatedAt = Date().timeIntervalSince1970
        loaded.save(root: root)
        job = loaded

        task = Task { [weak self] in
            await self?.loop()
        }
    }

    /// 暂停：当前轮跑完后停下，状态存盘，随时可续。
    func pause() {
        guard isRunning else { return }
        isPaused = true
        detail = "正在暂停（当前这一轮结束后停止）…"
    }

    /// 彻底停止：取消在飞的请求。已完成的部分不会丢（每批都落盘）。
    func stop() {
        isPaused = true
        task?.cancel()
        task = nil
        persist(status: .paused)
        isRunning = false
        detail = "已停止"
    }

    /// 打开面板时做一次轻量统计。
    func preview(root: URL) {
        guard !isRunning else { return }
        let model = AINarrativeStore.shared.providerLabel
        let insights = WikiInsightStore.load(root: root)
        let result = WikiRepoIngest.inventory(root: root, insights: insights, model: model)
        totalCandidates = result.total
        alreadyProcessed = result.fresh
        self.root = root
        job = WikiCurationJob.load(root: root)
        currentRound = job.round
    }

    // MARK: 主循环

    private func loop() async {
        var consecutiveEmpty = 0
        let deadline = startedAt.addingTimeInterval(TimeInterval(options.maxMinutes * 60))

        while !Task.isCancelled && !isPaused {
            if job.callsUsed >= options.maxCallsTotal {
                append("已达调用上限 \(options.maxCallsTotal) 次，停在这里，下次继续")
                break
            }
            if Date() > deadline {
                append("已达时长上限 \(options.maxMinutes) 分钟，停在这里，下次继续")
                break
            }

            currentRound = job.round + 1
            job.round = currentRound - 1
            if let root { job.save(root: root) }
            let result = await runRound()

            if result.aborted {
                // 没有待处理文件：这是正常终态。
                break
            }

            job.round += 1
            job.updatedAt = Date().timeIntervalSince1970
            job.save(root: root ?? URL(fileURLWithPath: NSTemporaryDirectory()))

            if result.understood == 0 && result.written == 0 {
                consecutiveEmpty += 1
            } else {
                consecutiveEmpty = 0
            }
            if consecutiveEmpty >= 2 {
                // 连续两轮零产出，多半是配置或限流问题，停下面向人暴露。
                append("连续两轮没有任何产出，已暂停，请检查模型配置或限流")
                job.status = .failed
                job.lastError = "连续两轮零产出"
                break
            }

            if !options.wholeRepo { break }
            if result.remaining == 0 { break }
        }

        finish()
    }

    private func finish() {
        isRunning = false
        let status: WikiCurationStatus
        if job.status == .failed {
            status = .failed
        } else if isPaused {
            status = .paused
        } else if remainingAfterRun <= 0 {
            status = .finished
        } else {
            status = .paused
        }
        persist(status: status)
        task = nil
        store = nil

        if status == .finished {
            if let store, let graph = dependencyGraph {
                reconcileRelations(store: store, graph: graph)
            }
            detail = "完成"
            progress = 1
            finishedSummary = "已覆盖全部待处理文件，共 \(job.round) 轮、\(job.callsUsed) 次模型调用"
            // 长任务在后台跑完，用 Dock 提示一次；不申请通知权限，避免打断。
            NSApp.requestUserAttention(.informationalRequest)
        } else if status == .failed {
            detail = "已中止"
        } else if isPaused {
            detail = "已暂停，可继续"
        }
    }

    private func persist(status: WikiCurationStatus) {
        guard let root else { return }
        var copy = job
        copy.status = status
        copy.updatedAt = Date().timeIntervalSince1970
        copy.save(root: root)
        job = copy
    }

    // MARK: 单轮

    private struct RoundResult {
        var understood = 0
        var written = 0
        var remaining = 0
        var aborted = false
    }

    private func runRound() async -> RoundResult {
        guard let root, let store else { return RoundResult(aborted: true) }
        let model = AINarrativeStore.shared.providerLabel

        // 1. 分辨重要性
        stage = .scan
        detail = "扫描文件树并按重要度排序…"
        // 失败队列按轮重置：它是「这一轮需要重试什么」，不是永久账本。
        job.failures.removeAll()

        // 扫描要遍历整个文件树、跑一次 git log、再做切分，放主线程会让「点开始」先僵一两秒。
        let maxModules = options.wholeRepo ? 400 : WikiCurationRunner.defaultMaxModules
        let (modules, considered) = await Task.detached(priority: .userInitiated) {
            WikiRepoIngest.scan(root: root, maxFiles: 100_000, maxModules: maxModules)
        }.value
        totalCandidates = considered
        job.filesTotal = considered
        guard !modules.isEmpty else {
            errorMessage = "没有找到可分析的源码文件"
            return RoundResult(aborted: true)
        }

        // 先建依赖图：后面的排序与模块关系都以它为准，不再靠模型猜。
        let graph = await Task.detached(priority: .userInitiated) {
            WikiDependencyGraph.build(root: root, modules: modules)
        }.value
        dependencyGraph = graph
        graphSummary = graph.summary
        append("依赖图：\(graph.summary)")

        // 2. 用「文件结论缓存」判定待处理：文件没改且模型没换才算已建档。
        var insights = WikiInsightStore.load(root: root)
        var pendingModules: [RepoModule] = []
        var pendingCount = 0
        var freshCount = 0
        for module in modules {
            var pending: [RepoFileCandidate] = []
            for file in module.files {
                let url = root.appending(path: file.path)
                if insights.insight(for: file.path, url: url, model: model) != nil {
                    freshCount += 1
                } else {
                    pending.append(file)
                }
            }
            guard !pending.isEmpty else { continue }
            pendingModules.append(RepoModule(name: module.name, files: pending))
            pendingCount += pending.count
        }
        alreadyProcessed = freshCount
        job.filesDone = freshCount
        remainingAfterRun = pendingCount

        // 按依赖图拓扑序排：先建不依赖别人的基础模块，
        // 上层模块建档时才能引用到真实存在的条目，而不是悬空的名字。
        let rank = Dictionary(
            uniqueKeysWithValues: graph.topologicalOrder().enumerated().map { ($1, $0) }
        )
        pendingModules.sort { (rank[$0.name] ?? Int.max) < (rank[$1.name] ?? Int.max) }

        guard !pendingModules.isEmpty else {
            finishedSummary = "全部 \(freshCount) 个文件都已建档且没有改动，无需重建"
            progress = 1
            return RoundResult(aborted: true)
        }

        // 3. 选本轮处理的文件
        // 单元不拆分：整块进入本轮或整轮跳过，避免写出残缺的模块结论。
        let selected = WikiRepoIngest.selectUnits(
            pendingModules,
            budget: options.filesPerRound
        )
        let totalFiles = selected.reduce(0) { $0 + $1.files.count }
        append(
            "第 \(currentRound) 轮：全仓 \(considered) 个，已建档 \(freshCount) 个，待处理 \(pendingCount) 个，本轮 \(totalFiles) 个 / \(selected.count) 个模块"
        )

        // 4. 理解文件：缓存命中直接跳过，其余按字符装箱并发跑
        stage = .understand
        var resolved: [String: RepoFileInsight] = [:]
        var missing: [RepoFileCandidate] = []
        for module in selected {
            for file in module.files {
                let url = root.appending(path: file.path)
                if let hit = insights.insight(for: file.path, url: url, model: model) {
                    resolved[file.path] = hit
                } else {
                    missing.append(file)
                }
            }
        }
        cacheHits += resolved.count
        if !resolved.isEmpty {
            append("复用 \(resolved.count) 条已有文件结论，跳过 \(resolved.count) 次调用")
        }

        if !missing.isEmpty {
            let batches = WikiRepoIngest.batchPlan(
                files: missing,
                maxFilesPerBatch: options.maxFilesPerBatch,
                maxCharsPerBatch: options.maxCharsPerBatch
            )
            let system = Self.understandSystemPrompt
            let base = AINarrativeStore.shared.makeRequest(system: system, user: "")
            if let base, let kind = Self.providerKind() {
                // 把当前轮的状态挂到实例上，回调里才能逐批累加。
                activeInsights = insights
                activeResolved = resolved
                understoodCount = 0
                totalBatches = batches.count
                doneBatches = 0
                consumedBatches = []
                detail = "阅读 \(missing.count) 个文件（\(batches.count) 批，并发 \(options.concurrency)）…"
                // 读文件 + 拼提示词是纯 IO，放后台线程做，不阻塞界面。
                let jobs = await Task.detached(priority: .userInitiated) {
                    WikiRepoIngest.prepareJobs(batches: batches, root: root, base: base, kind: kind)
                }.value

                let outcomes = await WikiModelClient.run(
                    jobs,
                    concurrency: options.concurrency
                ) { outcome in
                    // 每批完成立刻回主线程落盘并刷新进度。
                    Task { @MainActor [weak self] in
                        self?.consumeUnderstanding(outcome, root: root, model: model)
                    }
                }
                // 兜底：回调的 Task 可能还排在队列里，这里再走一遍（consume 内部去重）。
                for outcome in outcomes {
                    consumeUnderstanding(outcome, root: root, model: model)
                }
                insights = activeInsights
                resolved = activeResolved
                markProcessed(Set(resolved.keys), root: root)
                job.save(root: root)
                progress = 0.55
            } else {
                append("模型未配置，无法阅读文件")
            }
        }
        let understood = understoodCount

        // 5. 理解联系（并发请求，主线程串行落盘）
        stage = .relate
        detail = "梳理 \(selected.count) 个模块…"
        var relateJobs: [WikiRelateJob] = []
        for module in selected {
            guard let relateJob = makeRelateJob(
                module: module,
                insights: resolved,
                allModules: selected,
                store: store,
                knownModuleContext: job.knownModuleContext(excluding: module.name),
                graph: graph
            ) else { continue }
            relateJobs.append(relateJob)
        }

        var written = 0
        if !relateJobs.isEmpty {
            let outcomes = await WikiModelClient.runRelate(
                relateJobs,
                concurrency: options.concurrency
            )
            // 本轮已存在的标题。写入用 refresh:false 不重建内存，
            // 所以不能靠 store.entry 判断「是不是已有条目」，得自己记。
            var knownTitles = Set(store.entries.map(\.title))
            for outcome in outcomes {
                job.callsUsed += 1
                guard let payload = outcome.payload else {
                    if let error = outcome.error {
                        job.failures.append("\(outcome.module)：\(error)")
                        append("模块 \(outcome.module) 跳过：\(error)")
                    }
                    continue
                }
                guard let module = selected.first(where: { $0.name == outcome.module }) else { continue }
                stage = .write
                detail = "写入草稿 \(module.name)"
                let draft = makeDraft(
                    module: module,
                    payload: payload,
                    insights: resolved,
                    existing: knownTitles.contains(module.name),
                    graph: graph
                )
                do {
                    _ = try store.applyDraft(
                        draft,
                        generatedBy: AINarrativeStore.shared.providerLabel,
                        sources: module.files.map(\.path),
                        // 关键：这一轮十几条写完后只刷新一次，
                        // 否则每条都触发力导向布局，主线程直接卡死。
                        refresh: false
                    )
                    knownTitles.insert(module.name)
                    job.note(module.name, responsibility: payload.responsibility)
                    written += 1
                    job.save(root: root)
                    append("已写入草稿：\(module.name)")
                } catch {
                    append("写入失败 \(module.name)：\(error.localizedDescription)")
                }
                stage = .relate
            }
            if written > 0 {
                // 一次性把内存与图谱更新到位。
                store.reload()
            }
        }

        job.failures = Array(job.failures.suffix(50))
        job.save(root: root)
        remainingAfterRun = max(pendingCount - understood, 0)
        progress = 1
        return RoundResult(understood: understood, written: written, remaining: remainingAfterRun)
    }

    /// 单批完成的处理：累加调用数、写入理解缓存、刷新进度。
    ///
    /// 幂等——`run` 的返回值和回调可能都会送同一个 outcome，靠 id 去重。
    private func consumeUnderstanding(_ outcome: WikiBatchOutcome, root: URL, model: String) {
        guard consumedBatches.insert(outcome.id).inserted else { return }
        doneBatches += 1
        if outcome.usedModel { job.callsUsed += 1 }
        if let error = outcome.error {
            job.failures.append(error)
            append("跳过一批（\(outcome.paths.count) 个文件）：\(error)")
        }
        for insight in outcome.insights {
            activeResolved[insight.path] = insight
            activeInsights.record(
                path: insight.path,
                purpose: insight.purpose,
                keyPoints: insight.keyPoints,
                url: root.appending(path: insight.path),
                model: model
            )
            understoodCount += 1
        }
        // 每批落盘：中途卡住或被强退时，已经花掉的调用与结论都还在。
        if !outcome.insights.isEmpty {
            activeInsights.save(root: root)
        }
        job.save(root: root)

        let ratio = totalBatches > 0 ? Double(doneBatches) / Double(totalBatches) : 0
        progress = 0.08 + 0.5 * ratio
        detail = "已理解 \(understoodCount) 个文件（\(doneBatches)/\(totalBatches) 批，累计 \(job.callsUsed) 次调用）"
    }

    // MARK: 提示词与请求组装

    private static let understandSystemPrompt = """
    你在为一个代码仓库建立知识库。阅读给出的文件片段，为每个文件写清它「在做什么」。
    只输出 JSON，不要解释：
    {"files":[{"path":"相对路径","purpose":"一句话职责","keyPoints":["最多3条要点"]}]}
    要点写实现中的关键取舍或容易踩的坑，不要复述代码结构。看不到的部分不要编造。
    """

    private static func providerKind() -> AIProviderKind? {
        let config = AINarrativeStore.shared.configuration
        return config.mode == .ccSwitchProxy ? .anthropic : config.provider
    }

    /// 把「本轮模块 + 已知模块摘要 + 已有条目」拼成一次联系推断的请求。
    private func makeRelateJob(
        module: RepoModule,
        insights: [String: RepoFileInsight],
        allModules: [RepoModule],
        store: WikiStore,
        knownModuleContext: String,
        graph: WikiDependencyGraph
    ) -> WikiRelateJob? {
        var lines: [String] = []
        lines.append("模块：\(module.name)")
        lines.append("文件：")
        for file in module.files {
            let purpose = insights[file.path]?.purpose ?? "（未解析）"
            lines.append("- \(file.path)：\(purpose)")
            if let points = insights[file.path]?.keyPoints, !points.isEmpty {
                lines.append("    要点：" + points.joined(separator: "；"))
            }
        }

        // 静态分析得到的依赖事实。模型看到的是「A 被 B 引用了 12 次」，
        // 而不是一串模块名——后者只能靠猜。
        lines.append("")
        lines.append("静态分析得到的依赖事实（已确定，不要重复列举，只用于解释边界）：")
        lines.append(graph.context(for: module.name))

        // 跨轮上下文：前几轮已经建过的模块，带上它们的职责，才谈得上「联系」。
        if !knownModuleContext.isEmpty {
            lines.append("")
            lines.append("此前已建档的模块（用于判断依赖关系）：")
            lines.append(knownModuleContext)
        }

        let others = allModules.filter { $0.name != module.name }.map(\.name)
        if !others.isEmpty {
            lines.append("")
            lines.append("本轮同时处理的其它模块：\(others.joined(separator: "、"))")
        }

        let existingTitles = store.entries.filter { $0.type == .module }.map(\.title)
        if !existingTitles.isEmpty {
            lines.append("")
            lines.append("知识库已有模块条目（可作为关系目标）：")
            lines.append(existingTitles.prefix(40).joined(separator: "、"))
        }

        let system = """
        你为一个代码仓库的某个模块撰写知识条目。依赖关系已经由静态分析给出，不要再列举或改动。
        你只负责三件事：这个模块负责什么、有哪些设计取舍、有哪些必须遵守的约定。
        只输出 JSON：
        {"responsibility":"2-3句职责与边界","decisions":["设计取舍"],"rules":["约定或坑"]}
        不要编造未在输入中出现的事实；不确定的字段留空数组。
        """

        guard let base = AINarrativeStore.shared.makeRequest(
            system: system,
            user: lines.joined(separator: "\n")
        ), let kind = Self.providerKind() else {
            return nil
        }

        return WikiRelateJob(module: module.name, kind: kind, request: base)
    }

    private func makeDraft(
        module: RepoModule,
        payload: WikiModuleDraftPayload,
        insights: [String: RepoFileInsight],
        existing: Bool,
        graph: WikiDependencyGraph
    ) -> WikiDraft {
        var body: [String] = []
        body.append("**职责**：\(payload.responsibility)")
        body.append("")
        body.append("**关键文件**")
        for file in module.files {
            let purpose = insights[file.path]?.purpose ?? ""
            body.append("- `\(file.fileName)` — \(purpose)")
        }
        if !payload.decisions.isEmpty {
            body.append("")
            body.append("**设计取舍**")
            body.append(contentsOf: payload.decisions.map { "- \($0)" })
        }
        if !payload.rules.isEmpty {
            body.append("")
            body.append("**约定与坑**")
            body.append(contentsOf: payload.rules.map { "- \($0)" })
        }
        // 依赖一节直接来自静态分析：不是模型的观点，因此单独成节、不进「约定」。
        let deps = graph.dependencies(of: module.name).prefix(8)
        if !deps.isEmpty {
            body.append("")
            body.append("**依赖**（静态分析）")
            body.append(contentsOf: deps.map { "- `\($0.to)` — \($0.count) 处引用" })
        }

        // 标题固定用模块名：重跑才能命中同一条目。
        return WikiDraft(
            action: existing ? .update : .create,
            target: existing ? module.name : "",
            title: module.name,
            type: .module,
            tags: ["仓库建档"],
            relations: relations(from: graph, module: module.name),
            body: body.joined(separator: "\n"),
            reason: "来自整仓建档：\(module.files.count) 个文件",
            sources: module.files.map(\.path),
            // 重复建档必须整块替换，否则同一模块会累积多段互相矛盾的结论。
            mergeMode: .replace
        )
    }

    /// 模块关系由依赖图生成：确定、可复现，不会随提示词波动。
    private func relations(from graph: WikiDependencyGraph, module: String) -> [WikiRelation] {
        var result: [WikiRelation] = []
        for edge in graph.dependencies(of: module).prefix(12) {
            result.append(WikiRelation(kind: "依赖", target: edge.to))
        }
        for edge in graph.dependents(of: module).prefix(12) {
            result.append(WikiRelation(kind: "被依赖", target: edge.from))
        }
        return result
    }

    /// 收尾补边。
    ///
    /// 建档按拓扑序推进，但第一轮写的模块可能引用了还没建档的模块名，
    /// 这些关系在 WikiStore 里找不到目标条目，就成了悬空引用。
    /// 全部跑完后按图再补一遍，此时目标条目大概率都已存在。
    private func reconcileRelations(store: WikiStore, graph: WikiDependencyGraph) {
        var patched = 0
        var pending: [WikiEntry] = []
        for entry in store.entries where entry.type == .module {
            guard graph.modules.contains(entry.title) else { continue }
            var updated = entry
            var existing = Set(updated.relations.map { "\($0.kind)|\($0.target)" })
            var changed = false

            for edge in graph.dependencies(of: entry.title).prefix(12) {
                let key = "依赖|\(edge.to)"
                if !existing.contains(key) {
                    updated.relations.append(WikiRelation(kind: "依赖", target: edge.to))
                    existing.insert(key)
                    changed = true
                }
            }
            for edge in graph.dependents(of: entry.title).prefix(12) {
                let key = "被依赖|\(edge.from)"
                if !existing.contains(key) {
                    updated.relations.append(WikiRelation(kind: "被依赖", target: edge.from))
                    existing.insert(key)
                    changed = true
                }
            }
            if changed {
                pending.append(updated)
                patched += 1
            }
        }
        // 一次性落盘：上百个条目逐条 save 等于上百次全量重扫 + 布局。
        if !pending.isEmpty {
            try? store.save(pending)
            append("按依赖图补齐 \(patched) 个模块的关系")
        }
    }

    // MARK: 进度记录

    private func markProcessed(_ paths: Set<String>, root: URL) {
        var state = WikiIngestState.load(root: root)
        for path in paths {
            state.markProcessed(path: path, url: root.appending(path: path))
        }
        state.save(root: root)
    }

    private func append(_ line: String) {
        log.append(line)
        if log.count > 80 { log.removeFirst(log.count - 80) }
        detail = line
    }
}
