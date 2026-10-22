//
//  Workspace.swift
//  CodeEdit
//
//  工作区模型：一个工作区由若干根目录与一份配置覆盖组成。
//

import Foundation

/// 工作区中的一个根目录（VS Code 中的 workspace folder）。
struct WorkspaceFolder: Codable, Identifiable, Hashable {
    var id: UUID
    /// 根目录的绝对路径。存储路径而非 `URL`，以便工作区文件可被读取和手动编辑。
    var path: String
    /// 导航器中显示的名称，为空时使用目录名。
    var name: String?

    init(path: String, name: String? = nil, id: UUID = UUID()) {
        self.id = id
        self.path = path
        self.name = name
    }

    init(url: URL, name: String? = nil, id: UUID = UUID()) {
        self.init(path: url.standardizedFileURL.path, name: name, id: id)
    }

    var url: URL {
        URL(fileURLWithPath: path)
    }

    /// 显示名：优先使用显式名称，否则取目录名。
    var displayName: String {
        if let name, !name.isEmpty {
            return name
        }
        return url.lastPathComponent
    }
}

/// 一个工作区。
///
/// 工作区是「配置与状态的隔离单元」：每个工作区拥有独立的根目录集合、独立的设置覆盖、
/// 独立的状态存储键（`id`）。同一个目录可以出现在多个工作区中，互不影响。
struct Workspace: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    /// 根目录集合。阶段性实现中固定为 1 个；多根能力复用同一结构，无需迁移数据。
    var folders: [WorkspaceFolder]
    /// 工作区级设置覆盖，深合并进用户全局设置。
    var settings: [String: JSONValue]
    var createdAt: Date

    init(
        name: String,
        folders: [WorkspaceFolder],
        settings: [String: JSONValue] = [:],
        createdAt: Date = Date(),
        id: UUID = UUID()
    ) {
        self.id = id
        self.name = name
        self.folders = folders
        self.settings = settings
        self.createdAt = createdAt
    }

    /// 至少需要一个有效根目录，否则无法作为工作区打开。
    var isValid: Bool {
        !folders.isEmpty
    }

    /// 用于窗口状态键、搜索索引路径等处的稳定标识。
    var stateKey: String {
        "workspaceState-\(id.uuidString)"
    }

    /// 默认名称：单根时取目录名，多根时取第一个目录名并标注数量。
    static func defaultName(for folders: [WorkspaceFolder]) -> String {
        guard let first = folders.first else { return "Untitled Workspace" }
        if folders.count == 1 {
            return first.displayName
        }
        return "\(first.displayName) +\(folders.count - 1)"
    }
}
