//
//  StructureBreadcrumbBar.swift
//  CodeEdit
//
//  结构地图顶部的面包屑：全仓 › 域 › 模块。
//
//  面包屑在这里不是装饰，它就是导航本身——地图的每一级都只画「当前节点的子节点」，
//  往下靠点卡片，往上只能靠它。所以每一段都是按钮，最后一段是当前位置、不可点。
//

import SwiftUI

/// 面包屑的一段。
struct StructureCrumb: Identifiable, Hashable {
    /// 点这一段要回到的路径。
    var path: [String]
    var title: String
    /// 这一段范围内的待确认数。0 不显示。
    var pending: Int = 0

    var id: String { path.joined(separator: "\u{1F}") + "#" + title }
}

struct StructureBreadcrumbBar: View {
    let crumbs: [StructureCrumb]
    /// 右侧的一句规模说明，随层级变化。
    let summary: String
    let onNavigate: ([String]) -> Void

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(crumbs.enumerated()), id: \.element.id) { offset, crumb in
                if offset > 0 {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                segment(crumb, isCurrent: offset == crumbs.count - 1)
            }
            Spacer(minLength: 8)
            Text(summary)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func segment(_ crumb: StructureCrumb, isCurrent: Bool) -> some View {
        let label = HStack(spacing: 4) {
            Text(crumb.title)
                .font(.system(size: 12, weight: isCurrent ? .semibold : .medium))
                .lineLimit(1)
            if crumb.pending > 0 {
                StructurePendingBadge(count: crumb.pending)
            }
        }
        if isCurrent {
            label
                .foregroundStyle(.primary)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
        } else {
            Button {
                onNavigate(crumb.path)
            } label: {
                label
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("回到「\(crumb.title)」")
        }
    }
}

/// 待确认数的小圆标。橙色在结构地图里只表示「等你确认」，不作他用。
struct StructurePendingBadge: View {
    let count: Int

    var body: some View {
        Text("\(count)")
            .font(.system(size: 9, weight: .bold).monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, 4.5)
            .frame(minWidth: 15, minHeight: 15)
            .background(Color.orange)
            .clipShape(Capsule())
            .accessibilityLabel("\(count) 处等你确认")
    }
}
