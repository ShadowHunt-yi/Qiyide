//
//  WikiEntryEditor.swift
//  CodeEdit
//
//  条目编辑器：右栏「编辑」后的表单。
//
//  为什么单独成文件：它是唯一一个不依赖窗口状态的视图（入参只有草稿与几个回调），
//  留在 WikiWindow 里让那个文件长到 1600 行，读起来要一直跳过它。
//
//  「所属域」是合并后加的：以前条目没有域字段，人只能在 frontmatter 手写；
//  现在给一个下拉，未归类条目可以在这里直接挂到某个域上。
//

import SwiftUI

struct WikiEntryEditor: View {

    @State private var draft: WikiEntry
    /// 可选域（id + 显示名）。来自当前领域模型。
    private let domainOptions: [(id: String, title: String)]
    private let onSave: (WikiEntry) -> Void
    private let onCancel: () -> Void
    private let onDelete: () -> Void

    @State private var tagsText: String
    @State private var sourcesText: String
    @State private var relationsText: String
    /// 空串表示「未归类」。用 String 而不是 optional 是为了直接绑到 Picker。
    @State private var domainSelection: String

    init(
        draft: WikiEntry,
        domainOptions: [(id: String, title: String)],
        onSave: @escaping (WikiEntry) -> Void,
        onCancel: @escaping () -> Void,
        onDelete: @escaping () -> Void
    ) {
        _draft = State(initialValue: draft)
        self.domainOptions = domainOptions
        self.onSave = onSave
        self.onCancel = onCancel
        self.onDelete = onDelete
        _tagsText = State(initialValue: draft.tags.joined(separator: ", "))
        _sourcesText = State(initialValue: draft.sources.joined(separator: ", "))
        _relationsText = State(
            initialValue: draft.relations.map { "\($0.kind):\($0.target)" }.joined(separator: "; ")
        )
        _domainSelection = State(initialValue: draft.domains.first ?? "")
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
                    labeled("所属域") {
                        VStack(alignment: .leading, spacing: 3) {
                            Picker("", selection: $domainSelection) {
                                Text("未归类").tag("")
                                ForEach(domainOptions, id: \.id) { option in
                                    Text(option.title).tag(option.id)
                                }
                            }
                            .labelsHidden()
                            .frame(maxWidth: 260)
                            if draft.domains.count > 1 {
                                Text("这条知识当前挂在 \(draft.domains.count) 个域上，保存后只保留所选的一个")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.orange)
                            }
                        }
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
        saved.domains = domainSelection.isEmpty ? [] : [domainSelection]
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
