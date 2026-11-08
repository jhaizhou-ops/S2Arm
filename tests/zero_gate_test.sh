#!/bin/bash
# 「必须为 0」计数闸门单测（tools/zero_gate.py，手写夹具，约 1 秒）：bash tests/zero_gate_test.sh
# 期望按判据手写：全 0 → 退出 0；现建管线 2（带名字行）→ 红并点名两个管线；未实现服务汇总非空 → 红并带名字；
# 未解析导入 1 → 红并点名模块与导入；未实现系统调用汇总「 0x27×3」→ 红；frames.tsv 缺 xlate_n 列 → 那项算未测、不算红；
# 着色器越界汇总 630 次 / 到上限 3 次 → 红并点名程序与类别；汇总全 0 → 绿
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); bad=0
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
Z() { python3 "$H/tools/zero_gate.py" "$1"; }
mk() {   # mk <目录> <每帧 shader_miss pso_n xlate_n 三列的行…>，host.log 另写
  local d=$1 i=0; shift; mkdir -p "$d"; printf 'frame\tshader_miss\tpso_n\txlate_n\n' > "$d/frames.tsv"
  for r in "$@"; do i=$((i + 1)); printf '%s\t%s\n' "$i" "$r" >> "$d/frames.tsv"; done
}
mkdir -p $T/missing $T/empty $T/header $T/blank $T/invalid
: > $T/empty/host.log
for d in header blank invalid; do : > $T/$d/host.log; printf 'frame\tshader_miss\tpso_n\txlate_n\n' > $T/$d/frames.tsv; done
printf '1\t\t\t\n' >> $T/blank/frames.tsv
printf '1\tbad\tbad\tbad\n' >> $T/invalid/frames.tsv
for d in missing empty header blank invalid; do
  o=$(Z $T/$d); r=$?
  ck "无数字观测 $d → 未测退出 2，不捏造服务 0" '[ $r = 2 ] && [[ "$o" == 未测* ]] && [[ "$o" != *"未实现服务 0"* ]]'
