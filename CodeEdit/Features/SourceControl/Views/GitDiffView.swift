//
//  GitDiffView.swift
//  CodeEdit
//
//  编辑器区内的差异标签页（VS Code 式并排对比）。
//

import AppKit
import SwiftUI

// MARK: - 并排对比的行对

/// 并排视图中的一行：左列是 HEAD 版本，右列是工作区版本。
struct GitDiffLinePair: Identifiable {
    let id: Int
    /// 该行在 HEAD 中的行号；右列独有行为 nil。
    let oldNumber: Int?
    /// 该行在工作区中的行号；左列独有行为 nil。
    let newNumber: Int?
    /// 左列文本；nil 表示空白对照行。
    let oldText: String?
    /// 右列文本；nil 表示空白对照行。
    let newText: String?
    let oldKind: GitClient.DiffRow.Kind
    let newKind: GitClient.DiffRow.Kind
}

// MARK: - 差异标签的数据源

/// 一个差异标签页的数据源。标签页在内存中存活期间持有。
@MainActor
final class GitDiffTabSource: ObservableObject, Identifiable {
    let id = UUID()
    let changedFile: GitChangedFile
    let file: CEWorkspaceFile
    let manager: SourceControlManager

    @Published private(set) var pairs: [GitDiffLinePair] = []
    @Published private(set) var phase: Phase = .loading
    /// 增删行数在加载时算一次：视图 body 里每次求值都 filter 一遍，大 diff 会反复 O(n)。
    @Published private(set) var addedCount: Int = 0
    @Published private(set) var removedCount: Int = 0

    enum Phase: Equatable {
        case loading
        case ready
        case empty
        case failed(String)
    }

    init(changedFile: GitChangedFile, file: CEWorkspaceFile, manager: SourceControlManager) {
        self.changedFile = changedFile
        self.file = file
        self.manager = manager
    }

