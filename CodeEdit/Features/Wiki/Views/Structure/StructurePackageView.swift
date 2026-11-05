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
    /// 参数是完整路径 `[域, 模块, 子包…]`。
    let onNavigate: ([String]) -> Void
    let onOpenFile: (String) -> Void

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 240), spacing: 8, alignment: .top)]

    private var largest: Int {
        max(contents.packages.map(\.classCount).max() ?? 1, 1)
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                header
                if !contents.packages.isEmpty {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                        ForEach(contents.packages) { package in
                            StructureTile(
                                title: package.name,
                                classCount: package.classCount,
                                ratio: Double(package.classCount) / Double(largest),
                                help: ([module.key] + package.subpath).joined(separator: "/")
                            ) {
                                onNavigate([domain.id, module.id] + package.subpath)
                            }
                        }
                    }
                }
                if !contents.files.isEmpty {
                    fileList
                }
            }
            .padding(12)
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

    private var fileList: some View {
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
                    HStack(spacing: 6) {
                        Image(systemName: "doc.text")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                        Text(file.fileName)
                            .font(.system(size: 11.5, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let label = contents.rootLabels[file.path], !label.isEmpty {
                            WikiChip(text: label)
                        }
                    }
                }
            }
        }
        .padding(.vertical, contents.packages.isEmpty ? 4 : 0)
        .structureCard()
    }
}
