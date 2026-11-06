//
//  StructureFacts.swift
//  CodeEdit
//
//  文件级的依赖事实：谁 import 了谁，在哪一行。
//
//  为什么要文件级：
//  结构地图在每一级都要回答「这里依赖了谁」——全仓看域与域，域里看模块与模块。
//  如果每一级各算一遍，全仓看到的「客服 → 搭子」和模块级看到的「biz → memory」
//  就可能对不上。所以依赖只在文件级存一份，带着证据（文件、行号、原文），
//  往上看时按文件所属的模块、域聚合。
//
//  为什么按全限定名解析：
//  知识库原有的依赖图按「包名末段」反查模块，同名包只保留先登记的那个，
//  `agent/memory/mapper` 和 `service/db/mapper` 会被当成同一个。
//  Java 的 import 写的是全限定名，直接对到文件就不会错位。
//

import Foundation

/// 一条文件级引用：`from` 文件 import 了 `to` 文件。
struct StructureReference: Hashable, Sendable {
    /// 仓库相对路径。
    var from: String
    var to: String
    /// import 语句所在行，从 1 起。
    var line: Int
    /// 语句原文，给人看证据用。
    var text: String
}

// MARK: - Java 源码

enum JavaSourceScanner {

    struct ImportLine: Hashable, Sendable {
        /// 全限定名。通配导入时是包名（不带 `.*`）。
        var name: String
        var line: Int
        var text: String
        var isWildcard: Bool
    }

    /// 读文件头部的 import 段。
    ///
    /// 遇到类型声明或注解就停：import 只会出现在它们之前，
    /// 再往下扫只会把方法体里碰巧以 `import` 开头的字符串算进来。
    static func imports(in text: String) -> [ImportLine] {
        var result: [ImportLine] = []
        var number = 0
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            number += 1
            if number > 600 { break }
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("import ") {
                var name = Substring(line.dropFirst("import ".count))
                if name.hasPrefix("static ") { name = name.dropFirst("static ".count) }
                if let end = name.firstIndex(of: ";") { name = name[..<end] }
                var symbol = name.trimmingCharacters(in: .whitespaces)
                let wildcard = symbol.hasSuffix(".*")
                if wildcard { symbol = String(symbol.dropLast(2)) }
                guard !symbol.isEmpty else { continue }
                result.append(ImportLine(name: symbol, line: number, text: line, isWildcard: wildcard))
            } else if startsDeclaration(line) {
                break
            }
        }
        return result
    }

    private static let declarationStarts = [
        "@", "public ", "class ", "interface ", "enum ", "abstract ", "final ", "record ", "sealed "
    ]

    private static func startsDeclaration(_ line: String) -> Bool {
        declarationStarts.contains { line.hasPrefix($0) }
    }

    /// 读文件头部。import 都是 ASCII，编码不对也不影响，所以解码失败时容错替换。
    static func readHead(of url: URL, limit: Int = 24_000) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: limit), !data.isEmpty else { return nil }
        return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }
}

/// 全限定名 → 文件。
struct JavaTypeResolver: Sendable {

    private var files: [String: String] = [:]
    /// 包名 → 该包里的一个文件。通配导入用它落到模块上。
    private var packages: [String: String] = [:]
    /// 仓库内所有类共有的包前缀。指向它却解析不到文件的 import 才算「没解析出来」。
    private(set) var commonPrefix: String = ""

    private static let marker = "/src/main/java/"

    init(paths: [String]) {
        var prefix: [Substring]?
        // 排序后再登记：同一个全限定名出现在两个源码根时，取路径靠前的那个，结果才稳定。
        for path in paths.sorted() {
            guard let name = Self.typeName(forPath: path) else { continue }
            if files[name] == nil { files[name] = path }
            let segments = name.split(separator: ".").dropLast()
            let package = segments.joined(separator: ".")
            if packages[package] == nil { packages[package] = path }

            if let current = prefix {
                var shared = 0
                while shared < current.count, shared < segments.count,
                      current[shared] == segments[segments.startIndex + shared] {
                    shared += 1
                }
                prefix = Array(current.prefix(shared))
            } else {
                prefix = Array(segments)
            }
        }
        commonPrefix = (prefix ?? []).joined(separator: ".")
    }

    /// `…/src/main/java/com/x/agent/Memory.java` → `com.x.agent.Memory`。
    static func typeName(forPath path: String) -> String? {
        guard path.hasSuffix(".java"), let range = path.range(of: marker) else { return nil }
        return path[range.upperBound...].dropLast(".java".count).replacingOccurrences(of: "/", with: ".")
    }

