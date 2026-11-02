//
//  WikiWindow.swift
//  CodeEdit
//
//  知识库窗口：左侧条目列表、中间图谱、右侧详情与编辑。
//
//  三栏放在一个窗口里，是为了让「看条目」和「看它在图里的位置」不必来回切——
//  知识最有用的时候，是你能同时看到它和它的邻居。
//

import AppKit
import SwiftUI

// MARK: - 窗口

enum WikiWindowPresenter {
    private static var openWindows: [NSWindow] = []

    static func show(workspace: WorkspaceDocument?) {
        guard let workspace, let root = workspace.fileURL else {
            NotificationManager.shared.post(
                iconSymbol: "info.circle",
                title: NSLocalizedString("Knowledge Base", comment: ""),
                description: NSLocalizedString("Open a folder first — knowledge entries live in .qiyide/wiki.", comment: ""),
                actionButtonTitle: "",
                action: {}
            )
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 720),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = NSLocalizedString("Knowledge Base", comment: "")
        window.contentView = NSHostingView(rootView: WikiWindowView(root: root, workspace: workspace))
        window.center()
        window.isReleasedWhenClosed = false
        openWindows.removeAll { !$0.isVisible }
        openWindows.append(window)
        window.makeKeyAndOrderFront(nil)
    }
}

// MARK: - 主视图

struct WikiWindowView: View {

    /// 用来定位「当前打开的文件」，作为知识生成的输入源之一。
    let workspace: WorkspaceDocument?

    @StateObject private var store: WikiStore
    /// 领域模型。合并后知识库和建模共用这一个窗口，两套数据各自持有：
    /// 条目是「人写的知识」，领域模型是「算出来的结构」，生命周期不同
    /// （模型会被重新识别覆盖，条目不会），混成一个 store 反而危险。
    @StateObject private var domains: DomainModelStore
    /// 建档是 App 级长任务：这里只订阅，不持有。关掉这个窗口任务也不会中断。
    @ObservedObject private var ingestion = WikiCurationRunner.shared
    @State private var showIngest = false
    @State private var query = ""
    @State private var typeFilter: WikiEntryType?
    @State private var selection: String?
    /// 选中的域（`MindNode.id`）。它同时是左栏条目的过滤条件。
    @State private var selectedDomain: String?
    /// 导图模式下选的视角：nil 表示建模视图（可编辑），否则只读投影。
    @State private var activeSpec: ViewSpec?
    /// 投影结果缓存：投影要遍历全部节点，不能每次 body 都算。
    @State private var projected: MindGraph?
    @State private var showBackfill = false
    /// 多选集合（批量操作的对象）。`selection` 始终是「当前展示详情」的那一条。
    @State private var multiSelection: Set<String> = []
    @State private var showBatchDelete = false
    @State private var batchNotice: String?

    /// 中间栏的三种看法：
    /// 导图看「域怎么划」，图谱看「知识谁连着谁」，架构看「系统分几层」。
    enum CenterMode: String, CaseIterable, Identifiable {
        case mindmap
        case graph
        case architecture
        var id: String { rawValue }
        var title: String {
            switch self {
            case .mindmap: return "导图"
            case .graph: return "图谱"
            case .architecture: return "架构"
            }
        }
    }

    @State private var centerMode: CenterMode = .mindmap
    @State private var buildingArchitecture = false
    @State private var architectureError: String?
    @State private var editing: WikiEntry?
    @State private var deleteTarget: WikiEntry?
    @State private var showDraftsOnly = false
    @State private var curating = false
    @State private var curatorMessage: String?
    @State private var curatorError: String?

