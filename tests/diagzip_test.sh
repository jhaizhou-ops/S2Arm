#!/bin/bash
# 诊断包 zip（ios/diagzip.m）单测：在 Mac 上编同一份源，打一个含中文名和子目录的目录，按 schema 1 核：
#   条目在根上（manifest.json、logs/…，不套外层文件夹）、每个条目都带 UTF-8 标记（通用标志第 11 位）、中文名按 UTF-8 解出来不乱码、
#   CRC 与内容逐字节一致、系统 unzip -t 也认。期望值直接写在下面，不跑被测实现推算。
set -u
H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
cat > "$T/main.m" <<'M'
#import <Foundation/Foundation.h>
#include "diagzip.h"
int main(int argc, char **argv) { (void)argc; @autoreleasepool { return s2a_write_zip(@(argv[1]), @(argv[2])) ? 0 : 1; } }
M
clang -fobjc-arc -O1 -I"$H/ios" -o "$T/z" "$T/main.m" "$H/ios/diagzip.m" -framework Foundation -lz || { echo "✗ 编不过"; exit 1; }
W="$T/w"; mkdir -p "$W/logs" "$W/metrickit"
printf '{"schema": 1}\n' > "$W/manifest.json"
python3 -c "import sys; open(sys.argv[1],'w').write('诊断包：已生成\n' * 5000)" "$W/logs/host.log"
printf 'crash\n' > "$W/metrickit/崩溃 一.json"
"$T/z" "$W" "$T/out.zip" || { echo "✗ s2a_write_zip 返回失败"; exit 1; }
python3 - "$T/out.zip" "$W" <<'P' || exit 1
import sys, zipfile, os
z = zipfile.ZipFile(sys.argv[1]); w = sys.argv[2]
want = ["logs/host.log", "manifest.json", "metrickit/崩溃 一.json"]
got = sorted(i.filename for i in z.infolist())
ok = True
def chk(name, cond, detail):
    global ok
    print(("✓ " if cond else "✗ ") + name + "：" + detail); ok &= cond
chk("条目在根上、中文名按 UTF-8 解出", got == want, f"期望 {want} → 真结果 {got}")
chk("每个条目带 UTF-8 标记", all(i.flag_bits & 0x800 for i in z.infolist()), str([hex(i.flag_bits) for i in z.infolist()]))
chk("CRC 全对", z.testzip() is None, str(z.testzip()))
chk("内容逐字节一致", all(z.read(n) == open(os.path.join(w, n), "rb").read() for n in want), "3 个文件")
chk("确实压缩了（deflate）", all(i.compress_type == 8 for i in z.infolist()) and z.getinfo("logs/host.log").compress_size < z.getinfo("logs/host.log").file_size // 10, "")
sys.exit(0 if ok else 1)
P
unzip -tq "$T/out.zip" > /dev/null || { echo "✗ unzip -t 不认"; exit 1; }
echo "diagzip 单测全过（5 项 + unzip -t）"
