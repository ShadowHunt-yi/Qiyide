#!/bin/bash
# 没有 Xcode 时，用 SwiftPM 编译完整 App 并手工组装成 build/QiyideDev.app。
#
# 背景：scripts/build.sh 依赖 xcodebuild，只装了命令行工具的机器上跑不了。
# 但 App 是纯 Swift、依赖全是 SwiftPM 包，命令行工具自带的 `swift build` 编得动。
# 这个脚本做三件 Xcode 平时替我们做的事：
#
#   1. 生成 Package.swift —— 依赖的版本从工程的 Package.resolved 里取，保证和 Xcode 用的是同一批；
#   2. 生成资源符号 —— Xcode 会从 Assets.xcassets 生成 `Color.steel`、`ImageResource.gitHubIcon`
#      这类符号，SwiftPM 不会，这里按同样的命名规则生成一份（颜色值直接读 colorset）；
#   3. 组装 .app —— 可执行文件、Info.plist、资源、依赖包的资源束、Sparkle.framework、图标。
#
# 和 Xcode 打出来的包的差别（都只影响外观，不影响功能）：
#   - 没有 actool，资源目录不会被编译成 Assets.car。颜色已经用生成的符号补上；
#     图片以散文件形式放进包里；CodeEditSymbols 的自定义 SF 符号显示为空白。
#   - 没有 Finder 扩展（OpenWithCodeEdit）。
#   - 不带沙箱授权（和 scripts/build.sh 的 CODE_SIGNING_ALLOWED=NO 一致）。
#
# 本地依赖的位置（和 Xcode 工程的约定相同，都在仓库的同级目录）：
#   ../CodeEditSourceEditor   必须有
#   ../CodeEditTextView       必须有
#   ../CodeEditLanguages      没有时从 CODEEDIT_LANGUAGES_URL 克隆到构建目录里
#
# 用法：
#   scripts/package-dev-spm.sh            # 增量编译 + 组装
#   scripts/package-dev-spm.sh --build-only # 只编译，不组装、不关闭或启动应用
#   scripts/package-dev-spm.sh --run      # 组装后启动
#   scripts/package-dev-spm.sh --no-build # 只重新组装（已编译过）
#   scripts/package-dev-spm.sh --test     # 对完整 App 模块跑 Wiki 与主题加载 Swift Testing 回归
#
# 需要走代理时先在外部导出 https_proxy / http_proxy。

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SIBLINGS="$(dirname "$REPO_ROOT")"
WORK="$REPO_ROOT/build/app-spm"
PKG="$WORK/app"
DEPS="$WORK/deps"
APP="$REPO_ROOT/build/QiyideDev.app"
DEV_NAME="QiyideDev"
DEV_BUNDLE_ID="app.qiyide.QiyideDev"
LANGUAGES_URL="${CODEEDIT_LANGUAGES_URL:-https://github.com/ShadowHunt-yi/CodeEditLanguages.git}"

DO_BUILD=1
DO_RUN=0
DO_TEST=0
DO_ASSEMBLE=1
for arg in "$@"; do
    case "$arg" in
        --no-build) DO_BUILD=0 ;;
        --build-only) DO_ASSEMBLE=0 ;;
        --run)      DO_RUN=1 ;;
        --test)     DO_TEST=1 ;;
        -h|--help)  sed -n '2,32p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)          echo "❌ 未知参数：$arg（用 --help 查看用法）"; exit 1 ;;
    esac
done

if [ "$DO_ASSEMBLE" = "0" ] && { [ "$DO_BUILD" = "0" ] || [ "$DO_RUN" = "1" ]; }; then
    echo "❌ --build-only 不能与 --no-build 或 --run 同用"
    exit 1
fi

# SwiftLint 插件会对每个声明它的包运行；命令行构建不需要，而且它要下载并执行二进制。
export DISABLE_SWIFTLINT=1

# ───────── 1. 本地依赖 ─────────

