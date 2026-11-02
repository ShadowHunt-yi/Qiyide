//
//  MindMapChrome.swift
//  CodeEdit
//
//  浮在画布上的控件：图例、缩放按钮，以及它们共用的自绘小按钮。
//
//  这些控件不参与布局，只是叠在画布上的一层，和「图怎么排」无关，所以单独放。
//

import SwiftUI

extension MindMapView {

    var legend: some View {
        HStack(spacing: 10) {
            legendItem(Color.accentColor.opacity(0.55), "领域")
            legendItem(Color.secondary.opacity(0.32), "模块")
            legendItem(Color.orange.opacity(0.6), "共享依赖")
            Text("拖动平移 · 双指缩放 · 双击展开")
                .foregroundStyle(.secondary)
        }
        .font(.system(size: 9.5))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(.regularMaterial, in: Capsule())
        .allowsHitTesting(false)
    }

    func legendItem(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 3) {
            RoundedRectangle(cornerRadius: 2)
                .fill(color)
                .overlay(
                    RoundedRectangle(cornerRadius: 2)
                        .strokeBorder(Color.secondary.opacity(0.25), lineWidth: 0.5)
                )
                .frame(width: 9, height: 9)
            Text(text)
        }
    }

    func zoomControls(_ layout: MindLayoutResult, size: CGSize) -> some View {
        HStack(spacing: 2) {
            MapChipButton(systemImage: "minus", help: "缩小") {
                zoom = clampZoom(zoom * 0.83)
                pinchZoom = 1
            }

            Text("\(Int((effectiveZoom * 100).rounded()))%")
                .font(.system(size: 9.5).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 32)

            MapChipButton(systemImage: "plus", help: "放大") {
                zoom = clampZoom(zoom * 1.2)
                pinchZoom = 1
            }

            Divider().frame(height: 11)

            MapChipButton(title: "适应", help: "缩放到能看见整棵树") {
                fit(layout, size: size)
            }
            MapChipButton(title: "复位", help: "回到 100% 并居中") {
                zoom = 1
                pan = .zero
                pinchZoom = 1
                dragPan = .zero
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(.regularMaterial, in: Capsule())
    }

    // MARK: 连线

// MARK: - 浮动控件

/// 自绘的小按钮。
///
/// 不用 `Button`：它在这里既会带出焦点环，也让离屏渲染（ImageRenderer）
/// 画不出内容、退化成占位符。三个内联样式（图标 / 文字 / hover 底色）
/// 完全够用，还能和自绘的导图保持同一套视觉。
struct MapChipButton: View {
    var systemImage: String?
    var title: String?
    let help: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Group {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 9, weight: .semibold))
            } else if let title {
                Text(title).font(.system(size: 10))
            }
        }
        .foregroundStyle(hovering ? .primary : .secondary)
        .frame(width: title == nil ? 16 : nil, height: 16)
        .padding(.horizontal, title == nil ? 0 : 5)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(hovering ? Color.secondary.opacity(0.16) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: action)
        .help(help)
    }
}
}

