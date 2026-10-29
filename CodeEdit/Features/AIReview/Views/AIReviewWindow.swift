//
//  AIReviewWindow.swift
//  CodeEdit
//
//  AI 改动审查窗口：按业务/技术分层、按重要度折叠，提供符号级与影响面信息。
//

import AppKit
import SwiftUI

// MARK: - 窗口

enum AIReviewWindowPresenter {
    private static var openWindows: [NSWindow] = []

    static func show(workspace: WorkspaceDocument?) {
        guard let workspace,
              let manager = workspace.sourceControlWorkspace?.activeManager ?? workspace.sourceControlManager else {
            NotificationManager.shared.post(
                iconSymbol: "info.circle",
                title: NSLocalizedString("AI Change Review", comment: ""),
                description: NSLocalizedString("Open a folder that belongs to a Git repository first.", comment: ""),
                actionButtonTitle: "",
                action: {}
            )
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1060, height: 680),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = NSLocalizedString("AI Change Review", comment: "")
        window.contentView = NSHostingView(rootView: AIReviewView(workspace: workspace, manager: manager))
        window.center()
        window.isReleasedWhenClosed = false
        openWindows.removeAll { !$0.isVisible }
        openWindows.append(window)
        window.makeKeyAndOrderFront(nil)
    }
}

// MARK: - 主视图

struct AIReviewView: View {
    let workspace: WorkspaceDocument

    @Environment(\.openWindow)
    private var openWindow

    @StateObject private var service: AIReviewService
    @StateObject private var wiki: WikiStore
    @State private var limit: Int = 20
    @State private var layerFilter: LayerFilter = .all
    @State private var selection: String?
    @State private var showLowImportance = false
    @State private var curatingID: String?
    @State private var curatorNotice: String?
    @AppStorage("aiReview.onlyImportant") private var onlyImportant: Bool = true

