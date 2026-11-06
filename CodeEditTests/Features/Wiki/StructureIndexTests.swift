//
//  StructureIndexTests.swift
//  CodeEditTests
//
//  结构地图的数据层：模块怎么从叶子包汇总、文件怎么落到模块上。
//
//  这些规则都是纯函数，所以用一小份手写的包清单就能把边界情况逐个钉住，
//  不需要真实仓库。真实仓库上的整体对账由 `StructureVerification` 负责。
//

import Foundation
import Testing
@testable import CodeEdit

@Suite
struct StructureIndexTests {

    // MARK: 夹具

    private func leaf(_ path: String, classes: Int) -> DomainAnalyzer.Leaf {
        let names = (0..<classes).map { "C\($0)" }
        return DomainAnalyzer.Leaf(
            parts: path.split(separator: "/").map(String.init),
            classes: names,
            files: names.map { "\(path)/\($0).java" }
        )
    }

    private func package(_ path: String, files: [String], root: String = "app/src/main/java/com/x") -> ScannedPackage {
        ScannedPackage(
            parts: path.split(separator: "/").map(String.init),
            sourceRoot: root,
            files: files.map { "\(root)/\(path)/\($0).java" }
        )
    }

    /// 一个达标域 `agent/cs`（带两个模块和域根）加一个兜底域 `agent`。
    private func sampleGraph() -> MindGraph {
        var root = MindNode(id: "system", title: "repo", kind: .system)
        var customer = MindNode(id: "domain:agent/cs", title: "客服", kind: .domain)
        customer.parentID = "system"
        customer.packages = ["agent/cs"]
        var rest = MindNode(id: "domain:leftover:agent", title: "搭子", kind: .domain)
        rest.parentID = "system"
        rest.packages = ["agent"]
        root.childIDs = [customer.id, rest.id]

        var nodes = [root, customer, rest]
        for (id, parent, key) in [
            ("module:agent/cs/biz", customer.id, "agent/cs/biz"),
            ("module:agent/cs/_root", customer.id, "agent/cs"),
            ("module:agent/memory", rest.id, "agent/memory")
        ] {
            var node = MindNode(id: id, title: String(key.split(separator: "/").last ?? ""), kind: .module)
            node.parentID = parent
            node.packages = [key]
            nodes.append(node)
        }
        return MindGraph(nodes: nodes, rootID: "system")
    }

    // MARK: 模块节点

    @Test
    func moduleSumsAllSubpackages() {
        // 旧实现只取第一个叶子：biz 下面有两个子包时类数会少算。
        let nodes = DomainAnalyzer.moduleNodes(
            domainID: "domain:agent/cs",
            domainParts: ["agent", "cs"],
            leaves: [leaf("agent/cs/biz", classes: 3), leaf("agent/cs/biz/handler", classes: 4)]
        )
        #expect(nodes.count == 1)
        #expect(nodes.first?.id == "module:agent/cs/biz")
        #expect(nodes.first?.classCount == 7)
        #expect(nodes.first?.parentID == "domain:agent/cs")
    }

    @Test
    func rootClassesBecomeRootModule() {
        let nodes = DomainAnalyzer.moduleNodes(
            domainID: "domain:agent/cs",
            domainParts: ["agent", "cs"],
            leaves: [leaf("agent/cs", classes: 5), leaf("agent/cs/biz", classes: 2)]
        )
        let root = nodes.first { DomainAnalyzer.isRootModule($0.id) }
        #expect(root?.classCount == 5)
        #expect(root?.packages == ["agent/cs"])
        #expect(nodes.reduce(0) { $0 + $1.classCount } == 7)
    }

    @Test
    func catchAllDomainUsesSecondLevelPackages() {
        // 兜底域只有一段路径，模块取第二段。
        let nodes = DomainAnalyzer.moduleNodes(
            domainID: "domain:leftover:agent",
            domainParts: ["agent"],
            leaves: [
                leaf("agent/memory", classes: 2),
                leaf("agent/memory/db", classes: 3),
                leaf("agent/tool", classes: 1)
            ]
        )
        #expect(nodes.map(\.id) == ["module:agent/memory", "module:agent/tool"])
        #expect(nodes.map(\.classCount) == [5, 1])
    }

