//
//  WikiRepoIngest.swift
//  CodeEdit
//
//  仓库建档的第一步：不用模型，纯确定性扫描与排序。
//
//  为什么先做这一步而不是直接把仓库丢给模型：
//  一个仓库几百上千个文件，模型读不完也不该读——先按「规模、入口、变更频率、是否测试」
//  算出重要度，只把真正承载业务的那一小部分交给模型，既省钱也更准。
//
//  这一步的产物是可解释的：每个文件为什么被选中，都带着理由（reasons），
//  人在界面上能看到「模型为什么先读这个文件」。
//

import Foundation

// MARK: - 候选文件

struct RepoFileCandidate: Identifiable, Hashable, Sendable {
    let path: String
    let bytes: Int
    /// 重要度评分（0 起，无上限，仅用于排序）。
    var score: Double
    /// 评分理由，直接展示给人看。
    var reasons: [String]

    var id: String { path }
    var fileName: String { (path as NSString).lastPathComponent }
    var directory: String { (path as NSString).deletingLastPathComponent }
}

struct RepoModule: Identifiable, Sendable {

    /// 这个知识单元的粒度：一个目录、一组同目录文件，或单个文件。
    enum Granularity: String, Sendable {
        case folder
        case fileGroup
        case singleFile

        var title: String {
            switch self {
            case .folder: return "目录"
            case .fileGroup: return "文件组"
            case .singleFile: return "单文件"
            }
        }
    }

    let name: String
    var files: [RepoFileCandidate]
    /// 切分判定的结果，写进知识条目便于人判断「这条为什么是这个范围」。
    var granularity: Granularity = .folder
    /// 内聚度 0...1。
    var cohesion: Double = 0

    var id: String { name }
    var totalScore: Double { files.reduce(0) { $0 + $1.score } }
    /// 界面与标题里用的短名。
    var displayName: String {
        let last = (name as NSString).lastPathComponent
        return last.isEmpty ? name : last
    }
}

// MARK: - 扫描

enum WikiRepoIngest {

    /// 不进入的目录：依赖、构建产物、缓存、数据目录。
    static let skippedDirectories: Set<String> = [
        ".git", ".build", "build", "Build", "DerivedData", "node_modules",
        "Pods", "Carthage", "vendor", "dist", "out", "target", "bin", "obj",
        ".venv", "venv", "__pycache__", ".next", ".nuxt", "coverage",
        ".qiyide", ".idea", ".vscode", "Resources", "Assets.xcassets"
    ]

    /// 参与评分的源码后缀。刻意不包含图片、二进制与压缩包。
    static let sourceExtensions: Set<String> = [
        "swift", "m", "mm", "h", "c", "cc", "cpp", "hpp",
        "ts", "tsx", "js", "jsx", "vue", "svelte",
        "py", "go", "rs", "java", "kt", "kts", "scala",
        "rb", "php", "cs", "sql", "sh", "gradle"
    ]

    static let documentationExtensions: Set<String> = ["md", "txt", "adoc"]

    /// 入口文件名，命中直接加分——它们是理解仓库的起点。
    static let entryFileNames: Set<String> = [
        "main.swift", "app.swift", "appdelegate.swift", "index.ts", "index.js",
        "main.go", "main.rs", "main.py", "__main__.py", "manage.py",
        "application.java", "program.cs", "router.ts", "app.ts", "server.ts"
    ]

    /// 扫描并评分。返回按模块分组的候选，模块按总分降序。
    static func scan(
        root: URL,
        maxFiles: Int,
        maxModules: Int
    ) -> (modules: [RepoModule], considered: Int) {
        let churn = churnCounts(root: root)
        var candidates: [RepoFileCandidate] = []
        var considered = 0

        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .nameKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return ([], 0)
        }

        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            if skippedDirectories.contains(name) {
                enumerator.skipDescendants()
                continue
            }
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { continue }

            let ext = url.pathExtension.lowercased()
            let isSource = sourceExtensions.contains(ext)
            let isDoc = documentationExtensions.contains(ext)
            guard isSource || isDoc else { continue }

            considered += 1
            guard isSource else { continue }

            let relative = relativePath(of: url, root: root)
            let bytes = values.fileSize ?? 0
            guard bytes > 0 else { continue }

