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
                Text("选择左侧的领域或条目，或点击导图中的节点")
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
        let url = store.root.appending(path: source)
        guard FileManager.default.fileExists(atPath: url.path) else {
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
                                    sourceRow(source)
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

    func draftBanner(_ entry: WikiEntry) -> some View {
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

    /// 分组标题 + 内容。样式统一在 `WikiSection`，这里只保留调用形式。
}
