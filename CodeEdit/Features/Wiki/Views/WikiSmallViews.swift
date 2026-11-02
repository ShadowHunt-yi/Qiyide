//
//  WikiSmallViews.swift
//  CodeEdit
//
//  知识库里的两个极小公共件：标签胶囊、分组标题。
//
//  为什么单独抽出来：这三行样式在窗口、体检面板、域归属面板里各写一遍，
//  改一次字号要改四处。抽出来后只加视觉参数，不加行为。
//

import SwiftUI

/// 小标签。颜色只表达语义（域=accent、缺口=orange、类型=secondary）。
struct WikiChip: View {
    let text: String
    var color: Color = .secondary

    var body: some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(color.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

/// 详情面板里的分组标题 + 内容。
struct WikiSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            content
        }
    }
}