done
printf 'frame\tshader_miss\n1\t3\n' > $T/missing/frames.tsv
o=$(Z $T/missing); r=$?; ck "缺日志但现翻实读 3 → 红项优先退出 1" '[ $r = 1 ] && [[ "$o" == *"现翻着色器 3"* ]]'
printf 'frame\tshader_miss\n1\t0\n' > $T/empty/frames.tsv
o=$(Z $T/empty); r=$?; ck "空日志但有数字 0 → 部分项通过，服务仍未测" '[ $r = 0 ] && [[ "$o" == *"现翻着色器 0"* ]] && [[ "$o" != *"未实现服务 0"* ]]'
SUM0=$'未实现服务：无\n[s2a] 未实现系统调用： 无\n[s2a] 未解析导入：0 个'
mk $T/ok $'0\t0\t0' $'0\t0\t0'; echo "$SUM0" > $T/ok/host.log
o=$(Z $T/ok); r=$?; ck "全 0 → 退出 0（${o}）" '[ $r = 0 ] && [[ "$o" == 🟢* ]]'
mk $T/pso $'0\t2\t0' $'0\t0\t0'; printf '%s\n[gal] 管线现建：顶点 nxgal_blit_vs 片元 nxgal_blit_fs\n[gal] 管线现建：顶点 s1a2b 片元 s3c4d\n' "$SUM0" > $T/pso/host.log
o=$(Z $T/pso); r=$?; ck "现建管线 2 → 红并点名两个（${o}）" '[ $r = 1 ] && [[ "$o" == *"现建管线 2："*nxgal_blit_vs*s1a2b* ]]'
mk $T/svc $'0\t0\t0'; printf '【红】未实现服务：caps:su×3；ns:am2×1；\n[s2a] 未实现系统调用： 无\n[s2a] 未解析导入：0 个\n' > $T/svc/host.log
o=$(Z $T/svc); r=$?; ck "未实现服务汇总非空 → 红并带服务名（${o}）" '[ $r = 1 ] && [[ "$o" == *"未实现服务：caps:su×3"* ]]'
mk $T/imp $'0\t0\t0'; printf '未实现服务：无\n[s2a] 未实现系统调用： 无\n[s2a] 【红】sdk: 导入 nnFooBar 没有任何模块定义\n[s2a] 未解析导入：1 个\n' > $T/imp/host.log
o=$(Z $T/imp); r=$?; ck "未解析导入 1 → 红并点名（${o}）" '[ $r = 1 ] && [[ "$o" == *"未解析导入 1：sdk: 导入 nnFooBar"* ]]'
mk $T/svcall $'0\t0\t0'; printf '未实现服务：无\n[s2a] 未实现系统调用： 0x27×3\n[s2a] 未解析导入：0 个\n' > $T/svcall/host.log
o=$(Z $T/svcall); r=$?; ck "未实现系统调用 0x27×3 → 红（${o}）" '[ $r = 1 ] && [[ "$o" == *"未实现系统调用：0x27×3"* ]]'
mk $T/empty_sc $'0\t0\t0'; printf '【红】未实现：系统调用/TestCall（fixture）\n未实现系统调用：\n' > $T/empty_sc/host.log
o=$(Z $T/empty_sc); r=$?; ck "空系统调用汇总不覆盖逐次红项 → 退出 1" '[ $r = 1 ] && [[ "$o" == *"系统调用：TestCall"* ]] && [[ "$o" != 🟢* ]]'
mkdir -p $T/nocol; printf 'frame\tshader_miss\tpso_n\n1\t0\t0\n' > $T/nocol/frames.tsv; echo "$SUM0" > $T/nocol/host.log
o=$(Z $T/nocol); r=$?; ck "缺 xlate_n 列 → 那项未测、不算红（${o}）" '[ $r = 0 ] && [[ "$o" == *"未测：当场翻译"* ]]'
mk $T/noname $'3\t0\t0'; echo "$SUM0" > $T/noname/host.log
o=$(Z $T/noname); r=$?; ck "现翻 3 但没打名字 → 照样红、注明没打名字（${o}）" '[ $r = 1 ] && [[ "$o" == *"现翻着色器 3：没打名字"* ]]'
mk $T/oob $'0\t0\t0'; printf '%s\n[gal] 【红】着色器越界：程序 00aa11bb22cc33dd 次数 630（常量缓冲、共享内存；次数 = 有越界访问的调用数）\n[gal] 【红】循环到上限：程序 1122334455667788 次数 3（次数 = …）\n[gal] 【红】着色器越界计数（收尾）：越界 1 支 合计 630 次；循环到上限 1 支 合计 3 次（900 支着色器在计）\n' "$SUM0" > $T/oob/host.log
o=$(Z $T/oob); r=$?; ck "越界 630 次 + 到上限 3 次 → 红并点名程序与类别（${o}）" '[ $r = 1 ] && [[ "$o" == *"着色器越界 1 支 630 次：00aa11bb22cc33dd×630（常量缓冲、共享内存）"* ]] && [[ "$o" == *"循环到上限 1 支 3 次：1122334455667788×3"* ]]'
mk $T/oob0 $'0\t0\t0'; printf '%s\n[gal] 着色器越界计数（收尾）：越界 0 支 合计 0 次；循环到上限 0 支 合计 0 次（900 支着色器在计）\n' "$SUM0" > $T/oob0/host.log
o=$(Z $T/oob0); r=$?; ck "越界汇总全 0 → 绿并列出该项（${o}）" '[ $r = 0 ] && [[ "$o" == *"着色器越界 / 循环到上限 0"* ]]'
rm -rf $T; [ $bad = 0 ] && echo "zero_gate 单测全过" || { echo "zero_gate 单测有不通"; exit 1; }