sync_sibling() {
    local name="$1"
    if [ ! -d "$SIBLINGS/$name" ]; then
        echo "❌ 找不到本地依赖 $SIBLINGS/$name"
        exit 1
    fi
    # 拷一份而不是直接引用：SwiftPM 会在包目录里写 .build，不该落到别人的仓库里。
    rsync -a --delete --exclude '.git' --exclude '.build' --exclude 'Example' "$SIBLINGS/$name/" "$DEPS/$name/"
}

prepare_dependencies() {
    mkdir -p "$DEPS" "$PKG/Sources/CodeEdit"
    sync_sibling CodeEditSourceEditor
    sync_sibling CodeEditTextView
    if [ -d "$SIBLINGS/CodeEditLanguages" ]; then
        sync_sibling CodeEditLanguages
    elif [ ! -d "$DEPS/CodeEditLanguages" ]; then
        echo "==> 同级目录没有 CodeEditLanguages，从 $LANGUAGES_URL 克隆"
        git clone --quiet --depth 1 "$LANGUAGES_URL" "$DEPS/CodeEditLanguages"
    fi
}

# ───────── 2. Package.swift ─────────

generate_manifest() {
    python3 - "$REPO_ROOT" "$PKG" <<'PY'
import json, sys
repo, pkg = sys.argv[1], sys.argv[2]
resolved = f'{repo}/CodeEdit.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved'
pins = {p['identity']: p for p in json.load(open(resolved))['pins']}

def requirement(identity):
    pin = pins[identity]
    state = pin['state']
    if state.get('version'):
        return f'.package(url: "{pin["location"]}", exact: "{state["version"]}")'
    if state.get('branch'):
        return f'.package(url: "{pin["location"]}", branch: "{state["branch"]}")'
    return f'.package(url: "{pin["location"]}", revision: "{state["revision"]}")'

# App 直接 import 的模块。JSONRPC / TextStory / ConcurrencyPlus 在 Xcode 里是间接依赖也能 import，
# SwiftPM 要求显式声明。
remote = [
    'codeeditsymbols', 'languageclient', 'languageserverprotocol', 'zipfoundation', 'sparkle',
    'aboutwindow', 'welcomewindow', 'logstream', 'swift-collections', 'grdb.swift',
    'collectionconcurrencykit', 'codeeditkit', 'swiftui-introspect', 'swift-async-algorithms',
    'swiftterm', 'jsonrpc', 'textstory', 'concurrencyplus',
]
products = [
    ('CodeEditSourceEditor', 'CodeEditSourceEditor'), ('CodeEditTextView', 'CodeEditTextView'),
    ('CodeEditLanguages', 'CodeEditLanguages'), ('CodeEditSymbols', 'CodeEditSymbols'),
    ('LanguageClient', 'LanguageClient'), ('LanguageServerProtocol', 'LanguageServerProtocol'),
    ('ZIPFoundation', 'ZIPFoundation'), ('Sparkle', 'Sparkle'), ('AboutWindow', 'AboutWindow'),
    ('WelcomeWindow', 'WelcomeWindow'), ('LogStream', 'LogStream'),
    ('OrderedCollections', 'swift-collections'), ('DequeModule', 'swift-collections'),
    ('GRDB', 'GRDB.swift'), ('CollectionConcurrencyKit', 'collectionconcurrencykit'),
    ('CodeEditKit', 'CodeEditKit'), ('SwiftUIIntrospect', 'SwiftUI-Introspect'),
    ('AsyncAlgorithms', 'swift-async-algorithms'), ('SwiftTerm', 'SwiftTerm'),
    ('JSONRPC', 'JSONRPC'), ('TextStory', 'TextStory'), ('ConcurrencyPlus', 'ConcurrencyPlus'),
]
lines = [
    '// swift-tools-version: 5.9',
    '// 由 scripts/package-dev-spm.sh 生成，不要手改。',
    'import PackageDescription',
    '',
    'let package = Package(',
    '    name: "QiyideSPM",',
    '    platforms: [.macOS(.v14)],',
    '    dependencies: [',
    '        .package(path: "../deps/CodeEditSourceEditor"),',
    '        .package(path: "../deps/CodeEditTextView"),',
    '        .package(path: "../deps/CodeEditLanguages"),',
]
lines += [f'        {requirement(identity)},' for identity in remote]
lines += [
    '    ],',
    '    targets: [',
    '        .executableTarget(',
    # 目标名沿用 CodeEdit：它就是 Xcode 工程里的模块名，测试里的 @testable import 也认这个名字。
    '            name: "CodeEdit",',
    '            dependencies: [',
]
lines += [f'                .product(name: "{name}", package: "{package}"),' for name, package in products]
lines += [
    '            ],',
    '            path: "Sources/CodeEdit",',
    '            swiftSettings: [.define("DEBUG")]',
    '        ),',
    # 带知识库与主题加载的 Swift Testing 回归；其余 XCTest 不在此脚本的覆盖范围。
    '        .testTarget(name: "CodeEditTests", dependencies: ["CodeEdit"], path: "Tests/CodeEditTests")',
    '    ],',
    '    swiftLanguageVersions: [.v5]',
    ')',
    '',
]
open(f'{pkg}/Package.swift', 'w').write('\n'.join(lines))
PY
    # 锁文件只在第一次拷：之后 SwiftPM 会自己维护它（去掉用不到的包）。
    if [ ! -f "$PKG/Package.resolved" ]; then
        cp "$REPO_ROOT/CodeEdit.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved" "$PKG/Package.resolved"
    fi
}

