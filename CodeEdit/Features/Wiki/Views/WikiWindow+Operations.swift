//
//  WikiWindow+Operations.swift
//  CodeEdit
//
//  导航与任务反馈始终可达；它们不取决于任何一类资源是否为空。
//

import SwiftUI

extension WikiWindowView {
    var modeNavigation: some View {
        HStack {
            Picker("知识与架构视角", selection: $centerMode) {
                ForEach(CenterMode.allCases) { mode in Text(mode.title).tag(mode) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 560)
            Spacer()
            if architectureTask.snapshot.id != nil {
                Button(architectureTask.snapshot.isActive ? "架构任务进行中" : "架构任务记录") {
                    showsArchitectureTask = true
                }
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    @ViewBuilder
    var architectureTaskBanner: some View {
        let snapshot = architectureTask.snapshot
        if let id = snapshot.id, snapshot.isActive || dismissedArchitectureTask != id {
            WikiOperationBanner(
                snapshot: snapshot, canRetrySave: architectureTask.canRetrySave,
                showsResultAction: centerMode != .architecture,
                onDetails: { showsArchitectureTask = true },
                onCancel: { architectureTask.cancel() },
                onRetry: { architectureTask.retry() },
                onStatic: { generateArchitecture(mode: .staticOnly) },
                onSettings: openArchitectureSettings,
                onResult: { centerMode = .architecture },
                onDismiss: { dismissedArchitectureTask = id }
            )
            Divider()
        }
    }

    @ViewBuilder
    var otherWorkBanner: some View {
        if ingestion.isRunning,
           ingestion.root?.standardizedFileURL.resolvingSymlinksInPath() == store.root.standardizedFileURL.resolvingSymlinksInPath() {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 3) {
                    Text(ingestion.isStopping ? "正在取消建档" : "仓库建档 · \(ingestion.stage.title)")
                        .font(.system(size: 12, weight: .medium))
                    Text(ingestion.detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                Button("查看建档") { showIngest = true }.controlSize(.small)
            }.padding(.horizontal, 14).padding(.vertical, 10).background(Color.accentColor.opacity(0.06))
            Divider()
        } else if domains.isAnalyzing || curating {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(domains.isAnalyzing ? domains.progressText : "正在从改动提炼知识草稿…")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
            }.padding(.horizontal, 14).padding(.vertical, 10).background(Color.accentColor.opacity(0.06))
            Divider()
        }
    }

    func openArchitectureSettings() {
        showsArchitectureTask = false
        SettingsNavigation.shared.request(.ai)
        openWindow(id: "settings")
    }

    func architectureDomainDetail(_ domain: WikiDomain) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text(domain.name).font(.system(size: 16, weight: .medium))
                    Spacer()
                    Button { selectedArchitectureDomain = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).accessibilityLabel("收起架构域详情")
                }
                Text(domain.layer.title).font(.system(size: 12)).foregroundStyle(.secondary)
                Text(domain.purpose.isEmpty ? "暂无职责说明" : domain.purpose).font(.system(size: 12))
                Divider()
                Text("包含 \(domain.modules.count) 个模块").font(.system(size: 12, weight: .medium))
                ForEach(domain.modules, id: \.self) { module in
                    Text(module).font(.system(size: 12)).textSelection(.enabled)
                }
                if !domain.keyRules.isEmpty {
                    Divider()
                    Text("边界与规则").font(.system(size: 12, weight: .medium))
                    ForEach(domain.keyRules, id: \.self) { Text($0).font(.system(size: 12)) }
                }
                let edges = store.architecture.domainEdges.filter { $0.from == domain.name || $0.to == domain.name }
                if !edges.isEmpty {
                    Divider()
                    Text("相关依赖").font(.system(size: 12, weight: .medium))
                    ForEach(Array(edges.enumerated()), id: \.offset) { _, edge in
                        Text("\(edge.from) → \(edge.to) · \(edge.weight)").font(.system(size: 12))
                    }
                }
                Divider()
                Text("\(store.architecture.generatedBy) · \(Date(timeIntervalSince1970: store.architecture.generatedAt).formatted())")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Text("架构是静态推断或 AI 草稿，不代表业务已验证。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }
}
