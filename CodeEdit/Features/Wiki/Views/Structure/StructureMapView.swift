//
//  StructureMapView.swift
//  CodeEdit
//
//  结构地图：沿真实包路径逐级下钻，全仓 › 域 › 模块 › 子包 › 文件。
//
//  和导图的分工：
//  导图回答「域该怎么划」，可以拖、可以改，是建模用的；
//  结构地图回答「现在的代码长什么样」和「这个分支改了哪些结构」，是拿来看和把关的。
//  两者读同一份领域模型，所以在导图里改了归属，这里立刻跟着变。
//
//  每一级只画「当前节点的子节点」，往上靠面包屑。这样无论仓库多大，
//  一屏里的东西都是有限的——全仓看域，域里看模块，模块里看文件。
//
//  叠加分支增量时，底图不变，只是每个节点上多了改动标记，顶部多了一句结论和待确认清单。
//  清单跟着面包屑收窄：走进哪个域，就只剩这个域里要确认的事。
//

import SwiftUI

struct StructureMapView: View {

    @ObservedObject var store: DomainModelStore
    let root: URL
    /// 进入某个域时同步给窗口，左栏和右栏跟着切到这个域。
    @Binding var selectedDomain: String?
    /// 参数是仓库相对路径。
    let onOpenFile: (String) -> Void
    /// 离屏渲染时为真：数据由调用方给定，不再自己加载。
    private let isStatic: Bool

    @State private var index: StructureIndex
    /// 当前位置：`[域标识, 模块标识, 子包段…]`，空数组是全仓。
    @State private var path: [String]
    @State private var isLoading = false

    @AppStorage("wiki.structure.showsDiff") private var showsDiff = true
    @AppStorage("wiki.structure.includeWorkingTree") private var includeWorkingTree = true
    @State private var target: String?
    @State private var targets: [String] = []
    @State private var diff: StructureDiff?
    @State private var diffError: String?
    @State private var isDiffing = false
    /// 结果的代数号：先发后到的旧结果不能盖掉新的。
    @State private var diffGeneration = 0
    @State private var decisions: [String: StructureDecision] = [:]
    /// 这个分支声明只动的域。空集合表示没有声明。
    @State private var scope: Set<String> = []
    @State private var notice: String?

    /// - Parameters:
    ///   - preloaded: 离屏渲染没有视图生命周期，`.task` 不保证跑完，所以允许直接塞一份建好的索引。
    ///   - preloadedDiff: 同上。给了它就按「叠加分支增量」渲染。
    ///   - initialPath: 直接渲染某一级。
    init(
        store: DomainModelStore,
        root: URL,
        selectedDomain: Binding<String?>,
        onOpenFile: @escaping (String) -> Void,
        preloaded: StructureIndex? = nil,
        preloadedDiff: StructureDiff? = nil,
        preloadedDecisions: [String: StructureDecision] = [:],
        initialPath: [String] = []
    ) {
        self.store = store
        self.root = root
        _selectedDomain = selectedDomain
        self.onOpenFile = onOpenFile
        isStatic = preloaded != nil
        _index = State(initialValue: preloaded ?? .empty)
        _path = State(initialValue: initialPath)
        _diff = State(initialValue: preloadedDiff)
        _decisions = State(initialValue: preloadedDecisions)
    }

