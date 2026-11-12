import Foundation

extension Theme {
    /// 运行时兜底不依赖 Bundle/用户磁盘，也不写回设置；主题目录为空仍能打开代码文件。
    static func resolved(selected: Theme?, available: [Theme], appearance: ThemeType) -> Theme {
        if let selected { return selected }
        return available.first { $0.appearance == appearance } ?? available.first ?? fallback(appearance: appearance)
    }

    static func fallback(appearance: ThemeType) -> Theme {
        let dark = appearance == .dark
        let text = Attributes(color: dark ? "#E6E6E6" : "#202020")
        let background = Attributes(color: dark ? "#202124" : "#FFFFFF")
        let selection = Attributes(color: dark ? "#394B68" : "#CCE0FF")
        let cursor = Attributes(color: dark ? "#8AB4F8" : "#005CC5")
        let editor = EditorColors(text: text, insertionPoint: cursor,
            invisibles: .init(color: dark ? "#70757A" : "#8C8C8C"), background: background,
            lineHighlight: .init(color: dark ? "#282A2D" : "#F5F7FA"), selection: selection,
            keywords: .init(color: dark ? "#C58AF9" : "#A626A4"), commands: cursor,
            types: .init(color: dark ? "#81C995" : "#166534"), attributes: cursor, variables: text,
            values: .init(color: dark ? "#F28B82" : "#B91C1C"),
            numbers: .init(color: dark ? "#FDD663" : "#8A5200"),
            strings: .init(color: dark ? "#81C995" : "#166534"),
            characters: .init(color: dark ? "#81C995" : "#166534"),
            comments: .init(color: dark ? "#9AA0A6" : "#666666"))
        let terminal = TerminalColors(text: text, boldText: text, cursor: cursor,
            background: background, selection: selection, black: .init(color: "#202020"),
            red: .init(color: "#CC5555"), green: .init(color: "#2D8A4E"), yellow: .init(color: "#AD7A00"),
            blue: .init(color: "#4585CC"), magenta: .init(color: "#A566CC"), cyan: .init(color: "#248A93"),
            white: .init(color: "#D6D6D6"), brightBlack: .init(color: "#777777"),
            brightRed: .init(color: "#F28B82"), brightGreen: .init(color: "#81C995"),
            brightYellow: .init(color: "#FDD663"), brightBlue: .init(color: "#8AB4F8"),
            brightMagenta: .init(color: "#C58AF9"), brightCyan: .init(color: "#78D9EC"),
            brightWhite: .init(color: "#FFFFFF"))
        return .init(editor: editor, terminal: terminal, author: "Qiyide", license: "MIT",
                     metadataDescription: "主题加载异常时的只读运行时兜底", distributionURL: "",
                     isBundled: true, name: "qiyide.runtime-fallback.\(appearance.rawValue)",
                     displayName: dark ? "Safe Fallback (Dark)" : "Safe Fallback (Light)",
                     appearance: appearance, version: "1")
    }
}