            let scored = score(
                path: relative,
                bytes: bytes,
                churn: churn[relative] ?? 0
            )
            candidates.append(scored)
        }

        // 切分粒度由结构决定：够内聚的目录整块成单元，不够就下钻到文件。
        // 固定三段路径会把 `Features/Wiki` 切对，但别的仓库就会切错。
        let allUnits = WikiKnowledgeSegmentation.segment(files: candidates)
        let topUnits = Array(allUnits.prefix(maxModules))
        let selected = selectUnits(topUnits, budget: maxFiles)
        return (selected, candidates.count)
    }

    /// 单文件评分。规则保持可解释：每条加分/减分都写进 reasons。
    static func score(path: String, bytes: Int, churn: Int) -> RepoFileCandidate {
        var score = 0.0
        var reasons: [String] = []

        // 规模：文件越大，通常承载的信息越多，但边际递减。
        let sizeScore = min(Double(bytes) / 20_000.0, 5.0)
        score += sizeScore
        if sizeScore >= 1.0 {
            reasons.append("规模 \(bytes / 1024) KB")
        }

        let name = (path as NSString).lastPathComponent.lowercased()
        if entryFileNames.contains(name) {
            score += 6
            reasons.append("入口文件")
        }

        // 变更频率：经常被改的文件往往正是核心。
        if churn > 0 {
            let churnScore = min(Double(churn), 6.0) * 0.9
            score += churnScore
            reasons.append("近期改动 \(churn) 次")
        }

        // 测试文件对「理解系统」的价值低于实现本身。
        let lowerPath = path.lowercased()
        if lowerPath.contains("/test") || lowerPath.contains("spec") || lowerPath.hasSuffix("tests.swift") {
            score -= 5
            reasons.append("测试文件降权")
        }

        // 过深的目录多半是边缘代码。
        let depth = path.split(separator: "/").count
        if depth > 4 {
            score -= Double(depth - 4) * 0.6
            reasons.append("层级较深")
        }

        // 生成代码没有阅读价值。
        if lowerPath.contains("generated") || lowerPath.contains(".pb.") {
            score -= 8
            reasons.append("疑似生成代码")
        }

        return RepoFileCandidate(
            path: path,
            bytes: bytes,
            score: max(score, 0),
            reasons: reasons
        )
    }

    /// 在本轮预算内挑选知识单元。
    ///
    /// 关键约束：**单元不拆**。一个单元要么整块进入本轮，要么整轮跳过。
    /// 之前按文件数截断，会让 36 个文件的目录只读 12 个，产出的条目是残缺的，
    /// 下一轮再补时又会整块覆盖，前言不搭后语。
    static func selectUnits(_ units: [RepoModule], budget: Int) -> [RepoModule] {
        var result: [RepoModule] = []
        var remaining = budget

        for unit in units {
            guard remaining > 0 else { break }
            // 超预算的单元允许独占一轮，否则大单元永远轮不上。
            if unit.files.count > remaining && !result.isEmpty { break }
            result.append(unit)
            remaining -= unit.files.count
        }
        return result
    }

    /// 只统计不挑选：仓库里有多少源码文件、其中多少已经建过档。
    /// 用于界面上「全仓 733 个，已建档 120 个」这种概览，不做评分。
    static func inventory(root: URL, state: WikiIngestState) -> (total: Int, fresh: Int) {
        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return (0, 0) }

        var total = 0
        var fresh = 0
        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            if skippedDirectories.contains(name) {
                enumerator.skipDescendants()
                continue
            }
            guard sourceExtensions.contains(url.pathExtension.lowercased()) else { continue }
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
                  values.isRegularFile == true else { continue }
            total += 1
            if state.isFresh(path: relativePath(of: url, root: root), url: url) {
                fresh += 1
            }
        }
        return (total, fresh)
    }

    /// 基于「文件结论缓存」的概览：比 mtime 判定更准，换模型后旧结论会自动失效。
    static func inventory(
        root: URL,
        insights: WikiInsightStore,
        model: String
    ) -> (total: Int, fresh: Int) {
        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return (0, 0) }

        var total = 0
        var fresh = 0
        for case let url as URL in enumerator {
            if skippedDirectories.contains(url.lastPathComponent) {
                enumerator.skipDescendants()
                continue
            }
            guard sourceExtensions.contains(url.pathExtension.lowercased()) else { continue }
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
                  values.isRegularFile == true else { continue }
            total += 1
            if insights.insight(for: relativePath(of: url, root: root), url: url, model: model) != nil {
                fresh += 1
            }
        }
        return (total, fresh)
    }

    // MARK: 批次规划

    /// 把文件按「字符预算 + 文件数预算」装箱。
    ///
    /// 第一版固定每批 3 个文件，单次请求只有约 7500 字符，而模型上下文是 20 万 token 级——
    /// 98% 的窗口是空的，于是 60 个文件要发 20 次请求。改成按字符装箱后，
    /// 同样 60 个文件只需 6~8 次。
    static func batchPlan(
        files: [RepoFileCandidate],
        maxFilesPerBatch: Int = 10,
        maxCharsPerBatch: Int = 24_000
    ) -> [[RepoFileCandidate]] {
        guard maxFilesPerBatch > 0, maxCharsPerBatch > 0 else { return [files] }

        var batches: [[RepoFileCandidate]] = []
        var current: [RepoFileCandidate] = []
        var used = 0

        for file in files {
            // 大文件会被摘录，按「摘录后的估计长度」计入预算，避免单文件吃掉整批。
            let cost = min(max(file.bytes, 800), excerptCharLimit)
            if !current.isEmpty && (current.count >= maxFilesPerBatch || used + cost > maxCharsPerBatch) {
                batches.append(current)
                current = []
                used = 0
            }
            current.append(file)
            used += cost
        }
        if !current.isEmpty { batches.append(current) }
        return batches
    }

    /// 单文件送模型的字符上限。超过就只送「头部 + 声明行」。
    static let excerptCharLimit = 8_000

    /// 声明行：大文件里真正能说明「它在干什么」的部分。
    private static let declarationRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"^\s*(import|from|#include|using|package|class|struct|enum|protocol|extension|func|def|interface|export|public|private|internal|open|static|init|type|let|var|const)\b"#
    )

    /// 读取并摘录一个文件。
    ///
    /// 小文件读全文；大文件读「前 120 行 + 声明行」，这比截断前 N 行更有效：
    /// 一个 3000 行的控制器，前 120 行可能全是 license 和 import，声明行才承载结构。
    static func excerpt(for file: RepoFileCandidate, root: URL) -> String? {
        let url = root.appending(path: file.path)
        guard let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty else {
            return nil
        }
        guard text.count > excerptCharLimit else { return text }

        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var parts: [String] = []
        parts.append("// 文件较大（\(file.bytes / 1024) KB），以下为头部与声明摘要")
        parts.append(contentsOf: lines.prefix(120).map(String.init))

        var declarations: [String] = []
        for line in lines.dropFirst(120) {
            let text = String(line)
            guard text.count < 200 else { continue }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            if declarationRegex?.firstMatch(in: text, options: [], range: range) != nil {
                declarations.append(text)
            }
            if declarations.count >= 80 { break }
        }
        if !declarations.isEmpty {
            parts.append("")
            parts.append("// 其余行的声明摘要")
            parts.append(contentsOf: declarations)
        }

        return String(parts.joined(separator: "\n").prefix(excerptCharLimit))
    }

    /// 读文件 + 拼提示词，组装成可并发的批次。
    ///
    /// 这一步是纯 IO 与字符串处理，放在 nonisolated 函数里执行，不占主线程。
    static func prepareJobs(
        batches: [[RepoFileCandidate]],
        root: URL,
        base: AINarrativeRequest,
        kind: AIProviderKind
    ) -> [WikiBatchJob] {
        batches.enumerated().compactMap { index, batch -> WikiBatchJob? in
            var sections: [String] = []
            var paths: [String] = []
            for file in batch {
                guard let excerpt = excerpt(for: file, root: root) else { continue }
                sections.append("=== \(file.path) ===\n" + excerpt)
                paths.append(file.path)
            }
            guard !sections.isEmpty else { return nil }
            return WikiBatchJob(
                id: "batch-\(index)",
                kind: kind,
                request: base.withUserPrompt(sections.joined(separator: "\n\n")),
                paths: paths
            )
        }
    }

    // MARK: 变更频率

    /// 一个 git 调用拿到近期每个文件被改的次数，作为「核心程度」的代理指标。
    static func churnCounts(root: URL, commits: Int = 300) -> [String: Int] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = [
            "-C", root.path, "log", "--format=", "--name-only", "-n", String(commits)
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        guard (try? process.run()) != nil else { return [:] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let text = String(data: data, encoding: .utf8) else {
            return [:]
        }

        var counts: [String: Int] = [:]
        for line in text.split(separator: "\n") {
            let path = line.trimmingCharacters(in: .whitespaces)
            guard !path.isEmpty else { continue }
            counts[path, default: 0] += 1
        }
        return counts
    }

    static func relativePath(of url: URL, root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let filePath = url.standardizedFileURL.path
        guard filePath.hasPrefix(rootPath) else { return filePath }
        return String(filePath.dropFirst(rootPath.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}