# ───────── 3. 源码与生成的符号 ─────────

sync_sources() {
    rsync -a --delete --include='*/' --include='*.swift' --exclude='*' --prune-empty-dirs \
        "$REPO_ROOT/CodeEdit/" "$PKG/Sources/CodeEdit/"
    mkdir -p "$PKG/Tests/CodeEditTests"
    rsync -a --delete "$REPO_ROOT/CodeEditTests/Features/Wiki/" "$PKG/Tests/CodeEditTests/"
    mkdir -p "$PKG/Tests/CodeEditTests/Theme"
    rsync -a --delete "$REPO_ROOT/CodeEditTests/Features/Theme/" "$PKG/Tests/CodeEditTests/Theme/"

    python3 - "$REPO_ROOT" "$PKG" "$DEPS" <<'PY'
import json, os, re, sys
repo, pkg, deps = sys.argv[1], sys.argv[2], sys.argv[3]
catalog = f'{repo}/CodeEdit/Assets.xcassets'

def member(name):
    """Xcode 的命名规则：按非字母数字切开，首段小写开头，其余首字母大写。"""
    parts = [p for p in re.split(r'[^A-Za-z0-9]+', name) if p]
    head = parts[0][0].lower() + parts[0][1:]
    return head + ''.join(p[0].upper() + p[1:] for p in parts[1:])

def component(value):
    text = str(value)
    if text.lower().startswith('0x'):
        return int(text, 16) / 255
    number = float(text)
    return number / 255 if number > 1 else number

def color_expression(entry):
    color = entry['color']
    c = color['components']
    values = ', '.join(f'{component(c[k]):.4f}' for k in ('red', 'green', 'blue'))
    alpha = f'{component(c.get("alpha", 1)):.4f}'
    red, green, blue = values.split(', ')
    if 'p3' in color.get('color-space', ''):
        return f'NSColor(displayP3Red: {red}, green: {green}, blue: {blue}, alpha: {alpha})'
    return f'NSColor(srgbRed: {red}, green: {green}, blue: {blue}, alpha: {alpha})'

colors, images = [], []
for directory, _, _ in os.walk(catalog):
    name, extension = os.path.splitext(os.path.basename(directory))
    if extension == '.colorset':
        entries = json.load(open(f'{directory}/Contents.json'))['colors']
        entries = [e for e in entries if 'components' in e.get('color', {})]
        if not entries:
            continue
        light = next((e for e in entries if not e.get('appearances')), entries[0])
        dark = next((e for e in entries if any(a.get('value') == 'dark' for a in e.get('appearances', []))), light)
        colors.append((name, color_expression(light), color_expression(dark)))
    elif extension == '.imageset':
        images.append(name)

out = [
    '// 由 scripts/package-dev-spm.sh 生成，不要手改，也不要提交。',
    '// Xcode 会从 Assets.xcassets 生成这些符号；SwiftPM 不会，这里按同样的命名规则补上。',
    'import AppKit',
    'import DeveloperToolsSupport',
    'import SwiftUI',
    '',
    'private func catalogColor(light: NSColor, dark: NSColor) -> NSColor {',
    '    NSColor(name: nil) { appearance in',
    '        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light',
    '    }',
    '}',
    '',
    'extension NSColor {',
]
for name, light, dark in sorted(colors):
    out.append(f'    static let {member(name)} = catalogColor(')
    out.append(f'        light: {light},')
    out.append(f'        dark: {dark}')
    out.append('    )')
out += ['}', '', 'extension Color {']
for name, _, _ in sorted(colors):
    out.append(f'    static let {member(name)} = Color(nsColor: .{member(name)})')
out += ['}', '', 'extension ImageResource {']
for name in sorted(images):
    out.append(f'    static let {member(name)} = ImageResource(name: "{name}", bundle: .main)')
out += ['}', '']

# 本地定制的 CodeEditLanguages 里有 validateQuery；从 GitHub 克隆下来的那份可能还没有。
# 它只用于 Debug 下的启动自检，缺了就补一个「全部通过」的空实现。
has_validate = False
for directory, _, files in os.walk(f'{deps}/CodeEditLanguages/Sources'):
    for file in files:
        if file.endswith('.swift') and 'func validateQuery' in open(os.path.join(directory, file), encoding='utf-8').read():
            has_validate = True
if not has_validate:
    out += [
        'import CodeEditLanguages',
        '',
        'extension TreeSitterModel {',
        '    /// 占位实现：这份 CodeEditLanguages 没有查询自检。',
        '    func validateQuery(for language: TreeSitterLanguage) -> String? { nil }',
        '}',
        '',
    ]

target = f'{pkg}/Sources/CodeEdit/_SPMGenerated'
os.makedirs(target, exist_ok=True)
open(f'{target}/GeneratedAssetSymbols.swift', 'w', encoding='utf-8').write('\n'.join(out))
PY
}

