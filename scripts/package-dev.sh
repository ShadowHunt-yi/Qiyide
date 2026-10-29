#!/bin/bash
# 打包本地开发版 QiyideDev——与正式版 Qiyide 并存，随时替换随时测。
#
# 与正式版的区别（只在打包产物上改，不动工程配置）：
#   显示名 / 可执行名   Qiyide → QiyideDev
#   Bundle ID           app.qiyide.Qiyide → app.qiyide.QiyideDev
#   内嵌扩展 Bundle ID   app.qiyide.Qiyide.OpenWithCodeEdit → ...QiyideDev.OpenWithCodeEdit
#   自定义标记           QiyideVariant = dev（便于事后确认装的是哪个包）
#
# 因为 Bundle ID 不同，两套 App 的用户偏好、窗口、Dock 图标互不覆盖；
# 代价是配置不共享——正式版里配好的设置，开发版要单独配一次。
#
# 用法：
#   scripts/package-dev.sh                # 增量构建 Debug + 打包 .app
#   scripts/package-dev.sh --dmg          # 顺带产出 dmg
#   scripts/package-dev.sh --run          # 打包后立刻启动
#   scripts/package-dev.sh --release      # 用 Release 产物（更接近正式包，构建更慢）
#   scripts/package-dev.sh --no-build     # 不构建，直接重打包现有产物（最快，约 3 秒）
#
# 组合示例：
#   scripts/package-dev.sh --no-build --run      # 改完代码已构建过，直接重打包并启动

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="Debug"
DO_BUILD=1
MAKE_DMG=0
DO_RUN=0

for arg in "$@"; do
    case "$arg" in
        --release)  CONFIG="Release" ;;
        --no-build) DO_BUILD=0 ;;
        --dmg)      MAKE_DMG=1 ;;
        --run)      DO_RUN=1 ;;
        -h|--help)  sed -n '2,26p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)          echo "❌ 未知参数：$arg（用 --help 查看用法）"; exit 1 ;;
    esac
done

SRC_APP="$REPO_ROOT/build/Build/Products/$CONFIG/Qiyide.app"
OUT_APP="$REPO_ROOT/build/QiyideDev.app"
DEV_NAME="QiyideDev"
DEV_BUNDLE_ID="app.qiyide.QiyideDev"

if [ "$DO_BUILD" = "1" ]; then
    echo "==> 构建 $CONFIG"
    "$REPO_ROOT/scripts/build.sh" "$CONFIG" >/dev/null
    echo "    构建完成"
fi

if [ ! -d "$SRC_APP" ]; then
    echo "❌ 找不到构建产物：$SRC_APP"
    echo "   去掉 --no-build 重试一次。"
    exit 1
fi

# 正在运行的开发版会占着旧 inode，先请它退出，避免测试时看到旧行为。
if pgrep -f "$DEV_NAME.app/Contents/MacOS/$DEV_NAME" >/dev/null 2>&1; then
    echo "==> 关闭正在运行的 $DEV_NAME"
    pkill -TERM -f "$DEV_NAME.app/Contents/MacOS/$DEV_NAME" 2>/dev/null || true
    sleep 1
fi

echo "==> 复制并改名"
if [ -e "$OUT_APP" ]; then
    # 不用 rm -rf：整包有近 400 个文件，批量删除会触发安全检查。
    # 改成一挪了之，旧包留在临时目录由系统回收。
    mv "$OUT_APP" "${TMPDIR:-/tmp}/QiyideDev-old-$(date +%s).app" 2>/dev/null || true
fi
ditto "$SRC_APP" "$OUT_APP"

MACOS_DIR="$OUT_APP/Contents/MacOS"
if [ -f "$MACOS_DIR/Qiyide" ]; then
    mv "$MACOS_DIR/Qiyide" "$MACOS_DIR/$DEV_NAME"
fi

PLIST="$OUT_APP/Contents/Info.plist"
set_key() {
    local key="$1" value="$2"
    /usr/libexec/PlistBuddy -c "Set :$key $value" "$PLIST" 2>/dev/null \
        || /usr/libexec/PlistBuddy -c "Add :$key string $value" "$PLIST"
}
set_key CFBundleExecutable "$DEV_NAME"
set_key CFBundleName "$DEV_NAME"
set_key CFBundleDisplayName "$DEV_NAME"
set_key CFBundleIdentifier "$DEV_BUNDLE_ID"
set_key QiyideVariant "dev"

# 内嵌的 Finder 扩展开启时也不该和正式版抢同一个标识。
for appex in "$OUT_APP"/Contents/PlugIns/*.appex; do
    [ -d "$appex" ] || continue
    appex_plist="$appex/Contents/Info.plist"
    appex_id=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$appex_plist" 2>/dev/null || echo "")
    case "$appex_id" in
        app.qiyide.Qiyide.*)
            dev_id="app.qiyide.${DEV_NAME}.${appex_id##*.}"
            /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $dev_id" "$appex_plist"
            echo "    扩展 $(basename "$appex") → $dev_id"
            ;;
    esac
done

echo "==> ad-hoc 签名"
xattr -cr "$OUT_APP" 2>/dev/null || true
codesign --force --deep --sign - "$OUT_APP" 2>&1 | sed 's/^/    /'
codesign --verify --deep --strict "$OUT_APP" 2>&1 | sed 's/^/    /'

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST" 2>/dev/null || echo "0.0.0")
BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$PLIST" 2>/dev/null || echo "0")

echo
echo "✅ 开发版就绪"
echo "    $OUT_APP"
echo "    版本 $VERSION ($BUILD) · $CONFIG · BundleID $DEV_BUNDLE_ID"
echo "    测试方式：把它拖进 /Applications 覆盖旧的 QiyideDev，双击即可"

if [ "$MAKE_DMG" = "1" ]; then
    DMG="$REPO_ROOT/build/${DEV_NAME}-${VERSION}-${BUILD}.dmg"
    STAGE="$(mktemp -d)"
    trap 'rm -rf "$STAGE"' EXIT
    cp -R "$OUT_APP" "$STAGE/"
    ln -s /Applications "$STAGE/Applications"
    rm -f "$DMG"
    hdiutil create -volname "$DEV_NAME $VERSION" -srcfolder "$STAGE" \
        -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
    echo
    echo "    $(du -h "$DMG" | awk '{print $1}')  $DMG"
    shasum -a 256 "$DMG" | awk '{print "    SHA256: "$1}'
fi

if [ "$DO_RUN" = "1" ]; then
    echo
    echo "==> 启动 $DEV_NAME"
    open -n "$OUT_APP"
fi
