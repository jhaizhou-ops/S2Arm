#!/bin/bash
# 门禁覆盖：tools/toolchain.sh pack/ipa.sh pack/shell_build.sh services/opus/build.sh services/vpx/build.sh services/vpx/patches/* services/dav1d/build.sh
# 审计 #1534 P1-107：Mac 本地编译缓存跟编译器走（壳编号不变，只在取本机缓存时比工具链版本行）。假 xcrun（版本行由 FAKE_CLANG / FAKE_METAL 定）放 PATH 最前：
#   ① s2a_tc_sweep（shell_build.sh 清引擎树 iOS 中间产物）：记录与本机相同 → 目录留；不同 / 没有记录 → 删掉、写新记录
#   ② pack/ipa.sh 判壳缓存命中的那一行（原样取出求值）：记录同 → 命中；不同 / 没有记录 → 不命中；给了发布源 → 不按本机编译器判；出壳后写记录那一行写的就是命中要的
#   ③ 三支编解码库（opus / vpx / dav1d，iOS）：本机缓存目录名带 clang 版本行哈希（<平台>-<版本>-<脚本哈希>-<版本行哈希前 8 位>）：本编译器那份在 → 直接回库路径、不取源码；
#      只有别的编译器那份 / 旧布局（不带版本行哈希）→ 重编（假 curl / gh 取不到源码包，报「取不到源码包」），且别的编译器那份原样留着（11-05：两套 Xcode 轮流 rm -rf 互删，单测 dlopen 不到 rc=134）；
#      取不到版本行（xcrun 失败）→ 报红、不出库
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; bad=0
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
mkdir -p "$T/bin"
cat > "$T/bin/xcrun" <<'X'
#!/bin/bash
for a; do [ "$a" = --version ] || continue; [ "${FAKE_CLANG:-}" = fail ] && exit 1; case " $* " in *" metal "*) echo "Apple metal version ${FAKE_METAL:-1}";; *) echo "Apple clang version ${FAKE_CLANG:-1} (fake)"; echo "Target: fake";; esac; exit 0; done
o=; p=; for a; do [ "$p" = -o ] && o=$a; p=$a; done; [ -z "$o" ] || : > "$o"
X
cp "$T/bin/xcrun" "$T/bin/libtool"; printf '#!/bin/sh\nexit 1\n' > "$T/bin/curl"; cp "$T/bin/curl" "$T/bin/gh"; chmod +x "$T/bin/"*
export PATH="$T/bin:$PATH" S2A_BUILD_CACHE="$T/bc" FAKE_CLANG=1 FAKE_METAL=1
# 走 toolchain.sh「上游已解析：沿用」那条路（不碰真 Xcode）
tc() { S2A_TC_RESOLVED=1 DEVELOPER_DIR=$T S2A_TC_METAL="Apple metal version $FAKE_METAL" bash -c "source '$H/tools/toolchain.sh' || exit 9; $1"; }

# ① s2a_tc_sweep
B=$T/b; mk() { mkdir -p "$B/gal/ios" "$B/nvn/ios"; : > "$B/gal/ios/x.o"; }
sw() { tc "s2a_tc_sweep '$B/.ios_toolchain' '$B/gal/ios' '$B/nvn/ios' '$B/nope'"; }
mk; sw; r=$?
ck "① 没有记录 → 清掉、写记录（rc=${r}）" '[ $r = 0 ] && [ ! -e $B/gal/ios ] && [ ! -e $B/nvn/ios ] && [ -s $B/.ios_toolchain ]'
mk; sw; r=$?
ck "① 记录与本机相同 → 目录留（rc=${r}）" '[ $r = 0 ] && [ -f $B/gal/ios/x.o ] && [ -d $B/nvn/ios ]'
mk; FAKE_CLANG=2 sw; r=$?
ck "① 换了 clang 版本行 → 清掉（rc=${r}）" '[ $r = 0 ] && [ ! -e $B/gal/ios ] && [ ! -e $B/nvn/ios ] && grep -q "clang version 2" $B/.ios_toolchain'
mk; FAKE_CLANG=2 FAKE_METAL=7 sw; r=$?
ck "① 只换 Metal 编译器版本行 → 也清掉（rc=${r}）" '[ $r = 0 ] && [ ! -e $B/gal/ios ] && grep -q "metal version 7" $B/.ios_toolchain'