# ───────── 4. 编译 ─────────

build_app() {
    cd "$PKG"
    # CodeEditSymbols 的资源只有一个 xcassets，靠 Xcode 自动识别。SwiftPM 不认，
    # Bundle.module 就不存在：把它转成可编辑的本地副本，在清单里显式声明资源。
    if [ ! -d "$PKG/Packages/CodeEditSymbols" ]; then
        swift package --disable-sandbox resolve > "$WORK/resolve.log" 2>&1 || { tail -20 "$WORK/resolve.log"; exit 1; }
        swift package --disable-sandbox edit CodeEditSymbols >> "$WORK/resolve.log" 2>&1
    fi
    python3 - "$PKG/Packages/CodeEditSymbols/Package.swift" <<'PY'
import sys
path = sys.argv[1]
text = open(path).read()
if 'Symbols.xcassets' not in text:
    old = '''            name: "CodeEditSymbols",
            dependencies: []
        ),'''
    assert old in text, 'CodeEditSymbols 的清单结构变了，需要更新这段补丁'
    text = text.replace(old, '''            name: "CodeEditSymbols",
            dependencies: [],
            resources: [.copy("Symbols.xcassets")]
        ),''')
    open(path, 'w').write(text)
PY

    echo "==> swift build（首次要拉依赖并全量编译，几分钟；之后是增量）"
    if ! swift build --disable-sandbox -c debug > "$WORK/build.log" 2>&1; then
        echo "❌ 编译失败。去重后的错误："
        grep -E "error:" "$WORK/build.log" | sed -E 's|.*/Sources/CodeEdit/||' | sort -u | head -30
        echo "    完整日志：$WORK/build.log"
        exit 1
    fi
    echo "    编译通过（日志 $WORK/build.log）"
}

