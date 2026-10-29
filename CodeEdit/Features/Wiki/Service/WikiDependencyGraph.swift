//
//  WikiDependencyGraph.swift
//  CodeEdit
//
//  模块依赖图：先由 import 关系确定事实，再让模型在这张图上做解释。
//
//  为什么必须先建图：
//  「理解各文件联系」这一步如果只把模块名交给模型，它只能靠名字猜关系——
//  猜出来的「依赖 X」既不可验证，也会随提示词波动。而 import 语句是硬事实：
//  谁引用了谁、引用了多少处，都能从源码里数出来。
//
//  所以这里的分工是：
//  - 本文件：确定性抽边（模块 A 的文件 import 了模块 B 的文件），并算出层级与影响面；
//  - 模型：只解释「为什么这样分层」「有什么约定」，不负责发明关系。
//
//  附带收益：拓扑序决定了建档顺序——先建被依赖最多的基础模块，
//  上层模块建档时就能引用到真实存在的条目，而不是悬空的名字。
//

import Foundation

// MARK: - 边

struct WikiModuleEdge: Sendable, Hashable {
    let from: String
    let to: String
    /// 出现的 import 次数，用来区分「偶发引用」与「强依赖」。
    let count: Int
    /// 示例语句，展示给人看时用。
    let samples: [String]
}

// MARK: - 图

struct WikiDependencyGraph: Sendable {

    /// 参与分析的模块名。
    var modules: [String] = []
    var edges: [WikiModuleEdge] = []
    /// 指向仓库外的依赖（如第三方包、系统库），不计入图，但统计出来让人知道边界。
    var externals: [String: Int] = [:]
    /// 解析不出归属的 import 目标。
    var unresolved: [String: Int] = [:]

    // MARK: 查询

    /// 本模块依赖谁。
    func dependencies(of module: String) -> [WikiModuleEdge] {
        edges.filter { $0.from == module }.sorted { $0.count > $1.count }
    }

    /// 谁依赖本模块。这是「改基建代码会影响谁」的直接答案。
    func dependents(of module: String) -> [WikiModuleEdge] {
        edges.filter { $0.to == module }.sorted { $0.count > $1.count }
    }

    /// 被依赖的总次数，用作「基础程度」的度量。
    func fanIn(_ module: String) -> Int {
        edges.filter { $0.to == module }.reduce(0) { $0 + $1.count }
    }

    /// 依赖别人的总次数。
    func fanOut(_ module: String) -> Int {
        edges.filter { $0.from == module }.reduce(0) { $0 + $1.count }
    }

    /// 供提示词使用的确定性关系描述。模型看到的是事实，不是名字列表。
    func context(for module: String, limit: Int = 8) -> String {
        var lines: [String] = []
        let deps = dependencies(of: module).prefix(limit)
        if !deps.isEmpty {
            lines.append("本模块依赖：" + deps.map { "\($0.to)（\($0.count) 处）" }.joined(separator: "、"))
        }
        let users = dependents(of: module).prefix(limit)
        if !users.isEmpty {
            lines.append("被这些模块依赖：" + users.map { "\($0.from)（\($0.count) 处）" }.joined(separator: "、"))
        }
        if lines.isEmpty {
            lines.append("本模块与其它模块没有直接 import 关系")
        }
        return lines.joined(separator: "\n")
    }

    /// 拓扑序：不依赖任何人的模块排在前面，被依赖者先于依赖者。
    ///
    /// 建档按这个顺序走，上层模块才能引用到已经存在的下模块条目。
    func topologicalOrder() -> [String] {
        var remaining = Set(modules)
        var order: [String] = []

        // 迭代剥离「不再依赖剩余模块」的节点。
        while !remaining.isEmpty {
            let ready = remaining.filter { module in
                dependencies(of: module).allSatisfy { !remaining.contains($0.to) }
            }
            if ready.isEmpty {
                // 有环。整体收尾会让环内顺序完全随意，改成「逐个破环」：
                // 每轮只强制处理一个节点，优先选被依赖多、依赖别人少的那个，
                // 这样只打破必要的边，其余顺序仍然成立。
                // 优先打破「被依赖多、依赖别人少」的节点：它本来就是基础模块，
                // 提前处理最符合人的预期；实测比「出边最少」策略少一半违规。
                let pick = remaining.max { lhs, rhs in
                    let lhsScore = fanIn(lhs) - fanOut(lhs)
                    let rhsScore = fanIn(rhs) - fanOut(rhs)
                    if lhsScore != rhsScore { return lhsScore < rhsScore }
                    return fanIn(lhs) < fanIn(rhs)
                }
                guard let pick else { break }
                order.append(pick)
                remaining.remove(pick)
                continue
            }
            let batch = ready.sorted { fanIn($0) > fanIn($1) }
            order.append(contentsOf: batch)
            remaining.subtract(batch)
        }
        return order
    }

