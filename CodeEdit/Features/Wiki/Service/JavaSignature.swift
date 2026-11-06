//
//  JavaSignature.swift
//  CodeEdit
//
//  从一行 Java 代码里认出「对外可见的声明」。
//
//  用途只有一个：判断一处改动是不是动了接口。只改方法体不算，改了公开方法的
//  参数或返回类型才算。所以这里宁可漏、不可错——认错一行，
//  人就会在待确认里看到一条莫名其妙的「接口变化」，之后就不再相信这个清单了。
//
//  这是按行的启发式，不是语法分析：跨多行的参数表只看得到第一行。
//  对「签名变没变」这个问题够用，因为改参数几乎总会动到声明所在的那一行。
//

import Foundation

enum JavaSignature {

    struct Declaration: Hashable, Sendable {
        /// 方法名或类型名。
        var name: String
        /// 去掉首尾空白、行尾的 `{` 和 `;` 之后的原文，用来比较「同一个名字前后是否一样」。
        var text: String
    }

    /// 这些词开头的行是语句，不是声明。
    private static let statementStarts: Set<String> = [
        "return", "new", "throw", "else", "if", "for", "while", "switch", "case", "do",
        "try", "catch", "assert", "super", "this", "synchronized", "yield"
    ]
    private static let typeKeywords: Set<String> = ["class", "interface", "enum", "record"]

    /// - Parameter inInterface: 所在文件是接口。接口里的方法不写 `public` 也是公开的。
    static func parse(_ line: String, inInterface: Bool) -> Declaration? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first, first.isLetter || first == "<" else { return nil }

        let tokens = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard let head = tokens.first, !statementStarts.contains(head), !tokens.contains("private") else {
            return nil
        }

        // 类型声明：public class X extends Y
        if let offset = tokens.firstIndex(where: { typeKeywords.contains($0) }), offset + 1 < tokens.count,
           tokens.contains("public") || inInterface {
            let name = tokens[offset + 1].prefix { $0.isLetter || $0.isNumber || $0 == "_" }
            return name.isEmpty ? nil : Declaration(name: String(name), text: normalize(trimmed))
        }

        // 方法或构造器：左括号之前至少是「类型 名字」或「修饰符 名字」。
        guard let paren = trimmed.firstIndex(of: "(") else { return nil }
        let before = trimmed[..<paren]
        // 赋值、调用链都不是声明。
        guard !before.contains("="), !before.hasSuffix(".") else { return nil }
        let words = before.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard words.count >= 2, let name = words.last, isIdentifier(name) else { return nil }
        guard tokens.contains("public") || tokens.contains("protected") || inInterface else { return nil }
        return Declaration(name: String(name), text: normalize(trimmed))
    }

    /// 文件是不是接口。只看头部：类型声明总在文件前面。
    static func isInterface(_ text: String) -> Bool {
        for raw in text.split(separator: "\n").prefix(400) {
            let tokens = raw.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard let offset = tokens.firstIndex(where: { typeKeywords.contains(String($0)) }) else { continue }
            // 注释里出现的 interface 不算。
            if let first = tokens.first, first.hasPrefix("*") || first.hasPrefix("//") || first.hasPrefix("/*") {
                continue
            }
            return tokens[offset] == "interface"
        }
        return false
    }

    private static func isIdentifier(_ text: Substring) -> Bool {
        guard let first = text.first, first.isLetter || first == "_" else { return false }
        return text.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    private static func normalize(_ text: String) -> String {
        var result = text
        while let last = result.last, last == "{" || last == ";" || last == " " {
            result.removeLast()
        }
        return result.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
    }

    /// 改动行里，哪些公开声明被改掉或删掉了。
    ///
    /// 判定方式：同一个名字，删除侧有、新增侧没有 → 被删；
    /// 两侧都有但文本不同 → 签名变了；文本相同 → 只是挪了位置，不算。
    /// 纯新增的方法不算接口变化：它不会让现有的调用方坏掉。
    static func changes(in lines: [StructureGit.DiffLine], inInterface: Bool) -> [StructureEvidence] {
        var removed: [String: [(Declaration, Int)]] = [:]
        var added: [String: [(Declaration, Int)]] = [:]
        for line in lines {
            guard let declaration = parse(line.text, inInterface: inInterface) else { continue }
            if line.isAddition {
                added[declaration.name, default: []].append((declaration, line.number))
            } else {
                removed[declaration.name, default: []].append((declaration, line.number))
            }
        }

        var evidence: [StructureEvidence] = []
        for name in removed.keys.sorted() {
            let before = removed[name] ?? []
            let after = added[name] ?? []
            if Set(before.map(\.0.text)) == Set(after.map(\.0.text)) { continue }
            for (declaration, number) in before {
                evidence.append(StructureEvidence(file: "", line: number, sign: "-", text: declaration.text))
            }
            for (declaration, number) in after {
                evidence.append(StructureEvidence(file: "", line: number, sign: "+", text: declaration.text))
            }
        }
        return evidence
    }
}