# 对着完整 App 的模块跑知识库的单元测试。
# scripts/verify/wiki-dev/run.sh test 跑的是「知识库 + 替身」的精简模块，这里才是真模块。
run_tests() {
    cd "$PKG"
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
    echo "==> swift test"
    local result=0
    swift test --disable-sandbox --disable-xctest ${flags[@]+"${flags[@]}"} > "$WORK/test.log" 2>&1 || result=$?
    grep -E "✘|Test run with|error:" "$WORK/test.log" | sed -E 's|.*/Tests/CodeEditTests/||' | head -30 || true
    echo "    完整日志：$WORK/test.log"
    if [ "$result" -ne 0 ]; then return "$result"; fi
    grep -q "Test run with .* passed" "$WORK/test.log"
}

# ───────── 5. 组装 .app ─────────

assemble_app() {
    if [ ! -x "$PKG/.build/debug/CodeEdit" ]; then
        echo "❌ 找不到编译产物 $PKG/.build/debug/CodeEdit，去掉 --no-build 重试"
        exit 1
    fi
    # .build/debug 是个符号链接；find 不会顺着起点的链接往下走，所以先解析成真实路径。
    local products
    products="$(cd "$PKG/.build/debug" && pwd -P)"

    # 打包不应关闭用户应用，尤其不能按同名匹配 /Applications 下的安装版。
    # 只有本次输出包自己正在运行时才拒绝替换，由用户决定何时退出。
    if ps -axww -o comm= | sed 's/^[[:space:]]*//' | grep -Fx "$APP/Contents/MacOS/$DEV_NAME" >/dev/null; then
        echo "❌ 开发输出包正在运行，未关闭或替换它：$APP"
        echo "    请自行退出后重试，或使用 --build-only 仅校验编译。"
        exit 1
    fi
    if [ -e "$APP" ]; then
        # 不用 rm -rf：整包文件多，批量删除会触发安全检查。挪走，由系统回收。
        mv "$APP" "${TMPDIR:-/tmp}/QiyideDev-old-$(date +%s).app" 2>/dev/null || true
    fi

    echo "==> 组装 $APP"
    local contents="$APP/Contents"
    mkdir -p "$contents/MacOS" "$contents/Resources" "$contents/Frameworks"
    cp "$products/CodeEdit" "$contents/MacOS/$DEV_NAME"

    # DefaultThemes 在仓库根目录（不是 CodeEdit/），Xcode 用蓝色文件夹单独复制；必须保持目录名。
    if [ ! -d "$REPO_ROOT/DefaultThemes" ]; then
        echo "❌ 缺少仓库根目录 DefaultThemes，不能交付会导致空主题崩溃的包"
        return 1
    fi
    cp -R "$REPO_ROOT/DefaultThemes" "$contents/Resources/DefaultThemes"

    # 资源：Xcode 把同步目录里的非源码文件平铺进 Resources，这里照做；.lproj 保持目录结构。
    find "$REPO_ROOT/CodeEdit" -type d -name '*.lproj' | while read -r lproj; do
        cp -R "$lproj" "$contents/Resources/"
    done
    find "$REPO_ROOT/CodeEdit" -type f \
        ! -name '*.swift' ! -name '.DS_Store' ! -name 'Info.plist' ! -name '*.entitlements' \
        ! -path '*.xcassets/*' ! -path '*.lproj/*' ! -path '*/Preview Content/*' \
        -exec cp {} "$contents/Resources/" \;

    # 依赖包的资源束：Bundle.module 会到主包的 Resources 下找。
    find "$products" -maxdepth 1 -name '*.bundle' -exec cp -R {} "$contents/Resources/" \;
    # 动态框架（Sparkle 等二进制依赖）和动态库（CodeEditKit 是动态库产品）。
    find "$products" -maxdepth 1 -name '*.framework' -exec cp -R {} "$contents/Frameworks/" \;
    find "$products" -maxdepth 1 -name '*.dylib' -exec cp {} "$contents/Frameworks/" \;
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$contents/MacOS/$DEV_NAME" 2>/dev/null || true

    copy_catalog_assets "$contents/Resources"
    write_info_plist "$contents/Info.plist"
    python3 "$REPO_ROOT/scripts/verify/verify-dev-themes.py" "$APP"

    xattr -cr "$APP" 2>/dev/null || true
    codesign --force --deep --sign - "$APP" 2>&1 | sed 's/^/    /'
}

