//
//  XMLHighlightProvider.swift
//  CodeEdit
//
//  XML 族标记语言（xml/plist/svg/xsl/xsd/xaml/wsdl/rdf/rss…）的词法高亮。
//
//  不依赖 tree-sitter：XML 语法族（含 plist 的 DOCTYPE 与自定义标签）
//  用词法正则逐段标注更可控。token 规则：
//    注释 `<!-- -->`      → comment
//    CDATA               → string
//    处理指令 `<? ?>`     → keyword
//    DOCTYPE `<!DOCTYPE>` → keyword
//    标签名 / 结束斜杠     → tag
//    属性名               → property
//    属性值（引号串）      → string
//    标签尖括号 / 等号     → punctuationSpecial / keyword
//

import AppKit
import CodeEditSourceEditor
import CodeEditLanguages
import CodeEditTextView

final class XMLHighlightProvider: HighlightProviding {
    /// 整体模式：按优先级交替匹配，先命中者生效，天然避免重叠。
    private static let pattern = try! NSRegularExpression(
        pattern:
            "(<!--.*?-->)"                                  // 1 注释
            + "|(<\\!\\[CDATA\\[.*?\\]\\]>)"                 // 2 CDATA
            + "|(<\\?.*?\\?>)"                              // 3 处理指令
            + "|(<\\!DOCTYPE[^>]*>)"                        // 4 DOCTYPE
            + "|(<)(/?)([A-Za-z_:][\\w:.-]*)"               // 5 <  6 斜杠  7 标签名
            + "((?:[^>\"']|\"[^\"]*\"|'[^']*')*)"          // 8 标签体（属性区）
            + "(/?)(>)",                                   // 9 自闭合  10 >
        options: [.dotMatchesLineSeparators]
    )

    /// 属性区内的 `名 = 值` 模式。
    private static let attributePattern = try! NSRegularExpression(
        pattern: "([A-Za-z_:][\\w:.-]*)(\\s*)(=)(\\s*)(\"[^\"]*\"|'[^']*')?",
        options: []
    )

    func setUp(textView: TextView, codeLanguage: CodeLanguage) {}

    /// 单次编辑最多失效的上下文行数（前后各 2 行）。
    ///
    /// 原先每次编辑都返回整篇文档的失效区间，高亮器会全文重排——大 plist/xml 上
    /// 每敲一个字都要重扫全文。XML token 极少跨越超过两行的边界，
    /// 跨行注释/CDATA 的极端情况由下一次全文查询校正。
    private static let contextLines = 2

    func applyEdit(
        textView: TextView,
        range: NSRange,
        delta: Int,
        completion: @escaping @MainActor (Result<IndexSet, Error>) -> Void
    ) {
        let text = textView.textStorage.string as NSString
        guard text.length > 0 else {
            completion(.success(IndexSet()))
            return
        }
        let edited = NSRange(location: min(range.location, text.length), length: 0)
        var window = text.lineRange(for: edited)
        for _ in 0..<Self.contextLines where window.location > 0 {
            let previous = text.lineRange(for: NSRange(location: max(window.location - 1, 0), length: 0))
            window = NSRange(location: previous.location, length: window.max - previous.location)
        }
        for _ in 0..<Self.contextLines where window.max < text.length {
            let next = text.lineRange(for: NSRange(location: window.max, length: 0))
            window = NSRange(location: window.location, length: next.max - window.location)
        }
        completion(.success(IndexSet(integersIn: NSRange(location: window.location, length: max(window.length, 1)))))
    }

    /// 超过该长度不再做词法高亮：正则全文扫描的代价会让编辑器失去响应。
    private static let maxHighlightLength = 2_000_000

    func queryHighlightsFor(
        textView: TextView,
        range: NSRange,
        completion: @escaping @MainActor (Result<[HighlightRange], Error>) -> Void
    ) {
        let text = textView.textStorage.string as NSString
        guard text.length <= Self.maxHighlightLength else {
            completion(.success([]))
            return
        }
        completion(.success(Self.tokenize(text)))
    }

    /// 全文词法扫描，输出不重叠的高亮区间。
    static func tokenize(_ text: NSString) -> [HighlightRange] {
        var results: [HighlightRange] = []
        let full = NSRange(location: 0, length: text.length)

        pattern.enumerateMatches(in: text as String, options: [], range: full) { match, _, _ in
            guard let match else { return }
            func range(_ idx: Int) -> NSRange? {
                let r = match.range(at: idx)
                return r.location == NSNotFound ? nil : r
            }
            func add(_ r: NSRange?, _ capture: CaptureName) {
                guard let r else { return }
                results.append(HighlightRange(range: r, capture: capture))
            }

            if let comment = range(1) {
                add(comment, .comment)
            } else if let cdata = range(2) {
                add(cdata, .string)
            } else if let instruction = range(3) {
                add(instruction, .keyword)
            } else if let doctype = range(4) {
                add(doctype, .keyword)
            } else {
                // 标签：<  /  name  attrs  /  >
                add(range(5), .tag)      // <
                add(range(6), .tag)      // /
                add(range(7), .tag)      // 标签名
                add(range(9), .tag)      // 自闭合斜杠
                add(range(10), .tag)     // >
                if let attrs = range(8) {
                    tokenizeAttributes(text, in: attrs, into: &results)
                }
            }
        }
        return results
    }

    /// 扫描标签体里的属性：名 → property，= → keyword，值 → string。
    private static func tokenizeAttributes(
        _ text: NSString,
        in body: NSRange,
        into results: inout [HighlightRange]
    ) {
        attributePattern.enumerateMatches(in: text as String, options: [], range: body) { match, _, _ in
            guard let match else { return }
            func add(_ idx: Int, _ capture: CaptureName) {
                let r = match.range(at: idx)
                guard r.location != NSNotFound else { return }
                results.append(HighlightRange(range: r, capture: capture))
            }
            add(1, .property)   // 属性名
            add(3, .keyword)    // =
            add(5, .string)     // 属性值
        }
    }
}
