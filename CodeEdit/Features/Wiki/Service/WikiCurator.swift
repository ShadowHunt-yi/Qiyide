//
//  WikiCurator.swift
//  CodeEdit
//
//  知识库的 AI 维护者：把一次改动沉淀成一条知识草稿。
//
//  定位：知识库主要由 AI 维护，人只做确认与校正。因此这里产出的永远是
//  `status: draft`，必须由人点「确认」才成为可信知识——模型可以写，但不能替人背书。
//
//  两个防呆设计：
//  1. 先把现有条目摘要喂给模型，让它自己判断「这是新知识还是对已有条目的补充」，
//     避免同一个概念每次改动都新建一条；
//  2. 只接受严格 JSON，解析失败就报错，不做「从散文里猜结构」的兜底——
//     猜出来的知识比没有知识更糟。
//

import Foundation

// MARK: - 输入与产物

struct WikiCurationInput {
    /// 提交标题或「未提交改动」。
    let subject: String
    /// 改动的文件路径。
    let files: [String]
    /// 命中的风险信号（可空）。
    let signals: [String]
    /// 补丁原文，内部按配置截断。
    let diff: String
}

struct WikiDraft {
    enum Action: String {
        case create
        case update
    }

    /// 命中已有条目时怎么合并。
    enum MergeMode {
        /// 追加一段「补充」：适合一次改动带来的增量知识，原文必须保留。
        case append
        /// 整块替换：适合重复建档——同一模块跑十轮不能追加十段互相矛盾的结论。
        case replace
    }

    var action: Action
    /// action == .update 时指向已有条目的标题。
    var target: String
    var title: String
    var type: WikiEntryType
    var tags: [String]
    var relations: [WikiRelation]
    var body: String
    /// 模型给出的「为什么值得记录」，只在确认界面展示，不写入正文。
    var reason: String
    /// 关联代码路径，取自本次改动的文件列表。
    var sources: [String]
    /// 默认按增量追加，建档流程显式传 replace。
    var mergeMode: MergeMode = .append
}

enum WikiCuratorError: LocalizedError {
    case notConfigured(String)
    case invalidResponse(String)
    case emptyContent

    var errorDescription: String? {
        switch self {
        case .notConfigured(let reason): return reason
        case .invalidResponse(let raw): return "模型返回的不是预期的 JSON：\(raw)"
        case .emptyContent: return "模型没有返回可用的知识内容"
        }
    }
}

// MARK: - 维护者

@MainActor
enum WikiCurator {

    static let promptVersion = "wiki-v1"

    /// 生成一条草稿。失败时抛出可读错误，不静默降级——知识库宁可不写，也不要写错。
    static func propose(
        input: WikiCurationInput,
        existing: [WikiEntry]
    ) async throws -> WikiDraft {
        let store = AINarrativeStore.shared
        guard let provider = store.makeProvider() else {
            throw WikiCuratorError.notConfigured(store.blockedReason ?? "模型未配置")
        }
        guard let request = store.makeRequest(
            system: systemPrompt(),
            user: userPrompt(input: input, existing: existing)
        ) else {
            throw WikiCuratorError.notConfigured(store.blockedReason ?? "模型未配置")
        }

        // 偶发空响应时重试比让人手动再点一次更省事；间隔一下，避免连击触发限流。
        var lastError: Error = WikiCuratorError.emptyContent
        // 逐次加大预算：推理模型可能把预算全花在思考上，导致正文为空。
        let budgets = [2048, 4096, 4096]
        for attempt in 0..<3 {
            if attempt > 0 {
                try? await Task.sleep(nanoseconds: 1_200_000_000)
            }
            do {
                let raw = try await provider.complete(request.withMaxTokens(budgets[attempt]))
                if let draft = parse(raw) { return draft }
                lastError = WikiCuratorError.invalidResponse(String(raw.prefix(160)))
            } catch {
                lastError = WikiCuratorError.invalidResponse(AINarrativeError.describe(error))
            }
        }
        throw lastError
    }

    // MARK: 提示词

