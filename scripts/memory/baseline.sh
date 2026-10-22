#!/bin/bash
# S1（冷启动空载）内存基线采集。
#
# 用法：baseline.sh <Qiyide.app 路径> [采样秒数=60] [fixture 目录]
# 输出：终端表格 + <repo>/docs/customization/baseline-<时间戳>.md
#
# 说明：
#   - 使用 /usr/bin/footprint 采集 phys_footprint（与 Xcode Memory Report 同口径）
#   - 同时统计 CodeEdit 派生的语言服务器进程数量，用于验证「关窗不释放」问题
#   - S2/S3（十标签 / 关标签回落）需人工操作，脚本会打印操作提示

set -euo pipefail

APP_PATH="${1:?请传入 Qiyide.app 的绝对路径}"
DURATION="${2:-60}"
FIXTURE="${3:-$HOME/CodeEditMemoryFixture}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
STAMP="$(date +%Y%m%d-%H%M%S)"
REPORT="$REPO_ROOT/docs/customization/baseline-$STAMP.md"

if [ ! -d "$APP_PATH" ]; then
    echo "找不到应用：$APP_PATH" >&2
    exit 1
fi

BIN="$APP_PATH/Contents/MacOS/CodeEdit"

echo "启动 $APP_PATH ..."
if [ -d "$FIXTURE" ]; then
    "$BIN" --memory-probe --open "$FIXTURE" &
else
    "$BIN" --memory-probe &
fi
APP_PID=$!
sleep 3

{
    echo "# 内存基线 $STAMP"
    echo
    echo "| 项目 | 值 |"
    echo "| --- | --- |"
    echo "| 应用 | \`$APP_PATH\` |"
    echo "| fixture | \`$FIXTURE\` |"
    echo "| 采样时长 | ${DURATION}s |"
    echo "| PID | $APP_PID |"
    echo
    echo "| 秒 | footprint | RSS | 语言服务器进程数 |"
    echo "| --- | --- | --- | --- |"
} > "$REPORT"

echo "秒	footprint	RSS	LS进程"
for t in $(seq 1 5 "$DURATION"); do
    FOOTPRINT="$(footprint "$APP_PID" 2>/dev/null | grep -E 'phys_footprint|Footprint:' | head -1 | sed 's/.*: *//' || echo "-")"
    RSS="$(ps -o rss= -p "$APP_PID" 2>/dev/null | awk '{printf "%.1f MB", $1/1024}' || echo "-")"
    LS_COUNT="$(pgrep -P "$APP_PID" -l 2>/dev/null | grep -cE 'sourcekit|clangd|pyright|typescript|gopls|lua|jdtls' || true)"
    [ -z "$FOOTPRINT" ] && FOOTPRINT="-"
    printf "%ss\t%s\t%s\t%s\n" "$t" "$FOOTPRINT" "$RSS" "$LS_COUNT"
    printf "| %s | %s | %s | %s |\n" "$t" "$FOOTPRINT" "$RSS" "$LS_COUNT" >> "$REPORT"
    sleep 5
done

echo
echo "报告已写入：$REPORT"
echo
echo "接下来请手工完成："
echo "  S2：在侧栏依次打开 fixture 中的 10 个文件，每个滚动到末尾，观察读数稳定值"
echo "  S3：关闭其中 9 个标签，等待 30s，记录回落幅度"
echo "  S4：退出应用，确认语言服务器进程数归零（pgrep -fl sourcekit / clangd 等）"
