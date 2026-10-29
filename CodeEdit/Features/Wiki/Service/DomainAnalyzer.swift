//
//  DomainAnalyzer.swift
//  CodeEdit
//
//  领域识别：把仓库的包结构、命名、调用、注释、文档、git 作者六类线索
//  算成一个可解释的分数，产出导图的初始结构。
//
//  为什么是「打分 + 证据」而不是规则硬判：
//  本仓库的实际情况证明单一规则都会误判——
//  - 只看目录：`agent/customerservice` 会被当成 `agent` 的子模块，
//    但它与 agent 核心零互引，业务上是并列的独立域；
//  - 只看类数：`service/db` 有 237 个类，可它只是持久化实现，不是业务域；
//  - 只看中文词：`建议` 出现 540 次，但有一半是通用提示语，不构成领域。
//  所以每类线索各出一份证据，加权汇总后再由人确认——这也是导图要支持人工改的原因。
//
//  聚合粒度（关键）：
//  域内的类几乎都在子包里（`agent/customerservice/core/*`），本层目录往往一个 .java 都没有。
//  直接按目录统计会把整个域漏掉，所以先扫叶子包，再统一聚合到第二层作为域候选。
//  实测这一步让 `agent/customerservice` 从「不存在」变成 54 个类的候选域。
//

import Foundation

// MARK: - 结果

struct DomainAnalysisResult: Sendable {
    var graph: MindGraph
    var warnings: [String] = []
    var packageCount: Int = 0
    var classCount: Int = 0
    var elapsed: TimeInterval = 0
}

// MARK: - 分析器

enum DomainAnalyzer {

    /// 判定阈值。改这些数会直接改变域的多少，放在一处便于调参。
    enum Threshold {
        /// 少于这个类数的候选不参与域判定。
        static let domainMinClasses = 18
        /// 域的分界。
        static let domainScore = 0.70
        /// 子域的分界。
        static let subdomainScore = 0.45
        /// 单个文件最多读多少字节找中文词。
        static let readLimit = 6_000
        /// git 作者统计最多看多少次提交。
        static let gitLogLimit = 200
        /// 每个候选最多扫多少个文件找中文词。
        static let termScanFileLimit = 60
    }

    /// 这些路径段说明该包属于技术实现层，不是业务域。
    /// 命中后分数打对折——它仍会出现在导图里（作为模块），只是不会被当域。
    private static let technicalSegments: Set<String> = [
        "db", "mapper", "domain", "entity", "repository", "dao",
        "utils", "util", "config", "constant", "dto", "enums",
        "mq", "cache", "exception", "job", "proxy"
    ]

    /// 中文停用词：只保留名词性词汇，避免「我们」「注意」这类词占据高频位。
    private static let stopwords: Set<String> = [
        "我们", "这个", "可以", "如果", "注意", "需要", "这里", "因此", "所以",
        "使用", "通过", "以及", "或者", "并且", "但是", "因为", "由于", "已经",
        "没有", "不是", "就是", "什么", "怎么", "为了", "用于", "进行", "实现",
        "支持", "按照", "根据", "对应", "相关", "目前", "当前", "其中", "包括",
        "返回", "调用", "参数", "方法", "字段", "数据", "处理", "逻辑", "默认"
    ]

    // MARK: 中间结构

    /// 一个叶子包（真正含 .java 的目录）。
    private struct Leaf {
        var parts: [String]
        var classes: [String]
        var files: [String]
    }

    /// 聚合后的域候选。所有统计都基于聚合后的类名与文件列表。
    private struct Candidate {
        var key: String                  // agent/suggest
        var parts: [String]
        var classes: [String] = []
        var files: [String] = []
        var dominantPrefix: String = ""
        var prefixShare: Double = 0
        var externalRefs: Int = 0
        var entryCount: Int = 0
        var termCounts: [String: Int] = [:]
        var authors: [AuthorStat] = []

        var classCount: Int { classes.count }
        var topTerm: String? {
            termCounts.max { $0.value < $1.value }?.key
        }
        var isTechnical: Bool {
            parts.contains { technicalSegments.contains($0.lowercased()) }
        }
    }

    // MARK: 入口

