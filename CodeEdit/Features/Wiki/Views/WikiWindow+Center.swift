//
//  WikiWindow+Center.swift
//  CodeEdit
//
//  中间栏：当前视角的内容和局部操作。视角导航与任务状态留在窗口外层。
//
//  「哪个视图」和「这个视图能做什么操作」放在一起：
//  分开写就会出现「切到架构模式还留着导图的按钮」这种事。
//

import SwiftUI

extension WikiWindowView {

    var centerPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
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
                    // 页签多了一个之后，中间栏最窄时放不下固定宽度：让视角菜单先让出空间。
                    .frame(minWidth: 84, idealWidth: 118, maxWidth: 124)
                    .help("建模可编辑；其余视角是同一份模型的只读投影")
                }

                Spacer()

                if centerMode == .mindmap {
                    mindMapActions
                        .fixedSize()
                        .layoutPriority(1)
                } else if centerMode == .architecture {
                    if !store.architecture.isEmpty {
                        Text("重建时保留当前架构，新结果保存后再替换")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Menu {
                        Button("生成架构视图") { generateArchitecture() }
                        Button("仅静态分析") { generateArchitecture(mode: .staticOnly) }
                    } label: {
                        Text(buildingArchitecture ? "生成中…" : (store.architecture.isEmpty ? "生成架构视图" : "重新生成"))
                    }
                    .disabled(buildingArchitecture)
                    .controlSize(.small)
                    .help("分析源代码与依赖；必要时调用 AI，进度显示在上方任务条")
                    Button("任务详情") { showsArchitectureTask = true }.controlSize(.small)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)

            Divider()

            switch centerMode {
            case .knowledge:
                WikiKnowledgeOverview(
                    store: store, entries: filteredEntries,
                    onSelect: { selection = $0 },
                    onCreateRule: { create(type: .rule) },
                    onShowContext: { showKnowledgeContext = true }
                )
            case .mindmap:
                MindMapView(
                    store: domains,
                    selection: mindMapSelection,
                    displayGraph: activeSpec == nil ? nil : displayGraph,
                    isReadOnly: activeSpec != nil,
                    graphToken: (activeSpec?.id ?? "model") + "#\(domains.revision)"
                )
            case .structure:
                StructureMapView(
                    store: domains,
                    root: store.root,
                    selectedDomain: mindMapSelection,
                    onOpenFile: openSource,
                    knowledgeEntries: store.entries,
                    knowledgeReport: store.knowledgeReport,
                    onSelectKnowledge: { selection = $0 }
                )
            case .architecture:
                if let error = store.architectureReadError {
                    HStack(alignment: .top, spacing: 10) {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.system(size: 12)).foregroundStyle(.orange).textSelection(.enabled)
                        Spacer()
                        Button("重试读取") { Task { await store.reload() } }.controlSize(.small)
                    }.padding(12)
                }
                if store.architecture.isEmpty {
                    WikiArchitectureTaskContent(
                        snapshot: architectureTask.snapshot,
                        canRetrySave: architectureTask.canRetrySave,
                        onStart: { generateArchitecture() },
                        onStatic: { generateArchitecture(mode: .staticOnly) },
                        onRetry: { architectureTask.retry() },
                        onSettings: openArchitectureSettings
                    )
                } else {
                    WikiArchitectureView(architecture: store.architecture, selection: $selectedArchitectureDomain)
                }
            case .graph:
                WikiGraphView(graph: store.graph, selection: $selection)
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

    func generateArchitecture(mode: WikiArchitectureMode = .automatic) {
        dismissedArchitectureTask = nil
        if !architectureTask.start(mode: mode) { showsArchitectureTask = true }
    }

}
