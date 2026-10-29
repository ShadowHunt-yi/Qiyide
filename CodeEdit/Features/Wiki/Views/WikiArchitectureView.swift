//
//  WikiArchitectureView.swift
//  CodeEdit
//
//  架构图：人用来「把控全局」的视图。
//
//  与力导向图谱的分工要分清：
//  - 图谱回答「这个模块连着谁」，节点多起来就看不清了；
//  - 架构图回答「系统分几层、每层有哪些域、依赖往哪个方向流」，
//    节点固定为 5–9 个域，永远看得清。
//
//  布局刻意不用弹簧：层次是事实（入口在最上、基建在最下），
//  力导向会把它画成一团，反而丢掉最重要的信息。
//

import SwiftUI

struct WikiArchitectureView: View {

    let architecture: WikiArchitecture
    @State private var selectedDomain: String?

    var body: some View {
        if architecture.isEmpty {
            empty
        } else {
            content
        }
    }

    // MARK: 主体

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                header
                ForEach(Array(architecture.layered.enumerated()), id: \.element.layer) { index, item in
                    if index > 0 {
                        flowRow(to: item.layer)
                    }
                    layerRow(layer: item.layer, domains: item.domains)
                }
                if let domain = selectedDomain.flatMap({ name in
                    architecture.domains.first { $0.name == name }
                }) {
                    detail(domain)
                }
            }
            .padding(14)
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.25))
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("\(architecture.domains.count) 个域 · \(architecture.moduleCount) 个模块")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Spacer()
            if !architecture.generatedBy.isEmpty {
                Text(architecture.generatedBy)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.bottom, 2)
    }

    // MARK: 层

    private func layerRow(layer: WikiLayer, domains: [WikiDomain]) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(layer.title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Self.color(for: layer))
                Text("\(domains.count) 域")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            .frame(width: 58, alignment: .leading)
            .padding(.top, 6)

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 146), spacing: 8)],
                alignment: .leading,
                spacing: 8
            ) {
                ForEach(domains) { domain in
                    card(domain)
                }
            }
        }
    }

    private func card(_ domain: WikiDomain) -> some View {
        let isSelected = selectedDomain == domain.name
        return Button {
            selectedDomain = isSelected ? nil : domain.name
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(domain.name)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text("\(domain.modules.count)")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Text(domain.purpose.isEmpty ? "—" : domain.purpose)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if let edge = strongestEdge(of: domain.name) {
                    Text("→ \(edge.to) \(edge.weight)")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, minHeight: 62, alignment: .topLeading)
            .background(
                Self.color(for: domain.layer).opacity(isSelected ? 0.22 : 0.10),
                in: RoundedRectangle(cornerRadius: 7)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(
                        Self.color(for: domain.layer).opacity(isSelected ? 0.8 : 0.25),
                        lineWidth: isSelected ? 1.2 : 0.5
                    )
            )
        }
        .buttonStyle(.plain)
        .help(domain.purpose)
    }

    // MARK: 层间流向

    /// 只显示进入这一层的主要流向：全部画出来会变成一团线，信息反而丢失。
    private func flowRow(to layer: WikiLayer) -> some View {
        let names = Set(architecture.domains(in: layer).map(\.name))
        let incoming = architecture.domainEdges.filter { names.contains($0.to) }
        let total = incoming.reduce(0) { $0 + $1.weight }
        guard total > 0 else { return AnyView(EmptyView()) }
        let top = incoming.prefix(2)
            .map { "\($0.from)→\($0.to) \($0.weight)" }
            .joined(separator: "、")

        return AnyView(
            HStack(spacing: 6) {
                Image(systemName: "arrow.down")
                    .font(.system(size: 8))
                Text("\(total) 次调用进入 \(layer.title)")
                    .font(.system(size: 9))
                Text(top)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                Spacer()
            }
            .foregroundStyle(.secondary)
            .padding(.leading, 68)
            .padding(.vertical, 1)
        )
    }

    // MARK: 详情

    private func detail(_ domain: WikiDomain) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(domain.name)
                    .font(.system(size: 12, weight: .medium))
                Text(domain.layer.title)
                    .font(.system(size: 9))
                    .foregroundStyle(Self.color(for: domain.layer))
                Spacer()
                Button {
                    selectedDomain = nil
                } label: {
                    Image(systemName: "xmark").font(.system(size: 9))
                }
                .buttonStyle(.plain)
            }

            if !domain.purpose.isEmpty {
                Text(domain.purpose)
                    .font(.system(size: 11))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !domain.keyRules.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(domain.keyRules, id: \.self) { rule in
                        Text("· \(rule)")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            let modules = domain.modules.sorted()
            if !modules.isEmpty {
                Text("模块 " + modules.prefix(8).joined(separator: "、")
                     + (modules.count > 8 ? " 等 \(modules.count) 个" : ""))
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 0.5)
        )
        .padding(.top, 4)
    }

    private var empty: some View {
        VStack(spacing: 6) {
            Image(systemName: "square.3.layers.3d")
                .font(.system(size: 22))
                .foregroundStyle(.tertiary)
            Text("还没有架构视图")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Text("从「AI 整理」→「生成架构视图」开始")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.25))
    }

    // MARK: 工具

    private func strongestEdge(of domain: String) -> WikiDomainEdge? {
        architecture.domainEdges.first { $0.from == domain }
    }

    static func color(for layer: WikiLayer) -> Color {
        switch layer {
        case .entry: return .blue
        case .business: return .purple
        case .domain: return .teal
        case .data: return .orange
        case .infrastructure: return .gray
        }
    }
}