    /// 精确匹配不中时逐段去尾再试：`a.b.Outer.Inner`、静态导入的 `a.b.Util.method` 都指向外层类的文件。
    func resolve(_ name: String) -> String? {
        var candidate = Substring(name)
        for _ in 0..<3 {
            if let path = files[String(candidate)] { return path }
            guard let dot = candidate.lastIndex(of: ".") else { return nil }
            candidate = candidate[..<dot]
        }
        return nil
    }

    func resolve(_ line: JavaSourceScanner.ImportLine) -> String? {
        // 通配导入可能是包（`import a.b.*`），也可能是类的静态成员（`import static a.b.C.*`）。
        line.isWildcard ? (packages[line.name] ?? resolve(line.name)) : resolve(line.name)
    }

    /// 这个名字是不是指向仓库自己的代码。
    func isInternal(_ name: String) -> Bool {
        !commonPrefix.isEmpty && name.hasPrefix(commonPrefix + ".")
    }
}

// MARK: - 事实集

struct StructureFacts: Sendable {

    private(set) var references: [StructureReference] = []
    /// 指向仓库自己的包、却对不到文件的 import。数量是解析精度的直接指标；
    /// 分支 diff 里也靠它发现「文件删了但还有人在引用」。
    private(set) var dangling: [Dangling] = []
    private(set) var scannedFiles = 0

    struct Dangling: Hashable, Sendable {
        var from: String
        var name: String
        var line: Int
    }

    private var outgoingIndex: [String: [Int]] = [:]
    private var incomingIndex: [String: [Int]] = [:]

    static let empty = StructureFacts()

    init(references: [StructureReference] = [], dangling: [Dangling] = [], scannedFiles: Int = 0) {
        // 并发扫描的到达顺序不定，排一次保证同样的代码得到同样的结果。
        self.references = references.sorted {
            $0.from != $1.from ? $0.from < $1.from : $0.line < $1.line
        }
        self.dangling = dangling.sorted { $0.from != $1.from ? $0.from < $1.from : $0.line < $1.line }
        self.scannedFiles = scannedFiles
        for (offset, reference) in self.references.enumerated() {
            outgoingIndex[reference.from, default: []].append(offset)
            incomingIndex[reference.to, default: []].append(offset)
        }
    }

    func outgoing(from path: String) -> [StructureReference] {
        (outgoingIndex[path] ?? []).map { references[$0] }
    }

    func incoming(to path: String) -> [StructureReference] {
        (incomingIndex[path] ?? []).map { references[$0] }
    }

    /// 一段源码里的引用。纯函数：分支 diff 拿基准版本的文本也走这里。
    static func references(
        in text: String,
        from path: String,
        resolver: JavaTypeResolver
    ) -> (resolved: [StructureReference], dangling: [Dangling]) {
        var resolved: [StructureReference] = []
        var dangling: [Dangling] = []
        var seen = Set<String>()
        for line in JavaSourceScanner.imports(in: text) {
            if let target = resolver.resolve(line) {
                // 同一个文件对同一个目标只记一次（普通导入 + 静态导入）。
                guard target != path, seen.insert(target).inserted else { continue }
                resolved.append(StructureReference(from: path, to: target, line: line.line, text: line.text))
            } else if resolver.isInternal(line.name) {
                dangling.append(Dangling(from: path, name: line.name, line: line.line))
            }
        }
        return (resolved, dangling)
    }

    /// 扫描磁盘上的全部文件。按文件并发：每个文件只读头部，纯 IO + 少量字符串处理。
    static func scan(root: URL, paths: [String]) -> StructureFacts {
        let resolver = JavaTypeResolver(paths: paths)
        let collector = Collector()
        DispatchQueue.concurrentPerform(iterations: paths.count) { offset in
            let path = paths[offset]
            guard let text = JavaSourceScanner.readHead(of: root.appending(path: path)) else { return }
            let found = references(in: text, from: path, resolver: resolver)
            collector.add(found.resolved, found.dangling)
        }
        let result = collector.snapshot()
        return StructureFacts(references: result.0, dangling: result.1, scannedFiles: paths.count)
    }

    /// 并发汇总器：把锁和累加器封在一起，不在并发闭包里改捕获的局部变量。
    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var references: [StructureReference] = []
        private var dangling: [Dangling] = []

        func add(_ found: [StructureReference], _ missing: [Dangling]) {
            lock.lock()
            references.append(contentsOf: found)
            dangling.append(contentsOf: missing)
            lock.unlock()
        }

        func snapshot() -> ([StructureReference], [Dangling]) {
            lock.lock()
            defer { lock.unlock() }
            return (references, dangling)
        }
    }
}
