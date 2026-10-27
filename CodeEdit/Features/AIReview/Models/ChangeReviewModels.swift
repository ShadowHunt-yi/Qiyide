//
//  ChangeReviewModels.swift
//  CodeEdit
//
//  AI 改动审查：与 UI 无关的分析内核。
//
//  设计约束：
//  - 只依赖 Foundation，可在 App 之外单独编译验证（给定 git 输出的原始文本即可工作）；
//  - 所有判定都是确定性规则，不调用任何模型——模型只用于补充叙述，不能影响分层与评分。
//

import Foundation

// MARK: - 层级

/// 改动所属的架构层。
enum ChangeLayer: String, Codable, CaseIterable {
    case business
    case technical
    case both

    var title: String {
        switch self {
        case .business: return "业务架构"
        case .technical: return "技术架构"
        case .both: return "业务 + 技术"
        }
    }

    var shortTitle: String {
        switch self {
        case .business: return "业务"
        case .technical: return "技术"
        case .both: return "双跨"
        }
    }
}

// MARK: - 风险信号

/// 需要对一眼的风险信号。权重参与重要度评分。
enum RiskSignal: String, Codable, CaseIterable {
    /// 修复此前引入的问题（回归）。
    case regression
    /// 吞掉错误 / 静默失败路径。
    case silentFailure
    /// 公共或跨模块 API 变化。
    case publicAPI
    /// NSRange / 偏移 / 索引等边界算术。
    case boundaryArithmetic
    /// 并发与 actor 隔离。
    case concurrency
    /// 持久化与解码（设置、缓存、数据库）。
    case persistence
    /// 构建、依赖、CI 配置。
    case buildConfig
    /// 无测试改动。
    case noTests
    /// 影响面大（文件多或行数多）。
    case wideBlast

    var weight: Int {
        switch self {
        case .regression, .silentFailure, .publicAPI: return 3
        case .boundaryArithmetic, .concurrency, .persistence: return 2
        case .buildConfig, .noTests: return 2
        case .wideBlast: return 1
        }
    }

    var title: String {
        switch self {
        case .regression: return "回归修复"
        case .silentFailure: return "静默失败"
        case .publicAPI: return "公共 API"
        case .boundaryArithmetic: return "边界算术"
        case .concurrency: return "并发"
        case .persistence: return "持久化"
        case .buildConfig: return "构建配置"
        case .noTests: return "无测试"
        case .wideBlast: return "影响面大"
        }
    }
}

// MARK: - 符号

enum SymbolKind: String, Codable {
    case function
    case type
    case property

    var title: String {
        switch self {
        case .function: return "函数"
        case .type: return "类型"
        case .property: return "属性"
        }
    }
}

enum SymbolChange: String, Codable {
    case added
    case removed

    var symbol: String { self == .added ? "+" : "−" }
}

/// 从 diff 中识别出的声明级变化。
struct ChangedSymbol: Identifiable, Hashable {
    let name: String
    let kind: SymbolKind
    let change: SymbolChange
    let path: String

    var id: String { "\(path)|\(kind.rawValue)|\(name)|\(change.rawValue)" }
    var display: String { "\(kind.title) \(name)" }
}

// MARK: - 文件与提交

struct CommitFileChange: Identifiable, Hashable {
    let path: String
    let added: Int
    let removed: Int
    let layer: ChangeLayer
    let symbols: [ChangedSymbol]

    var id: String { path }
    var fileName: String { (path as NSString).lastPathComponent }
    var churn: Int { added + removed }
    var isTest: Bool { path.contains("/Tests/") || path.hasSuffix("Tests.swift") }
    var isSwift: Bool { path.hasSuffix(".swift") }
}

/// 分析器输入：一次提交及其原始 diff 文本。
struct RawCommit {
    let hash: String
    let shortHash: String
    let subject: String
    let body: String
    let author: String
    let date: Date
    /// (path, added, removed)，来自 `git show --numstat`。
    let numstat: [(path: String, added: Int, removed: Int)]
    /// 完整补丁文本，来自 `git show --format= --unified=3`。
    let diffText: String
}

