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

    @StateObject private var service: AIReviewService
    @State private var limit: Int = 20
    @State private var layerFilter: LayerFilter = .all
    @State private var selection: String?
    @State private var showLowImportance = false
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

    private var lowToggleRow: some View {
        Button {
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
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: 小组件

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
