//
//  StructureMapView.swift
//  CodeEdit
//
//  结构地图：沿真实包路径逐级下钻，全仓 › 域 › 模块 › 子包 › 文件。
//
//  和导图的分工：
//  导图回答「域该怎么划」，可以拖、可以改，是建模用的；
//  结构地图回答「现在的代码长什么样」，只读，是拿来看和定位的。
//  两者读同一份领域模型，所以在导图里改了归属，这里立刻跟着变。
//
//  每一级只画「当前节点的子节点」，往上靠面包屑。这样无论仓库多大，
//  一屏里的东西都是有限的——全仓看域，域里看模块，模块里看文件。
//

import SwiftUI

struct StructureMapView: View {

    @ObservedObject var store: DomainModelStore
    let root: URL
    /// 进入某个域时同步给窗口，左栏和右栏跟着切到这个域。
    @Binding var selectedDomain: String?
    /// 参数是仓库相对路径。
    let onOpenFile: (String) -> Void

    @State private var index: StructureIndex
    /// 当前位置：`[域标识, 模块标识, 子包段…]`，空数组是全仓。
    @State private var path: [String]
    @State private var isLoading = false

    /// - Parameters:
    ///   - preloaded: 离屏渲染没有视图生命周期，`.task` 不保证跑完，所以允许直接塞一份建好的索引。
    ///   - initialPath: 同上，用来直接渲染某一级。
    init(
        store: DomainModelStore,
        root: URL,
        selectedDomain: Binding<String?>,
        onOpenFile: @escaping (String) -> Void,
        preloaded: StructureIndex? = nil,
        initialPath: [String] = []
    ) {
        self.store = store
        self.root = root
        _selectedDomain = selectedDomain
        self.onOpenFile = onOpenFile
        _index = State(initialValue: preloaded ?? .empty)
        _path = State(initialValue: initialPath)
    }

    var body: some View {
        VStack(spacing: 0) {
            if !index.isEmpty {
                StructureBreadcrumbBar(crumbs: crumbs, summary: summary) { path = $0 }
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
        } else if let domain = currentDomain {
            if let module = currentModule {
                StructurePackageView(
                    domain: domain,
                    module: module,
                    subpath: currentSubpath,
                    contents: index.contents(of: module, at: currentSubpath),
                    onNavigate: { path = $0 },
                    onOpenFile: onOpenFile
                )
            } else {
                StructureDomainView(domain: domain) { path = $0 }
            }
        } else {
            StructureOverviewView(index: index) { path = $0 }
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
        var result = [StructureCrumb(path: [], title: root.lastPathComponent)]
        if let domain = currentDomain {
            result.append(StructureCrumb(path: [domain.id], title: domain.title))
            if let module = currentModule {
                var here = [domain.id, module.id]
                result.append(StructureCrumb(path: here, title: module.title))
                for segment in currentSubpath {
                    here.append(segment)
                    result.append(StructureCrumb(path: here, title: segment))
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

    // MARK: 加载

    private func reload() async {
        guard !store.graph.isEmpty else {
            index = .empty
            path = []
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
    }
}
