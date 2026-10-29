//
//  WikiEntry.swift
//  CodeEdit
//
//  知识条目：一个 Markdown 文件 = 一条知识。
//
//  为什么用「文件即条目」：
//  - 随仓库走，能被 code review，也能 git diff 出知识是怎么演进的；
//  - 外部编辑器改完，索引重新扫描即可生效，不需要额外的同步机制。
//
//  前置声明用手写 key: value，而不是 YAML：
//  只要支持标题/类型/标签/来源/关系五个字段，自己解析比引入 YAML 依赖更可控，
//  也能容忍用户手抖写错而不至于整条读不出来。
//

import Foundation

// MARK: - 类型

enum WikiEntryType: String, CaseIterable, Identifiable, Codable {
    case topic
    case decision
    case module
    case rule
    case term
    case incident

    var id: String { rawValue }

    var title: String {
        switch self {
        case .topic: return "主题"
        case .decision: return "决策"
        case .module: return "模块"
        case .rule: return "规范"
        case .term: return "术语"
        case .incident: return "事故"
        }
    }

    /// 图谱里用来判断「同类聚在一起」的权重。
    var clusterKey: String { rawValue }
}

// MARK: - 状态

/// 草稿由 AI 生成、等待人确认；已确认的条目才会被当作可信知识使用。
enum WikiStatus: String, Codable {
    case draft
    case confirmed

    var title: String {
        switch self {
        case .draft: return "草稿"
        case .confirmed: return "已确认"
        }
    }
}

// MARK: - 关系

/// 条目之间的关系。kind 是自由词（属于/导致/约束/依赖），不预设枚举——
/// 团队的说法各不相同，硬编码只会逼人造假。
struct WikiRelation: Hashable {
    var kind: String
    var target: String

    var display: String { "\(kind)·\(target)" }
}

// MARK: - 条目

struct WikiEntry: Identifiable, Hashable {
    /// 文件名（不含扩展名），重命名标题不会改它，保证链接稳定。
    let id: String
    var title: String
    var type: WikiEntryType
    var tags: [String]
    /// 关联的代码路径。审查时用它匹配改动文件。
    var sources: [String]
    var relations: [WikiRelation]
    var body: String
    var updatedAt: Date
    var fileURL: URL
    /// AI 起草、尚未被人确认的条目为 draft。
    var status: WikiStatus = .confirmed
    /// 生成这条内容所用的模型标识，便于事后追溯「这句话是谁写的」。
    var generatedBy: String = ""

    /// 归一化后的标题，用于解析 `[[链接]]`。
    var normalizedTitle: String { WikiEntry.normalize(title) }

    var isDraft: Bool { status == .draft }

    /// 界面显示用的短标题。
    ///
    /// 知识单元的名字是仓库相对路径，Java 项目动辄一百多字符，
    /// 列表里按行截断只会留下开头那截 `saas-plus-ai-platform-app/src/...`，
    /// 最关键的末段反而看不见。这里取「末两段」，保留语义又不占地方。
    var displayTitle: String {
        let parts = title.split(separator: "/")
        guard parts.count > 2 else { return title }
        return parts.suffix(2).joined(separator: "/")
    }

    var summary: String {
        let firstLine = body
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !$0.hasPrefix("#") }
        return firstLine ?? ""
    }

    static func normalize(_ title: String) -> String {
        title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

// MARK: - 解析与序列化

extension WikiEntry {

    /// 从文件正文解析。缺字段一律给默认值，绝不因为格式问题丢弃整条知识。
    static func parse(text: String, fileURL: URL) -> WikiEntry {
        var title = fileURL.deletingPathExtension().lastPathComponent
        var type: WikiEntryType = .topic
        var tags: [String] = []
        var sources: [String] = []
        var relations: [WikiRelation] = []
        var body = text
        var status: WikiStatus = .confirmed
        var generatedBy = ""
        var updatedAt = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? Date()

        if let header = frontmatter(in: text) {
            body = header.body
            for line in header.lines {
                guard let separator = line.firstIndex(of: ":") else { continue }
                let key = line[..<separator].trimmingCharacters(in: .whitespaces).lowercased()
                let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
                switch key {
                case "title":
                    if !value.isEmpty { title = value }
                case "type":
                    type = WikiEntryType(rawValue: value.lowercased()) ?? .topic
                case "tags":
                    tags = splitList(value)
                case "sources", "source":
                    sources = splitList(value)
                case "relations":
                    relations = parseRelations(value)
                case "status":
                    status = WikiStatus(rawValue: value.lowercased()) ?? .confirmed
                case "generated":
                    generatedBy = value
                case "updated":
                    if let date = ISO8601DateFormatter().date(from: value) { updatedAt = date }
                default:
                    continue
                }
            }
        }

        let name = fileURL.deletingPathExtension().lastPathComponent
        return WikiEntry(
            id: name,
            title: title,
            type: type,
            tags: tags,
            sources: sources,
            relations: relations,
            body: body.trimmingCharacters(in: .whitespacesAndNewlines),
            updatedAt: updatedAt,
            fileURL: fileURL,
            status: status,
            generatedBy: generatedBy
        )
    }

    /// 序列化回 Markdown。字段顺序固定，便于 diff 阅读。
    func markdown() -> String {
        var lines: [String] = ["---"]
        lines.append("title: \(title)")
        lines.append("type: \(type.rawValue)")
        if !tags.isEmpty { lines.append("tags: \(tags.joined(separator: ", "))") }
        if !sources.isEmpty { lines.append("sources: \(sources.joined(separator: ", "))") }
        if !relations.isEmpty {
            lines.append("relations: \(relations.map { "\($0.kind):\($0.target)" }.joined(separator: "; "))")
        }
        lines.append("status: \(status.rawValue)")
        if !generatedBy.isEmpty { lines.append("generated: \(generatedBy)") }
        lines.append("updated: \(ISO8601DateFormatter().string(from: updatedAt))")
        lines.append("---")
        lines.append("")
        lines.append(body)
        lines.append("")
        return lines.joined(separator: "\n")
    }

    // MARK: 内部工具

    private static func frontmatter(in text: String) -> (lines: [String], body: String)? {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        guard normalized.hasPrefix("---") else { return nil }
        let parts = normalized.components(separatedBy: "\n")
        guard parts.first?.trimmingCharacters(in: .whitespaces) == "---" else { return nil }
        var collected: [String] = []
        var closingIndex: Int?
        for index in 1..<parts.count where parts[index].trimmingCharacters(in: .whitespaces) == "---" {
            closingIndex = index
            break
        }
        guard let closingIndex else { return nil }
        collected = Array(parts[1..<closingIndex])
        let body = parts[(closingIndex + 1)...].joined(separator: "\n")
        return (collected, body)
    }

    private static func splitList(_ value: String) -> [String] {
        value
            .split(whereSeparator: { $0 == "," || $0 == "，" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private static func parseRelations(_ value: String) -> [WikiRelation] {
        value
            .split(separator: ";")
            .compactMap { item -> WikiRelation? in
                let text = item.trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty else { return nil }
                guard let separator = text.firstIndex(of: ":") else {
                    // 只写了目标没写关系词，按「相关」处理，不丢信息。
                    return WikiRelation(kind: "相关", target: text)
                }
                let kind = String(text[..<separator]).trimmingCharacters(in: .whitespaces)
                let target = String(text[text.index(after: separator)...])
                    .trimmingCharacters(in: .whitespaces)
                guard !target.isEmpty else { return nil }
                return WikiRelation(kind: kind.isEmpty ? "相关" : kind, target: target)
            }
    }
}
