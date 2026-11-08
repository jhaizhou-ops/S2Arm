#!/bin/bash
# 出包·能力清单阶段：pack/stage_caps.sh <款>（10-29 出包线，从改写阶段拆出的轻阶段，几秒）
#   在产物根里出两份清单，同一判定（pack/gen_caps.sh → tools/caps_policy.py）：s2a_caps.tsv = 发布口径（默认开、强信号才关），
#   s2a_caps.all.tsv = --all-caps 测试包口径（有来源即开）。iOS 包 / Mac 宿主 / 安卓包都读 s2a_caps.tsv，ipa.sh --all-caps 换成 .all 那份。
#   键 = 判定代码 + 引擎推导 + 强信号 / 60 帧登记表 + 验证账里本款的行 + 改写阶段键（清单读改写出的宽屏启用表 / 帧率表）+ 强信号失效键（caps_policy.py signal-hash）。
#   原先这份键算在改写阶段的键里（10-29 泛化线 caps-root）：改一行判定代码，每款都整段重改写（几十秒到几分钟），而清单本身只要几秒。
#   安卓（F7 #1574，S2A_PACK_PLAT=android）：改写由 android/tools/make_pack.py 出包时跑、模块不进产物根，没有 .stage_rewrite——
#   键改按「宽屏已验证表的安卓行 + 安卓改写键（改写器源码指纹 + 后端键 + ABI / spin / sdkcut）」；清单首行 plat<TAB>android，
#   命中的安卓验证行写进产物根 widen_verified.tsv（发布缺省关的「真机验过」判据与运行时标记；apple 行不放行安卓包）。
set -u
G=${1:?款}; H=$(cd "$(dirname "$0")" && pwd); R=$(cd "$H/.." && pwd); source "$H/roots.sh"
PY=${S2A_PYTHON:-${S2A_PY:-$(bash "$R/tools/machine.sh" get S2A_PY 2> /dev/null)}}; PY=${PY:-$(command -v python3)}
CUR=$(root_cur "$G"); [ -n "$CUR" ] && [ -f "$CUR/exefs/main" ] || { echo "【红】$G 现行产物根没有 exefs/main"; exit 1; }
source "$H/stage_keyfiles.sh"; stage_deps_on || exit 1; SELF=$(cd "$(dirname "$0")" && pwd)/$(basename "$0")   # 实际读入进键（各阶段同一套，pack/stage_keyfiles.sh）
PID=$("$PY" -c 'import struct,sys; d=open(sys.argv[1],"rb").read(); a=struct.unpack_from("<I",d,0x70)[0]; assert d[a:a+4]==b"ACI0"; print("%016X" % struct.unpack_from("<Q",d,a+0x10)[0])' "$CUR/exefs/main.npdm" 2> /dev/null) || PID=-
TGT=apple; [ "${S2A_PACK_PLAT:-ios}" = android ] && TGT=android   # 清单 / 失效键 / 验证行都按它分平台（caps_policy.py --target）
if [ "$TGT" = android ]; then
  BID=$(xxd -s 0x40 -l 16 -p "$CUR/exefs/main")
  VT="${S2A_WIDEN_DIR:-$R/graphics/widen/tables}/verified.tsv"; VR=$([ -f "$VT" ] && awk -F'\t' -v p="$PID" -v b="$BID" '!/^#/ && toupper($1) == p && tolower($2) == b && tolower($4) == "android" { print; exit }' "$VT")
  ABI=$(awk -F"'" '/^REWRITE_ABI = /{print $2; exit}' "$R/android/tools/make_pack.py"); [ -n "$ABI" ] || { echo "【红】取不到安卓改写 ABI（android/tools/make_pack.py REWRITE_ABI）"; exit 1; }
  SD=$("$PY" "$H/rewriter.py" source) && RK=$("$PY" "$H/rewriter.py" key) || { echo "【红】$G 取不到安卓改写键（pack/rewriter.py source / key）"; exit 1; }
  RWK="target=android rewriter=$SD:$RK abi=$ABI spin=${S2A_REWRITE_SPIN:-0} sdkcut=${S2A_SDK_ADDR_CUT:-1}$([ -n "$VR" ] && printf ' verified=%s' "$(printf '%s' "$VR" | shasum -a 256 | cut -c1-16)")"