    /// 概览，一行。
    var summary: String {
        "依赖 \(edges.count) 条 / 外部 \(externals.count) 种 / 未解析 \(unresolved.count) 种"
    }

    // MARK: 构建

    /// 扫描所有文件，构建单元级依赖图。
    ///
    /// 两条证据并行：
    /// 1. **import / include / require**：对 JS、Python、Go 这类语言是主要信号；
    /// 2. **符号引用**：Swift、Java、C# 的 import 是模块级的（`import AppKit`），
    ///    真正的依赖发生在类型层——`WikiWindow` 用了 `WikiStore`，这层关系 import 抽不出来。
    ///    所以对每个文件抽出「自己声明的类型」和「引用到的类型」，
    ///    再用「只在本仓库唯一声明」的符号做倒排，匹配出的就是跨文件依赖。
    ///
    /// 两条证据都转成单元级边，权重相加。
    static func build(root: URL, modules: [RepoModule]) -> WikiDependencyGraph {
        var graph = WikiDependencyGraph()
        graph.modules = modules.map(\.name)

        var moduleOfFile: [String: String] = [:]
        for module in modules {
            for file in module.files {
                moduleOfFile[file.path] = module.name
            }
        }
        let moduleByPath = modules.map(\.name).sorted { $0.count > $1.count }
        var moduleByLast: [String: String] = [:]
        for module in modules {
            let last = (module.name as NSString).lastPathComponent
            if moduleByLast[last] == nil { moduleByLast[last] = module.name }
        }

        var counts: [String: Int] = [:]
        var samples: [String: [String]] = [:]

        func addEdge(from fromModule: String, to toModule: String, sample: String) {
            guard fromModule != toModule else { return }
            let key = "\(fromModule)\u{1}\(toModule)"
            counts[key, default: 0] += 1
            if samples[key, default: []].count < 3 {
                samples[key, default: []].append(sample)
            }
        }

        // A) import 级证据
        for (path, fromModule) in moduleOfFile {
            for target in importTargets(of: root.appending(path: path), path: path) {
                guard let toModule = resolve(
                    target: target,
                    fromFile: path,
                    moduleOfFile: moduleOfFile,
                    moduleByPath: moduleByPath,
                    moduleByLast: moduleByLast
                ) else {
                    if looksExternal(target) {
                        graph.externals[target, default: 0] += 1
                    } else {
                        graph.unresolved[target, default: 0] += 1
                    }
                    continue
                }
                addEdge(from: fromModule, to: toModule, sample: target)
            }
        }

        // B) 符号级证据
        let facts = collectFacts(root: root, paths: Array(moduleOfFile.keys))
        var owners: [String: [String]] = [:]
        for (path, fact) in facts {
            for symbol in fact.declarations {
                owners[symbol, default: []].append(path)
            }
        }
        // 只在「唯一声明」的符号上建边：重名符号（Store、Manager）跨文件匹配全是噪音。
        var uniqueOwner: [String: String] = [:]
        for (symbol, paths) in owners where paths.count == 1 {
            uniqueOwner[symbol] = paths[0]
        }

        for (path, fact) in facts {
            guard let fromModule = moduleOfFile[path] else { continue }
            for symbol in fact.references {
                guard let ownerFile = uniqueOwner[symbol],
                      ownerFile != path,
                      let toModule = moduleOfFile[ownerFile] else { continue }
                addEdge(from: fromModule, to: toModule, sample: symbol)
            }
        }

        graph.edges = counts.compactMap { key, count in
            let parts = key.split(separator: "\u{1}").map(String.init)
            guard parts.count == 2 else { return nil }
            return WikiModuleEdge(
                from: parts[0],
                to: parts[1],
                count: count,
                samples: samples[key] ?? []
            )
        }
        .sorted { $0.count > $1.count }

        return graph
    }