# 资源目录没法编译成 Assets.car：图片以散文件放进去（按资源名能找到），图标用 iconutil 合成。
copy_catalog_assets() {
    local resources="$1"
    python3 - "$REPO_ROOT/CodeEdit/Assets.xcassets" "$resources" "$WORK" <<'PY'
import json, os, shutil, sys
catalog, resources, work = sys.argv[1], sys.argv[2], sys.argv[3]
for directory, _, _ in os.walk(catalog):
    name, extension = os.path.splitext(os.path.basename(directory))
    if extension == '.imageset':
        entries = [e for e in json.load(open(f'{directory}/Contents.json'))['images'] if e.get('filename')]
        if not entries:
            continue
        # 取倍率最高的那张，按资源名落盘：NSImage(named:) 会按文件名找到它。
        best = max(entries, key=lambda e: int(e.get('scale', '1x')[0]))
        source = f'{directory}/{best["filename"]}'
        shutil.copy(source, f'{resources}/{name}{os.path.splitext(source)[1]}')
    elif extension == '.appiconset':
        iconset = f'{work}/AppIcon.iconset'
        os.makedirs(iconset, exist_ok=True)
        for entry in json.load(open(f'{directory}/Contents.json'))['images']:
            if not entry.get('filename') or 'size' not in entry:
                continue
            size = entry['size'].split('x')[0]
            suffix = '@2x' if entry.get('scale') == '2x' else ''
            shutil.copy(f'{directory}/{entry["filename"]}', f'{iconset}/icon_{size}x{size}{suffix}.png')
PY
    if [ -d "$WORK/AppIcon.iconset" ] && command -v iconutil >/dev/null 2>&1; then
        iconutil -c icns "$WORK/AppIcon.iconset" -o "$resources/AppIcon.icns" 2>/dev/null || true
    fi
}

# Info.plist 里的 $(…) 是 Xcode 的构建变量，这里填上它们在 Debug 构建下的值。
write_info_plist() {
    local plist="$1"
    cp "$REPO_ROOT/CodeEdit/Info.plist" "$plist"
    set_key() {
        /usr/libexec/PlistBuddy -c "Set :$1 $2" "$plist" 2>/dev/null \
            || /usr/libexec/PlistBuddy -c "Add :$1 string $2" "$plist"
    }
    set_key CFBundleExecutable "$DEV_NAME"
    set_key CFBundleName "$DEV_NAME"
    set_key CFBundleDisplayName "$DEV_NAME"
    set_key CFBundleIdentifier "$DEV_BUNDLE_ID"
    set_key CFBundlePackageType "APPL"
    set_key CFBundleDevelopmentRegion "en"
    set_key CFBundleIconFile "AppIcon"
    set_key NSHumanReadableCopyright "Copyright © 2022-2025 CodeEdit"
    set_key CE_VERSION_POSTFIX "spm"
    set_key LSMinimumSystemVersion "14.0"
    set_key QiyideVariant "dev-spm"
    /usr/libexec/PlistBuddy -c "Add :NSHighResolutionCapable bool true" "$plist" 2>/dev/null || true
}

# ───────── 入口 ─────────

if [ "$DO_TEST" = "1" ]; then
    prepare_dependencies
    generate_manifest
    sync_sources
    build_app
    run_tests
    exit $?
fi

if [ "$DO_BUILD" = "1" ]; then
    prepare_dependencies
    generate_manifest
    sync_sources
    build_app
fi
if [ "$DO_ASSEMBLE" = "0" ]; then
    echo "✅ 完整 App 编译通过；未组装、关闭或启动应用。"
    exit 0
fi
assemble_app

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist" 2>/dev/null || echo "?")
BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP/Contents/Info.plist" 2>/dev/null || echo "?")
echo
echo "✅ 开发版就绪（SwiftPM 构建）"
echo "    $APP"
echo "    版本 $VERSION ($BUILD) · Debug · BundleID $DEV_BUNDLE_ID"

if [ "$DO_RUN" = "1" ]; then
    echo "==> 启动 $DEV_NAME"
    open -n "$APP"
fi
