import Foundation

struct ThemeLoadResult {
    var themes: [Theme] = []
    var issues: [String] = []
}

/// 独立读取两类目录：内置资源缺失不应连带阻止加载用户主题；损坏项不使整个主题库归零。
enum ThemeResourceLoader {
    static func load(userDirectory: URL, bundledDirectory: URL?) -> ThemeLoadResult {
        var result = ThemeLoadResult()
        var seen = Set<String>()
        let locations: [(URL?, Bool)] = [(userDirectory, false), (bundledDirectory, true)]
        for (directory, bundled) in locations {
            guard let directory else {
                if bundled { result.issues.append("内置主题目录不可用，使用内存安全主题") }
                continue
            }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                if bundled { result.issues.append("开发包缺少 DefaultThemes，使用用户主题或内存安全主题") }
                continue
            }
            do {
                let files = try FileManager.default.contentsOfDirectory(at: directory,
                    includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
                    .filter { $0.pathExtension.lowercased() == "cetheme" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
                for file in files {
                    do {
                        var theme = try JSONDecoder().decode(Theme.self, from: Data(contentsOf: file))
                        guard !theme.name.isEmpty else {
                            result.issues.append("主题缺少名称：\(file.lastPathComponent)")
                            continue
                        }
                        // 用户主题覆盖同 id 的内置主题；避免靠文件遍历顺序重复替换选择。
                        guard seen.insert(theme.name).inserted else { continue }
                        theme.fileURL = file
                        theme.isBundled = bundled
                        result.themes.append(theme)
                    } catch {
                        result.issues.append("主题无法读取：\(file.lastPathComponent)")
                    }
                }
            } catch {
                result.issues.append("主题目录无法读取：\(directory.lastPathComponent)")
            }
        }
        if result.themes.isEmpty { result.issues.append("没有可用主题；编辑器将使用内存安全主题，不重置用户选项") }
        return result
    }
}
