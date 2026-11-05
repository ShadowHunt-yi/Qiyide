//
//  StructureOverviewView.swift
//  CodeEdit
//
//  结构地图的第一级：全仓。每个域一张卡片，卡片里是它真实的模块。
//
//  为什么是「卡片网格」而不是「域 × 层」的矩阵：
//  真实仓库里多数域按功能分包（画像下面是 inference / intention / timeline），
//  不是按技术层分包。把层当行，这些模块没有格子可落，格子里就只剩一个点。
//  所以这里让模块自己当主角：域下面列的就是包名，看一眼知道里面有什么。
//
//  每张卡片最多列 `visibleRows` 行。排序固定按类数降序，不把「有改动的」顶到前面——
//  位置不变，人才能靠空间记忆找东西。
//

import SwiftUI

struct StructureOverviewView: View {
    let index: StructureIndex
    let onNavigate: ([String]) -> Void

    /// 每张域卡片最多显示几个模块。其余折叠成「另有 N 个模块」。
    static let visibleRows = 6

    private let columns = [GridItem(.adaptive(minimum: 210, maximum: 340), spacing: 10, alignment: .top)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                ForEach(index.domains) { domain in
                    StructureDomainCard(domain: domain, onNavigate: onNavigate)
                }
            }
            .padding(12)
        }
    }
}

/// 一个域的卡片：标题行进入域，模块行直接进入模块。
struct StructureDomainCard: View {
    let domain: StructureDomain
    let onNavigate: ([String]) -> Void

    private var visible: [StructureModule] {
        Array(domain.modules.prefix(StructureOverviewView.visibleRows))
    }

    private var hiddenCount: Int {
        domain.modules.count - visible.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                ForEach(visible) { module in
                    StructureRowButton(help: module.key) {
                        onNavigate([domain.id, module.id])
                    } label: {
                        HStack(spacing: 6) {
                            Text(module.title)
                                .font(.system(size: 11.5, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 4)
                            Text("\(module.classCount)")
                                .font(.system(size: 10).monospacedDigit())
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                if hiddenCount > 0 {
                    StructureRowButton(help: "查看「\(domain.title)」的全部模块") {
                        onNavigate([domain.id])
                    } label: {
                        Text("另有 \(hiddenCount) 个模块")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                    }
                }
                if domain.modules.isEmpty {
                    Text("仓库里没有找到这个域的代码")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                }
            }
            .padding(.vertical, 4)
        }
        .structureCard()
    }

    private var header: some View {
        StructureRowButton(help: "进入「\(domain.title)」") {
            onNavigate([domain.id])
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(domain.title)
                            .font(.system(size: 12.5, weight: .semibold))
                            .lineLimit(1)
                        if let tag = domain.kind.tag {
                            WikiChip(text: tag)
                        }
                    }
                    if !domain.keys.isEmpty {
                        Text(domain.keys.joined(separator: ", "))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 4)
                Text("\(domain.classCount) 类")
                    .font(.system(size: 10.5).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 3)
        }
    }
}

extension StructureDomain.Kind {
    /// 域名旁边的小标签。普通业务域不需要标。
    var tag: String? {
        switch self {
        case .domain: return nil
        case .catchAll: return "兜底"
        case .shared: return "共享"
        // 标题已经叫「未划分」了，再挂一个同名标签只是重复。
        case .unassigned: return nil
        }
    }

    /// 域这一级顶部的一句说明。
    var note: String? {
        switch self {
        case .domain: return nil
        case .catchAll: return "兜底域：这个一级包下没有被其他域认领的代码都在这里。"
        case .shared: return "被多个域共用、人工标成共享依赖的模块。"
        case .unassigned: return "不属于任何域的包。类太少，识别时没有单独成域。"
        }
    }
}
