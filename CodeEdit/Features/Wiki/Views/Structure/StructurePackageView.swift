//
//  StructurePackageView.swift
//  CodeEdit
//
//  结构地图的第三级及以下：一个模块（或它的某个子包）里面有什么。
//
//  这一级和上面两级是同一种画法：先列下一级子包，再列直接放在这里的文件。
//  有子包就继续往下点，面包屑跟着变长；没有子包就直接是文件清单。
//  点文件在编辑器里打开——走到文件这一步，人要看的就是代码本身。
//

import SwiftUI

struct StructurePackageView: View {
    let domain: StructureDomain
    let module: StructureModule
    /// 相对模块的子路径。空数组表示模块本身。
    let subpath: [String]
    let contents: StructureContents
    var overlay: StructureOverlay?
    /// 参数是完整路径 `[域, 模块, 子包…]`。
    let onNavigate: ([String]) -> Void
    let onOpenFile: (String) -> Void

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 240), spacing: 8, alignment: .top)]

    private var largest: Int {
        max(contents.packages.map(\.classCount).max() ?? 1, 1)
    }

    /// 恰好落在这一级的文件改动，按路径查。
    private var changes: [String: StructureFileChange] {
        guard let overlay else { return [:] }
        var result: [String: StructureFileChange] = [:]
        for change in overlay.diff.changes(module: module.id, at: subpath) {
            result[change.path] = change
        }
        return result
    }

    var body: some View {
        let changes = self.changes
        let deleted = changes.values.filter { $0.kind == .deleted }.sorted { $0.path < $1.path }
        VStack(alignment: .leading, spacing: 12) {
            header
            if !contents.packages.isEmpty {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                    ForEach(contents.packages) { package in
                        packageTile(package)
                    }
                }
            }
            if !contents.files.isEmpty || !deleted.isEmpty {
                fileList(changes: changes, deleted: deleted)
            }
        }
    }

    private func packageTile(_ package: StructurePackage) -> some View {
        let path = [domain.id, module.id] + package.subpath
        return StructureTile(
            title: package.name,
            classCount: package.classCount,
            ratio: Double(package.classCount) / Double(largest),
            help: ([module.key] + package.subpath).joined(separator: "/"),
            marks: overlay?.diff.marks(module: module.id, under: package.subpath) ?? StructureMarks(),
            pending: overlay?.pending(path) ?? 0,
            isQuiet: overlay != nil
        ) {
            onNavigate(path)
        }
    }

    private var title: String {
        subpath.last ?? module.title
    }

    private var fullKey: String {
        ([module.key] + subpath).joined(separator: "/")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title)
                    .font(.system(
                        size: 15,
                        weight: .semibold,
                        design: module.isRoot && subpath.isEmpty ? .default : .monospaced
                    ))
                Text("\(contents.classCount) 个类")
                    .font(.system(size: 10.5).monospacedDigit())
                    .foregroundStyle(.secondary)
                if subpath.isEmpty, overlay?.diff.newModules.contains(module.id) == true {
                    WikiChip(text: "本分支新增", color: StructurePalette.added)
                }
            }
            Text(fullKey)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            if module.isRoot {
                Text("直接放在「\(domain.title)」根目录下、没有进任何子包的类。")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func fileList(changes: [String: StructureFileChange], deleted: [StructureFileChange]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // 有子包时才需要这行小标题，把「这一级自己的文件」和上面的子包分开。
            if !contents.packages.isEmpty {
                HStack {
                    Text("直接放在这一级的文件")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Text("\(contents.files.count)")
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                Divider()
            }
            ForEach(contents.files) { file in
                StructureRowButton(help: file.path) {
                    onOpenFile(file.path)
                } label: {
                    fileLabel(
                        name: file.fileName,
                        change: changes[file.path],
                        origin: contents.rootLabels[file.path]
                    )
                }
            }
            // 删掉的文件磁盘上已经没有了，点不开，但要让人看见它被删了。
            ForEach(deleted) { change in
                fileLabel(name: change.fileName, change: change, origin: nil)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3.5)
                    .help(change.counterpart.map { "移到了 \($0)" } ?? change.path)
            }
        }
        .padding(.vertical, contents.packages.isEmpty ? 4 : 0)
        .structureCard()
    }

    private func fileLabel(name: String, change: StructureFileChange?, origin: String?) -> some View {
        HStack(spacing: 6) {
            if overlay != nil {
                // 固定宽度的标记列：有没有改动，文件名都从同一条竖线开始。
                Text(change?.kind.sign ?? "")
                    .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(change.map { StructurePalette.color($0.kind) } ?? .clear)
                    .frame(width: 10)
            }
            Image(systemName: "doc.text")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Text(name)
                .font(.system(size: 11.5, design: .monospaced))
                .strikethrough(change?.kind == .deleted)
                .foregroundStyle(overlay != nil && change == nil ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.middle)
            if let change {
                ForEach(StructureAsk.Kind.allCases.filter(change.tags.contains), id: \.self) { kind in
                    WikiChip(text: kind.title, color: StructurePalette.pending)
                }
                if change.counterpart != nil {
                    WikiChip(text: change.kind == .deleted ? "已移走" : "移入")
                }
                if change.isUncommitted {
                    WikiChip(text: "未提交")
                }
            }
            if let origin, !origin.isEmpty {
                WikiChip(text: origin)
            }
        }
    }
}