else
  RWK=$(cat "$CUR/.stage_rewrite" 2> /dev/null); [ -n "$RWK" ] || { echo "【红】$G 现行产物根还没有改写阶段（能力清单要读改写产物）"; exit 1; }
fi
#   验证账（实测退回，caps_policy fps60_measured）只取本款程序号的行：别的款入账不让本款重出清单（S2A_DEPS_KEYED：清单里不整份记它）
#   判定代码与登记表（caps_policy / caps_ledger / profile_guess 及其导入、名单_*.tsv）按实际读入进键，不再手工列（10-30 根修：名单永远落后于代码）
#   能力的宿主实现文件（caps_policy SIGNAL_IMPL：caps.c / widen.c / nvn_mtl.m …）同理：caps_policy 只按去注释、去日志文本的判定文本读它们，
#   那份判定文本已由下面的强信号失效键（signal-hash）进键；按原始字节再整份记，改一行注释就整段重出清单（10-31 出包线：马车8 只改 caps.c 一行注释，清单重出 46 秒）
SIF=$("$PY" "$R/tools/caps_policy.py" signal-files --target "$TGT") && [ -n "$SIF" ] || { echo "【红】$G 取不到能力实现文件清单（tools/caps_policy.py signal-files --target ${TGT}）"; exit 1; }
export S2A_DEPS_KEYED=docs/名单_验证账.tsv:$SIF
K=$({ grep -i "^$PID	" "$R/docs/名单_验证账.tsv" 2> /dev/null; echo "rewrite=$RWK"
  "$PY" "$R/tools/caps_policy.py" signal-hash --target "$TGT" 2> /dev/null; } | shasum -a 256 | cut -c1-16)   # 强信号失效键（caps_policy SIGNAL_IMPL：满屏 / 60 帧宿主实现 + 数据选择代码，毫秒级）：实现变了，登记的强信号随之失效、清单要重出
KB=$K; K=$(stage_deps_key "$CUR" caps "$KB" "$SELF" "$R/pack/gen_caps.sh") || exit 1
root_stage_done "$CUR" caps "$K" && { echo "🟢 $G 现行已是能力清单 ${K}，跳过"; exit 0; }
TAG=$(root_tag "$G" "caps-${K:0:8}"); W=$(root_begin "$G" "$TAG") || exit 1
# 克隆根可能带别的平台或已撤销的旧标记。必须先清，再按当前安卓验证账重建，
# 让 gen_caps.sh 判定及并发重放都看到本次权威结果；清除失败不能继续出清单。
if [ "$TGT" = android ]; then
  rm -f "$W/widen_verified.tsv" || { echo "【红】$G 清除旧宽屏验证标记失败"; root_abort "$G" "$TAG"; exit 1; }
  if [ -n "$VR" ]; then printf '%s\n' "$VR" > "$W/widen_verified.tsv" || { echo "【红】$G 写安卓宽屏验证标记失败"; root_abort "$G" "$TAG"; exit 1; }; fi
fi
# 两种口径一次判定（gen_caps.sh --both：引擎推导读 RomFS 文件头只做一次，11-03 火纹原先两次各 160 秒）
S2A_CAPS_TARGET=$TGT bash "$R/pack/gen_caps.sh" "$G" "$W" "$W/s2a_caps.tsv" --both "$W/s2a_caps.all.tsv" > "$W/caps.log" 2>&1 \
  || { echo "【红】$G 生成包内能力清单失败（$(tail -1 "$W/caps.log")）"; root_abort "$G" "$TAG"; exit 1; }
K=$(stage_deps_save "$W" caps "$KB" "$SELF" "$R/pack/gen_caps.sh") || { root_abort "$G" "$TAG"; exit 1; }
echo "$K" > "$W/.stage_caps"
[ "$TGT" = android ] && WV=widen_verified.tsv || WV=   # 安卓标记是本阶段产物：重放到新现行时按它换（苹果那份归改写阶段）
ROOT_REPLAY="s2a_caps.tsv s2a_caps.all.tsv caps.log .stage_caps .stage_caps.deps $WV" root_commit "$G" "$TAG" || exit 1
echo "🟢 $G 能力清单（键 ${K}）：$(grep -E '^(widen|fps60)	' "$(root_cur "$G")/s2a_caps.tsv" | cut -f1,2 | tr '\t\n' '= ')"
