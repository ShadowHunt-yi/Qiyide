//
//  DomainModelWindow.swift
//  CodeEdit
//
//  领域建模窗口：左边导图，右边选中节点的判定依据。
//
//  为什么单独开窗口而不是塞进知识库窗口：
//  建模是「一次性、需要大画布」的动作，而知识库是「日常查阅」。
//  两者尺寸诉求相差一倍，挤在一个窗口里会让导图永远看不清模块名。
//  建模完成、模型锁定后，知识库窗口直接读锁定结果，互不干扰。
//

import AppKit
import SwiftUI

// MARK: - 窗口

@MainActor
enum DomainModelWindowPresenter {
    private static var openWindows: [NSWindow] = []
    /// store 由 Presenter 持有而不是 View：窗口一关 View 就没了，
    /// 但识别是长任务，不能跟着视图一起被释放。
    private static var stores: [DomainModelStore] = []

    static func show(workspace: WorkspaceDocument?) {
        guard let workspace, let root = workspace.fileURL else {
            NotificationManager.shared.post(
                iconSymbol: "info.circle",
                title: NSLocalizedString("Domain Modeling", comment: ""),
                description: NSLocalizedString("Open a folder first — domain models live in .qiyide/wiki.", comment: ""),
                actionButtonTitle: "",
                action: {}
            )
            return
        }

        let store = DomainModelStore(root: root)
        stores.append(store)
        // 只留最近几个，关掉的窗口不再占内存。
        if stores.count > 4 { stores.removeFirst(stores.count - 4) }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1240, height: 780),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = NSLocalizedString("Domain Modeling", comment: "")
        window.contentView = NSHostingView(rootView: DomainModelView(store: store))
        window.center()
        window.isReleasedWhenClosed = false
        // 导图需要宽度，下限给到 980。
        window.minSize = NSSize(width: 980, height: 560)
        openWindows.removeAll { !$0.isVisible }
        openWindows.append(window)
        window.makeKeyAndOrderFront(nil)

        // 没有锁定模型时自动跑一次识别。
        //
        // 之所以放在 Presenter 而不是 View 的 onAppear/task：视图生命周期在
        // NSHostingView 里并不可靠（无头启动时实测不触发），而识别是本窗口的
        // 主功能，不该依赖一个可能不发生的事件。
        if store.graph.isEmpty {
            Task { await store.analyze() }
        }
    }
}

// MARK: - 主视图

struct DomainModelView: View {

    /// 由 Presenter 持有并传入。识别任务的生命周期不能绑在视图上。
    @ObservedObject var store: DomainModelStore
    @State private var selection: String?
    /// nil = 建模视图（直接编辑原模型）；非 nil = 投影视图（只读）。
    @State private var activeSpec: ViewSpec?
    @State private var customSpecs: [ViewSpec] = []
    @State private var showCustomSpecSheet = false
    @State private var draftSpec = ViewSpec.custom(name: "")
    @State private var seedNotice: String?

    private var allSpecs: [ViewSpec] { ViewSpec.presets + customSpecs }

