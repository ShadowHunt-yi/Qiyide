//
//  StructureDiffViews.swift
//  CodeEdit
//
//  叠加分支增量时多出来的三样东西：对比条、一句结论、待确认清单。
//
//  它们的顺序就是人看一个分支的顺序：先知道在和谁比，再看结论，
//  结论说有事才往下看清单。清单里每一条都是一道判断题，答完一条少一条。
//

import AppKit
import SwiftUI

// MARK: - 对比条

/// 选「只看地图」还是「叠加分支增量」，以及和哪个分支比。
struct StructureDiffBar: View {
    @Binding var showsDiff: Bool
    let targets: [String]
    @Binding var target: String?
    @Binding var includeWorkingTree: Bool
    /// 可以声明进范围的域：`(标识, 名字)`。
    let domains: [(id: String, title: String)]
    @Binding var scope: Set<String>
    let diff: StructureDiff?
    let isLoading: Bool
    let error: String?
    let onRefresh: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Picker("", selection: $showsDiff) {
                Text("地图").tag(false)
                Text("分支增量").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 120)
            .help("地图：现在的代码长什么样。分支增量：这个分支相对目标分支改了哪些结构。")

            if showsDiff {
                targetMenu
                Toggle("含未提交", isOn: $includeWorkingTree)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .font(.system(size: 10.5))
                    .fixedSize()
                    .help("把工作区里还没提交的改动也算进来")
                Button(action: onRefresh) {
                    Image(systemName: "arrow.clockwise").font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .disabled(isLoading)
                .help("重新计算")
            }

            Spacer(minLength: 8)
            status
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }

    private var targetMenu: some View {
        Menu {
            Button("默认分支") { target = nil }
            if !targets.isEmpty {
                Divider()
                ForEach(targets, id: \.self) { name in
                    Button(name) { target = name }
                }
            }
            Divider()
            // 动手之前说好只动哪几个域；之后越界的改动会变成一条待确认。
            Menu(scope.isEmpty ? "声明改动范围" : "改动范围（\(scope.count) 个域）") {
                ForEach(domains, id: \.id) { domain in
                    Toggle(domain.title, isOn: Binding(
                        get: { scope.contains(domain.id) },
                        set: { isOn in
                            if isOn { scope.insert(domain.id) } else { scope.remove(domain.id) }
                        }
                    ))
                }
                if !scope.isEmpty {
                    Divider()
                    Button("清除范围") { scope = [] }
                }
            }
        } label: {
            Text("对比 \(target ?? diff?.targetName ?? "默认分支")")
                .font(.system(size: 10.5))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .menuStyle(.borderlessButton)
        // 分支名可以很长，空间不够时它先被截断，开关和数字要保住。
        .frame(maxWidth: 190)
        .fixedSize(horizontal: false, vertical: true)
        .help("对比 \(target ?? diff?.targetName ?? "默认分支")。基准取两者的分叉点，口径与 PR 一致。")
    }

    @ViewBuilder private var status: some View {
        if !showsDiff {
            EmptyView()
        } else if isLoading {
            HStack(spacing: 5) {
                ProgressView().scaleEffect(0.4).frame(width: 12, height: 12)
                Text("计算中…").font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
        } else if let error {
            Text(error)
                .font(.system(size: 10.5))
                .foregroundStyle(.orange)
                .lineLimit(1)
                .help(error)
        } else if let diff {
            // 当前分支名不写在这里：窗口标题和 git 状态栏已经有了，这里留给两个数。
            Text("\(diff.commitCount) 提交 · \(diff.fileCount) 文件")
                .font(.system(size: 10.5).monospacedDigit())
                .foregroundStyle(.secondary)
                .fixedSize()
                .layoutPriority(1)
                .help("\(diff.headName) 相对 \(diff.targetName)，分叉点 \(diff.baseCommit)")
        }
    }
}

// MARK: - 结论

struct StructureVerdictView: View {
    let verdict: StructureVerdict

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(verdict.headline)
                .font(.system(size: 14, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
            if !verdict.facts.isEmpty {
                Text(verdict.facts.joined(separator: " · "))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - 待确认

/// 当前范围内的待确认。没决定的在上，决定过的收成一行垫在下面，随时可以撤销。
struct StructureAskList: View {
    let asks: [StructureAsk]
    let decisions: [String: StructureDecision]
    /// 当前位置，用来决定「定位」跳到哪个锚点。
    let path: [String]
    let onNavigate: ([String]) -> Void
    let onOpenFile: (String) -> Void
    let onDecide: (StructureAsk, StructureDecision?) -> Void
    let onAdopt: (StructureAsk) -> Void

    var body: some View {
        let open = asks.filter { decisions[$0.id] == nil }
        let decided = asks.filter { decisions[$0.id] != nil }
        VStack(alignment: .leading, spacing: 6) {
            ForEach(open) { ask in
                StructureAskRow(
                    ask: ask,
                    path: path,
                    onNavigate: onNavigate,
                    onOpenFile: onOpenFile,
                    onDecide: onDecide,
                    onAdopt: onAdopt
                )
            }
            if !decided.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(decided) { ask in
                        decidedRow(ask)
                    }
                }
                .padding(.vertical, 3)
                .structureCard()
            }
            remedy
        }
    }

    private func decidedRow(_ ask: StructureAsk) -> some View {
        let decision = decisions[ask.id] ?? .accepted
        return HStack(spacing: 6) {
            Text(decision.title)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(decision == .violation ? StructurePalette.deleted : StructurePalette.added)
            Text(ask.title)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            Button("撤销") { onDecide(ask, nil) }
                .buttonStyle(.plain)
                .font(.system(size: 10.5))
                .foregroundStyle(Color.accentColor)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 3.5)
    }

    /// 标成违规的条目合成一段话，复制了就能发给 AI。
    @ViewBuilder private var remedy: some View {
        let text = StructureDecisionStore.remedyText(asks: asks, decisions: decisions)
        if !text.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("给 AI 的修改要求")
                        .font(.system(size: 11, weight: .semibold))
                    Spacer()
                    Button("复制") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    }
                    .controlSize(.small)
                }
                Text(text)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .structureCard()
        }
    }
}

struct StructureAskRow: View {
    let ask: StructureAsk
    let path: [String]
    let onNavigate: ([String]) -> Void
    let onOpenFile: (String) -> Void
    let onDecide: (StructureAsk, StructureDecision?) -> Void
    let onAdopt: (StructureAsk) -> Void