    @Test
    func modulesAreOrderedBySizeThenName() {
        let nodes = DomainAnalyzer.moduleNodes(
            domainID: "d",
            domainParts: ["a"],
            leaves: [leaf("a/zeta", classes: 2), leaf("a/alpha", classes: 2), leaf("a/big", classes: 9)]
        )
        #expect(nodes.map(\.title) == ["big", "alpha", "zeta"])
    }

    // MARK: 归属规则

    @Test
    func longestPathWins() {
        let assigner = StructureAssigner(graph: sampleGraph(), sourceRoots: [])
        // `agent/cs/...` 归客服，不归兜底的 `agent`。
        #expect(assigner.assign(parts: ["agent", "cs", "biz", "x"]).domainID == "domain:agent/cs")
        #expect(assigner.assign(parts: ["agent", "cs", "biz", "x"]).moduleID == "module:agent/cs/biz")
        #expect(assigner.assign(parts: ["agent", "memory"]).domainID == "domain:leftover:agent")
    }

    @Test
    func rootModuleOnlyClaimsExactPath() {
        let assigner = StructureAssigner(graph: sampleGraph(), sourceRoots: [])
        let direct = assigner.assign(parts: ["agent", "cs"])
        #expect(direct.isRoot)
        #expect(direct.moduleID == "module:agent/cs/_root")

        // 模型之后新加的子包：不能被域根吞掉，要成为一个新模块，并标成「模型外」。
        let fresh = assigner.assign(parts: ["agent", "cs", "handoff"])
        #expect(fresh.moduleID == "module:agent/cs/handoff")
        #expect(!fresh.isModeled)
        #expect(!fresh.isRoot)
    }

    @Test
    func unknownPackagesAreUnassigned() {
        let assigner = StructureAssigner(graph: sampleGraph(), sourceRoots: [])
        let result = assigner.assign(parts: ["enums", "deep"])
        #expect(result.domainID == StructureAssigner.unassignedDomainID)
        #expect(result.moduleID == "module:enums")
    }

    @Test
    func movedModuleFollowsItsNode() {
        // 人把 memory 从搭子拖到客服下：文件跟着节点走。
        var graph = sampleGraph()
        graph.move("module:agent/memory", toParent: "domain:agent/cs")
        let assigner = StructureAssigner(graph: graph, sourceRoots: [])
        #expect(assigner.assign(parts: ["agent", "memory", "db"]).domainID == "domain:agent/cs")
    }

    @Test
    func adoptingAPackageCreatesOrMovesItsModule() {
        var graph = sampleGraph()
        // 模型里还没有的包：新建节点挂到指定的域下。
        graph.adopt(package: "agent/handoff", title: "handoff", into: "domain:agent/cs")
        #expect(graph.node("module:agent/handoff")?.parentID == "domain:agent/cs")
        #expect(graph.node("module:agent/handoff")?.isManual == true)
        // 模型里已有的包：改挂过去，不重复建节点。
        graph.adopt(package: "agent/memory", title: "memory", into: "domain:agent/cs")
        #expect(graph.nodes.filter { $0.id == "module:agent/memory" }.count == 1)

        let assigner = StructureAssigner(graph: graph, sourceRoots: [])
        #expect(assigner.assign(parts: ["agent", "handoff"]).domainID == "domain:agent/cs")
        #expect(assigner.assign(parts: ["agent", "handoff"]).isModeled)
        #expect(assigner.assign(parts: ["agent", "memory", "db"]).domainID == "domain:agent/cs")
        // 不存在的域：什么都不做。
        graph.adopt(package: "agent/tool", title: "tool", into: "domain:nope")
        #expect(graph.node("module:agent/tool") == nil)
    }

