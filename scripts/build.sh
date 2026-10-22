#!/bin/bash
# 命令行构建 Qiyide。
#
# 用法：
#   scripts/build.sh                # Debug
#   scripts/build.sh Release        # Release
#
# 三个必须参数的原因：
#   -skipPackagePluginValidation / -skipMacroValidation
#       命令行构建不会弹出「是否信任插件/宏」的对话框，必须显式跳过校验。
#   DISABLE_SWIFTLINT=1
#       SwiftLint 插件会对每个声明它的 target 运行，包括第三方依赖。
#       依赖自身的风格问题会被报成 error（例如 LanguageServerProtocol 的测试里有
#       一行 278 字符，超过 SwiftLint 默认 error 阈值 200），从而中断构建；
#       即使不中断，也只是把数千条 warning 刷满日志。
#       该插件支持此环境变量短路（见 SwiftLintPlugin/Plugins/SwiftLint/main.swift）。
#
# 需要走代理时先在外部导出：
#   export https_proxy=http://127.0.0.1:7890 http_proxy=http://127.0.0.1:7890

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${1:-Debug}"
if [ "$#" -gt 0 ]; then shift; fi

export DISABLE_SWIFTLINT=1

LOG="$REPO_ROOT/build/build.log"
APP="$REPO_ROOT/build/Build/Products/$CONFIG/Qiyide.app"
mkdir -p "$REPO_ROOT/build"

echo "==> 配置: $CONFIG"
echo "==> DISABLE_SWIFTLINT=${DISABLE_SWIFTLINT:-<未设置>}（非空则跳过 SwiftLint）"
echo "==> 日志: $LOG"
echo

set +e
xcodebuild \
    -project "$REPO_ROOT/CodeEdit.xcodeproj" \
    -scheme CodeEdit \
    -configuration "$CONFIG" \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$REPO_ROOT/build" \
    -skipPackagePluginValidation \
    -skipMacroValidation \
    -IDEPackageSupportDisableManifestSandbox=1 \
    -IDEPackageSupportDisablePluginExecutionSandbox=1 \
    CODE_SIGNING_ALLOWED=NO \
    "$@" \
    build 2>&1 | tee "$LOG"
STATUS=${PIPESTATUS[0]}
set -e

echo
if grep -q "Linting '" "$LOG"; then
    echo "⚠️  日志里出现了 SwiftLint 的 Linting 输出：DISABLE_SWIFTLINT 未传到插件进程。"
    echo "    改用系统级注入后重试："
    echo "      launchctl setenv DISABLE_SWIFTLINT 1"
    echo "      ./scripts/build.sh"
    echo "    用完后撤销：launchctl unsetenv DISABLE_SWIFTLINT"
    echo
fi

if [ "$STATUS" -ne 0 ]; then
    echo "❌ 构建失败（退出码 ${STATUS}）。错误行："
    grep -E "error: " "$LOG" | head -20
    exit "$STATUS"
fi

echo "✅ 构建成功"
echo "    产物: $APP"
/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP/Contents/Info.plist" 2>/dev/null \
    | sed 's/^/    BundleID: /'
if [ -d "$APP/Contents/Resources/zh-Hans.lproj" ]; then
    echo "    中文资源: 已入包"
else
    echo "    中文资源: 缺失"
fi