    enum LayerFilter: String, CaseIterable, Identifiable {
        case all, business, technical
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: return "全部"
            case .business: return "业务架构"
            case .technical: return "技术架构"
            }
        }
    }

    init(workspace: WorkspaceDocument, manager: SourceControlManager) {
        self.workspace = workspace
        _service = StateObject(wrappedValue: AIReviewService(manager: manager, workspace: workspace))
        let root = workspace.fileURL ?? URL(fileURLWithPath: NSTemporaryDirectory())
        _wiki = StateObject(wrappedValue: WikiStore(root: root))
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            content
        }
        .frame(minWidth: 860, minHeight: 520)
        .background(Color(nsColor: .textBackgroundColor))
        .task {
            if !wiki.isLoaded { wiki.reload() }
            if service.phase == .idle {
                await service.load(limit: limit)
            }
        }
    }

    // MARK: 工具栏

    private var toolbar: some View {
        HStack(spacing: 10) {
            Picker("", selection: $layerFilter) {
                ForEach(LayerFilter.allCases) { filter in
                    Text(filter.title).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 260)

            Toggle("只看重要", isOn: $onlyImportant)
                .toggleStyle(.checkbox)
                .font(.system(size: 11))

            aiStatusChip

            Spacer()

            if case .loading = service.phase {
                ProgressView().scaleEffect(0.6)
            }

            Picker("", selection: $limit) {
                Text("最近 20 次提交").tag(20)
                Text("最近 50 次提交").tag(50)
                Text("最近 100 次提交").tag(100)
            }
            .labelsHidden()
            .frame(width: 140)
            .onChange(of: limit) { _, newValue in
                Task { await service.load(limit: newValue) }
            }

            Button {
                Task { await service.load(limit: limit) }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("重新分析")

            Button("导出清单") {
                exportManifests()
            }
            .help("写入 <仓库>/.qiyide/changes/")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: 内容

    /// 常驻状态：AI 现在能不能用，点一下直接进设置。
    private var aiStatusChip: some View {
        Button {
            openAISettings()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "sparkles")
                    .font(.system(size: 10))
                Text(service.isNarrativeReady ? "AI 就绪" : "AI 未开启")
                    .font(.system(size: 10))
            }
            .foregroundStyle(service.isNarrativeReady ? Color.accentColor : Color.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(
                        service.isNarrativeReady
                            ? Color.accentColor.opacity(0.12)
                            : Color.secondary.opacity(0.12)
                    )
            )
        }
        .buttonStyle(.plain)
        .help("\(service.narrativeStatusText)——点击打开设置")
    }

    @ViewBuilder
    private var content: some View {
        if case .failed(let message) = service.phase {
            errorView(message)
        } else if service.entries.isEmpty {
            ProgressView("正在分析提交…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            HSplitView {
                listPane.frame(minWidth: 340, idealWidth: 400, maxWidth: 520)
                detailPane.frame(minWidth: 420)
            }
        }
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 24))
                .foregroundStyle(.orange)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
            Button("重试") { Task { await service.load(limit: limit) } }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    // MARK: 列表

    private var matchingEntries: [ReviewEntry] {
        service.entries.filter { entry in
            switch layerFilter {
            case .all: return true
            case .business: return entry.layer != .technical
            case .technical: return entry.layer != .business
            }
        }
    }

    private var importantEntries: [ReviewEntry] {
        matchingEntries.filter { $0.importance != .low }
    }

    private var lowEntries: [ReviewEntry] {
        matchingEntries.filter { $0.importance == .low }
    }

    private var listPane: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if matchingEntries.isEmpty {
                    Text("没有可分析的提交")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(16)
                }

                if !service.isNarrativeReady {
                    narrativeBanner
                    Divider()
                }

                ForEach(onlyImportant ? importantEntries : (showLowImportance ? matchingEntries : importantEntries)) {
                    entry in
                    entryRow(entry)
                    Divider()
                }

                if !onlyImportant, !lowEntries.isEmpty {
                    lowToggleRow
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.35))
    }

    /// 未配置时的引导条：说明这个功能存在，并给一个直达设置的入口。
    private var narrativeBanner: some View {
        Button {
            openAISettings()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 10))
                Text("开启 AI 叙述，可为每次提交生成一句话说明")
                    .font(.system(size: 11))
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 4)
                Text("去设置")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.accentColor)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var lowToggleRow: some View {        Button {
            showLowImportance.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: showLowImportance ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                Text("低优先级 \(lowEntries.count) 条（构建配置 / 文案 / 小改动）")
                    .font(.system(size: 11))
                Spacer()
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
    }

    private func entryRow(_ entry: ReviewEntry) -> some View {
        Button {
            selection = entry.id
        } label: {
            HStack(alignment: .top, spacing: 8) {
                importanceBadge(entry.importance)
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.subject)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    HStack(spacing: 6) {
                        Text(entry.shortHash)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                        layerChip(entry.layer)
                        Text("+\(entry.added) −\(entry.removed)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                        if service.isReviewed(entry.id) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(.green)
                        }
                    }
                    Text(entry.summary)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .background(selection == entry.id ? Color.accentColor.opacity(0.12) : Color.clear)
        }
        .buttonStyle(.plain)
    }

    // MARK: 详情

    @ViewBuilder
    private var detailPane: some View {
        if let entry = service.entries.first(where: { $0.id == selection }) {
            detail(entry)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "rectangle.and.text.magnifyingglass")
                    .font(.system(size: 26))
                    .foregroundStyle(.tertiary)
                Text("选择左侧一条改动查看详情")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func detail(_ entry: ReviewEntry) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header(entry)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    relatedKnowledge(entry)
                    narrativeSection(entry)

                    section("摘要") {
                        Text(entry.summary)
                            .font(.system(size: 12))
                            .textSelection(.enabled)
                        if !entry.signals.isEmpty {
                            HStack(spacing: 4) {
                                ForEach(entry.signals, id: \.self) { signal in
                                    chip(signal.title, color: signalColor(signal))
                                }
                            }
                        }
                    }

                    section("影响面") {
                        HStack(spacing: 16) {
                            statBlock("业务文件", "\(entry.businessFiles.count)")
                            statBlock("技术文件", "\(entry.technicalFiles.count)")
                            statBlock("声明变化", "\(entry.symbols.count)")
                            statBlock("增删行", "+\(entry.added) −\(entry.removed)")
                        }
                    }

                    section("声明级变化") {
                        if entry.symbols.isEmpty {
                            Text("仅函数体变化，未触及声明（或非 Swift 文件）")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        } else {
                            VStack(alignment: .leading, spacing: 3) {
                                ForEach(entry.symbols.prefix(20)) { symbol in
                                    HStack(spacing: 6) {
                                        Text(symbol.change.symbol)
                                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                                            .foregroundStyle(symbol.change == .added ? .green : .red)
                                        Text(symbol.display)
                                            .font(.system(size: 11))
                                        Text((symbol.path as NSString).lastPathComponent)
                                            .font(.system(size: 10))
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                            }
                        }
                    }

                    section("文件（按层）") {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(entry.files) { file in
                                Button {
                                    openFile(file.path)
                                } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: file.isTest ? "checkmark.seal" : "doc.text")
                                            .font(.system(size: 10))
                                            .foregroundStyle(.tertiary)
                                        Text(file.path)
                                            .font(.system(size: 11, design: .monospaced))
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                        layerChip(file.layer)
                                        Spacer()
                                        Text("+\(file.added) −\(file.removed)")
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(14)
            }
        }
    }

    /// 把一次改动沉淀成知识草稿。产出的永远是 draft，由人在知识库里确认。
    private func curate(_ entry: ReviewEntry) {
        guard AINarrativeStore.shared.isReady else {
            curatorNotice = AINarrativeStore.shared.blockedReason ?? "模型未配置"
            return
        }
        let label = AINarrativeStore.shared.providerLabel
        let input = WikiCurationInput(
            subject: entry.subject,
            files: entry.files.map(\.path),
            signals: entry.signals.map(\.title),
            diff: service.patch(for: entry)
        )
        curatingID = entry.id
        curatorNotice = nil
        Task {
            do {
                let draft = try await WikiCurator.propose(
                    input: input,
                    existing: wiki.entries
                )
                let applied = try wiki.applyDraft(
                    draft,
                    generatedBy: label,
                    sources: Array(input.files.prefix(8))
                )
                curatorNotice = "已生成草稿「\(applied.title)」，到知识库确认后生效"
            } catch {
                curatorNotice = error.localizedDescription
            }
            curatingID = nil
        }
    }

    private func header(_ entry: ReviewEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                importanceBadge(entry.importance)
                Text(entry.subject)
                    .font(.system(size: 13, weight: .medium))
                    .textSelection(.enabled)
                Spacer()
                Button(service.isReviewed(entry.id) ? "标记未读" : "标记已读") {
                    service.toggleReviewed(entry.id)
                }
            }
            if let curatorNotice {
                Text(curatorNotice)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            HStack(spacing: 8) {
                Text(entry.shortHash)
                    .font(.system(size: 10, design: .monospaced))
                    .textSelection(.enabled)
                Text(entry.author)
                Text(entry.date.formatted(date: .abbreviated, time: .shortened))
                layerChip(entry.layer)
                Text("重要度 \(entry.score)")
                Spacer()
                Button("复制补丁") {
                    copyPatch(entry)
                }
                Button("复制清单") {
                    copyManifest(entry)
                }
                Button(curatingID == entry.id ? "整理中…" : "沉淀为知识") {
                    curate(entry)
                }
                .disabled(curatingID != nil)
                .help("让模型从这次改动里提炼一条知识草稿，确认后才入库")
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: 小组件

    /// 相关知识：按改动文件路径匹配知识库条目。
    ///
    /// 这是知识库真正被用到的时刻——审 diff 时旁边直接摆出「这个文件过去踩过什么」。
    @ViewBuilder
    private func relatedKnowledge(_ entry: ReviewEntry) -> some View {
        let related = wiki.entries(matchingPaths: entry.files.map(\.path))
        if !related.isEmpty {
            section("相关知识 \(related.count)") {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(related) { item in
                        Button {
                            WikiWindowPresenter.show(workspace: workspace)
                        } label: {
                            HStack(alignment: .top, spacing: 6) {
                                Circle()
                                    .fill(WikiGraphView.color(for: item.type))
                                    .frame(width: 6, height: 6)
                                    .padding(.top, 5)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(item.title)
                                        .font(.system(size: 11, weight: .medium))
                                    if !item.summary.isEmpty {
                                        Text(item.summary)
                                            .font(.system(size: 10))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("在知识库中查看")
                    }
                }
            }
        }
    }

    /// 模型叙述。规则摘要始终在上方单独展示，这里只补一句话人话解释。
    @ViewBuilder
    private func narrativeSection(_ entry: ReviewEntry) -> some View {
        section("AI 叙述") {
            switch service.narrative(for: entry) {
            case .unavailable(let reason):
                HStack(spacing: 8) {
                    Text(reason)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Button("去设置") { openAISettings() }
                        .controlSize(.small)
                        .buttonStyle(.link)
                }
            case .idle:
                Button {
                    service.generateNarrative(for: entry)
                } label: {
                    Label("生成叙述", systemImage: "sparkles")
                        .font(.system(size: 11))
                }
                .controlSize(.small)
            case .streaming(let text):
                VStack(alignment: .leading, spacing: 6) {
                    Text(text.isEmpty ? "正在生成…" : text)
                        .font(.system(size: 12))
                        .foregroundStyle(text.isEmpty ? .secondary : .primary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        ProgressView().scaleEffect(0.45).frame(width: 12, height: 12)
                        Button("停止") {
                            service.cancelNarrative(for: entry)
                        }
                        .controlSize(.small)
                        .buttonStyle(.link)
                    }
                }
            case .ready(let text, let cached):
                VStack(alignment: .leading, spacing: 6) {
                    Text(text)
                        .font(.system(size: 12))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        chip(cached ? "缓存" : service.narrativeProviderLabel, color: .secondary)
                        if service.redactions(for: entry) > 0 {
                            chip("已脱敏 \(service.redactions(for: entry)) 处", color: .orange)
                                .help("发送前替换了手机号、身份证、邮箱、密钥等敏感值")
                        }
                        Button("重新生成") {
                            service.generateNarrative(for: entry, force: true)
                        }
                        .controlSize(.small)
                        .buttonStyle(.link)
                    }
                }
            case .failed(let message):
                VStack(alignment: .leading, spacing: 6) {
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("重试") {
                        service.generateNarrative(for: entry, force: true)
                    }
                    .controlSize(.small)
                    .buttonStyle(.link)
                }
            }
        }
    }


    /// 打开「设置 → AI」。设置是自定义 Window 场景，只能通过 openWindow 打开。
    private func openAISettings() {
        SettingsNavigation.shared.request(.ai)
        openWindow(sceneID: .settings)
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            content()
        }
    }

    private func statBlock(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.system(size: 15, weight: .medium))
                .monospacedDigit()
            Text(title)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }

    private func importanceBadge(_ importance: ReviewEntry.Importance) -> some View {
        Text(importance.title)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: 20, height: 16)
            .background(importanceColor(importance))
            .clipShape(RoundedRectangle(cornerRadius: 3))
    }

    private func layerChip(_ layer: ChangeLayer) -> some View {
        Text(layer.shortTitle)
            .font(.system(size: 9))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(Color.secondary.opacity(0.35), lineWidth: 0.5)
            )
    }

    private func chip(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(color.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private func importanceColor(_ importance: ReviewEntry.Importance) -> Color {
        switch importance {
        case .high: return .red
        case .medium: return .orange
        case .low: return .secondary
        }
    }

    private func signalColor(_ signal: RiskSignal) -> Color {
        switch signal {
        case .regression, .silentFailure: return .red
        case .publicAPI, .boundaryArithmetic, .concurrency, .persistence: return .orange
        default: return .secondary
        }
    }

    // MARK: 动作

    private func copyPatch(_ entry: ReviewEntry) {
        guard let patch = service.patches[entry.id] else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(patch, forType: .string)
    }

    private func copyManifest(_ entry: ReviewEntry) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(service.manifestJSON(for: entry), forType: .string)
    }

    private func exportManifests() {
        do {
            guard let directory = try service.exportManifests() else { return }
            NotificationManager.shared.post(
                iconSymbol: "checkmark.circle",
                title: NSLocalizedString("Manifests exported", comment: ""),
                description: directory.path,
                actionButtonTitle: "",
                action: {}
            )
        } catch {
            NotificationManager.shared.post(
                iconSymbol: "exclamationmark.triangle",
                title: NSLocalizedString("Export failed", comment: ""),
                description: error.localizedDescription,
                actionButtonTitle: "",
                action: {}
            )
        }
    }

    private func openFile(_ path: String) {
        guard let file = workspace.workspaceFileManager?.getFile(path, createIfNotFound: true) else { return }
        workspace.editorManager?.openTab(item: file)
    }
}
