#!/bin/bash
# 安卓回放层分叉计数快检（tools/android_fork_ratchet.py，约 1 秒；只打印、不拦合入）：bash tests/android_fork_ratchet_test.sh
# 门禁只看：android/native/* graphics/nvn/gfx/nvn/* runtime/src/* tools/android_fork_ratchet.py tools/android_fork_baseline.json
#   ① 本树跑得通、四项都有计数、退出 0（计数涨了也只打印提示）
#   ② 判定本身（假仓库，期望手写）：基线各 1 处；在 android/native/direct/x.c 加一条 case OP_ → 仍退出 0、打印「提示 op_cases」并点名 x.c；
#      删回去、注释里的不计 → 没有提示；在 runtime/src/y.c 加一处 __ANDROID__ → 仍退出 0、提示 shared_android
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; bad=0
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
o1=$(python3 "$H/tools/android_fork_ratchet.py" 2>&1); r1=$?
ck "① 本树退出 0、四项都有计数（$(tr '\n' ' ' <<< "$o1")）" '[ $r1 = 0 ] && [ $(grep -cE "^(计数|提示) " <<< "$o1") = 4 ]'
mkdir -p "$T/tools" "$T/android/native/nvn" "$T/android/native/direct" "$T/graphics/nvn/gfx/nvn" "$T/runtime/src"
cp "$H/tools/android_fork_ratchet.py" "$T/tools/"
printf '#define mtl_a nvn_be_a\n' > "$T/android/native/nvn/nvn_be_compat.h"
printf 'void mtl_go(int x) {\n    switch (x) { case OP_A: break; }\n}\n' > "$T/android/native/direct/x.c"
printf '#ifdef __ANDROID__\nint z;\n#endif\n' > "$T/runtime/src/y.c"
printf 'int w;\n' > "$T/graphics/nvn/gfx/nvn/w.c"
python3 "$T/tools/android_fork_ratchet.py" --write-baseline > /dev/null
printf 'void mtl_go(int x) {\n    switch (x) { case OP_A: break;\n    case OP_B: break; }\n}\n' > "$T/android/native/direct/x.c"
o2=$(python3 "$T/tools/android_fork_ratchet.py" 2>&1); r2=$?
ck "② 加一条 case OP_ → 仍退出 0（rc=${r2}）、提示 op_cases 并点名 x.c（$(tr '\n' ' ' <<< "$o2" | cut -c1-200)）" '[ $r2 = 0 ] && grep -q "提示 op_cases" <<< "$o2" && grep -q "direct/x.c 2" <<< "$o2"'
printf 'void mtl_go(int x) {\n    switch (x) { case OP_A: break; }  // case OP_B 只在注释里\n}\n' > "$T/android/native/direct/x.c"
o3=$(python3 "$T/tools/android_fork_ratchet.py" 2>&1); r3=$?
ck "③ 删回去、注释里的不计 → 退出 0、没有提示（rc=${r3}）" '[ $r3 = 0 ] && ! grep -q "^提示" <<< "$o3"'
printf '#ifdef __ANDROID__\nint z;\n#endif\n#if defined(__ANDROID__)\nint q;\n#endif\n' > "$T/runtime/src/y.c"
o4=$(python3 "$T/tools/android_fork_ratchet.py" 2>&1); r4=$?
ck "④ 共用文件加一处 __ANDROID__ → 仍退出 0（rc=${r4}）、提示 shared_android" '[ $r4 = 0 ] && grep -q "提示 shared_android" <<< "$o4"'
exit $bad
