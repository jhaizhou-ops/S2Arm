#!/bin/bash
# 平台耦合盘点 + 只减不增门禁（tools/platform_scan.py；平台 adapter 边界设计 P0，docs/架构_多终端.md §5）：bash tests/platform_scan_test.sh
# 门禁覆盖：compat/tree/src/* compat/patches/* services/* tools/platform_scan.py
# A 段（合成仓库，期望按规则手算）：
#   ① 补丁新增的 OperatingSystem.IsIOS 行计 1 苹果行；树里原有（补丁没加）的 IsIOS 不计
#   ② services 里的 NativeLibrary.GetExport 计 1 按名找导出；services 里 IsAndroid 计 1 安卓行
#   ③ 行内写「// 平台例外：…」的不计
#   ④ 门禁：本树比基线多一行 IsMacOS → 退出 1、点名那一行；⑤ 反过来（本树少一行）→ 退出 0
#   ⑥ 平台行原样搬到另一个共享文件（#1067 源码分区，#1083）→ 退出 0（门禁按「类别 + 行文本」总次数比，不看文件）
#   ⑦ 同样的行文本在另一个文件多写一处 → 退出 1、+1、点名多出来的那个文件
#   ⑧ 按名找导出按导出名计：同一个名字换查法 → 退出 0；⑨ 查一个新名字 → 退出 1、点名
# B 段：真仓库对 GATE_SCAN_BASE（缺省 origin/main）跑只减不增，新增 0 处才过
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; bad=0
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
PS="python3 $H/tools/platform_scan.py --trainlog /dev/null"
mk() {   # $1 = 根；$2 = 额外的 services 行
    local R=$1; mkdir -p $R/compat/tree/src/Ryujinx.Foo $R/compat/patches $R/services/S2A.Services
    printf 'class A {\n  void F() { if (OperatingSystem.IsIOS()) G(); }\n  void P() { if (OperatingSystem.IsIOS()) Q(); }\n}\n' > $R/compat/tree/src/Ryujinx.Foo/A.cs
    printf -- '--- a/src/Ryujinx.Foo/A.cs\n+++ b/src/Ryujinx.Foo/A.cs\n@@ -1,1 +1,2 @@\n+  void P() { if (OperatingSystem.IsIOS()) Q(); }\n' > $R/compat/patches/0001-x.patch
    printf 'class B {\n  nint p = NativeLibrary.GetExport(h, "s2a_x");\n  bool a = OperatingSystem.IsAndroid();\n  bool e = OperatingSystem.IsAndroid();   // 平台例外：单测样例\n%s}\n' "$2" > $R/services/S2A.Services/B.cs
}
mk $T/base ''
L=$($PS --root $T/base --lines)
ck "① 补丁加的 IsIOS 计 1、树里原有的不计（实得苹果 $(grep -c '	apple	' <<< "$L")）" '[ "$(grep -c "	apple	" <<< "$L")" = 1 ] && grep -q "void P()" <<< "$L" && ! grep -q "void F()" <<< "$L"'
ck "② services 按名找导出 1、安卓行 1" '[ "$(grep -c "	export	" <<< "$L")" = 1 ] && [ "$(grep -c "	android	" <<< "$L")" = 1 ]'
ck "③ 行内「平台例外」不计" '! grep -q "平台例外" <<< "$L"'
mk $T/head '  bool m = OperatingSystem.IsMacOS();\n'
o=$($PS --root $T/head --gate $T/base); r=$?
ck "④ 多一行 IsMacOS：退出 ${r}（期望 1）、点名新增那一行" '[ $r = 1 ] && grep -q "【红】新增苹果平台行（+1）：services/S2A.Services/B.cs：bool m = OperatingSystem.IsMacOS();" <<< "$o"'
o=$($PS --root $T/base --gate $T/head); r=$?
ck "⑤ 反过来（本树少一行）：退出 ${r}（期望 0）" '[ $r = 0 ] && grep -q "新增 0 处" <<< "$o"'
mkdir -p $T/mv; cp -R $T/base/. $T/mv/
grep -v 'bool a = OperatingSystem.IsAndroid();' $T/base/services/S2A.Services/B.cs > $T/mv/services/S2A.Services/B.cs
printf 'class C {\n  bool a = OperatingSystem.IsAndroid();\n}\n' > $T/mv/services/S2A.Services/C.cs
o=$($PS --root $T/mv --gate $T/base); r=$?
ck "⑥ 安卓行原样搬到 C.cs：退出 ${r}（期望 0）、新增 0" '[ $r = 0 ] && grep -q "新增 0 处" <<< "$o"'
mkdir -p $T/dup; cp -R $T/base/. $T/dup/
printf 'class D {\n  bool a = OperatingSystem.IsAndroid();\n}\n' > $T/dup/services/S2A.Services/D.cs
o=$($PS --root $T/dup --gate $T/base); r=$?
ck "⑦ 同样的安卓行在 D.cs 多写一处：退出 ${r}（期望 1）、+1 点名 D.cs" '[ $r = 1 ] && grep -q "【红】新增安卓平台行（+1）：services/S2A.Services/D.cs：bool a = OperatingSystem.IsAndroid();" <<< "$o"'
# ⑧ 同一个导出名换个查法（主程序句柄 → 显式 owner）：不算新增（11-01 补时导出改查 exportOwner 被误拦）；⑨ 查一个新导出名照样 +1
mkdir -p $T/rw; cp -R $T/base/. $T/rw/
sed 's|NativeLibrary.GetExport(h, "s2a_x")|NativeLibrary.TryGetExport(owner, "s2a_x", out nint q) ? q : 0|' $T/base/services/S2A.Services/B.cs > $T/rw/services/S2A.Services/B.cs
o=$($PS --root $T/rw --gate $T/base); r=$?
ck "⑧ 同一导出 s2a_x 换查法：退出 ${r}（期望 0）、新增 0" '[ $r = 0 ] && grep -q "新增 0 处" <<< "$o"'
mk $T/newx '  nint y = NativeLibrary.GetExport(h, "s2a_y");\n'
o=$($PS --root $T/newx --gate $T/base); r=$?
ck "⑨ 新查 s2a_y：退出 ${r}（期望 1）、点名找导出 s2a_y" '[ $r = 1 ] && grep -q "【红】新增按名找导出（+1）：services/S2A.Services/B.cs：找导出 s2a_y" <<< "$o"'
# B 段：真仓库
BASE=${GATE_SCAN_BASE:-origin/main}
if git -C "$H" rev-parse --verify -q "$BASE^{commit}" > /dev/null; then
    mkdir -p $T/real && git -C "$H" archive "$BASE" compat/tree/src compat/patches services | tar -x -C $T/real
    o=$(cd "$H" && $PS --gate $T/real); r=$?
    ck "B 真仓库对 $BASE 只减不增：$(tail -1 <<< "$o")" '[ $r = 0 ]'
    [ $r = 0 ] || grep '【红】' <<< "$o" | head -20
else
    echo "不通 B 取不到基线 $BASE"; bad=1
fi
[ $bad = 0 ] && echo "platform_scan 单测全过" || { echo "platform_scan 单测有不通"; exit 1; }