/// 分析结果。
struct ReviewEntry: Identifiable {
    let id: String
    let shortHash: String
    let subject: String
    let author: String
    let date: Date
    let layer: ChangeLayer
    let files: [CommitFileChange]
    let signals: [RiskSignal]
    let score: Int
    let summary: String
    let added: Int
    let removed: Int

    var businessFiles: [CommitFileChange] { files.filter { $0.layer != .technical } }
    var technicalFiles: [CommitFileChange] { files.filter { $0.layer != .business } }
    var symbols: [ChangedSymbol] { files.flatMap(\.symbols) }

    /// 重要度分级：≥6 展开，3–5 摘要，<3 折叠。
    var importance: Importance {
        if score >= 6 { return .high }
        if score >= 3 { return .medium }
        return .low
    }

    enum Importance: String {
        case high, medium, low
        var title: String {
            switch self {
            case .high: return "高"
            case .medium: return "中"
            case .low: return "低"
            }
        }
    }
}

// MARK: - 分析器

enum ChangeReviewAnalyzer {

    // MARK: 入口

    static func analyze(_ raw: RawCommit) -> ReviewEntry {
        let diff = DiffScan(diffText: raw.diffText)

        let files: [CommitFileChange] = raw.numstat.map { item in
            CommitFileChange(
                path: item.path,
                added: item.added,
                removed: item.removed,
                layer: LayerClassifier.layer(for: item.path),
                symbols: diff.symbols.filter { $0.path == item.path }
            )
        }

        let layer = commitLayer(files: files)
        let signals = riskSignals(raw: raw, files: files, diff: diff)
        let score = signals.reduce(0) { $0 + $1.weight }

        return ReviewEntry(
            id: raw.hash,
            shortHash: raw.shortHash,
            subject: raw.subject,
            author: raw.author,
            date: raw.date,
            layer: layer,
            files: files,
            signals: signals,
            score: score,
            summary: summary(raw: raw, files: files, layer: layer, signals: signals),
            added: files.reduce(0) { $0 + $1.added },
            removed: files.reduce(0) { $0 + $1.removed }
        )
    }

    // MARK: 分层

    private static func commitLayer(files: [CommitFileChange]) -> ChangeLayer {
        guard !files.isEmpty else { return .technical }
        let hasBusiness = files.contains { $0.layer != .technical }
        let hasTechnical = files.contains { $0.layer != .business }
        if hasBusiness && hasTechnical { return .both }
        return hasBusiness ? .business : .technical
    }

    // MARK: 风险信号

    private static func riskSignals(
        raw: RawCommit,
        files: [CommitFileChange],
        diff: DiffScan
    ) -> [RiskSignal] {
        var signals: [RiskSignal] = []
        let text = (raw.subject + "\n" + raw.body).lowercased()

        if text.contains("回归") || text.contains("regression") || text.contains("revert")
            || text.contains("回退") {
            signals.append(.regression)
        }

        // 静默失败：新增的吞错路径（不包含循环里的 `continue`——那是控制流，不是吞错）。
        let swallowPatterns = ["try? ", "catch {", "catch{}", "?? nil", "// ignore error"]
        if diff.addedLines.contains(where: { line in
            swallowPatterns.contains { line.contains($0) }
        }) {
            signals.append(.silentFailure)
        }

        if diff.addedLines.contains(where: isPublicDeclaration)
            || diff.removedLines.contains(where: isPublicDeclaration) {
            signals.append(.publicAPI)
        }

        let arithmeticHints = ["nsrange(", ".location", "offset", "anchor", "range.max", "index("]
        if diff.addedLines.contains(where: { line in
            arithmeticHints.contains { line.lowercased().contains($0) }
        }) {
            signals.append(.boundaryArithmetic)
        }

        if diff.addedLines.contains(where: { line in
            line.contains("@MainActor") || line.contains("Task {") || line.contains("await ")
        }) {
            signals.append(.concurrency)
        }

        if files.contains(where: { $0.path.contains("Settings") || $0.path.contains("Store") })
            || diff.addedLines.contains(where: { $0.contains("init(from decoder") }) {
            signals.append(.persistence)
        }

        if files.contains(where: { isBuildConfigPath($0.path) }) {
            signals.append(.buildConfig)
        }

        let touchesCode = files.contains { $0.isSwift && !$0.isTest }
        let touchesTests = files.contains(where: \.isTest)
        if touchesCode && !touchesTests {
            signals.append(.noTests)
        }

        if files.count >= 8 || files.reduce(0, { $0 + $1.churn }) >= 300 {
            signals.append(.wideBlast)
        }

        return RiskSignal.allCases.filter { signals.contains($0) }
    }

