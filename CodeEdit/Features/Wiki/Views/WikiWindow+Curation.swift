//
//  WikiWindow+Curation.swift
//  CodeEdit
//
//  「AI 整理」：把一份改动（工作区/提交/文件）喂给模型，产出一条待确认的草稿。
//
//  难点不在调模型，在「输入从哪来」：只认未提交改动，提交完或看历史代码时就再也生成不了。
//  所以这里显式区分四种输入源，并把取不到时的原因说清楚。
//

import Foundation

extension WikiWindowView {

    enum CurationSource {
        case workingTree
        case lastCommit
        case currentFile
        case selectedEntrySources
    }

    var activeFileURL: URL? {
        workspace?.editorManager?.activeEditor.selectedTab?.file.url
    }

    var selectedEntrySources: [String] {
        guard let id = selection, let entry = store.entry(id: id) else { return [] }
        return entry.sources
    }

    func curate(_ source: CurationSource) {
        guard var input = curationInput(for: source) else {
            curatorError = emptyReason(for: source)
            return
        }
        // 域上下文：按本次改动的文件路径匹配。有了它，模型知道自己在给哪个域写，
        // 产出的草稿也直接挂在域上——不用再跑一遍「域归属」。
        input.domain = domainContext(for: input.files)
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
                    sources: Array(input.files.prefix(8)),
                    domainID: input.domain?.id
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

    /// 给一批文件找域。只取「唯一确定」的结果——多义与无归属都返回 nil，
    /// 和「域归属」回填完全同一套规则（见 `WikiDomainBackfill.domain(forSources:graph:)`）。
    func domainContext(for files: [String]) -> WikiCurationInput.DomainContext? {
        guard let hit = WikiDomainBackfill.domain(forSources: files, graph: domains.graph) else {
            return nil
        }
        let node = domains.graph.node(hit.domainID)
        return WikiCurationInput.DomainContext(
            id: hit.domainID,
            title: hit.domainTitle,
            packages: node?.packages ?? [],
            classCount: node?.classCount ?? 0
        )
    }

    func curationInput(for source: CurationSource) -> WikiCurationInput? {
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

    func emptyReason(for source: CurationSource) -> String {
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

    func relativePath(of url: URL) -> String {
        let rootPath = store.root.standardizedFileURL.path
        let filePath = url.standardizedFileURL.path
        guard filePath.hasPrefix(rootPath) else { return filePath }
        return String(filePath.dropFirst(rootPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}
