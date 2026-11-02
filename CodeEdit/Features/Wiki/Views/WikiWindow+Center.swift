//
//  WikiWindow+Center.swift
//  CodeEdit
//
//  中间栏：三种看法（导图 / 图谱 / 架构）与它们的操作区。
//
//  「哪个视图」和「这个视图能做什么操作」放在一起：
//  分开写就会出现「切到架构模式还留着导图的按钮」这种事。
//

import SwiftUI

extension WikiWindowView {

    var centerPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Picker("", selection: $centerMode) {
                    ForEach(CenterMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 186)

                if centerMode == .mindmap {
                    Picker("", selection: $activeSpec) {
                        Text("建模").tag(ViewSpec?.none)
                        Divider()
                        ForEach(ViewSpec.presets) { spec in
                            Text(spec.name).tag(ViewSpec?.some(spec))
                        }
                        if !customSpecs.isEmpty {
                            Divider()
                            ForEach(customSpecs) { spec in
                                Text(spec.name).tag(ViewSpec?.some(spec))
                            }
                        }
                    }
                    .labelsHidden()
                    .frame(width: 124)
                    .help("建模可编辑；其余视角是同一份模型的只读投影")
                }

                Spacer()

                if centerMode == .mindmap {
                    mindMapActions
                } else if centerMode == .architecture {
                    if buildingArchitecture {
                        ProgressView().scaleEffect(0.4).frame(width: 14, height: 14)
                    } else {
                        Button(store.architecture.isEmpty ? "生成架构视图" : "重建") {
                            generateArchitecture()
                        }
                        .controlSize(.small)
                        .help("扫代码建依赖图，让模型按依赖内聚划分域（约一分钟）")
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)

            Divider()

            switch centerMode {
            case .mindmap:
                MindMapView(
                    store: domains,
                    selection: mindMapSelection,
                    displayGraph: activeSpec == nil ? nil : displayGraph,
                    isReadOnly: activeSpec != nil,
                    graphToken: (activeSpec?.id ?? "model") + "#\(domains.revision)"
                )
            case .architecture:
                WikiArchitectureView(architecture: store.architecture)
            case .graph:
                WikiGraphView(graph: store.graph, selection: $selection)
            }
        }
        .onAppear {
            // 没有领域模型但有架构视图时先给全局；有模型就停在导图——
            // 建模是这条流水线的第一步，不该藏在二级入口里。
            if domains.graph.isEmpty && !store.architecture.isEmpty {
                centerMode = .architecture
            }
        }
    }

    /// 导图模式的操作区。识别/锁定/生成都放在这里，
    /// 让「一个页面」真的能走完建模到出知识的全过程，不用再开另一个窗口。
    var mindMapActions: some View {
        HStack(spacing: 8) {
            if domains.isAnalyzing {
                ProgressView().scaleEffect(0.4).frame(width: 14, height: 14)
                Text(domains.progressText.isEmpty ? "识别中…" : domains.progressText)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            } else {
                Button {
                    Task { await domains.analyze() }
                } label: {
                    Text(domains.graph.isEmpty ? "识别领域" : "重新识别")
                        .font(.system(size: 11))
                }
                .controlSize(.small)
                .help("扫包结构、命名、调用与注释，产出领域候选")
            }

            if domains.isLocked {
                Label("已锁定", systemImage: "lock.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.green)
            } else {
                Button("锁定") { domains.lock() }
                    .controlSize(.small)
                    .disabled(domains.graph.isEmpty)
                    .help("锁定后重新识别不会覆盖人工校正的结果")
            }

            Menu {
                Button("生成缺失知识") { generateMissingKnowledge() }
                    .disabled(domains.graph.domains.isEmpty)
                Button("域归属…") { showBackfill = true }
                    .disabled(domains.graph.isEmpty)
                Divider()
                Button("解除锁定") { domains.unlock() }
                    .disabled(!domains.isLocked)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("建模操作")
        }
    }

    /// 给还没有知识条目的域补草稿。已存在的会被跳过，不会覆盖人工内容。
    func generateMissingKnowledge() {
        do {
            let result = try WikiDomainSeeding.seed(graph: domains.graph, into: store)
            if result.created == 0 {
                curatorMessage = "没有新增知识（\(result.skipped) 条已存在）"
            } else {
                curatorMessage = "已生成 \(result.created) 条领域知识草稿"
            }
            if !result.warnings.isEmpty {
                curatorError = result.warnings.joined(separator: "；")
            }
        } catch {
            curatorError = "生成知识失败：\(error.localizedDescription)"
        }
    }

    func generateArchitecture() {
        guard !buildingArchitecture else { return }
        buildingArchitecture = true
        architectureError = nil
        let root = store.root
        Task {
            do {
                _ = try await WikiArchitectureBuilder.build(root: root)
                await store.reload()
                centerMode = .architecture
            } catch {
                architectureError = "架构划分失败：\(error.localizedDescription)"
            }
            buildingArchitecture = false
        }
    }

    var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "circle.hexagongrid")
                .font(.system(size: 30))
                .foregroundStyle(.tertiary)
            Text("还没有知识条目")
                .font(.system(size: 13, weight: .medium))
            Text("知识存在仓库的 .qiyide/wiki/ 下，随仓库一起提交与 review。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Menu("新建第一条") {
                ForEach(WikiEntryType.allCases) { type in
                    Button(type.title) { create(type: type) }
                }
            }
            .fixedSize()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
