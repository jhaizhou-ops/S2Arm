#!/bin/bash
# 门禁覆盖：pack/nx_unpack/* pack/oneclick/oneclick.sh tools/census/api_census.py pack/jobs/build.py
# 程序位数唯一判法 nx_unpack --npdm-isa（11-01 总指挥：只留读 main.npdm META 标志这一份，oneclick.sh / api_census 都调它）。
# 夹具自造：0x80 字节 META 头，只把第 0x0C 字节设成各款真实 main.npdm 的值（不放游戏文件）；期望按「最低位 1 = aarch64、0 = aarch32」手写：
#   64 位反例：马车8 4.0.1（0x07）、Captain Toad 1.1.0（0x07）——队列表都标 aarch32（只读了本体）；
#   32 位正例：马车8 3.0.0 原件、二之国、Goat Simulator、NSMBU Deluxe、怪猎 XX（都是 0x04）；不是 META / 不足 0x80 字节 → unknown、退出 3
set -u
H=$(cd "$(dirname "$0")" && pwd); ROOT=$(cd "$H/.." && pwd)
OUT=$ROOT/build/npdm_isa_test; rm -rf "$OUT"; mkdir -p "$OUT"
timeout 500 dotnet build "$ROOT/pack/nx_unpack/nx_unpack.csproj" -c Release --artifacts-path "$OUT/art" -v quiet -nologo > "$OUT/build.log" 2>&1 || { tail -20 "$OUT/build.log"; echo "不通 编译（期望编过）"; exit 1; }
B=$(find "$OUT/art/bin" -name nx_unpack.dll | head -1); [ -n "$B" ] || { echo "不通 没找到 nx_unpack.dll"; exit 1; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
printf '#!/bin/bash\nexec dotnet "%s" "$@"\n' "$B" > "$T/nxu"; chmod +x "$T/nxu"
bad=0
ck() { if [ "$2" = "$3" ]; then echo "通 $1"; else echo "不通 $1：期望「$2」→ 真结果「$3」"; bad=1; fi; }
mk() { python3 -c "import sys; b = bytearray(0x80); b[:4] = sys.argv[2].encode(); b[0x0c] = int(sys.argv[3], 16); open(sys.argv[1], 'wb').write(bytes(b[:int(sys.argv[4])]))" "$1" "$2" "$3" "${4:-128}"; }
isa() { "$T/nxu" --npdm-isa "$1" 2> /dev/null; echo "rc=$?"; }
for c in "马车8 4.0.1:07:aarch64" "Captain Toad 1.1.0:07:aarch64" "马车8 3.0.0 原件:04:aarch32" "二之国:04:aarch32" "Goat Simulator:04:aarch32" "NSMBU Deluxe:04:aarch32" "怪猎 XX:04:aarch32"; do
  IFS=: read -r name flag want <<< "$c"; mk "$T/n.npdm" META "$flag"
  ck "${name}（第 0x0C 字节 0x${flag}）" "$want rc=0" "$(isa "$T/n.npdm" | tr '\n' ' ' | sed 's/ $//')"
done
mk "$T/bad.npdm" NOPE 07; ck "不是 META → unknown、退出 3" "unknown rc=3" "$(isa "$T/bad.npdm" | tr '\n' ' ' | sed 's/ $//')"
mk "$T/short.npdm" META 07 64; ck "不足 0x80 字节 → unknown、退出 3" "unknown rc=3" "$(isa "$T/short.npdm" | tr '\n' ' ' | sed 's/ $//')"
# 调用方：api_census.is_32_game 走同一个子命令（S2A_NX_UNPACK 指过去），不再自己读 NSO
mkdir -p "$T/g64" "$T/g32"; mk "$T/g64/main.npdm" META 07; mk "$T/g32/main.npdm" META 04
got=$(S2A_NX_UNPACK="$T/nxu" python3 -c "import sys; sys.path.insert(0, '$ROOT/tools/census'); import api_census as a; print(a.is_32_game('$T/g64'), a.is_32_game('$T/g32'))")
ck "api_census.is_32_game：0x07 → False、0x04 → True" "False True" "$got"
# 调用方：oneclick.sh 从解包目录认时的 32 位判定也是这个子命令（不再自己读字节）
ck "oneclick.sh 调 --npdm-isa、不自己读 META 字节" "1 0" "$(grep -c "'--npdm-isa'" "$ROOT/pack/oneclick/oneclick.sh") $(grep -c "m\[0xC\] & 1" "$ROOT/pack/oneclick/oneclick.sh")"
# 调用方：Mac 准备（pack/jobs/build.py）合并后核位数也走这个子命令，不再内联读第 0x0C 字节（审计 P2-26）
ck "build.py 调 --npdm-isa、不自己读 META 字节" "1 0" "$(grep -c '"--npdm-isa"' "$ROOT/pack/jobs/build.py") $(grep -c '\[0xc\] & 1' "$ROOT/pack/jobs/build.py")"
[ $bad = 0 ] && echo "npdm_isa 单测全过" || { echo "npdm_isa 单测有不通"; exit 1; }
