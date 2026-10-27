//
//  GitBlameAnnotation.swift
//  CodeEdit
//
//  行级 git blame 标注：在行尾绘制「hash 作者 日期 摘要」，点击查看该行历史。
//

import AppKit
import CoreText
import CodeEditTextView

protocol GitBlameAnnotationDelegate: AnyObject {
    /// 点击某行的 blame 标注，请求打开该行的变更历史。
    func annotationClicked(_ annotation: GitBlameAnnotation)
}

/// 行尾的 blame 标注附件（借用 TextAttachment 机制在行尾绘制文本）。
final class GitBlameAnnotation: TextAttachment {
    let blame: GitBlameLine
    /// 1 起的行号。
    let line: Int
    weak var delegate: GitBlameAnnotationDelegate?

    var isSelected: Bool = false

    /// 预排好的 CTLine 与宽度都按需构建并缓存。
    ///
    /// 一个文件会创建「行数」个标注对象，若在 init 里预建 CTLine，
    /// 每次刷新都要为整篇文档做排版（大文件上是几十毫秒的主线程开销）；
    /// 实际上只有可见行才会被测量与绘制。
    private var cachedLine: CTLine?
    private var cachedWidth: CGFloat?
    /// 标注最大宽度：超过则截断，避免长摘要把行尾推得很远。
    private static let maxAnnotationWidth: CGFloat = 420

    /// 标注文本。只存字符串：一个文件会创建「行数」个标注对象，
    /// 若在 init 里就构造 NSAttributedString，每次刷新都是成千上万次分配。
    private let label: String

    private static let textAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
        .foregroundColor: NSColor.secondaryLabelColor
    ]

    init(blame: GitBlameLine, line: Int, delegate: GitBlameAnnotationDelegate?) {
        self.blame = blame
        self.line = line
        self.delegate = delegate
        self.label = "   " + blame.annotationText
    }

    /// 排版结果（延迟构建 + 缓存）：只有被测量或绘制的行才会真正排版。
    private func resolvedLine() -> CTLine {
        if let cachedLine {
            return cachedLine
        }
        let attributed = NSAttributedString(string: label, attributes: Self.textAttributes)
        let full = CTLineCreateWithAttributedString(attributed)
        let line = Self.truncatedLine(full, attributed: attributed, maxWidth: Self.maxAnnotationWidth)
        cachedLine = line
        return line
    }

    /// 行尾装饰：不参与换行计算，避免把换行符挤到下一行。
    var isTrailingDecoration: Bool { true }

    /// 按最大宽度截断 CTLine（结尾省略号）。
    private static func truncatedLine(
        _ line: CTLine,
        attributed: NSAttributedString,
        maxWidth: CGFloat
    ) -> CTLine {
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        guard width > maxWidth else { return line }
        let attributes = attributed.attributes(at: 0, effectiveRange: nil)
        let ellipsis = CTLineCreateWithAttributedString(
            NSAttributedString(string: "…", attributes: attributes)
        )
        return CTLineCreateTruncatedLine(line, Double(maxWidth), .end, ellipsis) ?? line
    }

    var width: CGFloat {
        if let cachedWidth {
            return cachedWidth
        }
        let line = resolvedLine()
        let width = min(CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) + 6, Self.maxAnnotationWidth)
        cachedWidth = width
        return width
    }

    func draw(in context: CGContext, rect: NSRect) {
        let ctLine = resolvedLine()
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        CTLineGetTypographicBounds(ctLine, &ascent, &descent, nil)
        // 基线垂直居中
        let baselineY = rect.midY - ((ascent + descent) / 2) + ascent
        context.saveGState()
        context.textPosition = CGPoint(x: rect.minX + 2, y: baselineY)
        CTLineDraw(ctLine, context)
        context.restoreGState()
    }

    // 单击与双击都打开行历史（单击走内核的 attachmentSingleClick 钩子）。
    func attachmentSingleClick() {
        delegate?.annotationClicked(self)
    }

    func attachmentAction() -> TextAttachmentAction {
        delegate?.annotationClicked(self)
        return .none
    }
}
