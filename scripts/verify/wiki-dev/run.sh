#!/bin/bash
# 不依赖 Xcode，单独编译并运行知识库功能（领域建模 / 结构地图 / 建档）。
#
# 背景：完整的 QiyideDev 需要 xcodebuild。只装了命令行工具的机器上打不出包，
# 但 CodeEdit/Features/Wiki 只依赖 Foundation / SwiftUI / AppKit，
# 加上几个替身类型（见 Stubs.swift）就能用 swiftc 直接编成可执行文件。
# 编译的是仓库里的同一份源码，所以「这里编得过」基本等于「工程里编得过」。
#
# 用法：
#   scripts/verify/wiki-dev/run.sh build                      # 只编译
#   scripts/verify/wiki-dev/run.sh domain <仓库>              # 领域识别 + 不变量，纯文本输出
#   scripts/verify/wiki-dev/run.sh wiki <仓库> [out.png]      # 离屏渲染整个知识库窗口
#   scripts/verify/wiki-dev/run.sh structure <仓库> [输出目录] # 结构地图：断言 + 各层级截图
#   scripts/verify/wiki-dev/run.sh open <仓库>                # 打开真实窗口，人工点验
#   scripts/verify/wiki-dev/run.sh test                       # 跑 CodeEditTests/Features/Wiki 下的单元测试
#
# 只读：除 open 模式下人工操作外，不会写被测仓库。

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
HERE="$REPO_ROOT/scripts/verify/wiki-dev"
OUT_DIR="$REPO_ROOT/build/wiki-dev"
BIN="$OUT_DIR/WikiDev"
MODE="${1:-}"
TARGET="${2:-}"
EXTRA="${3:-}"

build() {
    mkdir -p "$OUT_DIR"
    local sources=()
    while IFS= read -r file; do sources+=("$file"); done < <(
        find "$REPO_ROOT/CodeEdit/Features/Wiki" "$REPO_ROOT/CodeEdit/Utils/KeyChain" -name '*.swift' | sort
        # 改动审查里只有「模型调用」这一层被知识库用到；窗口与 git 扩展依赖 App，不编。
        find "$REPO_ROOT/CodeEdit/Features/AIReview" -name '*.swift' \
            | grep -v -E 'AIReviewService|AIReviewWindow|GitClient\+' | sort
    )
    sources+=("$HERE/Stubs.swift" "$HERE/main.swift")

    # 源码没变就不重编：整包编译要几十秒，反复跑验证时没必要等。
    local stamp="$OUT_DIR/.sources.sha"
    local digest
    digest="$(cat "${sources[@]}" | shasum | cut -d' ' -f1)"
    if [ -x "$BIN" ] && [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$digest" ]; then
        return 0
    fi

    echo "==> 编译 ${#sources[@]} 个文件" >&2
    # 与工程设置对齐：Swift 5 语言模式、最低 macOS 14、DEBUG 条件编译。
    if ! swiftc -swift-version 5 -target arm64-apple-macosx14.0 -D DEBUG -Onone -g \
        -module-name WikiDev -o "$BIN" "${sources[@]}" > "$OUT_DIR/build.log" 2>&1; then
        echo "❌ 编译失败：" >&2
        grep -E "error:" "$OUT_DIR/build.log" | head -30 >&2
        exit 1
    fi
    echo "$digest" > "$stamp"
    local warnings
    warnings="$(grep -c 'warning:' "$OUT_DIR/build.log" || true)"
    echo "==> 编译通过（警告 ${warnings} 条，日志 $OUT_DIR/build.log）" >&2
}

# 单元测试：用临时 SwiftPM 工程把同一批源码编成名为 CodeEdit 的模块，
# 这样测试文件里的 `@testable import CodeEdit` 原样可用，将来进 Xcode 工程不用改一个字。
run_tests() {
    local pkg="$OUT_DIR/pkg"
    mkdir -p "$pkg/Sources/CodeEdit" "$pkg/Tests/CodeEditTests"
    cat > "$pkg/Package.swift" <<'PKG'
// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "WikiDevTests",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "CodeEdit", path: "Sources/CodeEdit", swiftSettings: [.define("DEBUG")]),
        .testTarget(name: "CodeEditTests", dependencies: ["CodeEdit"], path: "Tests/CodeEditTests")
    ],
    swiftLanguageVersions: [.v5]
)
PKG
    # rsync 保留修改时间，没改过的文件不会触发重编。
    rsync -a --delete "$REPO_ROOT/CodeEdit/Features/Wiki/" "$pkg/Sources/CodeEdit/Wiki/"
    rsync -a --delete "$REPO_ROOT/CodeEdit/Utils/KeyChain/" "$pkg/Sources/CodeEdit/KeyChain/"
    rsync -a --delete --exclude 'AIReviewService.swift' --exclude 'AIReviewWindow.swift' \
        --exclude 'GitClient+*.swift' "$REPO_ROOT/CodeEdit/Features/AIReview/" "$pkg/Sources/CodeEdit/AIReview/"
    rsync -a "$HERE/Stubs.swift" "$pkg/Sources/CodeEdit/Stubs.swift"
    rsync -a --delete "$REPO_ROOT/CodeEditTests/Features/Wiki/" "$pkg/Tests/CodeEditTests/"
    # 命令行工具里只有 Swift Testing，没有 XCTest；而且 Testing.framework 与它的宏插件
    # 不在默认搜索路径上（装了 Xcode 才会自动带上），这里显式指过去。
    local clt="/Library/Developer/CommandLineTools"
    local frameworks="$clt/Library/Developer/Frameworks"
    local flags=()
    if [ -d "$frameworks/Testing.framework" ]; then
        flags=(
            -Xswiftc -F -Xswiftc "$frameworks"
            -Xswiftc -plugin-path -Xswiftc "$clt/usr/lib/swift/host/plugins/testing"
            -Xlinker -F -Xlinker "$frameworks"
            -Xlinker -rpath -Xlinker "$frameworks"
            -Xlinker -rpath -Xlinker "$clt/Library/Developer/usr/lib"
        )
    fi
    (cd "$pkg" && swift test --disable-sandbox --disable-xctest "${flags[@]}" 2>&1)
}

need_target() {
    if [ -z "$TARGET" ] || [ ! -d "$TARGET" ]; then
        echo "❌ 需要一个存在的仓库路径" >&2
        exit 2
    fi
}

case "$MODE" in
    build)
        build
        ;;
    domain)
        need_target; build
        QIYIDE_VERIFY_DOMAIN="$TARGET" "$BIN"
        ;;
    wiki)
        need_target; build
        QIYIDE_VERIFY_WIKI="$TARGET" QIYIDE_VERIFY_WIKI_OUT="${EXTRA:-$OUT_DIR/wiki-window.png}" "$BIN"
        ;;
    structure)
        need_target; build
        mkdir -p "${EXTRA:-$OUT_DIR/structure}"
        QIYIDE_VERIFY_STRUCTURE="$TARGET" QIYIDE_VERIFY_STRUCTURE_OUT="${EXTRA:-$OUT_DIR/structure}" "$BIN"
        ;;
    open)
        need_target; build
        WIKI_DEV_OPEN="$TARGET" "$BIN"
        ;;
    test)
        run_tests
        ;;
    *)
        sed -n '2,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
        exit 2
        ;;
esac