    private static func isPublicDeclaration(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("public ") || trimmed.hasPrefix("open ") else { return false }
        return ["func ", "var ", "let ", "class ", "struct ", "enum ", "protocol "]
            .contains { trimmed.contains($0) }
    }

    private static func isBuildConfigPath(_ path: String) -> Bool {
        path.hasSuffix("Package.swift") || path.hasSuffix("Package.resolved")
            || path.hasSuffix(".pbxproj") || path.hasPrefix(".github/")
            || path.hasPrefix("scripts/") || path.hasPrefix("Configs/")
    }

    // MARK: 摘要

    /// 确定性的中文摘要。模型不可用时由它兜底，也作为模型输出的校验基准。
    private static func summary(
        raw: RawCommit,
        files: [CommitFileChange],
        layer: ChangeLayer,
        signals: [RiskSignal]
    ) -> String {
        let business = files.filter { $0.layer != .technical }.count
        let technical = files.filter { $0.layer != .business }.count
        let added = files.reduce(0) { $0 + $1.added }
        let removed = files.reduce(0) { $0 + $1.removed }

        var parts: [String] = []
        let notable = signals.filter { $0.weight >= 2 }.map(\.title)
        if !notable.isEmpty {
            parts.append(notable.prefix(3).joined(separator: " / "))
        }
        parts.append("\(files.count) 个文件 +\(added) −\(removed)（业务 \(business) · 技术 \(technical)）")
        if signals.contains(.noTests) {
            parts.append("无测试改动")
        }
        if files.isEmpty {
            parts.append("无文件变化")
        }
        return parts.joined(separator: "；")
    }
}

// MARK: - 分层规则

enum LayerClassifier {
    /// 技术架构目录/文件。命中即判技术层；其余归业务层。
    private static let technicalPrefixes: [String] = [
        "CodeEdit/Utils/",
        "CodeEdit/Features/LSP/",
        "CodeEdit/Features/Diagnostics/",
        "CodeEdit/AppDelegate.swift",
        "CodeEdit/Info.plist",
        "scripts/",
        ".github/",
        "Configs/",
        "CodeEdit.xcodeproj/",
        "CodeEditTests/",
        "CodeEditUITests/",
        "Documentation.docc/",
        "docs/"
    ]

    private static let technicalFiles: Set<String> = [
        "Package.swift",
        "Package.resolved",
        "README.md",
        "NOTICE.md",
        "LICENSE.md",
        "CONTRIBUTING.md",
        "CODE_OF_CONDUCT.md"
    ]

    static func layer(for path: String) -> ChangeLayer {
        if technicalFiles.contains(path) { return .technical }
        if technicalPrefixes.contains(where: { path.hasPrefix($0) }) { return .technical }
        if path.contains("/Tests/") || path.hasSuffix("Tests.swift") { return .technical }
        return .business
    }
}

// MARK: - Diff 扫描

/// 从统一 diff 文本中提取行统计、符号与样本行。
struct DiffScan {
    let hunks: Int
    let addedLines: [String]
    let removedLines: [String]
    let symbols: [ChangedSymbol]

