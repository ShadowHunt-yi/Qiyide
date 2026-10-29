//
//  AINarrativeRedactor.swift
//  CodeEdit
//
//  发送给模型之前的脱敏。
//
//  为什么必须在客户端做：
//  1. 补丁里天然会带测试数据——手机号、身份证、邮箱、测试密钥；
//  2. 企业网关普遍有内容审核，命中就直接拒绝（实测某网关返回
//     `sensitive contain:["手机号",":198..."]`，流式下还会吞成空响应）；
//  3. 叙述只描述「改了什么」，这几类值对生成质量没有贡献，脱敏是无损的。
//
//  只替换成固定占位符，不改变行数结构，diff 的可读性不受影响。
//

import Foundation

enum AINarrativeRedactor {

    struct Result {
        let text: String
        /// 命中的敏感片段数，用于界面提示「已脱敏 N 处」。
        let hits: Int
    }

    private struct Rule {
        let pattern: String
        let replacement: String
        let regex: NSRegularExpression
    }

    private static let rules: [Rule] = {
        let definitions: [(String, String)] = [
            // 中国大陆手机号
            ("(?<![0-9])1[3-9][0-9]{9}(?![0-9])", "[手机号]"),
            // 18 位身份证（末位可为 X）
            (
                "(?<![0-9])[1-9][0-9]{5}(?:19|20)[0-9]{2}(?:0[1-9]|1[0-2])(?:0[1-9]|[12][0-9]|3[01])" +
                "[0-9]{3}[0-9Xx](?![0-9Xx])",
                "[身份证]"
            ),
            // 邮箱
            ("[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}", "[邮箱]"),
            // 常见密钥前缀
            ("(?i)\\b(?:sk|ak|pk|ghp|gho|xox[baprs])[-_][A-Za-z0-9_-]{16,}", "[密钥]"),
            // Bearer token
            ("(?i)\\bbearer\\s+[A-Za-z0-9._-]{20,}", "Bearer [密钥]"),
            // 16–19 位连续数字（银行卡 / 长账号）
            ("(?<![0-9])[0-9]{16,19}(?![0-9])", "[长数字]")
        ]
        return definitions.compactMap { pattern, replacement in
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
            return Rule(pattern: pattern, replacement: replacement, regex: regex)
        }
    }()

    /// 对整段提示词脱敏。返回替换后的文本与命中次数。
    static func redact(_ text: String) -> Result {
        guard !text.isEmpty else { return Result(text: text, hits: 0) }
        var output = text
        var hits = 0

        for rule in rules {
            // 每次替换后字符串长度变化，重新取 range。
            let range = NSRange(output.startIndex..<output.endIndex, in: output)
            let matches = rule.regex.numberOfMatches(in: output, range: range)
            if matches == 0 { continue }
            hits += matches
            output = rule.regex.stringByReplacingMatches(
                in: output,
                range: range,
                withTemplate: rule.replacement
            )
        }
        return Result(text: output, hits: hits)
    }
}