    @State private var showsEvidence = false

    /// 「定位」去哪：第一个还不在当前位置之内的锚点。都在了就不显示按钮。
    private var destination: [String]? {
        ask.anchors.first { anchor in
            !(anchor.count <= path.count && Array(path.prefix(anchor.count)) == anchor)
        }
    }

    var body: some View {
        // 两行讲完一条：第一行是「什么事 + 怎么定」，第二行是「为什么 + 去哪看」。
        // 六条待确认摞起来也不到半屏，底下的地图还露得出来。
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                WikiChip(text: ask.kind.title, color: StructurePalette.pending)
                Text(ask.title)
                    .font(.system(size: 12, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 6)
                actions
            }
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(ask.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 6)
                links
            }
            if showsEvidence {
                evidence
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .structureCard()
    }

    private var actions: some View {
        HStack(spacing: 6) {
            if let adoption = ask.adoption {
                Button("归入「\(adoption.domainTitle)」") { onAdopt(ask) }
                    .help("把这个包认领为「\(adoption.domainTitle)」的模块，地图随之更新")
                Button("留在原处") { onDecide(ask, .accepted) }
            } else {
                Button(ask.remedy.isEmpty ? "已知悉" : "接受") { onDecide(ask, .accepted) }
                if !ask.remedy.isEmpty {
                    Button("标为违规") { onDecide(ask, .violation) }
                        .help("记下来，并生成一条给 AI 的修改要求")
                }
            }
        }
        .controlSize(.small)
        .fixedSize()
    }

    private var links: some View {
        HStack(spacing: 10) {
            if !ask.evidence.isEmpty {
                Button(showsEvidence ? "收起" : "证据") { showsEvidence.toggle() }
                    .help("看是哪个文件的哪一行")
            }
            if let destination {
                Button("定位") { onNavigate(destination) }
                    .help("跳到它在地图上的位置")
            }
        }
        .buttonStyle(.plain)
        .font(.system(size: 10.5))
        .foregroundStyle(Color.accentColor)
        .fixedSize()
    }

    /// 证据行：哪个文件哪一行。点一行在编辑器里打开那个文件。
    private var evidence: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(ask.evidence.enumerated()), id: \.offset) { _, line in
                Button {
                    onOpenFile(line.file)
                } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(line.sign) \(line.text)")
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(color(line.sign))
                            .lineLimit(2)
                            .truncationMode(.middle)
                        if line.line > 0 {
                            Text("\((line.file as NSString).lastPathComponent):\(line.line)")
                                .font(.system(size: 9.5, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(line.sign == "-")
                .help(line.file)
            }
        }
        .padding(.vertical, 3)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }

    private func color(_ sign: String) -> Color {
        switch sign {
        case "+": return StructurePalette.added
        case "-": return StructurePalette.deleted
        default: return .primary
        }
    }
}
