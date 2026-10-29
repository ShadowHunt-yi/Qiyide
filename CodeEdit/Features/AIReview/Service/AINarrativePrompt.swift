//
//  AINarrativePrompt.swift
//  CodeEdit
//
//  把确定性分析结果拼成提示词。
//
//  设计要点：模型只拿到「已经算好的事实 + 截断的补丁」，
//  输入里不存在让它重新分层的空间，输出也只被当作叙述文本使用。
//

import Foundation

/// 提示词与脱敏统计。
struct AINarrativePromptOutput {
    let text: String
    /// 发送前替换掉的敏感片段数（手机号、身份证、邮箱、密钥等）。
    let redactions: Int
}

enum AINarrativePrompt {

    /// 提示词版本。改动措辞时递增，缓存键随之失效，避免新旧叙述混用。
    static let version = "v1"

    static func system() -> String {
        """
        你是一名资深代码评审者，正在为一次 Git 提交写中文审查说明。

        规则：
        1. 只输出 2 到 4 句自然语言，不用标题、不用列表、不用 Markdown 语法。
        2. 第一句说清这次改动做了什么；第二句说影响面；如有必要，最后一句指出人工重点核对的位置。
        3. 只能依据给出的信息，不要推测未出现的文件、函数或意图。
        4. 不要复述「分层」「评分」「重要度」这些已经算好的结论，也不要重新评判它们。
        5. 语气克制，不用「非常」「极大地」这类程度副词。
        """
    }

    static func user(for entry: ReviewEntry, diff: String, limit: Int) -> AINarrativePromptOutput {
        var lines: [String] = []
        lines.append("提交：\(entry.subject)")
        lines.append("作者：\(entry.author)")
        lines.append("改动规模：+\(entry.added) −\(entry.removed)，\(entry.files.count) 个文件")

        let testFiles = entry.files.filter(\.isTest)
        lines.append("测试文件：\(testFiles.isEmpty ? "无" : testFiles.map(\.path).joined(separator: ", "))")

        let businessFiles = entry.businessFiles.map(\.fileName)
        let technicalFiles = entry.technicalFiles.map(\.fileName)
        if !businessFiles.isEmpty {
            lines.append("业务侧文件：\(businessFiles.prefix(8).joined(separator: ", "))")
        }
        if !technicalFiles.isEmpty {
            lines.append("技术侧文件：\(technicalFiles.prefix(8).joined(separator: ", "))")
        }

        let symbols = entry.symbols.prefix(15).map { "\($0.change.symbol)\($0.display)" }
        if !symbols.isEmpty {
            lines.append("声明变化：\(symbols.joined(separator: "，"))")
        }

        if !entry.signals.isEmpty {
            lines.append("命中信号：\(entry.signals.map(\.title).joined(separator: "、"))")
        }

        let patch = truncate(diff, limit: limit)
        if !patch.isEmpty {
            lines.append("")
            lines.append("补丁（unified diff）：")
            lines.append(patch)
        }

        lines.append("")
        lines.append("请按规则输出这段改动的中文说明。")
        // 整段脱敏：提交标题、路径、声明名里同样可能带敏感值。
        let redacted = AINarrativeRedactor.redact(lines.joined(separator: "\n"))
        return AINarrativePromptOutput(text: redacted.text, redactions: redacted.hits)
    }

    /// 头 3/4 + 尾 1/4：提交的开头通常是主要改动，尾部常含收尾与测试。
    static func truncate(_ diff: String, limit: Int) -> String {
        let text = diff.trimmingCharacters(in: .whitespacesAndNewlines)
        guard limit > 0, text.count > limit else { return text }
        let headLength = limit * 3 / 4
        let tailLength = limit - headLength
        let head = String(text.prefix(headLength))
        let tail = String(text.suffix(tailLength))
        return head + "\n…（中间 \(text.count - limit) 字符已省略）…\n" + tail
    }
}
