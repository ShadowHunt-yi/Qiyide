#!/bin/bash
# 生成内存基线测试用的固定工作区。
#
# 用法：make-fixture.sh <输出目录> [文件数=10] [每文件大小KB=1024]
# 产物：<输出目录>/file_01.swift ... file_NN.swift，每个文件接近指定大小。

set -euo pipefail

OUT_DIR="${1:-$HOME/CodeEditMemoryFixture}"
COUNT="${2:-10}"
SIZE_KB="${3:-1024}"

mkdir -p "$OUT_DIR"

# 单个代码块约 200 字节，据此计算重复次数
BLOCK='func sampleFunction(index: Int) -> Int {
    let value = index * 2 + 1
    return value % 97
}
'
BLOCK_BYTES=$(printf '%s' "$BLOCK" | wc -c | tr -d ' ')
REPEATS=$(( (SIZE_KB * 1024) / BLOCK_BYTES ))

for i in $(seq -w 1 "$COUNT"); do
    TARGET="$OUT_DIR/file_${i}.swift"
    : > "$TARGET"
    printf '// 内存基线样本 %s\n\n' "$i" >> "$TARGET"
    for _ in $(seq 1 "$REPEATS"); do
        printf '%s' "$BLOCK" >> "$TARGET"
    done
done

echo "已生成 $COUNT 个文件于 $OUT_DIR"
ls -lh "$OUT_DIR" | tail -n "$COUNT"
