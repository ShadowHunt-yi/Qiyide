//
//  StructureDecisionStore.swift
//  CodeEdit
//
//  人对「待确认」做的决定，按分支落盘。
//
//  为什么要落盘：一个分支往往要看好几轮——AI 改一轮，人看一轮。
//  上一轮已经点过「接受」的那几条，这一轮不该再问一遍；
//  而标成违规的，要一直挂着，直到代码真的改回去（那时这条待确认自己就消失了）。
//
//  决定挂在「待确认的稳定标识」上，不挂在行号或文件内容上：
//  代码继续变，只要还是同一件事（同一对域之间的新依赖、同一个接口），决定就还作数。
//
//  同一个文件里还存着每个分支「声明的改动范围」：动手之前说好只动哪几个域，
//  之后越界的改动会自动变成一条待确认。
//
//  文件在 `.qiyide/wiki/structure/decisions.json`，按分支名分组。
//

import Foundation

/// 对一条待确认的决定。
enum StructureDecision: String, Codable, Sendable {
    /// 知道了，可以这样。
    case accepted
    /// 不该这样，要改回去。
    case violation

    var title: String {
        switch self {
        case .accepted: return "已接受"
        case .violation: return "标为违规"
        }
    }
}

enum StructureDecisionStore {

    private struct File: Codable {
        var version = 1
        /// 分支名 → 待确认标识 → 决定。
        var branches: [String: [String: StructureDecision]] = [:]
        /// 分支名 → 声明只动的域。可选：旧文件里没有这个字段。
        var scopes: [String: [String]]?
    }

    static func url(root: URL) -> URL {
        root.appending(path: ".qiyide/wiki/structure/decisions.json")
    }

    static func load(root: URL, branch: String) -> [String: StructureDecision] {
        read(root: root).branches[branch] ?? [:]
    }

    /// 写回某个分支的全部决定。空字典会把这个分支的记录删掉，不留空壳。
    static func save(_ decisions: [String: StructureDecision], root: URL, branch: String) {
        var file = read(root: root)
        file.branches[branch] = decisions.isEmpty ? nil : decisions
        write(file, root: root)
    }

    static func loadScope(root: URL, branch: String) -> Set<String> {
        Set(read(root: root).scopes?[branch] ?? [])
    }

    static func saveScope(_ scope: Set<String>, root: URL, branch: String) {
        var file = read(root: root)
        var scopes = file.scopes ?? [:]
        scopes[branch] = scope.isEmpty ? nil : scope.sorted()
        file.scopes = scopes.isEmpty ? nil : scopes
        write(file, root: root)
    }

    private static func write(_ file: File, root: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(file) else { return }
        let target = url(root: root)
        try? FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: target, options: .atomic)
    }

    private static func read(root: URL) -> File {
        guard let data = try? Data(contentsOf: url(root: root)),
              let file = try? JSONDecoder().decode(File.self, from: data) else {
            return File()
        }
        return file
    }

    /// 把标成违规的条目整理成一段可以直接发给 AI 的修改要求。
    static func remedyText(asks: [StructureAsk], decisions: [String: StructureDecision]) -> String {
        let lines = asks
            .filter { decisions[$0.id] == .violation && !$0.remedy.isEmpty }
            .enumerated()
            .map { "\($0.offset + 1). \($0.element.remedy)" }
        guard !lines.isEmpty else { return "" }
        return "以下改动不符合项目的结构约定，请修改：\n" + lines.joined(separator: "\n")
    }
}
