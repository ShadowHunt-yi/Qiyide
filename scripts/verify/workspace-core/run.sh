#!/bin/bash
# 独立验证多工作区数据层（不依赖 Xcode 工程，可在命令行直接跑）。
#
# 背景：本机环境无法执行 xcodebuild（嵌套沙箱受限），因此把「仅依赖 Foundation」的
# 工作区数据层抽出来，用临时 SwiftPM 工程编译并做行为断言。
#
# 用法：scripts/verify/workspace-core/run.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

mkdir -p "$WORK_DIR/Sources/Core"

cat > "$WORK_DIR/Package.swift" <<'PKG'
// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "CEVerify",
    platforms: [.macOS(.v13)],
    targets: [.executableTarget(name: "Core", path: "Sources/Core")]
)
PKG

cp "$REPO_ROOT/CodeEdit/Features/Workspace/Models/JSONValue.swift" "$WORK_DIR/Sources/Core/"
cp "$REPO_ROOT/CodeEdit/Features/Workspace/Models/Workspace.swift" "$WORK_DIR/Sources/Core/"
cp "$REPO_ROOT/CodeEdit/Features/Workspace/WorkspaceStore.swift" "$WORK_DIR/Sources/Core/"
cp "$REPO_ROOT/scripts/verify/workspace-core/main.swift" "$WORK_DIR/Sources/Core/"

cd "$WORK_DIR"
swift build --disable-sandbox
swift run --disable-sandbox