    static func systemPrompt() -> String {
        """
        你是这个代码仓库的知识库维护者。你的工作不是复述这次改了什么，而是判断：
        这次改动里有没有**可复用的判断**值得沉淀下来，供以后的人和 AI 参考。

        值得记录的：设计取舍与理由、踩过的坑与边界条件、模块职责边界、必须遵守的约定。
        不值得记录的：这次加了哪个函数、改了哪几行、提交本身的过程。

        规则：
        1. 只输出一个 JSON 对象，不要 Markdown 代码块，不要任何解释文字。
        2. 如果现有条目已经覆盖了同样的判断，返回 update 并给出该条目标题；
           否则返回 create。
        3. 正文用 2 到 5 句中文，写判断和理由，不写「本次提交」这类过程描述。
        4. 不确定的内容不要写，宁可少写一句。

        JSON 结构：
        {"action":"create|update","target":"已有条目标题，create 时为空串",
         "title":"条目标题","type":"topic|decision|module|rule|term|incident",
         "tags":["标签"],"relations":[{"kind":"属于","target":"已有条目标题"}],
         "body":"正文","reason":"为什么值得记录"}
        """
    }

    static func userPrompt(input: WikiCurationInput, existing: [WikiEntry]) -> String {
        var lines: [String] = []
        lines.append("本次改动：\(input.subject)")

        let fileList = input.files.prefix(12).joined(separator: "\n- ")
        if !fileList.isEmpty {
            lines.append("改动文件：\n- \(fileList)")
        }
        if !input.signals.isEmpty {
            lines.append("命中信号：\(input.signals.joined(separator: "、"))")
        }

        if !existing.isEmpty {
            lines.append("")
            lines.append("现有条目（标题 · 类型 · 摘要）：")
            for entry in existing.prefix(12) {
                let summary = entry.summary.replacingOccurrences(of: "\n", with: " ")
                lines.append("- \(entry.title) · \(entry.type.title) · \(String(summary.prefix(60)))")
            }
        }

        let diff = AINarrativePrompt.truncate(
            input.diff,
            limit: AINarrativeStore.shared.configuration.normalized().diffCharacters
        )
        if !diff.isEmpty {
            lines.append("")
            lines.append("补丁：")
            lines.append(diff)
        }

        lines.append("")
        lines.append("请判断是否值得沉淀，并按 JSON 结构输出。")
        // 与叙述层共用同一套脱敏规则，避免把敏感值发给模型。
        return AINarrativeRedactor.redact(lines.joined(separator: "\n")).text
    }

    // MARK: 解析

    static func parse(_ raw: String) -> WikiDraft? {
        guard let jsonText = extractJSON(from: raw),
              let data = jsonText.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let body = (object["body"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return nil }

        let title = (object["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }

        let action = WikiDraft.Action(rawValue: object["action"] as? String ?? "create") ?? .create
        let target = (object["target"] as? String ?? "").trimmingCharacters(in: .whitespaces)

        var relations: [WikiRelation] = []
        if let items = object["relations"] as? [[String: Any]] {
            relations = items.compactMap { item in
                let target = (item["target"] as? String ?? "").trimmingCharacters(in: .whitespaces)
                guard !target.isEmpty else { return nil }
                let kind = (item["kind"] as? String ?? "").trimmingCharacters(in: .whitespaces)
                return WikiRelation(kind: kind.isEmpty ? "相关" : kind, target: target)
            }
        }

        return WikiDraft(
            action: action,
            target: target,
            title: title,
            type: WikiEntryType(rawValue: object["type"] as? String ?? "") ?? .topic,
            tags: (object["tags"] as? [String] ?? []).filter { !$0.isEmpty },
            relations: relations,
            body: body,
            reason: (object["reason"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            sources: []
        )
    }

    /// 模型偶尔会包一层 ```json 或前后加寒暄，这里只取最外层的花括号。
    private static func extractJSON(from raw: String) -> String? {
        guard let start = raw.firstIndex(of: "{"),
              let end = raw.lastIndex(of: "}"),
              start < end else {
            return nil
        }
        return String(raw[start...end])
    }
}