    /// 当前要画的图。建模模式直接用原模型，其余走投影。
    private var displayGraph: MindGraph {
        guard let activeSpec else { return store.graph }
        return ViewProjector.project(store.graph, spec: activeSpec)
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if let drift = store.drift, !drift.isEmpty {
                driftStrip(drift)
                Divider()
            }
            if let error = store.errorMessage {
                noticeStrip(error, color: .orange)
                Divider()
            }
            if let seedNotice {
                HStack(spacing: 6) {
                    Image(systemName: "books.vertical").font(.system(size: 10))
                    Text(seedNotice).font(.system(size: 11))
                    Spacer()
                    Text("到「知识库 → 打开知识图谱」确认")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Button {
                        self.seedNotice = nil
                    } label: {
                        Image(systemName: "xmark").font(.system(size: 9))
                    }
                    .buttonStyle(.plain)
                }
                .foregroundStyle(.green)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                Divider()
            }
            content
        }
        .frame(minWidth: 980, minHeight: 560)
        .background(Color(nsColor: .textBackgroundColor))
        .onAppear {
            customSpecs = ViewSpecStore.loadAll(root: store.root)
        }
        .sheet(isPresented: $showCustomSpecSheet) {
            customSpecSheet
        }
    }

    // MARK: 自定义视角

    private var customSpecSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("自定义视角")
                .font(.system(size: 14, weight: .medium))
            Text("同一份领域模型，按这里的规则投影成一张新图。差异最大的是「共享依赖」——"
                 + "业务视角把它沉到基建层，技术视角让它和各层并列。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Form {
                TextField("名称", text: $draftSpec.name)

                Picker("分层依据", selection: $draftSpec.axis) {
                    ForEach(ViewAxis.allCases, id: \.self) { axis in
                        Text(axis.title).tag(axis)
                    }
                }

                Picker("展开粒度", selection: $draftSpec.granularity) {
                    ForEach(ViewGranularity.allCases, id: \.self) { item in
                        Text(item.title).tag(item)
                    }
                }

                Picker("共享依赖", selection: $draftSpec.sharedPolicy) {
                    ForEach(SharedDependencyPolicy.allCases, id: \.self) { item in
                        Text(item.title).tag(item)
                    }
                }

                Picker("边的语义", selection: $draftSpec.edgeSemantics) {
                    ForEach(ViewEdgeSemantics.allCases, id: \.self) { item in
                        Text(item.title).tag(item)
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("取消") { showCustomSpecSheet = false }
                Button("保存并应用") {
                    ViewSpecStore.save(draftSpec, root: store.root)
                    customSpecs = ViewSpecStore.loadAll(root: store.root)
                    activeSpec = draftSpec
                    showCustomSpecSheet = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(draftSpec.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(18)
        .frame(width: 460)
    }

    // MARK: 工具条

    private var toolbar: some View {
        HStack(spacing: 10) {
            if store.isAnalyzing {
                ProgressView().scaleEffect(0.5).frame(width: 16, height: 16)
                Text(store.progressText.isEmpty ? "识别中…" : store.progressText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                Button {
                    Task { await store.analyze() }
                } label: {
                    Label(store.graph.isEmpty ? "识别领域" : "重新识别", systemImage: "wand.and.stars")
                }
                .controlSize(.small)
                .help("扫描包结构、命名、调用、注释与文档，产出领域候选")
            }

            Spacer()

            if !store.graph.isEmpty {
                Picker("", selection: $activeSpec) {
                    Text("建模视图").tag(ViewSpec?.none)
                    Divider()
                    ForEach(allSpecs) { spec in
                        Text(spec.name).tag(ViewSpec?.some(spec))
                    }
                }
                .labelsHidden()
                .frame(width: 150)
                .help("切换视角：不同视角下共享依赖的归属不同")

                Button {
                    draftSpec = ViewSpec.custom(name: "自定义视角")
                    showCustomSpecSheet = true
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("自定义视角")

                Text("\(store.domains.count) 域 · \(store.graph.nodes.count) 节点")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            if store.isLocked {
                Label("已锁定", systemImage: "lock.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.green)
                Button("解除锁定") { store.unlock() }
                    .controlSize(.small)
                    .help("解除后可以重新识别，人工改动会保留到重新识别之前")
            } else if !store.graph.isEmpty {
                Button {
                    store.lock()
                } label: {
                    Label("锁定模型", systemImage: "lock.open")
                }
                .controlSize(.small)
                .help("锁定后自动识别不会覆盖人工校正的结果")
            }

            if store.isLocked {
                Button {
                    generateKnowledgeBase()
                } label: {
                    Label("生成知识库", systemImage: "books.vertical")
                }
                .controlSize(.small)
                .help("按领域生成知识草稿；同名条目会被跳过，不覆盖人工内容")
            }

            Menu {
                Button("导出 Markdown 大纲") { exportMarkdown() }
                Button("导出 JSON") { exportJSON() }
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(store.graph.isEmpty)
            .help("导出当前模型")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: 内容

    private var content: some View {
        HSplitView {
            MindMapView(
                store: store,
                selection: $selection,
                displayGraph: activeSpec == nil ? nil : displayGraph,
                isReadOnly: activeSpec != nil
            )
            .frame(minWidth: 620)
            detailPane
                .frame(minWidth: 280, idealWidth: 320, maxWidth: 420)
        }
    }

    @ViewBuilder
    private var detailPane: some View {
        if let id = selection, let node = store.node(id) {
            nodeDetail(node)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "hand.tap")
                    .font(.system(size: 22))
                    .foregroundStyle(.tertiary)
                Text("点选导图上的节点")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text("双击领域可展开模块，右键可改名、指定负责人、合并到其它领域。")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func nodeDetail(_ node: MindNode) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 6) {
                    Text(node.displayTitle)
                        .font(.system(size: 14, weight: .medium))
                    if node.isManual {
                        Text("人工")
                            .font(.system(size: 9))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.15))
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                    }
                    Spacer()
                }
                HStack(spacing: 8) {
                    Text(node.kind.title)
                    Text("\(node.classCount) 类")
                    Text("\(node.fileCount) 文件")
                }
                .font(.system(size: 10))
                .foregroundStyle(.secondary)

                if !node.owner.authors.isEmpty || node.owner.manual != nil {
                    section("负责人") {
                        if let manual = node.owner.manual {
                            row("人工指定", manual)
                        }
                        ForEach(node.owner.authors.prefix(4), id: \.name) { author in
                            row(author.name, "\(author.commits) 次提交")
                        }
                    }
                }

                if !node.evidence.isEmpty {
                    section("判定依据") {
                        ForEach(Array(node.evidence.enumerated()), id: \.offset) { _, item in
                            HStack(alignment: .top, spacing: 6) {
                                Text(item.kind.title)
                                    .font(.system(size: 9))
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(Color.secondary.opacity(0.12))
                                    .clipShape(RoundedRectangle(cornerRadius: 3))
                                Text(item.detail)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }

                if !node.packages.isEmpty {
                    section("归属包") {
                        ForEach(node.packages.prefix(6), id: \.self) { package in
                            Text(package)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }

                if node.confidence > 0 {
                    section("置信度") {
                        HStack(spacing: 8) {
                            ProgressView(value: node.confidence)
                                .frame(width: 120)
                            Text(String(format: "%.0f%%", node.confidence * 100))
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(14)
        }
    }

    private func section<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            Text(label).font(.system(size: 10, design: .monospaced))
            Spacer()
            Text(value).font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }

    // MARK: 条带

    private func driftStrip(_ drift: DriftReport) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 10))
            Text(driftSummary(drift))
                .font(.system(size: 11))
                .lineLimit(2)
            Spacer()
            Button("重新识别并对比") {
                Task { await store.analyze() }
            }
            .controlSize(.small)
        }
        .foregroundStyle(.orange)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func driftSummary(_ drift: DriftReport) -> String {
        var parts: [String] = []
        if !drift.uncoveredPackages.isEmpty {
            parts.append("\(drift.uncoveredPackages.count) 个新包未纳入（\(drift.uncoveredPackages.prefix(3).joined(separator: "、"))）")
        }
        if !drift.missingPackages.isEmpty {
            parts.append("\(drift.missingPackages.count) 个包已不在仓库中")
        }
        if drift.baseCommitChanged {
            parts.append("基线 commit 已变化")
        }
        return parts.joined(separator: "；")
    }

    private func noticeStrip(_ text: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle").font(.system(size: 10))
            Text(text).font(.system(size: 11)).lineLimit(3)
            Spacer()
            Button {
                store.errorMessage = nil
            } label: {
                Image(systemName: "xmark").font(.system(size: 9))
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: 生成知识库

    /// 按领域生成知识草稿。同名条目跳过——人工写过的内容不能被自动生成覆盖。
    private func generateKnowledgeBase() {
        let wikiStore = WikiStore(root: store.root)
        do {
            let result = try WikiDomainSeeding.seed(graph: store.graph, into: wikiStore)
            var parts: [String] = []
            if result.created > 0 { parts.append("已生成 \(result.created) 条草稿") }
            if result.skipped > 0 { parts.append("跳过 \(result.skipped) 条同名条目") }
            parts.append(contentsOf: result.warnings)
            seedNotice = parts.isEmpty ? "没有新增内容" : parts.joined(separator: "；")
        } catch {
            seedNotice = "生成失败：\(error.localizedDescription)"
        }
    }

    // MARK: 导出

    private func exportMarkdown() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "domains.md"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? store.markdownOutline().write(to: url, atomically: true, encoding: .utf8)
    }

    private func exportJSON() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "domains.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(store.graph) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
