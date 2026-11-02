//
//  WikiWindow+Toolbar.swift
//  CodeEdit
//
//  窗口上方三条横带：工具栏（搜索/筛选/动作）、流水线状态（识别→锚定→知识→审核）、批量操作条。
//
//  单独成文件是因为它们和「中间画什么」无关：
//  显示什么由数据推导，能点什么由当前阶段决定，改的都是同一条链路。
//

import AppKit
import SwiftUI

extension WikiWindowView {

    // MARK: 工具栏

    var toolbar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            TextField("搜索标题、标签、正文…", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .frame(width: 220)

            Picker("", selection: $typeFilter) {
                Text("全部类型").tag(WikiEntryType?.none)
                Divider()
                ForEach(WikiEntryType.allCases) { type in
                    Text(type.title).tag(WikiEntryType?.some(type))
                }
            }
            .labelsHidden()
            .frame(width: 110)

            Spacer()

            Toggle("只看草稿", isOn: $showDraftsOnly)
                .toggleStyle(.checkbox)
                .font(.system(size: 11))

            // 草稿多的时候没人愿意一条条点。这里给一个「一键全选草稿」的入口，
            // 但只做选中、不做直接确认——AI 写的东西仍然要人看过再签字。
            let draftCount = filteredEntries.filter(\.isDraft).count
            if draftCount > 1 {
                Button {
                    multiSelection = Set(filteredEntries.filter(\.isDraft).map(\.id))
                    selection = multiSelection.first
                } label: {
                    Text("草稿 \(draftCount)")
                        .font(.system(size: 11))
                }
                .buttonStyle(.link)
                .help("选中当前可见的全部草稿，再批量确认或丢弃")
            }

            Text(domains.graph.domains.isEmpty
                 ? "\(store.entries.count) 条知识"
                 : "\(domains.graph.domains.count) 域 · \(store.entries.count) 条知识")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            if curating {
                ProgressView().scaleEffect(0.45).frame(width: 14, height: 14)
            } else {
                Menu {
                    Button("整个仓库建档…") { showIngest = true }
                    Button("生成架构视图…") {
                        centerMode = .architecture
                        generateArchitecture()
                    }
                    Divider()
                    Button("未提交的改动") { curate(.workingTree) }
                    Button("最近一次提交") { curate(.lastCommit) }
                    Button("当前打开的文件") { curate(.currentFile) }
                        .disabled(activeFileURL == nil)
                    Divider()
                    Button("选中条目关联的代码") { curate(.selectedEntrySources) }
                        .disabled(selectedEntrySources.isEmpty)
                } label: {
                    Label("AI 整理", systemImage: "sparkles")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("选择输入源，让模型提炼一条待确认的知识草稿")
            }

            // 重扫在后台跑（几百毫秒），这里是唯一会给反馈的地方：
            // 转起来说明在读盘，不转说明扫描已经结束。
            Button {
                Task { await store.reload() }
            } label: {
                if store.isReloading {
                    ProgressView().scaleEffect(0.4).frame(width: 14, height: 14)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .disabled(store.isReloading)
            .help("重新扫描 .qiyide/wiki")

            Menu {
                Button("导出领域大纲（Markdown）") { exportOutline() }
                Button("导出领域模型（JSON）") { exportModel() }
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(domains.graph.isEmpty)
            .help("导出当前领域模型")

            Menu {
                ForEach(WikiEntryType.allCases) { type in
                    Button(type.title) { create(type: type) }
                }
            } label: {
                Label("新建", systemImage: "plus")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: 流水线状态

    /// 建模到查阅的五个阶段。全部由数据推导，不落盘——
    /// 存一份「已完成」的状态就会有它和现实脱节的那天。
    enum Stage {
        case identify, anchor, generate, review, ready
    }

    var stage: Stage {
        if domains.graph.isEmpty { return .identify }
        if !domains.isLocked { return .anchor }
        if store.entries.isEmpty { return .generate }
        if !store.drafts.isEmpty { return .review }
        return .ready
    }

    var stageStrip: some View {
        HStack(spacing: 5) {
            stageChip("识别", done: !domains.graph.isEmpty, active: stage == .identify) {
                Task { await domains.analyze() }
            }
            stageArrow
            stageChip("锚定", done: domains.isLocked, active: stage == .anchor) {
                domains.lock()
            }
            stageArrow
            stageChip(
                "知识",
                done: !store.entries.isEmpty,
                active: stage == .generate,
                badge: store.entries.isEmpty ? nil : "\(store.entries.count)"
            ) {
                generateMissingKnowledge()
            }
            stageArrow
            stageChip(
                "审核",
                done: !store.entries.isEmpty && store.drafts.isEmpty,
                active: stage == .review,
                badge: store.drafts.isEmpty ? nil : "\(store.drafts.count)"
            ) {
                // 只筛不确认：AI 写的东西仍然要人一条条看过。
                selectedDomain = nil
                showDraftsOnly = true
            }

            Spacer()

            Button {
                showCoherence = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: (coherence?.isEmpty ?? true)
                          ? "checkmark.shield"
                          : "exclamationmark.shield")
                        .font(.system(size: 9))
                    Text(coherence.map { $0.isEmpty ? "一致" : "体检 \($0.total)" } ?? "体检")
                        .font(.system(size: 10).monospacedDigit())
                }
                .foregroundStyle(coherence?.isEmpty == false ? Color.orange : Color.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("检查领域模型、知识条目与代码之间对不上的地方")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }

    func stageChip(
        _ title: String,
        done: Bool,
        active: Bool,
        badge: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: done
                      ? "checkmark.circle.fill"
                      : (active ? "circle.dotted" : "circle"))
                    .font(.system(size: 9))
                    .foregroundStyle(done ? Color.green : (active ? Color.accentColor : Color.secondary))
                Text(title)
                    .font(.system(size: 10, weight: active ? .medium : .regular))
                    .foregroundStyle(active ? Color.primary : Color.secondary)
                if let badge {
                    Text(badge)
                        .font(.system(size: 9).monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(active ? Color.accentColor.opacity(0.10) : Color.clear, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(helpText(for: title))
    }

    func helpText(for stage: String) -> String {
        switch stage {
        case "识别": return "扫包结构、命名、调用与注释，产出领域候选"
        case "锚定": return "人工校正后锁定，避免下次识别覆盖"
        case "知识": return "给还没有知识的域生成草稿"
        case "审核": return "筛出草稿逐条确认"
        default: return ""
        }
    }

    var stageArrow: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 7))
            .foregroundStyle(.quaternary)
    }


    /// 导出领域大纲。原独立建模窗口里的功能，合并后搬到这里。
    func exportOutline() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "domains.md"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? domains.markdownOutline().write(to: url, atomically: true, encoding: .utf8)
    }

    func exportModel() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "domains.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(domains.graph) else { return }
        try? data.write(to: url, options: .atomic)
    }

    // MARK: 批量操作

    var selectedEntries: [WikiEntry] {
        multiSelection.compactMap { store.entry(id: $0) }
    }

    var selectedDrafts: [WikiEntry] {
        selectedEntries.filter(\.isDraft)
    }

    var batchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "checklist")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text("已选 \(selectedEntries.count) 项")
                .font(.system(size: 11, weight: .medium))
            if !selectedDrafts.isEmpty {
                Text("草稿 \(selectedDrafts.count)")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
            }
            if let batchNotice {
                Text(batchNotice)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("确认草稿") {
                let count = store.confirm(ids: selectedDrafts.map(\.id))
                batchNotice = "已确认 \(count) 条"
                pruneSelection()
            }
            .controlSize(.small)
            .disabled(selectedDrafts.isEmpty)

            Button("丢弃草稿") {
                let count = store.discardDrafts(ids: selectedDrafts.map(\.id))
                batchNotice = "已丢弃 \(count) 条"
                pruneSelection()
            }
            .controlSize(.small)
            .disabled(selectedDrafts.isEmpty)

            Button("删除…") { showBatchDelete = true }
                .controlSize(.small)

            Divider().frame(height: 14)

            Button("全选可见") {
                multiSelection = Set(filteredEntries.map(\.id))
                selection = filteredEntries.first?.id
            }
            .controlSize(.small)

            Button("清除") {
                multiSelection = []
                selection = nil
                batchNotice = nil
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.accentColor.opacity(0.06))
    }

    /// 批量操作后清理已不存在的选中项。
    func pruneSelection() {
        let alive = Set(store.entries.map(\.id))
        multiSelection.formIntersection(alive)
        if let current = selection, !alive.contains(current) {
            selection = multiSelection.first
        }
    }
}
