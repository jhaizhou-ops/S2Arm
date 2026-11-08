#!/bin/bash
# 门禁只看：tools/digest.py tools/layer_map.py tools/layer_map.tsv
# 共用层日摘（tools/digest.py，架构梳理阶段一 S2）单测，约 2 秒：bash tests/digest_test.sh
# 临时 git 仓库 + 真的 layer_map.tsv，提交时间都在 2026-01-02（-0800）。期望按修订稿 4.4.1 + 11-06 总指挥口径（≤60 行：只逐笔列「改接口头 / 冷改动」，其余按模块计数）手写：
#   ① runtime/src/a.c（普通改动）→ 不逐笔列，计进「其余 … runtime/src/ N」
#   ② runtime/include/h.h → 逐笔列，标「改接口头」
#   ③ 提交说明含「🧊冷」、同笔加 docs/坑记录.md → 逐笔列，标「🧊冷；坑记录」
#   ④ android/native/nvn/b.c → 直连 Vulkan 一节计数；graphics/metal/c.m → Metal 一节计数；graphics/metal/d.m + platform/plat.h → 升共用层且逐笔列（改接口头）
#   ⑤ runtime/src/tests/t.c、docs/x.md、tools/y.py → 不进日摘（计进「工具与文档」）
#   ⑥ compat/patches 只改 Backends.Apple → 平台补丁不进；改 Ryujinx.HLE → 共用层计数
#   ⑦ 同标题两笔 → 只算一笔（runtime/src/ 计数里 a.c / 重复标题 / 共 2 笔，不是 3）
#   ⑧ 前一天、后一天的提交不进当天
set -u
H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); bad=0
trap 'rm -rf "$T"' EXIT
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
R=$T/r; mkdir -p "$R/tools" "$R/docs"; git -C "$R" init -q; git -C "$R" config user.email t@t; git -C "$R" config user.name t
cp "$H/tools/digest.py" "$H/tools/layer_map.py" "$H/tools/layer_map.tsv" "$R/tools/"
c() { local when=$1 msg=$2; shift 2; for f in "$@"; do mkdir -p "$R/$(dirname "$f")"; echo "$RANDOM" >> "$R/$f"; done
  git -C "$R" add -A; GIT_AUTHOR_DATE="$when" GIT_COMMITTER_DATE="$when" git -C "$R" commit -qm "$msg"; git -C "$R" rev-parse --short HEAD; }
D='2026-01-02T10:00:00-0800'
c 2026-01-01T10:00:00-0800 '前一天 native' runtime/src/old.c > /dev/null
s1=$(c $D '原生改一' runtime/src/a.c)
s2=$(c $D '接口头改' runtime/include/h.h)
printf '## 坑一\n现象\n' >> "$R/docs/坑记录.md"; s3=$(c $D '🧊冷 原生冷改' runtime/src/e.c)
s4=$(c $D '直连改' android/native/nvn/b.c)
s5=$(c $D 'Metal 改' graphics/metal/c.m)
s6=$(c $D 'Metal 带契约' graphics/metal/d.m platform/plat.h)
s7=$(c $D '只改测试文档工具' runtime/src/tests/t.c docs/x.md tools/y.py)
mkdir -p "$R/compat/patches"; printf -- '--- a/x\n+++ b/ryujinx/tree/src/Ryujinx.Graphics.Nvdec/Backends.Apple/A.cs\n' > "$R/compat/patches/p.patch"; s8=$(c $D '苹果补丁')
printf -- '--- a/x\n+++ b/ryujinx/tree/src/Ryujinx.HLE/B.cs\n' > "$R/compat/patches/q.patch"; s9=$(c $D '共用补丁')
s10=$(c $D '重复标题' runtime/src/f.c); s11=$(c $D '重复标题' runtime/src/g.c)
c 2026-01-03T10:00:00-0800 '后一天 native' runtime/src/new.c > /dev/null
o=$(python3 "$R/tools/digest.py" day 2026-01-02 --repo "$R" --ref HEAD 2>&1); rc=$?
sec() { awk -v h="$1" 'index($0, h) == 1 {f = 1; next} /^## / {f = 0} f' <<< "$o"; }
G=$(sec '## 共用层'); V=$(sec '## 直连 Vulkan'); M=$(sec '## Metal'); N=$(sec '## 不用跟')
ck "① 普通改动不逐笔列、计进 runtime/src/（rc=${rc}）" '[ $rc = 0 ] && ! grep -q "$s1" <<< "$G" && grep -q "其余.*runtime/src/ 2" <<< "$G"'
ck "② 接口头逐笔列" 'grep "$s2" <<< "$G" | grep -q "改接口头"'
ck "③ 冷 + 坑记录逐笔列" 'grep "$s3" <<< "$G" | grep -q "🧊冷；坑记录"'
ck "④ 直连 / Metal 计数；Metal 带 plat.h 升共用层逐笔列" 'grep -q "android/native/nvn/ 1" <<< "$V" && grep -q "graphics/metal/ 1" <<< "$M" && grep "$s6" <<< "$G" | grep -q "改接口头"'
ck "⑤ 单测 / 文档 / 工具不进、计工具与文档" '! grep -q "$s7" <<< "$o" && grep -q "工具与文档 1 笔" <<< "$N"'
ck "⑥ 苹果补丁不进、共用补丁计共用层" 'grep -q "compat/patches/ 1" <<< "$G" && grep -q "平台补丁 1 笔" <<< "$N"'
ck "⑦ 同标题只算一笔（runtime/src/ 2 笔）" 'grep -q "runtime/src/ 2" <<< "$G"'
ck "⑧ 前后一天不进；全文 ≤ 60 行（$(wc -l <<< "$o") 行）" '! grep -q "前一天\|后一天" <<< "$o" && [ $(wc -l <<< "$o") -le 60 ]'
[ $bad = 0 ] && echo "digest 单测全过"; exit $bad
