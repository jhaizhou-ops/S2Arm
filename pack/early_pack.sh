#!/bin/bash
# 出包与装机重叠·早装件（11-06 出包速度线，jhz：玩家都是冷出包，等的是「出包开始 → 能玩」）：pack/early_pack.sh <款> <输出目录>
#   刷新旁路（pack/refresh.sh 快路：改写 / 系统数据 / 能力表 / RomFS 索引）完成、写出 S2A_EARLY_READY 之后由启动器调（pack/jobs/ipa.py installAfter）。
#   这时直连库还在编（十几分钟）；把此刻的现行产物根出成两样东西，让启动器先装 App、先推大头资源：
#     <输出目录>/<款>.ipa   只出程序（pack/ipa.sh S2A_APP_ONLY_FROM：克隆产物根当工作根、组装签名打 ipa，不刷新、不动现行）
#     <输出目录>/pack/      早期资源包（pack/pack.py，来源清单 = pack/pkg_srcs.py srcs 同一份：romfs / exefs/main.npdm / ctl / 系统数据 / 追加内容…；
#                           此刻还没有 shaders/direct，清单里自然没有着色器库），pack/verify.py 逐字节核对
#   最后正式出包完，启动器照常装正式包：pack/jobs/install.py push_pack 按机上已解开的清单（index.applied.tsv）只补差量（着色器库 + 变了的小文件）。
#   现行产物根用 root_cur 取（按本进程钉住：直连链后面几次提交清旧版本时不删这一版），出完即放。任一步红退 1、打【红】行；不改产物根。
set -u
G=${1:?款}; O=${2:?输出目录}
H=$(cd "$(dirname "$0")" && pwd); R=$(cd "$H/.." && pwd); source "$H/roots.sh"
CUR=$(root_cur "$G"); [ -n "$CUR" ] && [ -d "$CUR" ] || { echo "【红】$G 没有现行产物根"; exit 1; }
rm -rf "$O"; mkdir -p "$O" || { echo "【红】建不了 $O"; exit 1; }
t0=$SECONDS
S2A_APP_ONLY_FROM=$CUR S2A_APP_ONLY_OUT=$O S2A_SIGN=${S2A_SIGN:-adhoc} bash "$H/ipa.sh" "$G" > "$O/ipa.log" 2>&1 || { echo "【红】$G 早装只出程序失败（$(grep -a '【红】' "$O/ipa.log" | tail -1 | cut -c1-200)；$O/ipa.log）"; exit 1; }
[ -f "$O/$G.ipa" ] || { echo "【红】$G 早装只出程序没产出 $O/$G.ipa"; exit 1; }
PY=${S2A_PYTHON:-${S2A_PY:-python3}}
"$PY" -c 'import sys; sys.path.insert(0, sys.argv[1]); import pkg_srcs; sys.stdout.write("".join(f"{d}={s}\n" for d, s in pkg_srcs.srcs(sys.argv[2])))' "$H" "$CUR" > "$O/srcs.txt" || { echo "【红】$G 早期资源包来源清单算不出"; exit 1; }
grep -q '^shaders/' "$O/srcs.txt" && { echo "【红】$G 早期资源包来源清单里已有着色器库（现行不是旁路刚完成的那一版？）"; exit 1; }
"$PY" "$H/pack.py" "$O/pack" "@$O/srcs.txt" > "$O/pack.log" 2>&1 || { echo "【红】$G 早期资源包失败（$(tail -1 "$O/pack.log" | cut -c1-200)）"; exit 1; }
"$PY" "$H/verify.py" "$O/pack" "@$O/srcs.txt" > "$O/verify.log" 2>&1 || { echo "【红】$G 早期资源包核对不过（$(tail -1 "$O/verify.log" | cut -c1-200)）"; exit 1; }
echo "🟢 $G 早装件（$((SECONDS - t0)) 秒）：$O/$G.ipa + 早期资源包 $(du -sh "$O/pack" | cut -f1)（不含着色器库），取自 $(basename "$CUR")"
