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

/// 知识库窗口。
///
/// 这里只放「三栏共享的状态」和窗口骨架。三栏各自的渲染在扩展文件里：
/// `+Toolbar`（顶部三条横带）、`+Sidebar`（左栏）、`+Center`（中间）、
/// `+Detail`（右栏）、`+Curation`（AI 整理）。
///
/// 成员没有加 `private`：扩展与主结构体分处不同文件，`private` 会挡住访问。
/// 这里的边界靠「栏」这个语义划分，不靠访问控制——真要封起来，
/// 得把状态收进一个 ObservableObject 再注入，那是另一件事（也会把状态拍卖给所有视图）。
struct WikiWindowView: View {

    /// 用来定位「当前打开的文件」，作为知识生成的输入源之一。
    let workspace: WorkspaceDocument?

    @StateObject var store: WikiStore
    /// 领域模型。合并后知识库和建模共用这一个窗口，两套数据各自持有：
    /// 条目是「人写的知识」，领域模型是「算出来的结构」，生命周期不同
    /// （模型会被重新识别覆盖，条目不会），混成一个 store 反而危险。
    @StateObject var domains: DomainModelStore
    /// 建档是 App 级长任务：这里只订阅，不持有。关掉这个窗口任务也不会中断。
    @ObservedObject var ingestion = WikiCurationRunner.shared
    @State var showIngest = false
    @State var query = ""
    @State var typeFilter: WikiEntryType?
    @State var selection: String?
    /// 选中的域（`MindNode.id`）。它同时是左栏条目的过滤条件。
    @State var selectedDomain: String?
    /// 导图模式下选的视角：nil 表示建模视图（可编辑），否则只读投影。
    @State var activeSpec: ViewSpec?
    /// 自定义视角。存在 `.qiyide/wiki/viewspec/*.json`，随仓库共享。
    @State var customSpecs: [ViewSpec] = []
    /// 投影结果缓存：投影要遍历全部节点，不能每次 body 都算。
    @State var projected: MindGraph?
    @State var showBackfill = false
    /// 一致性体检结果。由数据推导，不落盘。
    @State var coherence: CoherenceReport?
    /// 体检代数号：后台算完的旧报告不能盖掉新数据。
    @State var coherenceGeneration = 0
    @State var showCoherence = false
    /// 多选集合（批量操作的对象）。`selection` 始终是「当前展示详情」的那一条。
    @State var multiSelection: Set<String> = []
    @State var showBatchDelete = false
    @State var batchNotice: String?

    /// 中间栏的四种看法：
    /// 导图看「域怎么划」，结构看「现在的代码长什么样」，
    /// 图谱看「知识谁连着谁」，架构看「系统分几层」。
    enum CenterMode: String, CaseIterable, Identifiable {
        case mindmap
        case structure
        case graph
        case architecture
        var id: String { rawValue }
        var title: String {
            switch self {
            case .mindmap: return "导图"
            case .structure: return "结构"
            case .graph: return "图谱"
            case .architecture: return "架构"
            }
        }
    }

    @State var centerMode: CenterMode = .mindmap
    @State var buildingArchitecture = false
    @State var architectureError: String?
    @State var editing: WikiEntry?
    @State var deleteTarget: WikiEntry?
    @State var showDraftsOnly = false
    @State var curating = false
    @State var curatorMessage: String?
    @State var curatorError: String?

    init(
        root: URL,
        workspace: WorkspaceDocument?,
        autoLoad: Bool = false,
        initiallySelectedDomain: String? = nil,
        initialCenterMode: CenterMode = .mindmap
    ) {
        self.workspace = workspace
        let wikiStore = WikiStore(root: root)
        // 预览/离屏渲染没有视图生命周期，`.task` 不会跑，这里必须同步载入。
        // 这是唯一走同步扫描的地方——它不在用户交互路径上。
        if autoLoad {
            MainActor.assumeIsolated { wikiStore.reloadNow() }
        }
        _store = StateObject(wrappedValue: wikiStore)
        _domains = StateObject(wrappedValue: DomainModelStore(root: root))
        _selectedDomain = State(initialValue: initiallySelectedDomain)
        _centerMode = State(initialValue: initialCenterMode)
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            stageStrip
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
            if !store.isLoaded { await store.reload() }
        }
        .onChange(of: selection) { _, _ in
            editing = nil
        }
        .sheet(isPresented: $showIngest, onDismiss: { Task { await store.reload() } }) {
            WikiIngestSheet(runner: ingestion, store: store) {
                showIngest = false
            }
        }
        .sheet(isPresented: $showBackfill) {
            DomainBackfillSheet(root: store.root, graph: domains.graph, store: store) {
                recomputeCoherence()
            }
        }
        .sheet(isPresented: $showCoherence) {
            WikiCoherenceSheet(root: store.root, graph: domains.graph, store: store) {
                recomputeCoherence()
            }
        }
        .onAppear {
            refreshProjection()
            recomputeCoherence()
            customSpecs = ViewSpecStore.loadAll(root: store.root)
        }
        .onChange(of: activeSpec) { _, _ in refreshProjection() }
        .onChange(of: domains.revision) { _, _ in
            refreshProjection()
            recomputeCoherence()
        }
        .onChange(of: store.contentRevision) { _, _ in
            recomputeCoherence()
        }
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

    var deleteBinding: Binding<Bool> {
        Binding(
            get: { deleteTarget != nil },
            set: { if !$0 { deleteTarget = nil } }
        )
    }

    func recomputeCoherence() {
        // git + 上千次 fileExists 在后台跑；主线程只取一份条目快照（O(条目数)）。
        // 代数号保证「先发后到」的旧报告不会盖掉新的。
        coherenceGeneration &+= 1
        let generation = coherenceGeneration
        let root = store.root
        let graph = domains.graph
        Task {
            let report = await WikiCoherence.checkAsync(root: root, graph: graph, store: store)
            guard generation == coherenceGeneration else { return }
            coherence = report
        }
    }

    // MARK: 内容

    @ViewBuilder
    var content: some View {
        if let message = store.errorMessage {
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 22))
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Button("重试") { Task { await store.reload() } }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !store.isLoaded {
            // 重扫搬到了后台：刚打开的一两百毫秒里三栏都是空的，
            // 不给指示就像「知识库丢了」。
            VStack(spacing: 8) {
                ProgressView().scaleEffect(0.6).frame(height: 18)
                Text("正在读取 .qiyide/wiki…")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if store.entries.isEmpty && domains.graph.isEmpty {
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
    var displayGraph: MindGraph {
        guard let spec = activeSpec else { return domains.graph }
        return projected ?? ViewProjector.project(domains.graph, spec: spec)
    }

    /// 重算投影。只在「换视角」或「模型变了」时调用。
    func refreshProjection() {
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
    var mindMapSelection: Binding<String?> {
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



    func statusStrip(_ text: String, color: Color, symbol: String) -> some View {
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
    func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        WikiSection(title: title, content: content)
    }

    /// `domain:service/portrait` → `service/portrait`。
    static func domainLabel(_ domainID: String) -> String {
        let prefix = "domain:"
        return domainID.hasPrefix(prefix) ? String(domainID.dropFirst(prefix.count)) : domainID
    }

    func chip(_ text: String, color: Color) -> some View {
        WikiChip(text: text, color: color)
    }

    func create(type: WikiEntryType) {
        guard let entry = try? store.create(type: type) else { return }
        selection = entry.id
        editing = entry
    }
}

// 条目编辑器已移到 `WikiEntryEditor.swift`：它只依赖草稿与回调，不需要窗口状态。
