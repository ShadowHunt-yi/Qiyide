//
//  StructureCommon.swift
//  CodeEdit
//
//  结构地图三级视图共用的小件：可点的行、卡片外框、规模条。
//
//  三级视图用同一套画法是有意的：看懂全仓那一级，域和模块就不用再学。
//  所以外框、字号、悬停反馈都收在这里，不让每一级各写一份。
//

import SwiftUI

/// 卡片外框。与导图里的模块卡片保持同一种边线，两个视图切换时不会像换了个应用。
struct StructureCardStyle: ViewModifier {
    var isHighlighted = false

    func body(content: Content) -> some View {
        content
            .background(Color(nsColor: .controlBackgroundColor))
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(
                        isHighlighted ? Color.primary.opacity(0.45) : Color.secondary.opacity(0.28),
                        lineWidth: isHighlighted ? 1 : 0.5
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: 7))
    }
}

extension View {
    func structureCard(highlighted: Bool = false) -> some View {
        modifier(StructureCardStyle(isHighlighted: highlighted))
    }
}

/// 一整行可点，悬停时有底色。
///
/// 不用 `List`：List 的选中态和行高都是给「选一条」设计的，
/// 这里的行是「点了就进下一级」，更接近链接。
struct StructureRowButton<Label: View>: View {
    var help: String = ""
    let action: () -> Void
    @ViewBuilder var label: Label

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            label
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 3.5)
                .background(isHovering ? Color.primary.opacity(0.06) : Color.clear)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(help)
    }
}

/// 规模条：这个模块在同一个域里算大还是小，一眼可比。
struct StructureSizeBar: View {
    /// 0...1。
    let ratio: Double

    var body: some View {
        GeometryReader { proxy in
            Capsule()
                .fill(Color.secondary.opacity(0.35))
                .frame(width: max(3, proxy.size.width * min(max(ratio, 0), 1)))
        }
        .frame(height: 3)
    }
}

// MARK: - 分支增量的标记

/// 颜色只表示状态，不表示域。橙色只留给「等你确认」。
enum StructurePalette {
    static let added = Color.green
    static let modified = Color.blue
    static let deleted = Color.red
    static let pending = Color.orange

    static func color(_ kind: StructureFileChange.Kind) -> Color {
        switch kind {
        case .added: return added
        case .modified: return modified
        case .deleted: return deleted
        }
    }
}

/// 叠在地图上的那一层。视图只关心两件事：这个节点上有什么改动、还有几条待确认没决定。
struct StructureOverlay {
    let diff: StructureDiff
    /// 还没做决定的待确认。
    let openAsks: [StructureAsk]

    func pending(_ path: [String]) -> Int {
        openAsks.filter { $0.isInside(path) }.count
    }
}

/// `+2 ~3 −1`。没有改动时什么都不画。
struct StructureMarksLabel: View {
    let marks: StructureMarks

    var body: some View {
        HStack(spacing: 5) {
            if marks.added > 0 {
                Text("+\(marks.added)").foregroundStyle(StructurePalette.added)
            }
            if marks.modified > 0 {
                Text("~\(marks.modified)").foregroundStyle(StructurePalette.modified)
            }
            if marks.deleted > 0 {
                Text("−\(marks.deleted)").foregroundStyle(StructurePalette.deleted)
            }
        }
        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
        .accessibilityLabel("新增 \(marks.added)，变更 \(marks.modified)，删除 \(marks.deleted)")
    }
}
