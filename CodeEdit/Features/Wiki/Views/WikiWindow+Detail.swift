//
//  WikiWindow+Detail.swift
//  CodeEdit
//
//  右栏：条目正文、关联代码、反向链接、草稿横幅。
//
//  这一栏只读 store，不改任何数据——所有修改都走回调交给窗口，
//  免得「详情页自己存了一份」和「列表还显示旧的」这种分叉。
//

import AppKit
import SwiftUI

extension WikiWindowView {

    // MARK: 详情

    @ViewBuilder
    var detailPane: some View {
        if let draft = editing {
            WikiEntryEditor(
                draft: draft,
                domainOptions: domains.graph.domains.map { ($0.id, $0.displayTitle) },
                onSave: { saved in
                    do {
                        var edited = saved
                        edited.protectsHumanContent = true
                        try store.save(edited)
                        editing = nil
                    } catch { curatorError = error.localizedDescription }
                },
                onCancel: { editing = nil },
                onDelete: { deleteTarget = draft }
            )
        } else if let entry = selection.flatMap({ store.entry(id: $0) }) {
            detail(entry)
        } else if let domainID = selectedDomain,
                  domainID != Self.unassignedKey,
                  let node = domains.graph.node(domainID) {
            WikiDomainDetailView(
                node: node,
                entries: store.entries(inDomain: domainID),
                modules: domains.graph.children(of: domainID)
                    .sorted { $0.classCount > $1.classCount },
                onOpenMindMap: {
                    centerMode = .mindmap
                    activeSpec = nil
                },
                onGenerate: { generateMissingKnowledge() },
                onSelectEntry: { selection = $0 }
            )
        } else {
            VStack(spacing: 8) {
                Image(systemName: "sidebar.right")
                    .font(.system(size: 24))
                    .foregroundStyle(.tertiary)
                Text("选择一条知识，查看业务内容、确认记录和来源变化")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // 域详情已抽到 `WikiDomainDetailView`：它只依赖「节点 + 条目 + 模块 + 三个回调」，
    // 不需要窗口的其它状态。这里只负责取数和转发回调。

    /// 一行关联代码。
    ///
    /// 三种状态要分清，否则用户会以为功能坏了：
    /// - 包路径（`agent/suggest`）：模型给出的归属，不是文件，只展示；
    /// - 文件且存在：可点开；
    /// - 文件但不存在：橙色标出「已失效」——这正是体检里的「过期关联」。
    func sourceRow(_ source: String) -> some View {
        let isFile = !(source as NSString).pathExtension.isEmpty
        let exists = isFile
            ? FileManager.default.fileExists(atPath: store.root.appending(path: source).path)
            : true
        let clickable = isFile && exists

        return Button {
            if clickable { openSource(source) }
        } label: {
            HStack(spacing: 4) {
                if isFile && !exists {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(.orange)
                }
                Text(source)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(clickable ? Color.accentColor : (exists ? Color.secondary : Color.orange))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                if clickable {
                    Image(systemName: "arrow.up.forward.square")
                        .font(.system(size: 8))
                        .foregroundStyle(.quaternary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!clickable)
        .help(isFile ? (exists ? "在编辑器中打开" : "文件已不存在") : "领域包路径（不是文件）")
    }

    /// 在工作区里打开源码。没有工作区时退回访达。
    func openSource(_ source: String) {
        guard let url = WikiSourceInspector.resolvedFile(source, root: store.root),
              FileManager.default.fileExists(atPath: url.path) else {
            curatorError = "文件已不存在：\(source)"
            return
        }
        guard let editor = workspace?.editorManager?.activeEditor else {
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return
        }
        editor.openTab(file: CEWorkspaceFile(url: url), asTemporary: true)
    }


    func detail(_ entry: WikiEntry) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            knowledgeBanner(entry)
            Divider()
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
                    knowledgeEvidence(entry)
                    if let targetID = entry.proposalFor {
                        section("更新建议的原文") {
                            if let original = store.entry(id: targetID) {
                                Text(original.body)
                                    .font(.system(size: 12))
                                    .textSelection(.enabled)
                                    .lineLimit(showsFullOriginalKnowledge ? nil : 6)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Button(showsFullOriginalKnowledge ? "收起原文" : "查看完整原文") {
                                    showsFullOriginalKnowledge.toggle()
                                }
                                .buttonStyle(.link).font(.system(size: 10))
                            } else {
                                Text("原条目不存在，不能自动接受更新。")
                                    .font(.system(size: 11)).foregroundStyle(.orange)
                            }
                        }
                    }
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
                                    sourceRow(source)
                                }
                            }
                        }
                    }

                    section(entry.proposalFor == nil ? "正文" : "拟更新内容") {
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

    func knowledgeBanner(_ entry: WikiEntry) -> some View {
        let assessment = store.assessment(for: entry)
        return VStack(alignment: .leading, spacing: 7) {
            HStack {
                WikiKnowledgeBadge(assessment: assessment)
                Spacer()
                if entry.isDraft && entry.protectsHumanContent {
                    Button("删除…") { deleteTarget = entry }.controlSize(.small)
                } else if entry.isDraft {
                    Button("丢弃草稿") {
                        do {
                            try store.discardDraft(entry)
                            selection = nil
                        } catch { curatorError = error.localizedDescription }
                    }
                    .controlSize(.small)
                }
            }
            if entry.proposalFor != nil {
                Text(entry.provenance?.pipeline == "manual-source-binding-v1"
                     ? "已解析真实来源，原文未覆盖。请对照来源与原文后决定。"
                     : "AI 提出了更新，原文未覆盖。请对照后决定。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Button("接受更新并确认") {
                    do { selection = try store.acceptProposal(entry).id }
                    catch { curatorError = error.localizedDescription }
                }
                .disabled(store.isCheckingKnowledge)
                .controlSize(.small)
            } else if !assessment.state.canReference {
                if !entry.scopePaths.isEmpty && entry.sources.isEmpty {
                    Text("尚未绑定实际文件。校验只检查现有基线，不能靠反复点击变成可引用。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Button(sourceBindingID == entry.id ? "正在解析来源…" : "解析真实来源并生成更新建议") {
                        guard sourceBindingID == nil else { return }
                        sourceBindingID = entry.id
                        Task {
                            defer { sourceBindingID = nil }
                            do {
                                let proposal = try await store.proposeSourceBinding(for: entry)
                                selection = proposal.id
                                curatorMessage = "已生成来源绑定建议，原文未修改；请对照后接受更新，再校验来源。"
                            } catch { curatorError = error.localizedDescription }
                        }
                    }
                    .disabled(sourceBindingID != nil || store.isCheckingKnowledge)
                    .controlSize(.small)
                    Button("手动编辑文件来源与范围") { editing = entry }
                        .disabled(store.isCheckingKnowledge)
                        .controlSize(.small)
                } else {
                    Button("我已核对，确认当前知识") {
                        do { try store.confirm(entry) }
                        catch { curatorError = error.localizedDescription }
                    }
                    .disabled(store.isCheckingKnowledge)
                    .controlSize(.small)
                    .help("记录这版内容及来源。无法核验的来源仍不作为 AI 的依据。")
                }
            }
            if !assessment.nextStep.isEmpty {
                Text(assessment.nextStep).font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(WikiKnowledgeBadge.color(assessment.state).opacity(0.06))
    }

    func knowledgeEvidence(_ entry: WikiEntry) -> some View {
        let assessment = store.assessment(for: entry)
        return section("依据与确认") {
            Text(assessment.detail)
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let receipt = entry.confirmation {
                Text("人工确认：\(receipt.confirmedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                Text("内容版本：\(receipt.contentDigest.prefix(12))")
                    .font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
            }
            if !entry.generatedBy.isEmpty {
                Text("起草来源：\(entry.generatedBy)")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            ForEach(assessment.changedSources, id: \.self) { source in sourceRow(source) }
            if !assessment.issues.isEmpty {
                DisclosureGroup("具体来源问题（\(assessment.issues.count) 项）") {
                    ForEach(Array(assessment.issues.enumerated()), id: \.offset) { _, issue in
                        VStack(alignment: .leading, spacing: 3) {
                            if let path = issue.path {
                                Text(path).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                            }
                            Text(issue.detail).font(.system(size: 10)).foregroundStyle(.secondary)
                        }.padding(.vertical, 3)
                    }
                }.font(.system(size: 10))
            }
        }
    }

    /// 分组标题 + 内容。样式统一在 `WikiSection`，这里只保留调用形式。
}