    init(
        root: URL,
        workspace: WorkspaceDocument?,
        autoLoad: Bool = false,
        initiallySelectedDomain: String? = nil
    ) {
        self.workspace = workspace
        let wikiStore = WikiStore(root: root)
        // 预览/离屏渲染没有视图生命周期，`.task` 不会跑，这里允许同步载入。
        if autoLoad {
            MainActor.assumeIsolated { wikiStore.reload() }
        }
        _store = StateObject(wrappedValue: wikiStore)
        _domains = StateObject(wrappedValue: DomainModelStore(root: root))
        _selectedDomain = State(initialValue: initiallySelectedDomain)
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if let curatorMessage {
                statusStrip(curatorMessage, color: .secondary, symbol: "sparkles")
                Divider()
            }
            if let curatorError {
                statusStrip(curatorError, color: .red, symbol: "exclamationmark.triangle")
                Divider()
            }
            if let architectureError {
                statusStrip(architectureError, color: .red, symbol: "exclamationmark.triangle")
                Divider()
            }
            if multiSelection.count > 1 {
                batchBar
                Divider()
            }
            content
        }
        .frame(minWidth: 900, minHeight: 520)
        .background(Color(nsColor: .textBackgroundColor))
        .task {
            if !store.isLoaded { store.reload() }
        }
        .onChange(of: selection) { _, _ in
            editing = nil
        }
        .sheet(isPresented: $showIngest, onDismiss: { store.reload() }) {
            WikiIngestSheet(runner: ingestion, store: store) {
                showIngest = false
            }
        }
        .sheet(isPresented: $showBackfill) {
            DomainBackfillSheet(root: store.root, graph: domains.graph)
        }
        .onAppear { refreshProjection() }
        .onChange(of: activeSpec) { _, _ in refreshProjection() }
        .onChange(of: domains.revision) { _, _ in refreshProjection() }
        .alert("删除 \(selectedEntries.count) 条知识？", isPresented: $showBatchDelete) {
            Button("移到废纸篓", role: .destructive) {
                let count = store.delete(ids: selectedEntries.map(\.id))
                batchNotice = "已删除 \(count) 条"
                pruneSelection()
                showBatchDelete = false
            }
            Button("取消", role: .cancel) { showBatchDelete = false }
        } message: {
            Text("这些条目会移到废纸篓，可以恢复。")
        }
        .alert("删除这条知识？", isPresented: deleteBinding, presenting: deleteTarget) { entry in
            Button("移到废纸篓", role: .destructive) {
                try? store.delete(entry)
                if selection == entry.id { selection = nil }
                deleteTarget = nil
            }
            Button("取消", role: .cancel) { deleteTarget = nil }
        } message: { entry in
            Text("「\(entry.title)」会移到废纸篓，可以恢复。")
        }
    }

    private var deleteBinding: Binding<Bool> {
        Binding(
            get: { deleteTarget != nil },
            set: { if !$0 { deleteTarget = nil } }
        )
    }

    // MARK: 工具栏

    private var toolbar: some View {
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

            Button {
                store.reload()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("重新扫描 .qiyide/wiki")

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

    // MARK: 内容

    @ViewBuilder
    private var content: some View {
        if let message = store.errorMessage {
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 22))
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Button("重试") { store.reload() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if store.isLoaded && store.entries.isEmpty && domains.graph.isEmpty {
            emptyState
        } else {
            HSplitView {
                listPane.frame(minWidth: 220, idealWidth: 260, maxWidth: 340)
                centerPane.frame(minWidth: 320)
                detailPane.frame(minWidth: 300, idealWidth: 340, maxWidth: 420)
            }
        }
    }

    /// 当前要画的图。建模模式直接用原模型，其余用缓存的投影结果。
    private var displayGraph: MindGraph {
        guard let spec = activeSpec else { return domains.graph }
        return projected ?? ViewProjector.project(domains.graph, spec: spec)
    }

    /// 重算投影。只在「换视角」或「模型变了」时调用。
    private func refreshProjection() {
        guard let spec = activeSpec else {
            projected = nil
            return
        }
        projected = ViewProjector.project(domains.graph, spec: spec)
    }

    /// 导图选中的是「节点」，左栏和详情关心的是「域」。
    ///
    /// 点到模块时归到它的父域：否则用户在图上点开一个模块，左栏过滤会突然清空、
    /// 右侧又停在一个模块上，三栏各说各话。模块信息在导图卡片和悬停提示里已有。
    private var mindMapSelection: Binding<String?> {
        Binding(
            get: { selectedDomain },
            set: { nodeID in
                guard let nodeID else {
                    selectedDomain = nil
                    return
                }
                if let node = domains.graph.node(nodeID) {
                    selectedDomain = node.kind == .module ? node.parentID : nodeID
                } else {
                    selectedDomain = nodeID
                }
                selection = nil
                multiSelection = []
            }
        )
    }

    private var centerPane: some View {
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
    private var mindMapActions: some View {
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
    private func generateMissingKnowledge() {
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

    private func generateArchitecture() {
        guard !buildingArchitecture else { return }
        buildingArchitecture = true
        architectureError = nil
        let root = store.root
        Task {
            do {
                _ = try await WikiArchitectureBuilder.build(root: root)
                store.reload()
                centerMode = .architecture
            } catch {
                architectureError = "架构划分失败：\(error.localizedDescription)"
            }
            buildingArchitecture = false
        }
    }

    private var emptyState: some View {
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

    // MARK: 列表

    /// 可见列表。批量操作只作用于「可见」范围，避免选中项被筛选条件藏起来。
    private var filteredEntries: [WikiEntry] {
        var base = query.isEmpty ? store.entries : store.search(query)
        if let selectedDomain {
            if selectedDomain == Self.unassignedKey {
                base = base.filter { $0.domains.isEmpty }
            } else {
                base = base.filter { $0.domains.contains(selectedDomain) }
            }
        }
        if let typeFilter { base = base.filter { $0.type == typeFilter } }
        if showDraftsOnly { base = base.filter(\.isDraft) }
        return base
    }

    /// 「未归类」在左栏是一个伪域。用哨兵值而不是再加一个 Bool 状态位，
    /// 是为了让 `selectedDomain` 始终只有一个含义：当前过滤条件。
    private static let unassignedKey = "__unassigned__"

    private var listPane: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if !domains.graph.domains.isEmpty {
                    domainSection
                }
                entrySection
            }
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.35))
    }

    /// 领域段：条目按域聚合之后，左栏要先回答「有哪些域」。
    ///
    /// 只读 `domains.graph`（锁定或识别结果）。没有模型时整段不出现，
    /// 左栏退回成纯条目列表，和合并前一样能用。
    ///
    /// 和条目列表放在**同一个** ScrollView 里：拆成两个各自滚动时，
    /// 领域段被高度上限裁掉半行，看起来像渲染坏了；而且用户得猜哪边能滚。
    @ViewBuilder
    private var domainSection: some View {
        let nodes = domains.graph.domains

        HStack(spacing: 5) {
            Text("领域")
            Text("\(nodes.count)")
                .monospacedDigit()
            Spacer()
            if selectedDomain != nil {
                Button("清除") { selectedDomain = nil }
                    .buttonStyle(.link)
                    .font(.system(size: 9))
            }
        }
        .font(.system(size: 10))
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 10)
        .padding(.top, 7)
        .padding(.bottom, 2)

        ForEach(nodes) { node in
            domainRow(node)
        }

        if !store.unassignedEntries.isEmpty {
            unassignedRow
        }

        // 一条都没打标时，域下面的数字全是 0，看起来像「整个知识库都缺」。
        // 实际情况是「还没建立归属」，给一条直达补写的入口，而不是让每行都报警。
        if store.taggedDomainIDs.isEmpty && !store.entries.isEmpty {
            Button {
                showBackfill = true
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "link.badge.plus")
                        .font(.system(size: 9))
                    Text("\(store.entries.count) 条知识未标归属 · 去补写")
                        .font(.system(size: 10))
                    Spacer()
                }
                .foregroundStyle(.orange)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }

        Divider().padding(.top, 4)
    }

    private func domainRow(_ node: MindNode) -> some View {
        let count = store.entries(inDomain: node.id).count
        let isSelected = selectedDomain == node.id
        // 还没打标时显示「—」而不是「缺口」：0 不代表没有知识，只代表没建立归属。
        let tagged = !store.taggedDomainIDs.isEmpty
        return Button {
            selectedDomain = isSelected ? nil : node.id
            selection = nil
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(Color.accentColor.opacity(0.7))
                    .frame(width: 6, height: 6)
                Text(node.displayTitle)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if !tagged {
                    Text("—")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                } else {
                    Text(count == 0 ? "缺口" : "\(count) 条")
                        .font(.system(size: 9).monospacedDigit())
                        .foregroundStyle(count == 0 ? Color.orange : Color.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .background(isSelected ? Color.accentColor.opacity(0.14) : Color.clear)
        }
        .buttonStyle(.plain)
        .help("\(node.classCount) 类 · \(node.fileCount) 文件 · \(count) 条知识")
    }

    private var unassignedRow: some View {
        let isSelected = selectedDomain == Self.unassignedKey
        return Button {
            selectedDomain = isSelected ? nil : Self.unassignedKey
            selection = nil
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(Color.orange.opacity(0.65))
                    .frame(width: 6, height: 6)
                Text("未归类")
                    .font(.system(size: 11))
                Spacer(minLength: 4)
                Text("\(store.unassignedEntries.count)")
                    .font(.system(size: 9).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .background(isSelected ? Color.accentColor.opacity(0.14) : Color.clear)
        }
        .buttonStyle(.plain)
        .help("没有归属任何领域的条目")
    }

    @ViewBuilder
    private var entrySection: some View {
        if !domains.graph.domains.isEmpty || selectedDomain != nil {
            HStack(spacing: 5) {
                Text(filterTitle)
                Text("\(filteredEntries.count)")
                    .monospacedDigit()
                Spacer()
            }
            .font(.system(size: 10))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 10)
            .padding(.top, 7)
            .padding(.bottom, 2)
        }

        if filteredEntries.isEmpty {
            Text(emptyListText)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(16)
        }
        ForEach(filteredEntries) { entry in
            row(entry)
            Divider()
        }
    }

    private var filterTitle: String {
        guard let selectedDomain else { return "全部条目" }
        if selectedDomain == Self.unassignedKey { return "未归类条目" }
        return domains.graph.node(selectedDomain)?.displayTitle ?? "条目"
    }

    private var emptyListText: String {
        if !query.isEmpty { return "没有匹配「\(query)」的条目" }
        if selectedDomain == Self.unassignedKey { return "没有未归类条目" }
        if selectedDomain != nil {
            // 条目全都没打标时，说「这个域没有知识」是错的——
            // 知识在，只是还没建立归属。两者的下一步动作完全不同。
            if store.taggedDomainIDs.isEmpty {
                return "条目还没标归属，先在「域归属」里补写"
            }
            return "这个域还没有知识，可在导图模式点「⋯ → 生成缺失知识」"
        }
        return "没有条目"
    }

    private func row(_ entry: WikiEntry) -> some View {
        Button {
            handleTap(entry)
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Circle()
                    .fill(WikiGraphView.color(for: entry.type))
                    .frame(width: 7, height: 7)
                    .padding(.top, 5)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.displayTitle)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .help(entry.title)
                    HStack(spacing: 5) {
                        Text(entry.type.title)
                        if entry.isDraft {
                            Text("草稿")
                                .foregroundStyle(.orange)
                        }
                        // 每行都查一次度数：必须 O(1)，否则列表是 O(n²)。
                        let degree = store.graph.degree(of: entry.id)
                        if degree > 0 {
                            Text("· \(degree) 关联")
                        }
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    if !entry.summary.isEmpty {
                        Text(entry.summary)
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
            .background(rowBackground(entry))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("确认") { store.confirm(ids: [entry.id]) }
                .disabled(!entry.isDraft)
            Button("丢弃草稿") { store.discardDrafts(ids: [entry.id]) }
                .disabled(!entry.isDraft)
            Divider()
            Button("删除…") { deleteTarget = entry }
            Divider()
            Button("选中同类型全部") {
                multiSelection = Set(filteredEntries.filter { $0.type == entry.type }.map(\.id))
            }
            Button("选中全部草稿") {
                multiSelection = Set(filteredEntries.filter(\.isDraft).map(\.id))
            }
        }
    }

    private func rowBackground(_ entry: WikiEntry) -> Color {
        if selection == entry.id { return Color.accentColor.opacity(0.14) }
        if multiSelection.contains(entry.id) { return Color.accentColor.opacity(0.07) }
        return .clear
    }

    /// 点击语义与 Finder 一致：直接点是单选，⌘ 是切换，Shift 是范围。
    private func handleTap(_ entry: WikiEntry) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            if multiSelection.contains(entry.id) {
                multiSelection.remove(entry.id)
                if selection == entry.id { selection = multiSelection.first }
            } else {
                multiSelection.insert(entry.id)
                selection = entry.id
            }
        } else if flags.contains(.shift), let anchor = selection,
                  let from = filteredEntries.firstIndex(where: { $0.id == anchor }),
                  let to = filteredEntries.firstIndex(where: { $0.id == entry.id }) {
            let range = from <= to ? from...to : to...from
            multiSelection.formUnion(filteredEntries[range].map(\.id))
            selection = entry.id
        } else {
            selection = entry.id
            multiSelection = [entry.id]
        }
    }

    // MARK: 批量操作

    private var selectedEntries: [WikiEntry] {
        multiSelection.compactMap { store.entry(id: $0) }
    }

    private var selectedDrafts: [WikiEntry] {
        selectedEntries.filter(\.isDraft)
    }

    private var batchBar: some View {
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
    private func pruneSelection() {
        let alive = Set(store.entries.map(\.id))
        multiSelection.formIntersection(alive)
        if let current = selection, !alive.contains(current) {
            selection = multiSelection.first
        }
    }

    // MARK: 详情

    @ViewBuilder
    private var detailPane: some View {
        if let draft = editing {
            WikiEntryEditor(
                draft: draft,
                onSave: { saved in
                    try? store.save(saved)
                    editing = nil
                },
                onCancel: { editing = nil },
                onDelete: { deleteTarget = draft }
            )
        } else if let entry = selection.flatMap({ store.entry(id: $0) }) {
            detail(entry)
        } else if let domainID = selectedDomain,
                  domainID != Self.unassignedKey,
                  let node = domains.graph.node(domainID) {
            domainDetail(node)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "sidebar.right")
                    .font(.system(size: 24))
                    .foregroundStyle(.tertiary)
                Text("选择左侧的领域或条目，或点击导图中的节点")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// 域详情：选中左栏的域、或在导图上点一个域时显示。
    ///
    /// 它是「结构」和「知识」的接缝：上半是模型算出来的事实（依据、模块、负责人），
    /// 下半是挂在这个域下的知识条目。在此之前，这两半分处两个窗口。
    private func domainDetail(_ node: MindNode) -> some View {
        let entries = store.entries(inDomain: node.id)
        let modules = domains.graph.children(of: node.id).sorted { $0.classCount > $1.classCount }
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 6) {
                    Text(node.displayTitle)
                        .font(.system(size: 14, weight: .medium))
                        .lineLimit(2)
                    if node.isManual {
                        chip("人工", color: .accentColor)
                    }
                    Spacer()
                    Button("打开导图") {
                        centerMode = .mindmap
                        activeSpec = nil
                    }
                    .controlSize(.small)
                }

                HStack(spacing: 8) {
                    Text("领域")
                    Text("\(node.classCount) 类")
                    Text("\(node.fileCount) 文件")
                    Text("\(entries.count) 条知识")
                        .foregroundStyle(entries.isEmpty ? Color.orange : Color.secondary)
                }
                .font(.system(size: 10))
                .foregroundStyle(.secondary)

                if !node.packages.isEmpty {
                    section("归属包") {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(node.packages.prefix(6), id: \.self) { package in
                                Text(package)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                    }
                }

                if !node.owner.authors.isEmpty || node.owner.manual != nil {
                    section("负责人") {
                        VStack(alignment: .leading, spacing: 2) {
                            if let manual = node.owner.manual {
                                Text("人工指定：\(manual)")
                                    .font(.system(size: 10))
                            }
                            ForEach(node.owner.authors.prefix(4), id: \.name) { author in
                                HStack(spacing: 6) {
                                    Text(author.name)
                                        .font(.system(size: 10, design: .monospaced))
                                    Spacer()
                                    Text("\(author.commits) 次")
                                        .font(.system(size: 9))
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }
                }

                if !node.evidence.isEmpty {
                    section("判定依据") {
                        VStack(alignment: .leading, spacing: 5) {
                            ForEach(Array(node.evidence.enumerated()), id: \.offset) { _, item in
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    chip(item.kind.title, color: .secondary)
                                    Text(item.detail)
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Spacer(minLength: 2)
                                    Text(String(format: "%.0f%%", item.weight * 100))
                                        .font(.system(size: 9).monospacedDigit())
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }
                }

                if !modules.isEmpty {
                    section("包含模块（\(modules.count)）") {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(modules.prefix(12)) { module in
                                HStack(spacing: 6) {
                                    Text(module.displayTitle)
                                        .font(.system(size: 10, design: .monospaced))
                                        .lineLimit(1)
                                    Spacer()
                                    Text("\(module.classCount) 类")
                                        .font(.system(size: 9).monospacedDigit())
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            if modules.count > 12 {
                                Text("…还有 \(modules.count - 12) 个")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }

                section("知识条目（\(entries.count)）") {
                    if entries.isEmpty {
                        HStack(spacing: 6) {
                            Text("这个域还没有知识")
                                .font(.system(size: 10))
                                .foregroundStyle(.orange)
                            Button("生成草稿") { generateMissingKnowledge() }
                                .controlSize(.small)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(entries) { entry in
                                Button {
                                    selection = entry.id
                                } label: {
                                    HStack(spacing: 5) {
                                        Circle()
                                            .fill(WikiGraphView.color(for: entry.type))
                                            .frame(width: 6, height: 6)
                                        Text(entry.displayTitle)
                                            .font(.system(size: 10))
                                            .lineLimit(1)
                                        if entry.isDraft {
                                            Text("草稿")
                                                .font(.system(size: 8))
                                                .foregroundStyle(.orange)
                                        }
                                        Spacer()
                                        Image(systemName: "chevron.right")
                                            .font(.system(size: 7))
                                            .foregroundStyle(.quaternary)
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .padding(14)
        }
    }

    private func detail(_ entry: WikiEntry) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if entry.isDraft {
                draftBanner(entry)
                Divider()
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(WikiGraphView.color(for: entry.type))
                        .frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(entry.displayTitle)
                            .font(.system(size: 13, weight: .medium))
                            .lineLimit(1)
                        if entry.displayTitle != entry.title {
                            Text(entry.title)
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .textSelection(.enabled)
                        }
                    }
                    Spacer()
                    Button("编辑") { editing = entry }
                        .controlSize(.small)
                }
                HStack(spacing: 8) {
                    Text(entry.type.title)
                    Text(entry.updatedAt.formatted(date: .abbreviated, time: .shortened))
                    Spacer()
                }
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            }
            .padding(12)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if !entry.tags.isEmpty {
                        section("标签") {
                            HStack(spacing: 4) {
                                ForEach(entry.tags, id: \.self) { tag in
                                    chip(tag, color: .secondary)
                                }
                            }
                        }
                    }

                    // 所属域：条目与领域模型的唯一连接点。
                    //
                    // 显示的是域 id 去掉前缀后的包路径，而不是域标题——
                    // 标题可以随时改，包路径才是能对着代码核对的锚点。
                    section("所属域") {
                        if entry.domains.isEmpty {
                            HStack(spacing: 5) {
                                chip("未归类", color: .orange)
                                Text("可在「领域建模 → 域归属」补写")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.tertiary)
                            }
                        } else {
                            HStack(spacing: 4) {
                                ForEach(entry.domains, id: \.self) { domain in
                                    Button {
                                        selectedDomain = domain
                                        selection = nil
                                    } label: {
                                        chip(Self.domainLabel(domain), color: .accentColor)
                                    }
                                    .buttonStyle(.plain)
                                    .help("只看这个域（\(domain)）")
                                }
                            }
                        }
                    }

                    if !entry.sources.isEmpty {
                        section("关联代码") {
                            VStack(alignment: .leading, spacing: 3) {
                                ForEach(entry.sources, id: \.self) { source in
                                    Text(source)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                            }
                        }
                    }

                    section("正文") {
                        if entry.body.isEmpty {
                            Text("（空）")
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                        } else {
                            Text(entry.body)
                                .font(.system(size: 12))
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    let backlinks = store.backlinks(of: entry.id)
                    if !backlinks.isEmpty {
                        section("反向链接 \(backlinks.count)") {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(backlinks) { link in
                                    Button {
                                        selection = link.id
                                    } label: {
                                        HStack(spacing: 5) {
                                            Circle()
                                                .fill(WikiGraphView.color(for: link.type))
                                                .frame(width: 5, height: 5)
                                            Text(link.title)
                                                .font(.system(size: 11))
                                            Spacer()
                                        }
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
                .padding(12)
            }
        }
    }

    /// 知识生成的输入源。
    ///
    /// 只认「未提交改动」是错的：提交完、或者看的是历史代码，就再也生成不了知识。
    enum CurationSource {
        case workingTree
        case lastCommit
        case currentFile
        case selectedEntrySources
    }

    private var activeFileURL: URL? {
        workspace?.editorManager?.activeEditor.selectedTab?.file.url
    }

    private var selectedEntrySources: [String] {
        guard let id = selection, let entry = store.entry(id: id) else { return [] }
        return entry.sources
    }

    private func curate(_ source: CurationSource) {
        guard let input = curationInput(for: source) else {
            curatorError = emptyReason(for: source)
            return
        }
        guard AINarrativeStore.shared.isReady else {
            curatorError = AINarrativeStore.shared.blockedReason ?? "模型未配置"
            return
        }
        curating = true
        curatorError = nil
        curatorMessage = nil
        let label = AINarrativeStore.shared.providerLabel
        Task {
            do {
                let draft = try await WikiCurator.propose(
                    input: input,
                    existing: store.entries
                )
                let applied = try store.applyDraft(
                    draft,
                    generatedBy: label,
                    sources: Array(input.files.prefix(8))
                )
                selection = applied.id
                curatorMessage = draft.reason.isEmpty
                    ? "已生成草稿：\(applied.title)"
                    : "已生成草稿：\(applied.title)（\(draft.reason)）"
            } catch {
                curatorError = error.localizedDescription
            }
            curating = false
        }
    }

    private func curationInput(for source: CurationSource) -> WikiCurationInput? {
        switch source {
        case .workingTree:
            return WikiChangeSource.workingTree(root: store.root)
        case .lastCommit:
            return WikiChangeSource.lastCommit(root: store.root)
        case .currentFile:
            guard let url = activeFileURL else { return nil }
            return WikiChangeSource.files(root: store.root, paths: [relativePath(of: url)])
        case .selectedEntrySources:
            return WikiChangeSource.files(root: store.root, paths: selectedEntrySources)
        }
    }

    private func emptyReason(for source: CurationSource) -> String {
        switch source {
        case .workingTree:
            if let reason = WikiChangeSource.unavailableReason(root: store.root) {
                return reason
            }
            return "工作区是干净的。改用「最近一次提交」或「当前打开的文件」。"
        case .lastCommit:
            return "没有读到提交记录（这个目录可能还不是 git 仓库）。"
        case .currentFile:
            return "当前没有打开的文件。"
        case .selectedEntrySources:
            return "选中的条目还没有填写关联代码路径。"
        }
    }

    private func relativePath(of url: URL) -> String {
        let rootPath = store.root.standardizedFileURL.path
        let filePath = url.standardizedFileURL.path
        guard filePath.hasPrefix(rootPath) else { return filePath }
        return String(filePath.dropFirst(rootPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func statusStrip(_ text: String, color: Color, symbol: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 10))
            Text(text)
                .font(.system(size: 11))
                .lineLimit(2)
                .textSelection(.enabled)
            Spacer(minLength: 4)
            Button {
                curatorMessage = nil
                curatorError = nil
            } label: {
                Image(systemName: "xmark").font(.system(size: 9))
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: 小组件

    /// 草稿横幅：AI 写的东西必须被显式确认，不能默认当事实。
    private func draftBanner(_ entry: WikiEntry) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 10))
            VStack(alignment: .leading, spacing: 1) {
                Text("AI 起草 · 待确认")
                    .font(.system(size: 11, weight: .medium))
                if !entry.generatedBy.isEmpty {
                    Text(entry.generatedBy)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("丢弃") {
                try? store.discardDraft(entry)
                selection = nil
            }
            .controlSize(.small)
            Button("确认") {
                try? store.confirm(entry)
            }
            .controlSize(.small)
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.10))
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            content()
        }
    }

    /// `domain:service/portrait` → `service/portrait`。
    static func domainLabel(_ domainID: String) -> String {
        let prefix = "domain:"
        return domainID.hasPrefix(prefix) ? String(domainID.dropFirst(prefix.count)) : domainID
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

    private func create(type: WikiEntryType) {
        guard let entry = try? store.create(type: type) else { return }
        selection = entry.id
        editing = entry
    }
}

// MARK: - 编辑器

struct WikiEntryEditor: View {

    @State private var draft: WikiEntry
    private let onSave: (WikiEntry) -> Void
    private let onCancel: () -> Void
    private let onDelete: () -> Void

    @State private var tagsText: String
    @State private var sourcesText: String
    @State private var relationsText: String

    init(
        draft: WikiEntry,
        onSave: @escaping (WikiEntry) -> Void,
        onCancel: @escaping () -> Void,
        onDelete: @escaping () -> Void
    ) {
        _draft = State(initialValue: draft)
        self.onSave = onSave
        self.onCancel = onCancel
        self.onDelete = onDelete
        _tagsText = State(initialValue: draft.tags.joined(separator: ", "))
        _sourcesText = State(initialValue: draft.sources.joined(separator: ", "))
        _relationsText = State(
            initialValue: draft.relations.map { "\($0.kind):\($0.target)" }.joined(separator: "; ")
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("编辑条目")
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                Button("取消", action: onCancel)
                    .controlSize(.small)
                Button("保存") {
                    save()
                }
                .controlSize(.small)
                .keyboardShortcut("s", modifiers: .command)
            }
            .padding(12)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    labeled("标题") {
                        TextField("标题", text: $draft.title)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12))
                    }
                    labeled("类型") {
                        Picker("", selection: $draft.type) {
                            ForEach(WikiEntryType.allCases) { type in
                                Text(type.title).tag(type)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                    }
                    labeled("标签（逗号分隔）") {
                        TextField("锚点, 渲染", text: $tagsText)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11))
                    }
                    labeled("关联代码路径（逗号分隔）") {
                        TextField("CodeEdit/Features/...", text: $sourcesText)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11, design: .monospaced))
                    }
                    labeled("关系（关系词:目标; 多条用分号）") {
                        TextField("属于:改动审查; 导致:回归缺陷", text: $relationsText)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11))
                    }
                    labeled("正文（用 [[标题]] 建立链接）") {
                        TextEditor(text: $draft.body)
                            .font(.system(size: 12))
                            .frame(minHeight: 220)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .strokeBorder(Color.secondary.opacity(0.25), lineWidth: 0.5)
                            )
                    }
                }
                .padding(12)
            }

            Divider()
            HStack {
                Button("删除", role: .destructive, action: onDelete)
                    .controlSize(.small)
                Spacer()
                Text("保存到 .qiyide/wiki/\(draft.id).md")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            .padding(10)
        }
    }

    private func labeled<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            content()
        }
    }

    private func save() {
        var saved = draft
        saved.title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if saved.title.isEmpty { saved.title = draft.id }
        saved.tags = split(tagsText)
        saved.sources = split(sourcesText)
        saved.relations = relationsText
            .split(separator: ";")
            .compactMap { item -> WikiRelation? in
                let text = item.trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty else { return nil }
                guard let separator = text.firstIndex(of: ":") else {
                    return WikiRelation(kind: "相关", target: text)
                }
                let kind = String(text[..<separator]).trimmingCharacters(in: .whitespaces)
                let target = String(text[text.index(after: separator)...])
                    .trimmingCharacters(in: .whitespaces)
                guard !target.isEmpty else { return nil }
                return WikiRelation(kind: kind.isEmpty ? "相关" : kind, target: target)
            }
        onSave(saved)
    }

    private func split(_ text: String) -> [String] {
        text
            .split(whereSeparator: { $0 == "," || $0 == "，" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
