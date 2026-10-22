//
//  ProjectCEWorkspaceSettings.swift
//  CodeEdit
//
//  Created by Axel Martinez on 27/3/24.
//

import SwiftUI

class ProjectSettings: ObservableObject, Codable {
    var projectName: String = ""

    /// 多根工作区：主根之外的附加根目录（绝对路径）。
    ///
    /// 主根始终是打开工作区时的那个文件夹，不记录在此数组中；该数组只保存用户后续
    /// 通过「将文件夹添加到工作区」加入的目录，按加入顺序持久化到 `.qiyide/settings.json`。
    var additionalRoots: [String] = []

    init() {}

    /// Explicit decoder init for setting default values when key is not present in `JSON`
    required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.projectName = try container.decodeIfPresent(String.self, forKey: .projectName) ?? ""
        self.additionalRoots = try container.decodeIfPresent([String].self, forKey: .additionalRoots) ?? []
    }

    func isEmpty() -> Bool {
        projectName == "" && additionalRoots.isEmpty
    }
}
