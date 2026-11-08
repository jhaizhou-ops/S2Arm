#!/bin/bash
# 缓存键「烘焙脚本」项单测（graphics/tools/shbake/key_norm.py，约 1 秒）：临时 git 仓库里改文件、提交，比键。期望按规则手写：
#   ① 加整行注释、空行、行尾空白 → 键不变；② 改一行代码 → 变；③ 加 #include / #pragma / #define 行 → 变（预处理行不当注释）；
#   ④ .c 加 // 整行注释 → 不变；⑦ .cs 加 // 整行注释 → 不变、改代码 → 变（10-24 翻译器 C# 源码进着色器键）；⑤ 改的是工作树没提交 → 不变（键按 HEAD）；⑥ 文件改名（内容不变）→ 变（路径进键）
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; bad=0; n=0
ck() { n=$((n + 1)); if [ "$2" = "$3" ]; then echo "✓ $1"; else echo "✗ $1（$2 vs $3）"; bad=$((bad + 1)); fi; }
cd "$T" && git init -q && git config user.email t@t && git config user.name t
printf '#!/bin/bash\n# 说明\necho a\n' > a.sh; printf 'int x = 1;\n' > b.c; git add -A; git commit -qm 0
k() { python3 "$H/key_norm.py" "$T" a.sh b.c; }
cm() { git add -A; git commit -qm x; }
k0=$(k)
printf '#!/bin/bash\n# 说明\n\n# 补一行注释\n   # 缩进注释\necho a   \n\n' > a.sh; cm
ck "① 只加注释 / 空行 / 行尾空白，键不变" "$(k)" "$k0"
printf '#!/bin/bash\n# 说明\necho b\n' > a.sh; cm
k1=$(k); ck "② 改代码行，键变" "$([ "$k1" != "$k0" ] && echo 变 || echo 没变)" 变
printf '#!/bin/bash\n# 说明\necho b\n#include <x>\n' > a.sh; cm
k2=$(k); ck "③ 加 #include 行，键变" "$([ "$k2" != "$k1" ] && echo 变 || echo 没变)" 变
printf '// 注释\nint x = 1;\n// 再一行\n' > b.c; cm
ck "④ .c 加 // 整行注释，键不变" "$(k)" "$k2"
printf 'int x = 2;\n' > b.c
ck "⑤ 工作树改了没提交，键不变（按 HEAD）" "$(k)" "$k2"
git checkout -q b.c; git mv a.sh c.sh; cm
k3=$(python3 "$H/key_norm.py" "$T" c.sh b.c); ck "⑥ 改名、内容不变，键变" "$([ "$k3" != "$k2" ] && echo 变 || echo 没变)" 变
printf 'class A { int x = 1; }\n' > d.cs; cm; k4=$(python3 "$H/key_norm.py" "$T" d.cs)
printf '// 说明\nclass A { int x = 1; }\n    // 缩进注释\n' > d.cs; cm; ck "⑦ .cs 加 // 整行注释，键不变" "$(python3 "$H/key_norm.py" "$T" d.cs)" "$k4"
printf 'class A { int x = 2; }\n' > d.cs; cm; k5=$(python3 "$H/key_norm.py" "$T" d.cs); ck "⑦ .cs 改代码，键变" "$([ "$k5" != "$k4" ] && echo 变 || echo 没变)" 变
echo "t_key_norm：$n 项，失败 $bad"
exit $((bad > 0))
