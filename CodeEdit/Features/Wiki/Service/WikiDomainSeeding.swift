//
//  WikiDomainSeeding.swift
//  CodeEdit
//
//  把锁定的领域模型落成知识条目。
//
//  为什么用模板而不是直接调模型：
//  1. 领域模型里的信息（模块清单、类数、负责人、判定依据）本来就是结构化的，
//     拼成 Markdown 比让模型复述更准确，也不会编造；
//  2. 没配模型时也得能用——建模是基础能力，不该依赖外部服务；
//  3. 生成的是**草稿**，正文里明确留出「为什么这样设计」的空位，
//     等人补上再确认。模型写不出设计意图，只有人知道。
//
//  想让模型补全时，走已有的 `WikiCurator`（「AI 整理」菜单），不要在这里塞两次调用。
//

import Foundation

enum WikiDomainSeeding {

    struct Result: Sendable {
        var created: Int = 0
        var skipped: Int = 0
        var titles: [String] = []
        var warnings: [String] = []
    }

    /// 从领域模型生成草稿条目。
    /// - Parameters:
    ///   - graph: 已锁定的领域模型。
    ///   - store: 知识库存储。
    /// - Note: `WikiStore` 是 `@MainActor`，生成量只有几个域、每次写一个文件，
    ///         留在主线程足够快，也避免把文件写入和 UI 状态拆到两个线程。
    @MainActor
    static func seed(graph: MindGraph, into store: WikiStore) throws -> Result {
        var result = Result()
        guard !graph.domains.isEmpty else {
            result.warnings.append("领域模型为空，先完成识别与锚定")
            return result
        }

        for domain in graph.domains {
            let title = domain.displayTitle

            // 已存在同名条目就跳过：人工改过的内容不能被重新生成覆盖。
            if store.entry(titled: title) != nil {
                result.skipped += 1
                continue
            }

            var entry = try store.create(type: .module, title: title)
            entry.tags = ["domain", domain.kind.title]
            entry.sources = sources(for: domain, in: graph)
            entry.body = body(for: domain, in: graph)
            entry.status = .draft
            entry.generatedBy = "领域建模"
            try store.save(entry)

            result.created += 1
            result.titles.append(title)
        }

        return result
    }

    // MARK: 正文

    /// 关联代码路径：域本身 + 展开的模块，最多 8 条，避免 frontmatter 过长。
    private static func sources(for domain: MindNode, in graph: MindGraph) -> [String] {
        var paths = domain.packages
        for child in graph.children(of: domain.id) {
            paths.append(contentsOf: child.packages)
        }
        var seen = Set<String>()
        return paths
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .prefix(8)
            .map { $0 }
    }

    private static func body(for domain: MindNode, in graph: MindGraph) -> String {
        var lines: [String] = []

        lines.append("> 本条目由领域建模自动生成，正文只含事实。")
        lines.append("> **请补充「为什么这样设计」「改动时要注意什么」，然后确认。**")
        lines.append("")

        // 规模
        lines.append("## 规模")
        lines.append("")
        lines.append("- \(domain.classCount) 个类，\(domain.fileCount) 个文件")
        if !domain.packages.isEmpty {
            lines.append("- 主包：`\(domain.packages.first ?? "")`")
        }
        lines.append("")

        // 包含模块
        let children = graph.children(of: domain.id).sorted { $0.classCount > $1.classCount }
        if !children.isEmpty {
            lines.append("## 包含模块")
            lines.append("")
            lines.append("| 模块 | 类数 |")
            lines.append("| --- | --- |")
            for child in children.prefix(20) {
                lines.append("| \(child.displayTitle) | \(child.classCount) |")
            }
            if children.count > 20 {
                lines.append("| …还有 \(children.count - 20) 个 | |")
            }
            lines.append("")
        }

        // 负责人
        if !domain.owner.authors.isEmpty {
            lines.append("## 负责人")
            lines.append("")
            if let manual = domain.owner.manual, !manual.isEmpty {
                lines.append("- 指定：\(manual)")
            }
            for author in domain.owner.authors.prefix(4) {
                lines.append("- \(author.name)（\(author.commits) 次提交）")
            }
            lines.append("")
        }

        // 判定依据：这是模型给出的「为什么算一个域」，最值得留档
        if !domain.evidence.isEmpty {
            lines.append("## 判定依据")
            lines.append("")
            for item in domain.evidence {
                lines.append("- **\(item.kind.title)**：\(item.detail)")
            }
            lines.append("")
        }

        // 留白：让人补设计意图
        lines.append("## 设计意图（待补充）")
        lines.append("")
        lines.append("- 这个域解决什么问题？")
        lines.append("- 为什么边界划在这里，而不是别的包？")
        lines.append("- 改动时必须同时关注哪些模块？")
        lines.append("")

        return lines.joined(separator: "\n")
    }
}