    @Test
    func filePathMapsBackToBusinessPath() {
        let assigner = StructureAssigner(graph: sampleGraph(), sourceRoots: ["app/src/main/java/com/x"])
        #expect(assigner.parts(forFile: "app/src/main/java/com/x/agent/cs/biz/A.java") == ["agent", "cs", "biz"])
        #expect(assigner.parts(forFile: "docs/readme.md") == nil)
        // 已经删掉的文件也要能定位：分支 diff 里的旧路径磁盘上不存在。
        let gone = assigner.assign(file: "app/src/main/java/com/x/agent/cs/biz/Gone.java")
        #expect(gone?.moduleID == "module:agent/cs/biz")
    }

    // MARK: 索引

    @Test
    func indexSatisfiesInvariants() {
        let packages = [
            package("agent/cs", files: ["Root"]),
            package("agent/cs/biz", files: ["A", "B"]),
            package("agent/cs/biz/handler", files: ["H"]),
            package("agent/memory", files: ["M"]),
            package("agent/tool", files: ["T1", "T2"]),
            package("enums", files: ["E"])
        ]
        let index = StructureIndex.build(packages: packages, graph: sampleGraph())

        #expect(index.violations(packages: packages).isEmpty)
        #expect(index.classCount == 8)
        #expect(index.domain("domain:agent/cs")?.classCount == 4)
        #expect(index.module("module:agent/cs/biz")?.classCount == 3)
        // 兜底域里模型没记的 tool 也要出现。
        #expect(index.module("module:agent/tool")?.isModeled == false)
        #expect(index.domain(StructureAssigner.unassignedDomainID)?.modules.map(\.title) == ["enums"])
        // 业务域在前，「未划分」垫底。
        #expect(index.domains.last?.kind == .unassigned)
    }

    @Test
    func buildIsOrderIndependent() {
        let packages = [
            package("agent/cs/biz", files: ["A", "B"]),
            package("agent/memory", files: ["M"]),
            package("agent/tool", files: ["T"])
        ]
        let forward = StructureIndex.build(packages: packages, graph: sampleGraph())
        let backward = StructureIndex.build(packages: packages.reversed(), graph: sampleGraph())
        #expect(forward.domains == backward.domains)
    }

    @Test
    func contentsWalkDownThePackagePath() throws {
        let packages = [
            package("agent/cs/biz", files: ["A"]),
            package("agent/cs/biz/handler", files: ["H1", "H2"]),
            package("agent/cs/biz/handler/deep", files: ["D"])
        ]
        let index = StructureIndex.build(packages: packages, graph: sampleGraph())
        let module = try #require(index.module("module:agent/cs/biz"))

        let top = index.contents(of: module, at: [])
        #expect(top.files.map(\.name) == ["A"])
        #expect(top.packages.map(\.name) == ["handler"])
        #expect(top.packages.first?.classCount == 3)
        #expect(top.classCount == module.classCount)

        let handler = index.contents(of: module, at: ["handler"])
        #expect(handler.files.map(\.name) == ["H1", "H2"])
        #expect(handler.packages.map(\.subpath) == [["handler", "deep"]])
        #expect(index.contents(of: module, at: ["missing"]).classCount == 0)
    }

    @Test
    func sameBusinessPackageAcrossSourceRootsMerges() throws {
        // app 与 client 两个 Maven 模块里的同名包算同一个模块，文件各自保留并标出处。
        let packages = [
            package("agent/cs/biz", files: ["A"], root: "repo-app/src/main/java/com/x"),
            package("agent/cs/biz", files: ["B"], root: "repo-client/src/main/java/com/x")
        ]
        let index = StructureIndex.build(packages: packages, graph: sampleGraph())
        let module = try #require(index.module("module:agent/cs/biz"))
        #expect(module.classCount == 2)
        #expect(index.violations(packages: packages).isEmpty)

        let contents = index.contents(of: module, at: [])
        #expect(Set(contents.rootLabels.values) == ["app", "client"])
    }
}