    func load() async {
        phase = .loading
        do {
            let started = PerformanceRecorder.shared.begin()
            let rows = try await manager.diff(for: changedFile)
            PerformanceRecorder.shared.record(
                startedAt: started,
                category: .gitDiff,
                meta: ["rows": "\(rows.count)"]
            )
            let aligned = Self.align(rows)
            pairs = aligned
            addedCount = aligned.reduce(0) { $0 + ($1.newKind == .added ? 1 : 0) }
            removedCount = aligned.reduce(0) { $0 + ($1.oldKind == .removed ? 1 : 0) }
            phase = rows.isEmpty ? .empty : .ready
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// 把统一差异行配成并排对：连续的删除/新增块按序一行对一行（VS Code 的对齐规则），
    /// 数量不等时多出的一侧显示空白。
    static func align(_ rows: [GitClient.DiffRow]) -> [GitDiffLinePair] {
        var result: [GitDiffLinePair] = []
        var index = 0
        var id = 0

        while index < rows.count {
            let row = rows[index]
            if row.kind == .context {
                result.append(
                    GitDiffLinePair(
                        id: id,
                        oldNumber: row.oldNumber,
                        newNumber: row.newNumber,
                        oldText: row.text,
                        newText: row.text,
                        oldKind: .context,
                        newKind: .context
                    )
                )
                id += 1
                index += 1
                continue
            }

            var removed: [GitClient.DiffRow] = []
            var added: [GitClient.DiffRow] = []
            while index < rows.count, rows[index].kind != .context {
                if rows[index].kind == .removed {
                    removed.append(rows[index])
                } else {
                    added.append(rows[index])
                }
                index += 1
            }

            let count = max(removed.count, added.count)
            for offset in 0..<count {
                let removedRow = offset < removed.count ? removed[offset] : nil
                let addedRow = offset < added.count ? added[offset] : nil
                result.append(
                    GitDiffLinePair(
                        id: id,
                        oldNumber: removedRow?.oldNumber,
                        newNumber: addedRow?.newNumber,
                        oldText: removedRow?.text,
                        newText: addedRow?.text,
                        oldKind: removedRow?.kind ?? .context,
                        newKind: addedRow?.kind ?? .context
                    )
                )
                id += 1
            }
        }
        return result
    }
}

// MARK: - 打开差异标签

@MainActor
enum GitDiffTab {
    /// 在编辑器区打开一个文件的差异标签（VS Code 式）。
    static func open(
        changedFile: GitChangedFile,
        manager: SourceControlManager,
        workspace: WorkspaceDocument?,
        asTemporary: Bool = true
    ) {
        guard let editor = workspace?.editorManager?.activeEditor else { return }
        let ceFile = workspace?.workspaceFileManager?.getFile(changedFile.ceFileKey, createIfNotFound: true)
            ?? CEWorkspaceFile(url: changedFile.fileURL)
        let source = GitDiffTabSource(changedFile: changedFile, file: ceFile, manager: manager)
        editor.openDiffTab(source: source, asTemporary: asTemporary)
    }
}

// MARK: - 差异标签视图

/// VS Code 式并排差异：左列 HEAD、右列工作区，变更行对齐、增删着色。
struct GitDiffTabView: View {
    @ObservedObject var source: GitDiffTabSource

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            columnHeader
            Divider()
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
        .task(id: source.id) {
            await source.load()
        }
    }

    // MARK: 子视图

    private var header: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(source.file.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(relativePath)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if source.phase == .ready {
                Text("+\(source.addedCount)")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.green)
                Text("-\(source.removedCount)")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.red)
            }
            Button(NSLocalizedString("Open File", comment: "")) {
                source.manager.editorManager.openTab(item: source.file, asTemporary: false)
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var columnHeader: some View {
        HStack(spacing: 0) {
            Text("HEAD")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(NSLocalizedString("Working Tree", comment: ""))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundColor(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private var content: some View {
        switch source.phase {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .empty:
            CEContentUnavailableView(
                NSLocalizedString("No textual changes", comment: ""),
                systemImage: "doc.text.magnifyingglass"
            )
        case .failed(let message):
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 28))
                    .foregroundColor(.orange)
                Text(message)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                Button(NSLocalizedString("Retry", comment: "")) {
                    Task { await source.load() }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(30)
        case .ready:
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(source.pairs) { pair in
                        pairRow(pair)
                    }
                }
                // 选中能力放在容器上，而不是每一行的每个 Text 上：
                // 逐行开启 textSelection 会为每行建立独立的文本选择视图，大 diff 滚动明显卡顿。
                .textSelection(.enabled)
            }
        }
    }

    private func pairRow(_ pair: GitDiffLinePair) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            // 左列：HEAD
            Text(numberText(pair.oldNumber))
                .frame(width: 40, alignment: .trailing)
                .foregroundColor(.secondary)
            Text(pair.oldText ?? "")
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(1)
                .background(pair.oldKind == .removed ? Color.red.opacity(0.13) : .clear)
                .foregroundColor(pair.oldKind == .removed ? .red : .primary)

            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(width: 1)

            // 右列：工作区
            Text(numberText(pair.newNumber))
                .frame(width: 40, alignment: .trailing)
                .foregroundColor(.secondary)
            Text(pair.newText ?? "")
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(1)
                .background(pair.newKind == .added ? Color.green.opacity(0.13) : .clear)
                .foregroundColor(pair.newKind == .added ? .green : .primary)
        }
        .font(.system(size: 12, design: .monospaced))
        .padding(.horizontal, 6)
        .frame(minHeight: 18)
    }

    private func numberText(_ number: Int?) -> String {
        guard let number else { return "" }
        return String(number)
    }

    private var relativePath: String {
        let root = source.manager.workspaceURL.standardizedFileURL.path
        let path = source.file.url.standardizedFileURL.path
        guard path.hasPrefix(root + "/") else { return path }
        return String(path.dropFirst(root.count + 1))
    }
}
