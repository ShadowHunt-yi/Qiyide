import Foundation

// 多工作区数据层的可执行验收。
// 覆盖：JSON 深合并语义、工作区 CRUD、持久化往返、最近列表排序。

func fail(_ message: String) {
    FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
    exit(1)
}

func expect(_ condition: Bool, _ message: String) {
    if !condition { fail(message) }
}

// MARK: - 1. JSON 合并

let userSettings = try JSONValue.decode(from: Data("""
{
  "textEditing": { "showMinimap": true, "tabWidth": 4, "wrapLines": false },
  "theme": { "name": "Dark" },
  "terminal": { "shell": "zsh" }
}
""".utf8))

let workspaceOverride = try JSONValue.decode(from: Data("""
{
  "textEditing": { "showMinimap": false },
  "theme": null
}
""".utf8))

let folderOverride = try JSONValue.decode(from: Data("""
{ "textEditing": { "tabWidth": 2 }, "search": { "exclude": ["build"] } }
""".utf8))

let merged = JSONValue.merge([userSettings, workspaceOverride, folderOverride])

expect(merged["textEditing"]?["showMinimap"] == .bool(false), "工作区覆盖应生效")
expect(merged["textEditing"]?["tabWidth"] == .int(2), "文件夹覆盖应优先于用户设置")
expect(merged["textEditing"]?["wrapLines"] == .bool(false), "未覆盖的字段应保留")
expect(merged["theme"] == nil, "null 应清除该键")
expect(merged["terminal"]?["shell"] == .string("zsh"), "无关分组应保留")
expect(merged["search"]?["exclude"] == .array([.string("build")]), "新增分组应写入")

// 数组整体替换
let arrBase = try JSONValue.decode(from: Data(#"{"a":[1,2,3],"b":[9]}"#.utf8))
let arrOver = try JSONValue.decode(from: Data(#"{"a":[4]}"#.utf8))
let arrMerged = JSONValue.merge(base: arrBase, override: arrOver)
expect(arrMerged["a"] == .array([.int(4)]), "数组应整体替换而非逐项合并")
expect(arrMerged["b"] == .array([.int(9)]), "未覆盖数组应保留")

// 编码往返
let roundTrip = try JSONValue.decode(from: try merged.encoded())
expect(roundTrip == merged, "JSON 编码解码应无损")

// MARK: - 2. 工作区 CRUD 与持久化

let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
    .appending(path: "ce-workspace-test-\(UUID().uuidString)", directoryHint: .isDirectory)
try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tempRoot) }

let folderA = tempRoot.appending(path: "ProjectA", directoryHint: .isDirectory)
let folderB = tempRoot.appending(path: "ProjectB", directoryHint: .isDirectory)
try FileManager.default.createDirectory(at: folderA, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: folderB, withIntermediateDirectories: true)

let storeDir = tempRoot.appending(path: "store", directoryHint: .isDirectory)
let store = WorkspaceStore(directoryURL: storeDir)

let ws1 = try store.create(name: "", folders: [folderA])
expect(ws1.name == "ProjectA", "空名称应自动取目录名，实际: \(ws1.name)")
expect(store.allWorkspaces.count == 1, "创建后应有 1 个工作区")

let ws2 = try store.create(name: "双根工作区", folders: [folderA, folderB], settings: ["textEditing": .object(["tabWidth": .int(2)])])
expect(ws2.name == "双根工作区", "显式名称应保留")
expect(ws2.folders.count == 2, "应保存两个根目录")

// 最近列表：后创建的在前
expect(store.recentWorkspaces().map(\.id) == [ws2.id, ws1.id], "最近列表顺序错误")

// 重新打开已有目录应能匹配到工作区（同一文件夹集合）
expect(store.workspace(matchingFolders: [folderA])?.id == ws1.id, "目录匹配失败")

// 持久化往返
let reloaded = WorkspaceStore(directoryURL: storeDir)
expect(reloaded.allWorkspaces.count == 2, "重新加载后应有 2 个工作区")
expect(reloaded.workspace(id: ws2.id)?.folders.count == 2, "多根目录未持久化")
expect(reloaded.workspace(id: ws2.id)?.settings["textEditing"]?["tabWidth"] == .int(2), "设置覆盖未持久化")
expect(reloaded.recentWorkspaces().first?.id == ws2.id, "最近列表未持久化")
expect(reloaded.workspace(id: ws1.id)?.createdAt.timeIntervalSince1970 ?? 0 > 0, "创建时间未持久化")

// 更新与删除
var edited = reloaded
var target = try edited.workspace(id: ws1.id)!
target.name = "项目 A"
try edited.update(target)
expect(WorkspaceStore(directoryURL: storeDir).workspace(id: ws1.id)?.name == "项目 A", "更新未持久化")

try edited.delete(id: ws1.id)
expect(edited.allWorkspaces.count == 1, "删除后应剩 1 个工作区")
expect(edited.workspace(id: ws1.id) == nil, "删除应移除条目")

// 错误路径
do {
    _ = try edited.create(name: "空工作区", folders: [])
    fail("空目录应报错")
} catch { }
do {
    _ = try edited.create(name: "不存在", folders: [tempRoot.appending(path: "NotExist")])
    fail("不存在的目录应报错")
} catch { }
do {
    try edited.delete(id: UUID())
    fail("删除不存在的条目应报错")
} catch { }

// 状态键稳定性
expect(ws1.stateKey == "workspaceState-\(ws1.id.uuidString)", "状态键格式错误")

print("ALL CHECKS PASSED")