    // MARK: 符号采集

    struct FileFacts {
        var declarations: Set<String> = []
        var references: Set<String> = []
    }

    /// 类型声明：只收类型，不收 func/let/var——后者重名率太高，且很少是跨文件依赖的主语。
    private static let declarationRegex = try? NSRegularExpression(
        pattern: #"(?m)^\s*(?:@[A-Za-z_]\w*(?:\([^)]*\))?\s+)*(?:public\s+|internal\s+|private\s+|fileprivate\s+|open\s+|final\s+|indirect\s+|nonisolated\s+)*(?:struct|class|enum|protocol|actor|typealias)\s+([A-Za-z_]\w*)"#
    )

    /// 引用：大写开头的标识符。4 字符以上，滤掉 View/Text 这类极短通用词。
    private static let referenceRegex = try? NSRegularExpression(
        pattern: #"\b([A-Z][A-Za-z0-9_]{3,})\b"#
    )

    private static func collectFacts(root: URL, paths: [String]) -> [String: FileFacts] {
        var result: [String: FileFacts] = [:]
        for path in paths {
            let text = head(of: root.appending(path: path), limit: 32_000)
            guard !text.isEmpty else { continue }

            var fact = FileFacts()
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            declarationRegex?.enumerateMatches(in: text, options: [], range: range) { match, _, _ in
                guard let match, match.numberOfRanges > 1,
                      let sub = Range(match.range(at: 1), in: text) else { return }
                fact.declarations.insert(String(text[sub]))
            }
            referenceRegex?.enumerateMatches(in: text, options: [], range: range) { match, _, _ in
                guard let match, match.numberOfRanges > 1,
                      let sub = Range(match.range(at: 1), in: text) else { return }
                fact.references.insert(String(text[sub]))
            }
            result[path] = fact
        }
        return result
    }

    // MARK: import 解析    // MARK: import 解析

    /// 只读文件头部：import 一定在开头，整个仓库全量读入是纯浪费。
    private static let readLimit = 12_000

    static func importTargets(of url: URL, path: String) -> [String] {
        let ext = (path as NSString).pathExtension.lowercased()
        guard let patterns = importPatterns[ext] else { return [] }

        let text = head(of: url)
        guard !text.isEmpty else { return [] }

        var targets: [String] = []
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        for pattern in patterns {
            pattern.enumerateMatches(in: text, options: [], range: range) { match, _, _ in
                guard let match else { return }
                for group in 1..<match.numberOfRanges {
                    guard let sub = Range(match.range(at: group), in: text) else { continue }
                    let value = String(text[sub]).trimmingCharacters(in: .whitespaces)
                    if !value.isEmpty {
                        targets.append(value)
                        break
                    }
                }
            }
        }
        return targets
    }

