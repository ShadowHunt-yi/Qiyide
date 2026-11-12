//
//  ThemeModel+CRUD.swift
//  CodeEdit
//
//  Created by Austin Condiff on 6/18/24.
//

import SwiftUI
import UniformTypeIdentifiers

extension ThemeModel {
    /// 加载使用临时数组，不先清空已可用的主题。目录/单文件失败只报告，编辑器有内存兜底。
    /// 用户颜色覆盖仍只应用到内存；不创建或改写用户主题文件。
    func loadThemes() throws {
        var directoryIssues: [String] = []
        // 保留创建用户主题目录的旧行为，失败也不能使编辑器崩溃或阻断内置主题。
        if !filemanager.fileExists(atPath: themesURL.path) {
            do { try filemanager.createDirectory(at: themesURL, withIntermediateDirectories: true) }
            catch { directoryIssues.append("用户主题目录无法创建，使用内置或内存安全主题") }
        }
        let result = ThemeResourceLoader.load(userDirectory: themesURL, bundledDirectory: bundledThemesURL)
        let prefs = Settings.shared.preferences.theme
        var loaded: [Theme] = []
        var issues = directoryIssues + result.issues
        for var theme in result.themes {
            do {
                let terminalKeys = try theme.terminal.allProperties() as? [String: Theme.Attributes] ?? [:]
                let editorKeys = try theme.editor.allProperties() as? [String: Theme.Attributes] ?? [:]
                if let overrides = prefs.overrides[theme.name]?["terminal"] {
                    for key in terminalKeys.keys {
                        if let attributes = overrides[key] { theme.terminal[key] = attributes }
                    }
                }
                if let overrides = prefs.overrides[theme.name]?["editor"] {
                    for key in editorKeys.keys {
                        if let attributes = overrides[key] { theme.editor[key] = attributes }
                    }
                }
                loaded.append(theme)
            } catch { issues.append("主题颜色无法读取：" + theme.displayName) }
        }
        reportThemeLoad(issues.isEmpty ? nil : issues.joined(separator: "；"))
        // 所有资源不可用时保留上次可用状态，不把 nil / Broken 写回用户选择。
        guard !loaded.isEmpty else { return }
        themes = loaded
        selectedDarkTheme = darkThemes.first { $0.name == prefs.selectedDarkTheme } ?? darkThemes.first
        selectedLightTheme = lightThemes.first { $0.name == prefs.selectedLightTheme } ?? lightThemes.first
        let dark = NSAppearance.currentDrawing().bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        selectedTheme = themes.first { $0.name == prefs.selectedTheme }
            ?? (dark ? selectedDarkTheme : selectedLightTheme)
            ?? themes.first
    }

    func importTheme() {
        let openPanel = NSOpenPanel()
        let allowedTypes = [UTType(filenameExtension: "cetheme")!]

        openPanel.prompt = "Import"
        openPanel.allowedContentTypes = allowedTypes
        openPanel.canChooseFiles = true
        openPanel.canChooseDirectories = false
        openPanel.allowsMultipleSelection = false

        openPanel.begin { result in
            if result.rawValue == NSApplication.ModalResponse.OK.rawValue {
                if let url = openPanel.urls.first {
                    self.duplicate(url)
                }
            }
        }
    }

    func duplicate(_ url: URL) {
        do {
            self.isAdding = true
            // Construct the destination file URL
            var destinationFileURL = self.themesURL.appending(path: url.lastPathComponent)

            // Extract the base filename and extension
            let fileExtension = destinationFileURL.pathExtension

            var fileName = destinationFileURL.deletingPathExtension().lastPathComponent
            var newFileName = fileName

            var iterator = 1

            let isBundled = url.absoluteString.hasPrefix(bundledThemesURL?.absoluteString ?? "")
            let isImporting =
                !url.absoluteString.hasPrefix(bundledThemesURL?.absoluteString ?? "")
                && !url.absoluteString.hasPrefix(themesURL.absoluteString)

            if isBundled {
                newFileName = "\(fileName) \(iterator)"
                destinationFileURL = self.themesURL
                    .appending(path: newFileName)
                    .appendingPathExtension(fileExtension)
            }

            // Check if the file already exists
            while FileManager.default.fileExists(atPath: destinationFileURL.path) {
                fileName = destinationFileURL.deletingPathExtension().lastPathComponent

                // Remove any existing iterator
                if let range = fileName.range(of: " \\d+$", options: .regularExpression) {
                    fileName = String(fileName[..<range.lowerBound])
                }

                // Generate a new filename with an iterator
                newFileName = "\(fileName) \(iterator)"
                destinationFileURL = self.themesURL
                    .appending(path: newFileName)
                    .appendingPathExtension(fileExtension)

                iterator += 1
            }

            // Copy the file from selected URL to the destination
            try FileManager.default.copyItem(at: url, to: destinationFileURL)

            try self.loadThemes()

            if let index = self.themes.firstIndex(where: { $0.fileURL == destinationFileURL }) {
                self.themes[index].displayName = newFileName
                self.themes[index].name = newFileName.lowercased().replacingOccurrences(of: " ", with: "-")

                if isImporting != true {
                    self.themes[index].author = NSFullUserName()
                    self.save(self.themes[index])
                }

                self.previousTheme = self.selectedTheme

                activateTheme(self.themes[index])

                self.detailsTheme = self.themes[index]
                self.detailsIsPresented = true
            }
        } catch {
            print("Error adding theme: \(error.localizedDescription)")
        }
    }

    func rename(to newName: String, theme: Theme) {
        do {
            guard let oldURL = theme.fileURL else {
                throw NSError(
                    domain: "ThemeModel",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Theme file URL not found"]
                )
            }

            var finalName = newName
            var finalURL = themesURL.appending(path: finalName).appendingPathExtension("cetheme")
            var iterator = 1

            // Check for existing display names in themes
            while themes.contains(where: { theme != $0 && $0.displayName == finalName }) {
                finalName = "\(newName) \(iterator)"
                finalURL = themesURL.appending(path: finalName).appendingPathExtension("cetheme")
                iterator += 1
            }

            _ = self.getThemeActive(theme)

            try filemanager.moveItem(at: oldURL, to: finalURL)

            try self.loadThemes()
        } catch {
            print("Error renaming theme: \(error.localizedDescription)")
        }
    }

    /// Save theme to file
    func save(_ theme: Theme) {
        do {
            if let fileURL = theme.fileURL {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                let data = try encoder.encode(theme)
                let json = try JSONSerialization.jsonObject(with: data)
                let prettyJSON = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted])
                try prettyJSON.write(to: fileURL, options: .atomic)
            }
        } catch {
            print("Error saving theme: \(error.localizedDescription)")
        }
    }

    /// Removes the given theme from `–/Library/Application Support/Qiyide/themes`
    ///
    /// After removing the theme, themes are reloaded
    /// from `~/Library/Application Support/Qiyide/Themes`. See ``loadThemes()``
    /// for more information.
    ///
    /// - Parameter theme: The theme to delete
    func delete(_ theme: Theme) {
        if let url = theme.fileURL {
            do {
                try filemanager.removeItem(at: url)

                Settings.shared.preferences.theme.overrides.removeValue(forKey: theme.name)

                try self.loadThemes()
            } catch {
                print(error)
            }
        }
    }
}
