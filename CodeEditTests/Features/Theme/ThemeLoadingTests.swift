import Foundation
import Testing
@testable import CodeEdit

private final class ThemeFixture {
    let root = FileManager.default.temporaryDirectory.appending(path: "qiyide-theme-\(UUID().uuidString)")
    var user: URL { root.appending(path: "UserThemes") }
    var bundled: URL { root.appending(path: "DefaultThemes") }
    init() throws { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
    deinit { try? FileManager.default.removeItem(at: root) }
    func save(_ theme: Theme, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(theme).write(to: url)
    }
}

@Suite struct ThemeLoadingTests {
    @Test func noSelectedThemeAndNoLoadedThemesStillResolveInBothAppearances() {
        for appearance in [Theme.ThemeType.light, .dark] {
            let theme = Theme.resolved(selected: nil, available: [], appearance: appearance)
            #expect(theme.appearance == appearance)
            #expect(theme.fileURL == nil)
            #expect(!theme.editor.text.color.isEmpty)
            #expect(theme.editor.text.color != theme.editor.background.color)
            #expect(theme.name.hasPrefix("qiyide.runtime-fallback"))
        }
    }

    @Test func missingBundledDirectoryDoesNotDiscardUserThemes() throws {
        let f = try ThemeFixture()
        var user = Theme.fallback(appearance: .light); user.name = "user.custom"
        try f.save(user, to: f.user.appending(path: "User.cetheme"))
        let loaded = ThemeResourceLoader.load(userDirectory: f.user, bundledDirectory: f.bundled)
        #expect(loaded.themes.map(\.name) == ["user.custom"])
        #expect(loaded.themes[0].isBundled == false)
        #expect(!loaded.issues.isEmpty)
    }

    @Test func missingUserDirectoryDoesNotDiscardBundledThemesOrWriteUserFiles() throws {
        let f = try ThemeFixture()
        try f.save(.fallback(appearance: .dark), to: f.bundled.appending(path: "Dark.cetheme"))
        let loaded = ThemeResourceLoader.load(userDirectory: f.user, bundledDirectory: f.bundled)
        #expect(loaded.themes.count == 1)
        #expect(loaded.themes[0].isBundled)
        #expect(!FileManager.default.fileExists(atPath: f.user.path))
    }

    @Test func corruptThemeDoesNotDropOtherThemes() throws {
        let f = try ThemeFixture()
        try f.save(.fallback(appearance: .light), to: f.bundled.appending(path: "Valid.cetheme"))
        try Data("invalid JSON".utf8).write(to: f.bundled.appending(path: "Broken.cetheme"))
        let loaded = ThemeResourceLoader.load(userDirectory: f.user, bundledDirectory: f.bundled)
        #expect(loaded.themes.count == 1)
        #expect(loaded.issues.contains { $0.contains("Broken.cetheme") })
    }

    @Test func bothDirectoriesMissingHaveAnExplicitWarningAndSafeInMemoryResolution() throws {
        let f = try ThemeFixture()
        let loaded = ThemeResourceLoader.load(userDirectory: f.user, bundledDirectory: f.bundled)
        #expect(loaded.themes.isEmpty)
        #expect(loaded.issues.contains { $0.contains("DefaultThemes") })
        #expect(Theme.resolved(selected: nil, available: loaded.themes, appearance: .dark).appearance == .dark)
        #expect(!FileManager.default.fileExists(atPath: f.user.path))
    }

    @Test func selectedThemeIsHonoredAndMatchingAppearanceWinsWithoutASelection() {
        let light = Theme.fallback(appearance: .light), dark = Theme.fallback(appearance: .dark)
        #expect(Theme.resolved(selected: light, available: [dark], appearance: .dark).id == light.id)
        #expect(Theme.resolved(selected: nil, available: [light, dark], appearance: .dark).id == dark.id)
    }

    @Test func userOverrideIsNotReplacedByTheSameBundledThemeID() throws {
        let f = try ThemeFixture()
        var user = Theme.fallback(appearance: .light), bundled = user
        user.displayName = "User version"; bundled.displayName = "Bundled version"
        try f.save(user, to: f.user.appending(path: "A.cetheme"))
        try f.save(bundled, to: f.bundled.appending(path: "B.cetheme"))
        let loaded = ThemeResourceLoader.load(userDirectory: f.user, bundledDirectory: f.bundled)
        #expect(loaded.themes.count == 1)
        #expect(loaded.themes[0].displayName == "User version")
        #expect(!loaded.themes[0].isBundled)
    }
}

extension ThemeLoadingTests {
    @Test @MainActor func runtimeFallbackCreatesAValidEditorThemeWithoutResourceFiles() {
        for appearance in [Theme.ThemeType.light, .dark] {
            let theme = Theme.resolved(selected: nil, available: [], appearance: appearance)
            let editor = theme.editor.editorTheme
            #expect(editor.text.color != editor.background)
            #expect(editor.insertionPoint != editor.background)
            #expect(theme.editor.functions.color == theme.editor.variables.color)
            #expect(theme.editor.comments.color != theme.editor.background.color)
        }
    }

    @Test func allCorruptThemesFallBackWithoutRewritingCorruptFiles() throws {
        let f = try ThemeFixture()
        try FileManager.default.createDirectory(at: f.bundled, withIntermediateDirectories: true)
        let file = f.bundled.appending(path: "Corrupt.cetheme")
        let bytes = Data("corrupt theme".utf8); try bytes.write(to: file)
        let loaded = ThemeResourceLoader.load(userDirectory: f.user, bundledDirectory: f.bundled)
        #expect(loaded.themes.isEmpty)
        #expect(loaded.issues.count >= 1)
        #expect(Theme.resolved(selected: nil, available: loaded.themes, appearance: .light).appearance == .light)
        #expect(try Data(contentsOf: file) == bytes)
    }
}

extension ThemeLoadingTests {
    @Test func repositoryDefaultThemesDecodeAndContainBothAppearances() throws {
        // Test sources may live in the generated app-spm tree; locate only a parent repository's fixture folder.
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        var source: URL?
        for _ in 0..<10 {
            let candidate = directory.appending(path: "DefaultThemes")
            if FileManager.default.fileExists(atPath: candidate.path) { source = candidate; break }
            directory.deleteLastPathComponent()
        }
        let bundled = try #require(source)
        let f = try ThemeFixture()
        let expected = try FileManager.default.contentsOfDirectory(at: bundled, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "cetheme" }
        let loaded = ThemeResourceLoader.load(userDirectory: f.user, bundledDirectory: bundled)
        #expect(loaded.themes.count == expected.count)
        #expect(loaded.themes.count >= 2)
        #expect(loaded.issues.isEmpty)
        #expect(Set(loaded.themes.map(\.appearance)) == [.light, .dark])
        #expect(loaded.themes.contains { $0.name == "classic.light" })
        #expect(loaded.themes.contains { $0.name == "high.contrast.dark" })
    }
}