    init(diffText: String) {
        var hunkCount = 0
        var added: [String] = []
        var removed: [String] = []
        var symbols: [ChangedSymbol] = []
        var currentPath = ""

        for rawLine in diffText.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.hasPrefix("+++ b/") {
                currentPath = String(line.dropFirst(6))
                continue
            }
            if line.hasPrefix("@@") {
                hunkCount += 1
                continue
            }
            if line.hasPrefix("+"), !line.hasPrefix("+++") {
                let content = String(line.dropFirst())
                added.append(content)
                if let symbol = SymbolParser.parse(content, path: currentPath, change: .added) {
                    symbols.append(symbol)
                }
                continue
            }
            if line.hasPrefix("-"), !line.hasPrefix("---") {
                let content = String(line.dropFirst())
                removed.append(content)
                if let symbol = SymbolParser.parse(content, path: currentPath, change: .removed) {
                    symbols.append(symbol)
                }
                continue
            }
        }

        // 同一符号在 add/remove 两侧都出现 → 视为修改，保留「新增」一条并去重。
        var seen = Set<String>()
        var deduped: [ChangedSymbol] = []
        for symbol in symbols {
            let key = "\(symbol.path)|\(symbol.kind.rawValue)|\(symbol.name)"
            if seen.insert(key).inserted {
                deduped.append(symbol)
            }
        }

        self.hunks = hunkCount
        self.addedLines = added
        self.removedLines = removed
        self.symbols = deduped
    }
}

enum SymbolParser {
    private static let typeRegex = try? NSRegularExpression(
        pattern: #"^\s*(?:public\s+|open\s+|internal\s+|private\s+|fileprivate\s+)?(?:final\s+)?(class|struct|enum|protocol|extension|actor)\s+([A-Za-z_][A-Za-z0-9_]*)"#
    )
    private static let funcRegex = try? NSRegularExpression(
        pattern: #"^\s*(?:public\s+|open\s+|internal\s+|private\s+|fileprivate\s+)?(?:static\s+|class\s+)?(?:override\s+|mutating\s+|nonisolated\s+|async\s+)*func\s+([A-Za-z_][A-Za-z0-9_]*)"#
    )
    private static let propertyRegex = try? NSRegularExpression(
        pattern: #"^\s*(?:public\s+|open\s+|internal\s+|private\s+|fileprivate\s+)?(?:static\s+)?(?:var|let)\s+([A-Za-z_][A-Za-z0-9_]*)"#
    )

    static func parse(_ line: String, path: String, change: SymbolChange) -> ChangedSymbol? {
        guard path.hasSuffix(".swift") else { return nil }
        let range = NSRange(location: 0, length: (line as NSString).length)

        if let regex = typeRegex,
           let match = regex.firstMatch(in: line, range: range),
           let nameRange = Range(match.range(at: 2), in: line) {
            return ChangedSymbol(
                name: String(line[nameRange]),
                kind: .type,
                change: change,
                path: path
            )
        }
        if let regex = funcRegex,
           let match = regex.firstMatch(in: line, range: range),
           let nameRange = Range(match.range(at: 1), in: line) {
            return ChangedSymbol(
                name: String(line[nameRange]),
                kind: .function,
                change: change,
                path: path
            )
        }
        if let regex = propertyRegex,
           let match = regex.firstMatch(in: line, range: range),
           let nameRange = Range(match.range(at: 1), in: line) {
            // 只保留「存储属性声明」：带访问修饰符，或带类型标注且不是一行赋值。
            // 否则 `var anchor = lineRange.location` 这类局部变量会淹没真正的声明变化。
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let hasAccessModifier = ["public", "open", "internal", "private", "fileprivate", "static"]
                .contains { trimmed.hasPrefix($0 + " ") }
            let looksLikeDeclaration = line.contains(": ") && !line.contains("=")
            guard hasAccessModifier || looksLikeDeclaration else { return nil }
            return ChangedSymbol(
                name: String(line[nameRange]),
                kind: .property,
                change: change,
                path: path
            )
        }
        return nil
    }
}