# ② ipa.sh 壳缓存判命中（取原行求值）
STL=$(grep -a '^  STALE=' "$H/pack/ipa.sh"); WRL=$(grep -a 's2a_tc_fp > "\$SC/\.\$SID\.toolchain"' "$H/pack/ipa.sh" | sed 's/ ||.*//; s/^ *//')
ck "② ipa.sh 里有判命中行与写记录行" '[ -n "$STL" ] && [ -n "$WRL" ]'
SC=$T/sc; mkdir -p "$SC/abc"; : > "$SC/abc/manifest.json"
st() { tc "SC='$SC'; SID=abc; SHELL_DIR='$SC/abc'; $1; eval '$STL'; echo \"[\${STALE-无}]\""; }
o=$(st :); ck "② 没有记录（旧缓存）→ 不命中（${o}）" '[ "$o" = "[1]" ]'
o=$(S2A_SHELL_SOURCE=https://x st :); ck "② 给了发布源、没有记录 → 不按本机判，命中（${o}）" '[ "$o" = "[]" ]'
o=$(st "$WRL"); ck "② 写记录后同一工具链 → 命中（${o}）" '[ "$o" = "[]" ]'
o=$(FAKE_CLANG=3 st :); ck "② 换了 clang → 不命中（${o}）" '[ "$o" = "[1]" ]'
o=$(FAKE_METAL=3 st :); ck "② 换了 Metal 编译器 → 不命中（${o}）" '[ "$o" = "[1]" ]'
rm -f "$SC/abc/manifest.json"; o=$(st :); ck "② 壳不在 → 走原先的「没有就出」（不靠 STALE）（${o}）" '[ "$o" = "[]" ]'

# ③ 编解码库整机缓存
MMAC=$(sed -n 's/^MACOSX_DEPLOYMENT_TARGET=//p' "$H/tools/toolchain.env"); MIOS=$(sed -n 's/^IPHONEOS_DEPLOYMENT_TARGET=//p' "$H/tools/toolchain.env")
tag() { printf '%s' "$1" | shasum -a 256 | cut -c1-8; }   # 版本行（假 xcrun 输出的第一行）→ 目录名后缀
for lib in opus vpx dav1d; do
  s=$H/services/$lib/build.sh; v=$(sed -n 's/^VER=\([^;]*\);.*/\1/p' "$s"); h1=$( { cat "$s"; echo "$MMAC $MIOS"; } | shasum -a 256 | cut -c1-12)
  # vpx 的 H1 另带变体名与 S2Arm 补丁（services/vpx/build.sh 的 S2A_VPX_VARIANT，缺省 ship）
  [ "$lib" = vpx ] && h1=$( { cat "$s"; echo "$MMAC $MIOS ship"; cat "$H/services/vpx/patches/0001-s2a-vp9-nvdec-hook.patch"; } | shasum -a 256 | cut -c1-12)
  up=$(echo "$lib" | tr a-z A-Z); C=$T/cache/$lib; B0=$C/ios-arm64-$v-$h1
  O=$B0-$(tag "Apple clang version 1 (fake)"); OX=$B0-$(tag "Apple clang version 0 (fake)")
  seed() { rm -rf "$C"; for d; do mkdir -p "$d/include"; echo a > "$d/lib$lib.a"; done; }
  run() { env -u S2A_PREBUILT_TOOLS "S2A_${up}_CACHE=$C" bash "$s" ios-arm64 2>&1; }
  seed "$O"; o=$(run); r=$?
  ck "③ $lib 本编译器那份在 → 命中回库路径、不取源码（rc=${r}）" '[ $r = 0 ] && [[ "$(echo "$o" | tail -1)" == "$O"/s2a-*/libs2a_$lib.a ]] && [[ "$o" != *取不到源码包* ]]'
  seed "$OX"; o=$(run); r=$?
  ck "③ $lib 只有旧 clang 那份 → 不命中、去重编，旧 clang 那份原样留着（rc=${r}）" '[ $r != 0 ] && [[ "$o" == *取不到源码包* ]] && [ -s "$OX/lib$lib.a" ]'
  seed "$B0"; o=$(run); r=$?
  ck "③ $lib 只有旧布局（不带版本行哈希）→ 不命中、去重编（rc=${r}）" '[ $r != 0 ] && [[ "$o" == *取不到源码包* ]] && [ -s "$B0/lib$lib.a" ]'
  seed "$O" "$OX"; o=$(run); r=$?; o2=$(FAKE_CLANG=0 run | tail -1)
  ck "③ $lib 两套编译器的份并存 → 各取各的（rc=${r}）" '[ $r = 0 ] && [[ "$(echo "$o" | tail -1)" == "$O"/s2a-* ]] && [[ "$o2" == "$OX"/s2a-* ]]'
  seed "$O"; o=$(FAKE_CLANG=fail run); r=$?
  ck "③ $lib 取不到 clang 版本行 → 报红、不出库（rc=${r}）" '[ $r != 0 ] && [[ "$o" == *取不到*版本行* ]] && [ -s "$O/lib$lib.a" ]'
done
exit $bad