    var body: some View {
        VStack(spacing: 0) {
            if !index.isEmpty {
                StructureBreadcrumbBar(crumbs: crumbs, summary: summary) { path = $0 }
                Divider()
                StructureDiffBar(
                    showsDiff: diffToggle,
                    targets: targets,
                    target: $target,
                    includeWorkingTree: $includeWorkingTree,
                    domains: index.modeledDomains.map { ($0.id, $0.title) },
                    scope: scopeBinding,
                    diff: diff,
                    isLoading: isDiffing,
                    error: diffError,
                    onRefresh: { Task { await reloadDiff() } }
                )
                Divider()
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: store.revision) { await reload() }
        .onChange(of: path) { _, newPath in
            // 只有真正的业务域才同步出去；「未划分」「共享基建」在领域模型里没有对应节点。
            let domainID = newPath.first.flatMap { store.graph.node($0)?.id }
            if selectedDomain != domainID { selectedDomain = domainID }
        }
        .onChange(of: selectedDomain) { _, domainID in
            // 左栏点了另一个域：地图跟过去。取消选择时不动，留在原地更自然。
            guard let domainID, domainID != path.first, index.domain(domainID) != nil else { return }
            path = [domainID]
        }
        .onChange(of: showsDiff) { _, _ in Task { await reloadDiff() } }
        .onChange(of: target) { _, _ in Task { await reloadDiff() } }
        .onChange(of: includeWorkingTree) { _, _ in Task { await reloadDiff() } }
    }

    /// 离屏渲染时由「有没有给增量」决定，不读用户偏好：截图不能因为上次的开关状态而变。
    private var diffToggle: Binding<Bool> {
        isStatic ? .constant(diff != nil) : $showsDiff
    }

    /// 改了范围就落盘并重算：越界与否是算出来的，不是界面上的装饰。
    private var scopeBinding: Binding<Set<String>> {
        Binding(
            get: { scope },
            set: { newScope in
                scope = newScope
                guard !isStatic else { return }
                let branch = diff?.headName ?? StructureGit.headName(root: root)
                StructureDecisionStore.saveScope(newScope, root: root, branch: branch)
                Task { await reloadDiff() }
            }
        )
    }

    /// 当前生效的叠加层。只看地图、或增量还没算出来时为 nil。
    private var overlay: StructureOverlay? {
        guard diffToggle.wrappedValue, let diff else { return nil }
        return StructureOverlay(diff: diff, openAsks: diff.asks.filter { decisions[$0.id] == nil })
    }

    // MARK: 内容

    @ViewBuilder private var content: some View {
        if store.graph.isEmpty {
            noModel
        } else if index.isEmpty {
            if isLoading {
                loading
            } else {
                Text("没有扫描到源码文件")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        } else {
            let overlay = self.overlay
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let overlay {
                        diffHeader(overlay)
                    }
                    level(overlay)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private func level(_ overlay: StructureOverlay?) -> some View {
        if let domain = currentDomain {
            if let module = currentModule {
                StructurePackageView(
                    domain: domain,
                    module: module,
                    subpath: currentSubpath,
                    contents: index.contents(of: module, at: currentSubpath),
                    overlay: overlay,
                    onNavigate: { path = $0 },
                    onOpenFile: onOpenFile
                )
            } else {
                StructureDomainView(domain: domain, index: index, overlay: overlay) { path = $0 }
            }
        } else {
            StructureOverviewView(index: index, overlay: overlay) { path = $0 }
        }
    }

    /// 结论 + 当前范围内的待确认。
    @ViewBuilder
    private func diffHeader(_ overlay: StructureOverlay) -> some View {
        let asks = overlay.diff.asks(inside: path)
        StructureVerdictView(verdict: StructureVerdict.make(
            diff: overlay.diff,
            index: index,
            path: path,
            decided: Set(decisions.keys)
        ))
        if let notice {
            Text(notice)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
        }
        if !asks.isEmpty {
            StructureAskList(
                asks: asks,
                decisions: decisions,
                path: path,
                onNavigate: { path = $0 },
                onOpenFile: onOpenFile,
                onDecide: decide,
                onAdopt: adopt
            )
        }
    }

    private var loading: some View {
        VStack(spacing: 8) {
            ProgressView().scaleEffect(0.6).frame(height: 18)
            Text("正在扫描包结构…")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    /// 没有领域模型时地图画不出来：域是模型定的。给一个就地能点的入口，不让人去别的页签找。
    private var noModel: some View {
        VStack(spacing: 10) {
            Image(systemName: "square.grid.3x1.below.line.grid.1x2")
                .font(.system(size: 26))
                .foregroundStyle(.tertiary)
            Text("还没有领域模型")
                .font(.system(size: 13, weight: .medium))
            Text("结构地图按「域 › 模块 › 文件」展开，需要先识别出域。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            if store.isAnalyzing {
                HStack(spacing: 6) {
                    ProgressView().scaleEffect(0.5).frame(width: 14, height: 14)
                    Text(store.progressText.isEmpty ? "识别中…" : store.progressText)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
            } else {
                Button("识别领域") {
                    Task { await store.analyze() }
                }
                .controlSize(.small)
            }
            if let message = store.errorMessage {
                Text(message)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }
        }
    }

    // MARK: 位置

    private var currentDomain: StructureDomain? {
        path.first.flatMap { index.domain($0) }
    }

    private var currentModule: StructureModule? {
        guard path.count > 1, let module = index.module(path[1]) else { return nil }
        // 模块必须真的在这个域下，防止模型变了之后路径指向别处。
        return index.domain(ofModule: module.id)?.id == path[0] ? module : nil
    }

    /// 模块之下的子包路径。只在确实进了某个模块时才有意义。
    private var currentSubpath: [String] {
        currentModule == nil ? [] : Array(path.dropFirst(2))
    }

    private var crumbs: [StructureCrumb] {
        let overlay = self.overlay
        func crumb(_ path: [String], _ title: String) -> StructureCrumb {
            StructureCrumb(path: path, title: title, pending: overlay?.pending(path) ?? 0)
        }
        var result = [crumb([], root.lastPathComponent)]
        if let domain = currentDomain {
            result.append(crumb([domain.id], domain.title))
            if let module = currentModule {
                var here = [domain.id, module.id]
                result.append(crumb(here, module.title))
                for segment in currentSubpath {
                    here.append(segment)
                    result.append(crumb(here, segment))
                }
            }
        }
        return result
    }

    private var summary: String {
        if let module = currentModule {
            return "\(index.contents(of: module, at: currentSubpath).classCount) 个类"
        }
        if let domain = currentDomain {
            return "\(domain.modules.count) 个模块 · \(domain.classCount) 个类"
        }
        return "\(index.modeledDomains.count) 个域 · \(index.moduleCount) 个模块 · \(index.classCount) 个类"
    }

    // MARK: 决定

    private func decide(_ ask: StructureAsk, _ decision: StructureDecision?) {
        decisions[ask.id] = decision
        notice = nil
        guard !isStatic, let branch = diff?.headName else { return }
        StructureDecisionStore.save(decisions, root: root, branch: branch)
    }

    /// 把新包认领到建议的域下。改的是领域模型，所以地图会整体重算一遍。
    private func adopt(_ ask: StructureAsk) {
        guard let adoption = ask.adoption else { return }
        store.adopt(package: adoption.moduleKey, title: adoption.moduleTitle, into: adoption.domainID)
        store.persistIfLocked()
        notice = store.isLocked
            ? "已把 \(adoption.moduleKey) 归入「\(adoption.domainTitle)」，并写回锁定的领域模型。"
            : "已把 \(adoption.moduleKey) 归入「\(adoption.domainTitle)」。模型还没锁定，重新识别后这次归属会丢失。"
    }

    // MARK: 加载

    private func reload() async {
        guard !isStatic else { return }
        guard !store.graph.isEmpty else {
            index = .empty
            path = []
            diff = nil
            return
        }
        isLoading = true
        let built = await StructureIndex.load(root: root, graph: store.graph)
        index = built
        isLoading = false
        // 模型变了之后，原来的位置可能已经不存在：退到还存在的那一级。
        if currentDomain == nil {
            path = []
        } else if path.count > 1, currentModule == nil {
            path = [path[0]]
        } else if let module = currentModule {
            // 子包被删了：一段段往上退，直到还有内容的那一级。
            while path.count > 2, index.contents(of: module, at: Array(path.dropFirst(2))).classCount == 0 {
                path.removeLast()
            }
        }
        await reloadDiff()
    }

    private func reloadDiff() async {
        guard !isStatic else { return }
        diffGeneration &+= 1
        let generation = diffGeneration
        guard showsDiff, !index.isEmpty else {
            isDiffing = false
            return
        }
        isDiffing = true
        let root = self.root
        if targets.isEmpty {
            targets = await Task.detached { StructureGit.targets(root: root) }.value
        }
        // 范围是按分支存的，所以要先知道当前在哪个分支。
        let branch = await Task.detached { StructureGit.headName(root: root) }.value
        let declared = StructureDecisionStore.loadScope(root: root, branch: branch)
        if scope != declared { scope = declared }
        let options = StructureDiffBuilder.Options(
            target: target,
            includeWorkingTree: includeWorkingTree,
            scope: declared
        )
        let result = await StructureDiffBuilder.load(root: root, index: index, options: options)
        guard generation == diffGeneration else { return }
        isDiffing = false
        switch result {
        case .success(let built):
            diff = built
            diffError = nil
            decisions = StructureDecisionStore.load(root: root, branch: built.headName)
        case .failure(let failure):
            diff = nil
            diffError = failure.message
        }
    }
}
