//
//  StatusBarMemoryLabel.swift
//  CodeEdit
//
//  调试用内存读数（仅在 MemoryProbe 启用时显示）。
//

import SwiftUI

/// 状态栏右侧的实时内存读数。
///
/// 仅在 ``MemoryProbe/isEnabled`` 为真时被插入视图树，Release 下默认不可见，因此不影响普通用户界面。
struct StatusBarMemoryLabel: View {
    @ObservedObject private var probe = MemoryProbe.shared

    var body: some View {
        if let sample = probe.latest {
            Text(Self.format(sample.footprintBytes))
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundStyle(.secondary)
                .help(
                    """
                    footprint \(Self.format(sample.footprintBytes)) · \
                    peak \(Self.format(sample.peakFootprintBytes)) · \
                    RSS \(Self.format(sample.residentBytes)) · \
                    \(sample.openDocuments) 个文档
                    """
                )
        } else {
            EmptyView()
        }
    }

    private static func format(_ bytes: UInt64) -> String {
        String(format: "%.1f MB", Double(bytes) / 1_048_576)
    }
}
