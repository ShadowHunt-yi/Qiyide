//
//  WikiWindow+Sidebar.swift
//  CodeEdit
//
//  左栏：域列表 + 条目列表。
//
//  两个段落共用一个 ScrollView（原因见 `domainSection`），
//  所有行都用 `Button` + `.plain` 样式，让整行可点、又不带系统按钮的边框。
//

import AppKit
import SwiftUI

extension WikiWindowView {

    // MARK: 列表

    /// 可见列表。批量操作只作用于「可见」范围，避免选中项被筛选条件藏起来。
    var filteredEntries: [WikiEntry] {
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
    static let unassignedKey = "__unassigned__"

    var listPane: some View {
        // 只算一次。`filteredEntries` 会对整库做过滤/检索，
        // 原来头部计数、空态判断、ForEach 各调一次，一次 body 要扫三遍。
        let entries = filteredEntries
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if !domains.graph.domains.isEmpty {
                    domainSection
                }
                entrySection(entries)
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
    var domainSection: some View {
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
        if !store.hasDomainTags && !store.entries.isEmpty {
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

    func domainRow(_ node: MindNode) -> some View {
        let count = store.entries(inDomain: node.id).count
        let isSelected = selectedDomain == node.id
        // 还没打标时显示「—」而不是「缺口」：0 不代表没有知识，只代表没建立归属。
        let tagged = store.hasDomainTags
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

    var unassignedRow: some View {
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
    func entrySection(_ entries: [WikiEntry]) -> some View {
        if !domains.graph.domains.isEmpty || selectedDomain != nil {
            HStack(spacing: 5) {
                Text(filterTitle)
                Text("\(entries.count)")
                    .monospacedDigit()
                Spacer()
            }
            .font(.system(size: 10))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 10)
            .padding(.top, 7)
            .padding(.bottom, 2)
        }

        if entries.isEmpty {
            Text(emptyListText)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(16)
        }
        ForEach(entries) { entry in
            row(entry)
            Divider()
        }
    }

    var filterTitle: String {
        guard let selectedDomain else { return "全部条目" }
        if selectedDomain == Self.unassignedKey { return "未归类条目" }
        return domains.graph.node(selectedDomain)?.displayTitle ?? "条目"
    }

    var emptyListText: String {
        if !query.isEmpty { return "没有匹配「\(query)」的条目" }
        if selectedDomain == Self.unassignedKey { return "没有未归类条目" }
        if selectedDomain != nil {
            // 条目全都没打标时，说「这个域没有知识」是错的——
            // 知识在，只是还没建立归属。两者的下一步动作完全不同。
            if !store.hasDomainTags {
                return "条目还没标归属，先在「域归属」里补写"
            }
            return "这个域还没有知识，可在导图模式点「⋯ → 生成缺失知识」"
        }
        return "没有条目"
    }

    func row(_ entry: WikiEntry) -> some View {
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

    func rowBackground(_ entry: WikiEntry) -> Color {
        if selection == entry.id { return Color.accentColor.opacity(0.14) }
        if multiSelection.contains(entry.id) { return Color.accentColor.opacity(0.07) }
        return .clear
    }

    /// 点击语义与 Finder 一致：直接点是单选，⌘ 是切换，Shift 是范围。
    func handleTap(_ entry: WikiEntry) {
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
}