    static func analyze(
        root: URL,
        progress: @escaping @MainActor (String) -> Void
    ) async -> DomainAnalysisResult {
        let started = Date()

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var warnings: [String] = []

                Task { @MainActor in progress("定位源码目录…") }
                let javaRoots = findJavaRoots(root)
                guard !javaRoots.isEmpty else {
                    continuation.resume(returning: DomainAnalysisResult(
                        graph: .empty,
                        warnings: ["没有找到 src/main/java，可能不是 Java 工程"],
                        elapsed: Date().timeIntervalSince(started)
                    ))
                    return
                }

                Task { @MainActor in progress("扫描包结构…") }
                let leaves = scanLeaves(javaRoots: javaRoots)
                var candidates = aggregate(leaves: leaves)

                Task { @MainActor in progress("统计跨包引用…") }
                let refs = scanImports(javaRoots: javaRoots)
                for key in candidates.keys {
                    candidates[key]?.externalRefs = refs[key] ?? 0
                }

                Task { @MainActor in progress("提取中文业务词…") }
                attachChineseTerms(&candidates, root: root)

                Task { @MainActor in progress("统计作者归属…") }
                attachAuthors(&candidates, root: root)

                Task { @MainActor in progress("汇总判定…") }
                let graph = buildGraph(
                    candidates: candidates,
                    leaves: leaves,
                    root: root,
                    warnings: &warnings
                )

                let total = candidates.values.reduce(0) { $0 + $1.classCount }
                continuation.resume(returning: DomainAnalysisResult(
                    graph: graph,
                    warnings: warnings,
                    packageCount: candidates.count,
                    classCount: total,
                    elapsed: Date().timeIntervalSince(started)
                ))
            }
        }
    }

    // MARK: 扫描

    private static func findJavaRoots(_ root: URL) -> [URL] {
        var result: [URL] = []
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return result }

        for case let url as URL in enumerator {
            let last = url.lastPathComponent
            if ["node_modules", "target", "build", ".git", "dist", "vendor"].contains(last) {
                enumerator.skipDescendants()
                continue
            }
            if url.path.hasSuffix("/src/main/java") {
                result.append(url)
                enumerator.skipDescendants()
            }
        }
        return result
    }

    /// 扫出所有含 .java 的目录。深度上限 4（层/域/子域/再一层）。
    private static func scanLeaves(javaRoots: [URL]) -> [Leaf] {
        var leaves: [Leaf] = []
        let manager = FileManager.default

        for javaRoot in javaRoots {
            guard let enumerator = manager.enumerator(
                at: javaRoot,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            for case let url as URL in enumerator {
                guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else {
                    continue
                }
                let relative = url.path.replacingOccurrences(of: javaRoot.path + "/", with: "")
                guard !relative.isEmpty else { continue }
                let parts = relative.split(separator: "/").map(String.init)
                if parts.count > 4 {
                    enumerator.skipDescendants()
                    continue
                }
                let javaFiles = (try? manager.contentsOfDirectory(atPath: url.path))?
                    .filter { $0.hasSuffix(".java") } ?? []
                guard !javaFiles.isEmpty else { continue }

                leaves.append(Leaf(
                    parts: parts,
                    classes: javaFiles.map { String($0.dropLast(5)) },
                    files: javaFiles.map { "\(relative)/\($0)" }
                ))
            }
        }
        return leaves
    }

    /// 把叶子包聚合到第二层（`agent/suggest/generate` → `agent/suggest`）。
    ///
    /// 不聚合的话，域内绝大多数类都被算进子包，域本身会因为「本层没有类」而被丢弃。
    private static func aggregate(leaves: [Leaf]) -> [String: Candidate] {
        var result: [String: Candidate] = [:]
        for leaf in leaves {
            let key = leaf.parts.prefix(2).joined(separator: "/")
            guard !key.isEmpty else { continue }
            var candidate = result[key] ?? Candidate(
                key: key,
                parts: Array(leaf.parts.prefix(2))
            )
            candidate.classes.append(contentsOf: leaf.classes)
            candidate.files.append(contentsOf: leaf.files)
            result[key] = candidate
        }

        // 聚合后才能算前缀与入口：单个子包的前缀不代表整个域。
        for key in result.keys {
            guard var candidate = result[key] else { continue }
            let prefix = dominantPrefix(of: candidate.classes)
            candidate.dominantPrefix = prefix.prefix
            candidate.prefixShare = prefix.share
            candidate.entryCount = candidate.classes.filter {
                $0.hasSuffix("Service") || $0.hasSuffix("Api")
                    || $0.hasSuffix("Controller") || $0.hasSuffix("ApiImpl")
            }.count
            result[key] = candidate
        }
        return result
    }

    /// 类名驼峰首词。`CustomerServiceAccessContextService` → `Customer`。
    ///
    /// 不用最长公共前缀：`Impl`、`Service` 这类通用后缀会把公共前缀拉长，反而失去区分度。
    private static func dominantPrefix(of classes: [String]) -> (prefix: String, share: Double) {
        var counts: [String: Int] = [:]
        for name in classes {
            counts[camelHead(name), default: 0] += 1
        }
        guard let top = counts.max(by: { $0.value < $1.value }) else { return ("", 0) }
        return (top.key, Double(top.value) / Double(max(1, classes.count)))
    }

    /// 取类名的驼峰首词。`AiPortraitService` → `Ai`，`AIPortrait` → `AI`，`CustomerService*` → `Customer`。
    ///
    /// 与 Python 版的 `^([A-Z][a-z0-9]+|[A-Z0-9]{2,})` 等价：先认连续大写（缩写），
    /// 再退回「首大写 + 后续小写」。直接取首个大写字母会把 `AiPortrait` 截成 `A`，
    /// 导致 `service/portrait` 的前缀占比被算成 0.27（真实值应更高）。
    private static func camelHead(_ name: String) -> String {
        let chars = Array(name)
        guard let first = chars.first, first.isUppercase else { return "Other" }

        var upper = ""
        for char in chars {
            if char.isUppercase || char.isNumber {
                upper.append(char)
            } else {
                break
            }
        }
        if upper.count >= 2 { return upper }

        var token = ""
        for char in chars {
            if token.isEmpty {
                token.append(char)
            } else if char.isLowercase || char.isNumber {
                token.append(char)
            } else {
                break
            }
        }
        return token.isEmpty ? "Other" : token
    }

    /// 统计每个二级包被其它二级包 import 的次数。
    private static func scanImports(javaRoots: [URL]) -> [String: Int] {
        var counts: [String: Int] = [:]
        let pattern = try? NSRegularExpression(
            pattern: #"^import\s+(?:static\s+)?([\w.]+);"#,
            options: [.anchorsMatchLines]
        )

        for javaRoot in javaRoots {
            guard let enumerator = FileManager.default.enumerator(
                at: javaRoot,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }

            for case let url as URL in enumerator {
                guard url.pathExtension == "java",
                      let text = readPrefix(of: url) else { continue }
                let owner = aggregateKey(of: url, javaRoot: javaRoot)
                let range = NSRange(text.startIndex..., in: text)
                pattern?.enumerateMatches(in: text, range: range) { match, _, _ in
                    guard let match, let symbolRange = Range(match.range(at: 1), in: text) else { return }
                    let symbol = String(text[symbolRange])
                    guard let internalPath = internalParts(from: symbol) else { return }
                    let target = internalPath.prefix(2).joined(separator: "/")
                    guard !target.isEmpty, target != owner else { return }
                    counts[target, default: 0] += 1
                }
            }
        }
        return counts
    }

    private static func readPrefix(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: Threshold.readLimit)) ?? Data()
        return String(data: data, encoding: .utf8)
    }

    private static func aggregateKey(of file: URL, javaRoot: URL) -> String {
        file.deletingLastPathComponent().path
            .replacingOccurrences(of: javaRoot.path + "/", with: "")
            .split(separator: "/").prefix(2).joined(separator: "/")
    }

    /// 从完整包名里截出本仓库的相对路径段。
    /// `com.jd...platform.app.agent.suggest.FooService` → `["agent","suggest","FooService"]`
    private static func internalParts(from fullName: String) -> [String]? {
        guard let range = fullName.range(of: "platform.app.") else { return nil }
        return String(fullName[range.upperBound...]).split(separator: ".").map(String.init)
    }

    /// 提取中文业务词。只取 2–4 个汉字并剔除虚词，剩下的高频词基本就是业务名词
    /// （实测本仓库稳定抽出：画像 1460、建议 540、客服 257、搭子 217）。
    private static func attachChineseTerms(_ candidates: inout [String: Candidate], root: URL) {
        let pattern = try? NSRegularExpression(pattern: "[\u{4e00}-\u{9fa5}]{2,4}")
        for key in candidates.keys {
            guard var candidate = candidates[key] else { continue }
            var counts: [String: Int] = [:]
            for file in candidate.files.prefix(Threshold.termScanFileLimit) {
                guard let text = readPrefix(of: root.appending(path: file)) else { continue }
                let range = NSRange(text.startIndex..., in: text)
                pattern?.enumerateMatches(in: text, range: range) { match, _, _ in
                    guard let match, let wordRange = Range(match.range, in: text) else { return }
                    let word = String(text[wordRange])
                    guard !stopwords.contains(word) else { return }
                    counts[word, default: 0] += 1
                }
            }
            candidate.termCounts = counts
            candidates[key] = candidate
        }
    }

    /// 统计每个候选的提交作者。只对类数达标的候选跑，避免几百次 git 调用。
    private static func attachAuthors(_ candidates: inout [String: Candidate], root: URL) {
        for key in candidates.keys {
            guard var candidate = candidates[key],
                  candidate.classCount >= Threshold.domainMinClasses else { continue }
            let output = WikiChangeSource.run(
                ["log", "--no-merges", "--format=%an", "-\(Threshold.gitLogLimit)", "--", candidate.key],
                at: root
            ) ?? ""
            var counts: [String: Int] = [:]
            for line in output.split(separator: "\n") {
                let name = line.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { continue }
                counts[name, default: 0] += 1
            }
            candidate.authors = counts
                .map { AuthorStat(name: $0.key, commits: $0.value) }
                .sorted { $0.commits > $1.commits }
            candidates[key] = candidate
        }
    }

    // MARK: 打分

    private static func score(_ candidate: Candidate, maxClasses: Int) -> (Double, [Evidence]) {
        var evidence: [Evidence] = []

        // ① 体量：类数相对最大候选的占比。
        let sizeScore = min(1.0, Double(candidate.classCount) / Double(max(1, maxClasses)))
        evidence.append(Evidence(.naming, "\(candidate.classCount) 个类", weight: sizeScore))

        // ② 命名一致性。
        if candidate.prefixShare > 0.3 {
            evidence.append(Evidence(
                .naming,
                "\(candidate.dominantPrefix)* 占 \(Int(candidate.prefixShare * 100))%",
                weight: candidate.prefixShare
            ))
        }

        // ③ 调用闭合：零外部引用说明不依附别的域。
        let closureScore = candidate.externalRefs == 0
            ? 1.0
            : max(0, 1 - Double(candidate.externalRefs) / 80.0)
        if candidate.externalRefs == 0 {
            evidence.append(Evidence(.callClosure, "无跨包引用，业务独立", weight: 1.0))
        }

        // ④ 业务入口：Service/Api/Controller 类的密度。
        let entryScore = min(1.0, Double(candidate.entryCount) / 8.0)
        if candidate.entryCount > 0 {
            evidence.append(Evidence(.callClosure, "\(candidate.entryCount) 个服务/接口入口", weight: entryScore))
        }

        // ⑤ 中文业务词：出现越集中越像领域名。
        let topCount = candidate.termCounts.values.max() ?? 0
        let termScore = min(1.0, Double(topCount) / 60.0)
        if let term = candidate.topTerm {
            evidence.append(Evidence(.chineseTerm, "高频词「\(term)」×\(topCount)", weight: termScore))
        }

        var total = 0.28 * sizeScore
            + 0.22 * candidate.prefixShare
            + 0.14 * closureScore
            + 0.16 * entryScore
            + 0.20 * termScore

        // 技术层降权：db/mapper/dto 这类包再大也不是业务域。
        if candidate.isTechnical {
            total *= 0.5
            evidence.append(Evidence(.dataBoundary, "技术实现层，降权", weight: 0.5))
        }

        return (min(1.0, total), evidence)
    }

    // MARK: 组树

    private static func buildGraph(
        candidates: [String: Candidate],
        leaves: [Leaf],
        root: URL,
        warnings: inout [String]
    ) -> MindGraph {
        let maxClasses = candidates.values.map(\.classCount).max() ?? 1
        let scored = candidates.values
            .filter { $0.classCount >= Threshold.domainMinClasses }
            .map { (candidate: $0, result: score($0, maxClasses: maxClasses)) }
            .sorted { $0.result.0 > $1.result.0 }

        var nodes: [MindNode] = []
        var rootNode = MindNode(id: "system", title: root.lastPathComponent, kind: .system)
        rootNode.classCount = candidates.values.reduce(0) { $0 + $1.classCount }
        nodes.append(rootNode)

        var claimed = Set<String>()
        var usedTitles = Set<String>()

        for item in scored where item.result.0 >= Threshold.domainScore {
            var title = domainTitle(for: item.candidate)
            // 两个域抽到同一个中文词时，避让成包名，避免图上出现两个「AI画像」。
            if usedTitles.contains(title) {
                title = item.candidate.parts.joined(separator: " / ")
            }
            usedTitles.insert(title)

            let id = "domain:" + item.candidate.key
            var node = MindNode(id: id, title: title, kind: .domain)
            node.parentID = "system"
            node.packages = [item.candidate.key]
            node.classCount = item.candidate.classCount
            node.fileCount = item.candidate.files.count
            node.evidence = item.result.1
            node.owner = OwnerInfo(authors: item.candidate.authors)
            nodes.append(node)
            rootNode.childIDs.append(id)
            claimed.insert(item.candidate.key)

            // 域内子包作为模块挂上去。
            for leaf in leaves where leaf.parts.count >= 3 {
                let leafKey = leaf.parts.prefix(3).joined(separator: "/")
                guard leafKey.hasPrefix(item.candidate.key + "/") else { continue }
                let moduleID = "module:" + leafKey
                guard !nodes.contains(where: { $0.id == moduleID }) else { continue }
                var module = MindNode(id: moduleID, title: leaf.parts[2], kind: .module)
                module.parentID = id
                module.packages = [leafKey]
                module.classCount = leaf.classes.count
                module.fileCount = leaf.files.count
                nodes.append(module)
                node.childIDs.append(moduleID)
            }
            if let index = nodes.firstIndex(where: { $0.id == id }) {
                nodes[index] = node
            }
        }

        // 剩余候选：按第一层聚合。这里是「销售搭子」这类跨包产品概念的落点，
        // 自动识别只能给出「Agent 核心」这样的名字，具体叫什么由人在导图上改。
        var leftovers: [String: Candidate] = [:]
        for candidate in candidates.values where !claimed.contains(candidate.key) {
            let level1 = candidate.parts.first ?? candidate.key
            var bucket = leftovers[level1] ?? Candidate(key: level1, parts: [level1])
            bucket.classes.append(contentsOf: candidate.classes)
            bucket.files.append(contentsOf: candidate.files)
            for (term, count) in candidate.termCounts {
                bucket.termCounts[term, default: 0] += count
            }
            bucket.authors.append(contentsOf: candidate.authors)
            leftovers[level1] = bucket
        }

        for (level1, bucket) in leftovers.sorted(by: { $0.value.classCount > $1.value.classCount }) {
            guard bucket.classCount >= Threshold.domainMinClasses * 2 else { continue }
            let id = "domain:leftover:" + level1
            var node = MindNode(
                id: id,
                title: "\(level1.prefix(1).uppercased() + level1.dropFirst()) 核心",
                kind: .domain
            )
            node.parentID = "system"
            node.packages = [level1]
            node.classCount = bucket.classCount
            node.fileCount = bucket.files.count
            node.evidence = [Evidence(
                .dataBoundary,
                "\(bucket.classCount) 个类未归入任何域，按一级包聚合",
                weight: 0.5
            )]
            // 作者按提交数合并去重。
            var authorTotals: [String: Int] = [:]
            for author in bucket.authors {
                authorTotals[author.name, default: 0] += author.commits
            }
            node.owner = OwnerInfo(authors: authorTotals
                .map { AuthorStat(name: $0.key, commits: $0.value) }
                .sorted { $0.commits > $1.commits })
            node.isManual = false
            nodes.append(node)
            rootNode.childIDs.append(id)
        }

        if rootNode.childIDs.isEmpty {
            warnings.append("没有候选达到领域阈值，可能需要在导图上手工划分")
        }

        if let index = nodes.firstIndex(where: { $0.id == "system" }) {
            nodes[index] = rootNode
        }

        var graph = MindGraph(nodes: nodes, rootID: "system", generatedAt: Date())
        graph.baseCommit = WikiChangeSource.run(["rev-parse", "HEAD"], at: root)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        graph.rebuildIndex()
        return graph
    }

    /// 域标题：优先用高频中文业务词，拼上 `AI` 前缀。
    ///
    /// 本项目所有领域都是 AI 能力（AI画像、AI客服…），只写「画像」会和
    /// 「用户画像表」这类技术概念混淆，所以统一加前缀。
    private static func domainTitle(for candidate: Candidate) -> String {
        if let term = candidate.topTerm {
            return term.hasPrefix("AI") ? term : "AI" + term
        }
        let last = candidate.parts.last ?? candidate.key
        return last.prefix(1).uppercased() + last.dropFirst()
    }
}
