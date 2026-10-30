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
        /// 6000 字节只够约 2000 个汉字（UTF-8 每字 3 字节），命中数会被系统性低估。
        static let readLimit = 16_000
        /// git 作者统计最多看多少次提交。
        static let gitLogLimit = 200
        /// 每个候选最多扫多少个文件找中文词。
        static let termScanFileLimit = 100
        /// 中文词频的归一化分母。达到这个次数即视为「该词在此域高度集中」。
        static let termSaturation = 30
    }

    /// 这些路径段说明该包属于技术实现层，不是业务域。
    /// 命中后分数打对折——它仍会出现在导图里（作为模块），只是不会被当域。
    private static let technicalSegments: Set<String> = [
        "db", "mapper", "domain", "entity", "repository", "dao",
        "utils", "util", "config", "constant", "dto", "enums",
        "mq", "cache", "exception", "job", "proxy"
    ]

    /// 包名 → 中文业务名。命名用这个，不用中文词频。
    ///
    /// 实测中文词频极不可靠：`service/portrait` 里最高频的词是「对照」（来自对照组/对照表），
    /// 直接命名会得到「AI对照」。包名反而稳定——`portrait` 就是画像、`customerservice` 就是客服。
    /// 词频仍然保留，但只作为「判定依据」展示，不参与命名。
    private static let packageGlossary: [String: String] = [
        "portrait": "画像", "customerservice": "客服", "suggest": "建议",
        "corpus": "语料", "badge": "徽章", "insight": "洞察", "agent": "搭子",
        "chat": "对话", "memory": "记忆", "skill": "技能", "intent": "意图",
        "order": "订单", "product": "商品", "goods": "商品", "user": "用户",
        "member": "会员", "coupon": "优惠券", "promotion": "促销", "campaign": "活动",
        "payment": "支付", "refund": "退款", "settlement": "结算", "invoice": "发票",
        "cart": "购物车", "inventory": "库存", "logistics": "物流", "delivery": "配送",
        "review": "评价", "comment": "评论", "message": "消息", "notify": "通知",
        "search": "搜索", "recommend": "推荐", "risk": "风控", "audit": "审计",
        "report": "报表", "dashboard": "看板", "admin": "后台", "config": "配置"
    ]

    /// 技术动作词：高频但说明不了业务语义，不能拿来给域命名。
    /// 实测 `agent/customerservice` 的最高频中文词是「对齐」，直接命名会得到「AI对齐」这种不知所云的名字。
    private static let genericTerms: Set<String> = [
        "对齐", "校验", "处理", "转换", "同步", "分发", "编排", "路由",
        "兜底", "降级", "重试", "缓存", "加载", "解析", "渲染", "展示",
        "统计", "汇总", "明细", "列表", "详情", "编辑", "新建", "删除",
        "查询", "搜索", "导入", "导出", "刷新", "初始化", "记录", "结果"
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
        /// 已去掉公共包前缀的业务路径，如 `agent/suggest/generate`。
        var parts: [String]
        var classes: [String]
        /// 相对 `src/main/java`（仅用于展示）。
        var files: [String]
        /// 绝对路径：读文件内容必须用它，拼仓库根会得到不存在的路径。
        var absoluteFiles: [URL] = []
        /// 仓库相对路径：git 命令只认这个。
        var repoPaths: [String] = []
    }

    /// 一个 Maven 模块的扫描结果。
    ///
    /// 为什么要单独记前缀：Java 包路径动辄十几层
    /// （`com/jd/home/shj/server/saas/plus/ai/platform/app/agent/suggest`），
    /// 前 10 层对所有文件都一样。直接按物理层级统计，要么因为太深被跳过，
    /// 要么把「平台路径」当成业务层级。先求公共前缀，剩下的才是业务结构。
    private struct ModuleScan {
        var root: URL
        var prefix: [String]
        var classesByDir: [String: [String]]
        var filesByDir: [String: [String]]
    }

    /// 聚合后的域候选。所有统计都基于聚合后的类名与文件列表。
    private struct Candidate {
        var key: String                  // agent/suggest
        var parts: [String]
        var classes: [String] = []
        var files: [String] = []
        /// 读文件内容用（中文词提取）。
        var absoluteFiles: [URL] = []
        /// git 统计用（仓库相对路径）。
        var repoPaths: [String] = []
        var dominantPrefix: String = ""
        var prefixShare: Double = 0
        var externalRefs: Int = 0
        var entryCount: Int = 0
        var termCounts: [String: Int] = [:]
        var authors: [AuthorStat] = []

        var classCount: Int { classes.count }
        /// 最高频的业务词。跳过技术动作词——它们频次最高但说明不了业务语义。
        var topTerm: String? {
            termCounts
                .filter { !DomainAnalyzer.genericTerms.contains($0.key) }
                .max { $0.value < $1.value }?.key
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
                let modules = scanModules(javaRoots: javaRoots)
                let leaves = makeLeaves(modules: modules, root: root)
                var candidates = aggregate(leaves: leaves)

                Task { @MainActor in progress("统计跨包引用…") }
                let refs = scanImports(modules: modules)
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

    /// 扫描每个模块下的 .java 文件，并按目录归组。
    ///
    /// 一次遍历同时拿到类名与文件路径，避免为了算前缀再扫一遍。
    private static func scanModules(javaRoots: [URL]) -> [ModuleScan] {
        var modules: [ModuleScan] = []

        for javaRoot in javaRoots {
            guard let enumerator = FileManager.default.enumerator(
                at: javaRoot,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            var classesByDir: [String: [String]] = [:]
            var filesByDir: [String: [String]] = [:]

            for case let url as URL in enumerator where url.pathExtension == "java" {
                let relative = url.path.replacingOccurrences(of: javaRoot.path + "/", with: "")
                let dir = (relative as NSString).deletingLastPathComponent
                guard !dir.isEmpty else { continue }
                classesByDir[dir, default: []].append(url.deletingPathExtension().lastPathComponent)
                filesByDir[dir, default: []].append(relative)
            }

            guard !classesByDir.isEmpty else { continue }
            modules.append(ModuleScan(
                root: javaRoot,
                prefix: commonPrefix(Array(classesByDir.keys)),
                classesByDir: classesByDir,
                filesByDir: filesByDir
            ))
        }
        return modules
    }

    /// 去掉公共包前缀后转成叶子包。
    ///
    /// 同时算好两种路径：读文件要绝对路径、跑 git 要仓库相对路径。
    /// 之前只存了「相对 src/main/java」的路径，后续两个环节都拿它当基准，全部读空。
    private static func makeLeaves(modules: [ModuleScan], root: URL) -> [Leaf] {
        var leaves: [Leaf] = []
        for module in modules {
            let moduleRel = module.root.path
                .replacingOccurrences(of: root.path, with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            for (dir, classes) in module.classesByDir {
                guard let parts = businessParts(dir: dir, prefix: module.prefix) else { continue }
                let files = module.filesByDir[dir] ?? []
                leaves.append(Leaf(
                    parts: parts,
                    classes: classes,
                    files: files,
                    absoluteFiles: files.map { module.root.appending(path: $0) },
                    repoPaths: files.map { moduleRel.isEmpty ? $0 : "\(moduleRel)/\($0)" }
                ))
            }
        }
        return leaves
    }

    /// `com/jd/.../platform/app/agent/suggest` 去掉公共前缀后 → `["agent","suggest"]`
    private static func businessParts(dir: String, prefix: [String]) -> [String]? {
        var parts = dir.split(separator: "/").map(String.init)
        guard parts.count > prefix.count else { return nil }
        parts.removeFirst(prefix.count)
        return parts.isEmpty ? nil : parts
    }

    /// 一组目录路径的最长公共前缀（按段比较）。
    private static func commonPrefix(_ paths: [String]) -> [String] {
        guard var prefix = paths.first?.split(separator: "/").map(String.init) else { return [] }
        for path in paths.dropFirst() {
            let parts = path.split(separator: "/").map(String.init)
            var index = 0
            while index < prefix.count, index < parts.count, prefix[index] == parts[index] {
                index += 1
            }
            prefix = Array(prefix.prefix(index))
            if prefix.isEmpty { return [] }
        }
        return prefix
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
            candidate.absoluteFiles.append(contentsOf: leaf.absoluteFiles)
            candidate.repoPaths.append(contentsOf: leaf.repoPaths)
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

    /// 统计每个业务包（depth 2）被其它包 import 的次数。
    private static func scanImports(modules: [ModuleScan]) -> [String: Int] {
        var counts: [String: Int] = [:]
        let pattern = try? NSRegularExpression(
            pattern: #"^import\s+(?:static\s+)?([\w.]+);"#,
            options: [.anchorsMatchLines]
        )

        for module in modules {
            for (dir, files) in module.filesByDir {
                guard let ownerParts = businessParts(dir: dir, prefix: module.prefix) else { continue }
                let owner = ownerParts.prefix(2).joined(separator: "/")

                for file in files {
                    guard let text = readPrefix(of: module.root.appending(path: file)) else { continue }
                    let range = NSRange(text.startIndex..., in: text)
                    pattern?.enumerateMatches(in: text, range: range) { match, _, _ in
                        guard let match, let symbolRange = Range(match.range(at: 1), in: text) else { return }
                        let symbol = String(text[symbolRange])
                        guard let restParts = relativeImportParts(symbol, modules: modules) else { return }
                        // restParts 形如 ["agent","suggest","FooService"]，取前两段就是归属包。
                        let target = restParts.prefix(2).joined(separator: "/")
                        guard !target.isEmpty, target != owner else { return }
                        counts[target, default: 0] += 1
                    }
                }
            }
        }
        return counts
    }

    /// 把 import 的完整包名换算成「去掉模块公共前缀」的业务路径段。
    ///
    /// 用「最长前缀匹配」而不是硬编码某段包名：不同项目根包不同，
    /// 写死 `platform.app.` 在别的仓库上会全部失配。
    private static func relativeImportParts(_ symbol: String, modules: [ModuleScan]) -> [String]? {
        let parts = symbol.split(separator: ".").map(String.init)
        var best: [String]?
        for module in modules where parts.count > module.prefix.count {
            var matched = true
            for (index, segment) in module.prefix.enumerated() where parts[index] != segment {
                matched = false
                break
            }
            guard matched else { continue }
            let rest = Array(parts.dropFirst(module.prefix.count))
            if best == nil || rest.count < (best?.count ?? Int.max) {
                best = rest
            }
        }
        return best
    }

    /// 读文件头部。用于扫 import 与提取中文词。
    ///
    /// 编码必须容错：老 Java 工程的中文注释常是 GBK，严格按 UTF-8 解码会返回 nil，
    /// 整批文件被静默跳过——实测这会让中文词频从几百掉到十几，直接压垮评分。
    private static func readPrefix(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: Threshold.readLimit)) ?? Data()
        guard !data.isEmpty else { return nil }

        if let text = String(data: data, encoding: .utf8) { return text }
        // 回退到 GB18030（兼容 GBK/GB2312）。
        let gbEncoding = String.Encoding(
            rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
            )
        )
        if let text = String(data: data, encoding: gbEncoding) { return text }
        // 兜底：按 UTF-8 容错解码，非法字节替换成占位符，至少 ASCII 部分可用。
        return String(decoding: data, as: UTF8.self)
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
            for url in candidate.absoluteFiles.prefix(Threshold.termScanFileLimit) {
                guard let text = readPrefix(of: url) else { continue }
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
            // git 只认仓库相对路径；`candidate.key` 是去掉包前缀后的业务路径，用它查不到任何提交。
            guard let firstRepoPath = candidate.repoPaths.first else { continue }
            let gitDir = (firstRepoPath as NSString).deletingLastPathComponent
            let output = WikiChangeSource.run(
                ["log", "--no-merges", "--format=%an", "-\(Threshold.gitLogLimit)", "--", gitDir],
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

        // ③ 调用关系只做证据，不参与扣分。
        //
        // 原实现按「被引用次数」扣分，结果 `agent/customerservice`（被 web 与 agent 同时引用 85 次）
        // 被判定为「不够独立」而落选——但它恰恰是最该被识别为域的模块。
        // 被依赖得多说明这是有价值的基础能力，不是缺点。
        if candidate.externalRefs == 0 {
            evidence.append(Evidence(.callClosure, "无跨包引用，业务独立", weight: 1.0))
        } else {
            evidence.append(Evidence(.callClosure, "被引用 \(candidate.externalRefs) 次", weight: 0.6))
        }

        // ④ 业务入口：Service/Api/Controller 类的密度。
        let entryScore = min(1.0, Double(candidate.entryCount) / 8.0)
        if candidate.entryCount > 0 {
            evidence.append(Evidence(.callClosure, "\(candidate.entryCount) 个服务/接口入口", weight: entryScore))
        }

        // ⑤ 中文业务词：出现越集中越像领域名。
        // 用 topTerm（已排除技术动作词）的计数，而不是所有词的计数最大值。
        let topCount = candidate.topTerm.flatMap { candidate.termCounts[$0] } ?? 0
        let termScore = min(1.0, Double(topCount) / Double(Threshold.termSaturation))
        if let term = candidate.topTerm {
            evidence.append(Evidence(.chineseTerm, "高频词「\(term)」×\(topCount)", weight: termScore))
        }

        var total = 0.30 * sizeScore
            + 0.25 * candidate.prefixShare
            + 0.25 * entryScore
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

        #if DEBUG
        // 分数构成打到 stderr：阈值调不调得动，取决于看到每一项的实际值。
        for item in scored.prefix(10) {
            NSLog(
                "[Qiyide][score] %@ 分数=%.3f 类=%d 前缀=%.2f refs=%d 入口=%d 词=%d",
                item.candidate.key,
                item.result.0,
                item.candidate.classCount,
                item.candidate.prefixShare,
                item.candidate.externalRefs,
                item.candidate.entryCount,
                item.candidate.termCounts.values.max() ?? 0
            )
        }
        #endif

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
            // 剩下的一级包也走词典：`agent` 剩余 647 个类，正是「销售搭子」的主体。
            let chinese = packageGlossary[level1.lowercased()]
            var title = chinese.map { "AI\($0)" }
                ?? "\(level1.prefix(1).uppercased() + level1.dropFirst()) 核心"
            // 不同模块可能有同名包（app 的 portrait 与 client 的 portrait），
            // 都走词典会得到两个「AI画像」，这里用包路径后缀区分。
            if usedTitles.contains(title) {
                title += "（\(level1)）"
            }
            usedTitles.insert(title)
            var node = MindNode(
                id: id,
                title: title,
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

    /// 域标题：优先用包名词典，其次用包名本身。
    ///
    /// 不用中文词频命名——实测 `service/portrait` 的最高频词是「对照」，
    /// 会得到「AI对照」这种看不懂的名字。词频只留在依据里供人核对。
    private static func domainTitle(for candidate: Candidate) -> String {
        if let last = candidate.parts.last?.lowercased(),
           let chinese = packageGlossary[last] {
            return "AI" + chinese
        }
        let last = candidate.parts.last ?? candidate.key
        return last.prefix(1).uppercased() + last.dropFirst()
    }
}