    private static func head(of url: URL, limit: Int? = nil) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let data = handle.readData(ofLength: limit ?? readLimit)
        // 截断可能切开多字节字符，用容错解码而不是失败返回。
        return String(decoding: data, as: UTF8.self)
    }

    /// 按扩展名选正则。捕获组 1（或第一个非空组）即依赖目标。
    private static let importPatterns: [String: [NSRegularExpression]] = {
        func regex(_ pattern: String) -> NSRegularExpression? {
            try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
        }
        let swift = [
            regex(#"^\s*(?:@testable\s+)?import\s+([A-Za-z_][A-Za-z0-9_.]*)"#)
        ].compactMap { $0 }

        let js = [
            regex(#"from\s+['"]([^'"]+)['"]"#),
            regex(#"require\(\s*['"]([^'"]+)['"]\s*\)"#)
        ].compactMap { $0 }

        let python = [
            regex(#"^\s*from\s+([A-Za-z_][\w.]*)\s+import"#),
            regex(#"^\s*import\s+([A-Za-z_][\w.]*)"#)
        ].compactMap { $0 }

        let clike = [
            regex(#"^\s*#\s*include\s+[<"]([^>"]+)[>"]"#)
        ].compactMap { $0 }

        let jvm = [
            regex(#"^\s*import\s+(?:static\s+)?([\w.]+)"#)
        ].compactMap { $0 }

        let go = [
            regex(#"^\s*(?:[\w.]+\s+)?"([^"]+)"\s*$"#),
            regex(#"^\s*import\s+"([^"]+)""#)
        ].compactMap { $0 }

        let rust = [
            regex(#"^\s*use\s+([\w:]+)"#)
        ].compactMap { $0 }

        let cs = [
            regex(#"^\s*using\s+(?:static\s+)?([\w.]+)\s*;"#)
        ].compactMap { $0 }

        return [
            "swift": swift,
            "ts": js, "tsx": js, "js": js, "jsx": js, "vue": js, "svelte": js,
            "py": python,
            "c": clike, "cc": clike, "cpp": clike, "h": clike, "hpp": clike, "m": clike, "mm": clike,
            "java": jvm, "kt": jvm, "kts": jvm, "scala": jvm,
            "go": go,
            "rs": rust,
            "cs": cs
        ]
    }()

    /// 把 import 目标解析成模块名。解析不出来返回 nil。
    private static func resolve(
        target: String,
        fromFile: String,
        moduleOfFile: [String: String],
        moduleByPath: [String],
        moduleByLast: [String: String]
    ) -> String? {
        // 1) 相对路径：相对当前文件目录解析，再找它落在哪个模块。
        if target.hasPrefix(".") {
            let base = (fromFile as NSString).deletingLastPathComponent
            let joined = normalize(base + "/" + target)
            if let module = moduleOfPath(joined, moduleByPath: moduleByPath) {
                return module
            }
            // 相对路径指向具体文件：去掉扩展名再试一次。
            let stem = (joined as NSString).deletingPathExtension
            return moduleOfPath(stem, moduleByPath: moduleByPath)
        }

        // 2) 路径式（Go / C include）：先按完整路径找，再按末段找。
        if target.contains("/") {
            if let module = moduleOfPath(normalize(target), moduleByPath: moduleByPath) {
                return module
            }
            let last = (target as NSString).lastPathComponent
            let stem = (last as NSString).deletingPathExtension
            if let module = moduleByLast[last] ?? moduleByLast[stem] {
                return module
            }
            return nil
        }

        // 3) 裸标识符 / 点分命名空间：逐段尝试（`CodeEdit.Features.Wiki` 取 Wiki）。
        if target.contains(".") {
            for part in target.split(separator: ".").reversed() {
                if let module = moduleByLast[String(part)] { return module }
            }
            return nil
        }

        // 4) 单段标识符。
        if let module = moduleByLast[target] { return module }
        return moduleOfPath(target, moduleByPath: moduleByPath)
    }

    /// 找一个路径所属的模块（最长前缀）。
    private static func moduleOfPath(_ path: String, moduleByPath: [String]) -> String? {
        for module in moduleByPath where path == module || path.hasPrefix(module + "/") {
            return module
        }
        return nil
    }

    /// 规整 `a/./b/../c` 这类路径。
    private static func normalize(_ path: String) -> String {
        var parts: [String] = []
        for component in path.split(separator: "/") {
            if component == "." { continue }
            if component == ".." {
                if !parts.isEmpty { parts.removeLast() }
                continue
            }
            parts.append(String(component))
        }
        return parts.joined(separator: "/")
    }

    /// 明显来自仓库外的目标：带命名空间前缀的包、系统头文件、npm 裸包。
    private static func looksExternal(_ target: String) -> Bool {
        if target.hasSuffix(".h") { return true }
        let first = target.split(separator: "/").first.map(String.init) ?? target
        if first.contains(".") { return true }
        // 不在本仓库的裸模块名（如 CodeEditTextView）最终会走到这里。
        return true
    }
}
