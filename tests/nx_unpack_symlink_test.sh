#!/bin/bash
# 门禁覆盖：pack/nx_unpack/* compat/packages/*
# nx_unpack 源文件是符号链接（10-26 运维线：Downloads 里 15 个链接指向移动硬盘）：长度、0x100 处 HEAD 要按链接目标读。合成数据，不用游戏文件、不要密钥。
#   期望：① 链接到「0x100 处有 HEAD」的合成文件 → 认成卡带镜像（不报「0x100 处没有 HEAD」）；② 链接到 0 字节文件 → 报「0 字节」。
#   旧代码（FileInfo(src).Length 取链接自身长度）两条都错：① 报没有 HEAD、② 不报 0 字节。产物在 <仓库根>/build/nx_unpack_symlink_test。退出 0 = 全过
set -u
H=$(cd "$(dirname "$0")" && pwd); ROOT=$(cd "$H/.." && pwd); OUT=$ROOT/build/nx_unpack_symlink_test; mkdir -p "$OUT"
timeout 500 dotnet build -c Release "$ROOT/pack/nx_unpack" -o "$OUT/bin" > "$OUT/build.log" 2>&1 || { tail -30 "$OUT/build.log"; echo "不通 编译（期望编过）"; exit 1; }
D=$OUT/case; rm -rf "$D"; mkdir -p "$D/src" "$D/link" "$D/out"; : > "$D/prod.keys"
python3 -c "import sys; b=bytearray(0x400); b[0x100:0x104]=b'HEAD'; open(sys.argv[1],'wb').write(b)" "$D/src/fake.xci"
: > "$D/src/empty.nsp"
ln -s "$D/src/fake.xci" "$D/link/fake.xci"; ln -s "$D/src/empty.nsp" "$D/link/empty.nsp"
fail=0
timeout 60 "$OUT/bin/nx_unpack" "$D/prod.keys" "$D/out" --nacp-only "$D/link/fake.xci" > "$D/a.log" 2>&1
if LC_ALL=C /usr/bin/grep -q "没有 HEAD" "$D/a.log"; then echo "不通 ① 链接到卡带镜像被当成非卡带镜像（期望按目标读 0x100 处 HEAD）"; tail -3 "$D/a.log"; fail=1; else echo "通过 ① 链接到卡带镜像按目标认 HEAD"; fi
timeout 60 "$OUT/bin/nx_unpack" "$D/prod.keys" "$D/out" --nacp-only "$D/link/empty.nsp" > "$D/b.log" 2>&1
if LC_ALL=C /usr/bin/grep -q "0 字节" "$D/b.log"; then echo "通过 ② 链接到空文件报 0 字节"; else echo "不通 ② 链接到空文件没报 0 字节"; tail -3 "$D/b.log"; fail=1; fi
exit $fail
