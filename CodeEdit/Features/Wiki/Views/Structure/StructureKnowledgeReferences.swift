import SwiftUI

/// 结构提示关联业务约定，但不声称本次实现已经满足这些约定。
struct StructureKnowledgeReferences: View {
    let ask: StructureAsk
    let entries: [WikiEntry]
    let report: WikiKnowledgeReport
    let onSelect: (String) -> Void

    private var related: [WikiEntry] {
        let domains = Set(ask.anchors.compactMap(\.first))
        let paths = ask.evidence.map(\.file)
        return entries.filter { entry in
            entry.proposalFor == nil && (
                !domains.isDisjoint(with: entry.domains)
                || entry.sources.contains { source in
                    paths.contains { WikiKnowledgeContext.matches(source: source, path: $0) }
                }
            )
        }.sorted {
            let left = [.rule, .decision, .term].contains($0.type) ? 0 : 1
            let right = [.rule, .decision, .term].contains($1.type) ? 0 : 1
            return left == right ? $0.title < $1.title : left < right
        }
    }

    var body: some View {
        let matches = related
        let usable = matches.filter { report.assessment(for: $0).state.canReference }
        if !matches.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                if usable.isEmpty {
                    Text("关联知识尚待核验，当前只能依据结构事实判断。")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                } else {
                    Text("业务参考 · 不代表本次实现已满足")
                        .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                    ForEach(usable.prefix(2)) { entry in
                        Button { onSelect(entry.id) } label: {
                            HStack(alignment: .top, spacing: 6) {
                                Image(systemName: "text.book.closed").font(.system(size: 10))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.displayTitle).font(.system(size: 11, weight: .medium))
                                    Text(entry.summary).font(.system(size: 10)).lineLimit(2).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                                Text("查看依据").font(.system(size: 10))
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    if usable.count > 2 {
                        Text("另有 \(usable.count - 2) 条参考，可在知识库中继续查看。")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
        }
    }
}
