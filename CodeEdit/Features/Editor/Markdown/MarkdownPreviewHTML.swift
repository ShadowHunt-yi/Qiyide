//
//  MarkdownPreviewHTML.swift
//  CodeEdit
//
//  Markdown → HTML 的轻量渲染器，用于实时预览。
//
//  每个块级元素带 `data-line`（0 起源码行号），预览与源码的滚动同步
//  靠它把「源码行」映射到「预览元素」。
//
//  支持的块：ATX/Setext 标题、围栏代码块、引用、无序/有序列表（一层嵌套）、
//  表格、分隔线、段落。
//  支持的行内：`代码`、**粗体**、*斜体*、[链接](url)、![图片](url)、自动链接。
//

import Foundation

enum MarkdownPreviewHTML {
    /// 渲染整篇文档。
    /// - Parameter markdown: 源文档文本。
    /// - Returns: 完整 HTML 文档字符串（含基础样式，跟随系统深浅色）。
    static func render(_ markdown: String) -> String {
        let blocks = parse(markdown)
        let body = blocks.joined(separator: "\n")
        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
        :root { color-scheme: light dark; }
        body {
            font-family: -apple-system, "PingFang SC", sans-serif;
            font-size: 14px; line-height: 1.65;
            margin: 0; padding: 18px 26px 60vh 26px;
            word-wrap: break-word;
        }
        @media (prefers-color-scheme: dark) {
            body { color: #e6e6e6; background: #1e1e1e; }
            code, pre { background: #2d2d2d; }
            blockquote { color: #b0b0b0; border-color: #555; }
            table td, table th { border-color: #555; }
            tr:nth-child(odd) { background: #262626; }
        }
        @media (prefers-color-scheme: light) {
            body { color: #1a1a1a; background: #ffffff; }
            code, pre { background: #f4f4f4; }
            blockquote { color: #666; border-color: #ddd; }
            table td, table th { border-color: #ddd; }
            tr:nth-child(odd) { background: #fafafa; }
        }
        pre { padding: 10px 12px; border-radius: 6px; overflow-x: auto; }
        code { font-family: "SF Mono", Menlo, monospace; font-size: 12.5px; padding: 1px 4px; border-radius: 4px; }
        pre code { padding: 0; }
        h1, h2, h3, h4, h5, h6 { font-weight: 600; line-height: 1.35; margin: 1.1em 0 0.5em; }
        h1 { font-size: 1.7em; } h2 { font-size: 1.45em; } h3 { font-size: 1.22em; }
        h4 { font-size: 1.1em; } h5 { font-size: 1em; } h6 { font-size: 0.95em; }
        p { margin: 0.55em 0; }
        ul, ol { margin: 0.5em 0; padding-left: 1.7em; }
        li { margin: 0.22em 0; }
        blockquote { margin: 0.7em 0; padding: 0.2em 1em; border-left: 4px solid; }
        hr { border: none; border-top: 1px solid; opacity: 0.35; margin: 1.2em 0; }
        table { border-collapse: collapse; margin: 0.8em 0; }
        th, td { border: 1px solid; padding: 5px 11px; text-align: left; }
        img { max-width: 100%; }
        a { text-decoration: underline; }
        .mermaid {
            margin: 0.9em 0; text-align: center; overflow-x: auto;
            font-family: "SF Mono", Menlo, monospace; font-size: 12px;
        }
        </style>
        </head>
        <body>
        \(body)
        <script src="mermaid.min.js"></script>
        <script>
        (function() {
            try {
                if (typeof mermaid === 'undefined') { return; }
                var dark = window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches;
                mermaid.initialize({ startOnLoad: false, theme: dark ? 'dark' : 'default', securityLevel: 'loose' });
                if (mermaid.run) { mermaid.run({ querySelector: '.mermaid' }); }
                else { mermaid.init(undefined, '.mermaid'); }
            } catch (e) {}
        })();
        </script>
        </body>
        </html>
        """
    }

    // MARK: - 块级解析

    private static func parse(_ source: String) -> [String] {
        let lines = source.components(separatedBy: "\n")
        var html: [String] = []
        var index = 0

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // 空行
            if trimmed.isEmpty {
                index += 1
                continue
            }

            // 围栏代码块（mermaid 语言输出图表容器，由页面脚本渲染）
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                let fence = String(trimmed.prefix(3))
                let language = String(trimmed.dropFirst(3))
                    .trimmingCharacters(in: .whitespaces)
                    .lowercased()
                let start = index
                var code: [String] = []
                index += 1
                while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    code.append(escape(lines[index]))
                    index += 1
                }
                index += 1 // 跳过收尾围栏
                let joined = code.joined(separator: "\n")
                if language == "mermaid" {
                    // 内容经 HTML 转义，mermaid 读 textContent 时会还原。
                    html.append("<div class=\"mermaid\" data-line=\"\(start)\">\(joined)\n</div>")
                } else {
                    html.append("<pre data-line=\"\(start)\"><code>\(joined)\n</code></pre>")
                }
                continue
            }

            // 标题
            if let heading = atxHeading(trimmed) {
                html.append("<h\(heading.level) data-line=\"\(index)\">\(inline(heading.text))</h\(heading.level)>")
                index += 1
                continue
            }

            // 分隔线
            if isThematicBreak(trimmed) {
                html.append("<hr data-line=\"\(index)\">")
                index += 1
                continue
            }

            // 引用
            if trimmed.hasPrefix(">") {
                let start = index
                var quoted: [String] = []
                while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    var text = lines[index].trimmingCharacters(in: .whitespaces)
                    text.removeFirst()
                    if text.hasPrefix(" ") { text.removeFirst() }
                    quoted.append(text)
                    index += 1
                }
                let inner = quoted.map { "<p>\(inline($0))</p>" }.joined(separator: "")
                html.append("<blockquote data-line=\"\(start)\">\(inner)</blockquote>")
                continue
            }

            // 列表
            if unorderedMarker(trimmed) != nil || orderedMarker(trimmed) != nil {
                let start = index
                let (listHTML, next) = parseList(lines: lines, from: index)
                html.append("<\(listHTML.tag) data-line=\"\(start)\">\(listHTML.items)</\(listHTML.tag)>")
                index = next
                continue
            }

            // 表格（GFM）
            if trimmed.hasPrefix("|"), index + 1 < lines.count, isTableSeparator(lines[index + 1]) {
                let start = index
                let (tableHTML, next) = parseTable(lines: lines, from: index)
                html.append("<table data-line=\"\(start)\">\(tableHTML)</table>")
                index = next
                continue
            }

            // Setext 标题（下一行是 === 或 ---）
            if index + 1 < lines.count {
                let nextTrimmed = lines[index + 1].trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty, isSetextUnderline(nextTrimmed) {
                    let level = nextTrimmed.hasPrefix("=") ? 1 : 2
                    html.append("<h\(level) data-line=\"\(index)\">\(inline(trimmed))</h\(level)>")
                    index += 2
                    continue
                }
            }

            // 段落：合并连续非空行
            let start = index
            var para: [String] = []
            while index < lines.count {
                let t = lines[index].trimmingCharacters(in: .whitespaces)
                if t.isEmpty
                    || atxHeading(t) != nil
                    || unorderedMarker(t) != nil
                    || orderedMarker(t) != nil
                    || t.hasPrefix(">")
                    || t.hasPrefix("```")
                    || t.hasPrefix("~~~")
                    || isThematicBreak(t) {
                    break
                }
                para.append(t)
                index += 1
            }
            html.append("<p data-line=\"\(start)\">\(inline(para.joined(separator: " ")))</p>")
        }
        return html
    }

    private struct Heading {
        let level: Int
        let text: String
    }

    private static func atxHeading(_ line: String) -> Heading? {
        guard line.hasPrefix("#") else { return nil }
        var level = 0
        for ch in line {
            if ch == "#" { level += 1 } else { break }
        }
        guard level >= 1, level <= 6 else { return nil }
        var text = String(line.dropFirst(level))
        if text.hasPrefix(" ") { text.removeFirst() }
        // 去掉行尾的闭合 #
        while text.hasSuffix("#") {
            text.removeLast()
            if text.hasSuffix(" ") { text.removeLast() }
        }
        return Heading(level: level, text: text)
    }

    private static func isSetextUnderline(_ line: String) -> Bool {
        !line.isEmpty
            && (line.allSatisfy { $0 == "=" } || line.allSatisfy { $0 == "-" })
            && line.count >= 2
    }

    private static func isThematicBreak(_ line: String) -> Bool {
        let stripped = line.replacingOccurrences(of: " ", with: "")
        return stripped.count >= 3
            && (stripped.allSatisfy { $0 == "-" } || stripped.allSatisfy { $0 == "*" } || stripped.allSatisfy { $0 == "_" })
    }

    private static func unorderedMarker(_ line: String) -> String? {
        for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) {
            return marker
        }
        return nil
    }

    private static func orderedMarker(_ line: String) -> String? {
        guard let dotIndex = line.firstIndex(of: ".") else { return nil }
        let number = line[line.startIndex..<dotIndex]
        guard !number.isEmpty, number.allSatisfy({ $0.isNumber }),
              line.index(after: dotIndex) < line.endIndex,
              line[line.index(after: dotIndex)] == " " else {
            return nil
        }
        return String(line[line.startIndex...line.index(after: dotIndex)])
    }

    // MARK: - 列表

    private struct ListHTML {
        let tag: String
        let items: String
    }

    private static func parseList(lines: [String], from start: Int) -> (ListHTML, Int) {
        var index = start
        let firstMarker = unorderedMarker(lines[index].trimmingCharacters(in: .whitespaces)) != nil ? "-" : "1."
        let tag = firstMarker == "-" ? "ul" : "ol"
        var items: [String] = []

        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            let isUnordered = unorderedMarker(trimmed) != nil
            let isOrdered = orderedMarker(trimmed) != nil
            guard isUnordered || isOrdered else { break }

            let contentStart: String.Index
            if isUnordered {
                contentStart = trimmed.index(trimmed.startIndex, offsetBy: 2)
            } else {
                // orderedMarker 已包含数字与点后的空格，直接按其长度截取。
                contentStart = trimmed.index(trimmed.startIndex, offsetBy: orderedMarker(trimmed)!.count)
            }
            var content = String(trimmed[contentStart...])
            let itemLine = index
            index += 1

            // 列表项的续行（缩进的普通行）并入同一项
            while index < lines.count {
                let next = lines[index]
                let nextTrimmed = next.trimmingCharacters(in: .whitespaces)
                if nextTrimmed.isEmpty || unorderedMarker(nextTrimmed) != nil || orderedMarker(nextTrimmed) != nil {
                    break
                }
                if next.hasPrefix("    ") || next.hasPrefix("\t") {
                    content += " " + nextTrimmed
                    index += 1
                } else {
                    break
                }
            }
            items.append("<li data-line=\"\(itemLine)\">\(inline(content))</li>")
        }
        return (ListHTML(tag: tag, items: items.joined(separator: "")), index)
    }

    // MARK: - 表格

    private static func isTableSeparator(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("|") else { return false }
        return trimmed
            .replacingOccurrences(of: "|", with: "")
            .replacingOccurrences(of: " ", with: "")
            .allSatisfy { $0 == "-" || $0 == ":" }
    }

    private static func parseTable(lines: [String], from start: Int) -> (String, Int) {
        func cells(_ line: String) -> [String] {
            var text = line.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("|") { text.removeFirst() }
            if text.hasSuffix("|") { text.removeLast() }
            return text.components(separatedBy: "|").map {
                $0.trimmingCharacters(in: .whitespaces)
            }
        }

        var index = start
        let header = cells(lines[index])
        index += 2 // 跳过表头与分隔行
        var html = "<thead><tr>"
        for cell in header {
            html += "<th>\(inline(cell))</th>"
        }
        html += "</tr></thead><tbody>"
        while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
            html += "<tr>"
            for cell in cells(lines[index]) {
                html += "<td>\(inline(cell))</td>"
            }
            html += "</tr>"
            index += 1
        }
        html += "</tbody>"
        return (html, index)
    }

    // MARK: - 行内

    private static func inline(_ text: String) -> String {
        var result = escape(text)

        // 行内代码（先处理，避免其内容被后续规则改写）
        result = replace(result, pattern: "`([^`]+)`") { match in
            "<code>\(match)</code>"
        }
        // 粗体
        result = replace(result, pattern: "\\*\\*([^*]+)\\*\\*|__([^_]+)__") { match in
            "<strong>\(match)</strong>"
        }
        // 斜体
        result = replace(result, pattern: "\\*([^*]+)\\*|_([^_]+)_") { match in
            "<em>\(match)</em>"
        }
        // 图片
        result = replace(result, pattern: "!\\[([^\\]]*)\\]\\(([^)\\s]+)\\)") { alt, url in
            "<img alt=\"\(alt)\" src=\"\(url)\">"
        }
        // 链接
        result = replace(result, pattern: "\\[([^\\]]+)\\]\\(([^)\\s]+)\\)") { text, url in
            "<a href=\"\(url)\">\(text)</a>"
        }
        return result
    }

    private static func escape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// 简易正则替换：取第一捕获组（没有则取第零组）作为内容。
    private static func replace(
        _ text: String,
        pattern: String,
        transform: (String) -> String
    ) -> String {
        replace(text, pattern: pattern) { a, _ in transform(a) }
    }

    private static func replace(
        _ text: String,
        pattern: String,
        transform: (String, String) -> String
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        var result = text
        // 倒序替换避免偏移失效
        for match in matches.reversed() {
            func group(_ idx: Int) -> String {
                // 不同模式的捕获组数量不同，越界访问会抛 NSException。
                guard idx < match.numberOfRanges else { return "" }
                let r = match.range(at: idx)
                return r.location == NSNotFound ? "" : nsText.substring(with: r)
            }
            let first = group(1).isEmpty ? group(0) : group(1)
            let second = group(2)
            let replacement = transform(first, second)
            result = (result as NSString).replacingCharacters(in: match.range, with: replacement)
        }
        return result
    }
}
