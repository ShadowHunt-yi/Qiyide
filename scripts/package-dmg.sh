#!/bin/bash
# 把已构建的 Qiyide.app 打包成可分发的 dmg。
#
# 用法：
#   scripts/package-dmg.sh            # 打包 Release 产物
#   scripts/package-dmg.sh Debug      # 打包 Debug 产物
#
# 前置条件：先运行 `scripts/build.sh <配置>`（本脚本只打包，不重复构建）。
#
# 签名策略：
#   构建阶段用 CODE_SIGNING_ALLOWED=NO，产物是未签名的。这里默认做 ad-hoc 签名
#   （`codesign -s -`），否则部分 macOS 版本会把整包标记为「已损坏」，
#   连「右键 → 打开」都过不去。ad-hoc 签名的应用可在本机同架构运行，
#   但对外分发仍会被 Gatekeeper 拦截，需要 Developer ID 签名 + 公证后才无提示。
#   需要跳过时：ADHOC_SIGN=0 scripts/package-dmg.sh。

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${1:-Release}"
ADHOC_SIGN="${ADHOC_SIGN:-1}"

APP="$REPO_ROOT/build/Build/Products/$CONFIG/Qiyide.app"
if [ ! -d "$APP" ]; then
    echo "❌ 找不到构建产物：$APP"
    echo "   请先执行：scripts/build.sh $CONFIG"
    exit 1
fi

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist" 2>/dev/null || echo "0.0.0")
BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP/Contents/Info.plist" 2>/dev/null || echo "0")
DMG="$REPO_ROOT/build/Qiyide-$VERSION-$BUILD.dmg"
VOLUME_NAME="Qiyide $VERSION"

echo "==> 配置: $CONFIG"
echo "==> 版本: $VERSION ($BUILD)"
echo "==> 产物: $DMG"

if [ "$ADHOC_SIGN" = "1" ]; then
    echo "==> ad-hoc 签名（无证书）"
    # --deep 递归签名内嵌的框架与插件；未签名的整包在部分系统上会直接被判定为损坏。
    codesign --force --deep --sign - "$APP"
    codesign --verify --deep --strict --verbose=1 "$APP" 2>&1 | sed 's/^/    /'
else
    echo "==> 跳过签名（ADHOC_SIGN=0）"
fi

# 准备临时目录：应用本体 + /Applications 软链（拖拽安装的惯用布局）。
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

# 去掉可能残留的扩展属性，避免 dmg 内出现 ._ 影子文件。
xattr -cr "$STAGE/Qiyide.app" 2>/dev/null || true

rm -f "$DMG"
hdiutil create \
    -volname "$VOLUME_NAME" \
    -srcfolder "$STAGE" \
    -fs HFS+ \
    -format UDZO \
    -ov \
    "$DMG" >/dev/null

echo
echo "✅ 打包完成"
echo "    $(du -h "$DMG" | awk '{print $1}')  $DMG"
shasum -a 256 "$DMG" | awk '{print "    SHA256: "$1}'
