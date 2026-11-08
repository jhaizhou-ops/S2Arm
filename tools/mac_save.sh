#!/bin/bash
# Mac 局默认存档（10-24 jhz：Mac 局与真机局用同一份正式局存档；原生层线 Mac 跑动森停在新建角色页，因为没带进岛存档）：
#   source tools/mac_save.sh; mac_save_prep <款> <产物根快照> <局目录>
#   调用方没显式给 S2A_SAVE_DIR → 按游戏主程序构建号（exefs/main 0x40 起 16 字节，同 pack/ipa.sh 出真机包取存档的口径）找 <S2A_SAVES>/<款>_<构建号>/，
#   APFS 克隆到 <局目录>/save 再用（原件只读，局里怎么写都只改副本），存档里有 system_time 且调用方没给 S2A_SYSTEM_TIME 就一并带上；
#   显式给了 S2A_SAVE_DIR 的照旧不动；找不到存档就不带（新款 / 没录存档的款）。打一行说明到标准输出
# 存档类型对不上游戏（产物根 ctl/control.nacp：0x3080 账户存档大小、0x3090 设备存档大小）→ 报红、不起局
#   （10-27 动森是设备存档，社区档导入时放成 account/，局里读不到存档、崩在游戏代码里，白跑一局；导入器已改按自有存档定类型，这里是起局前最后一道）
mac_save_kind_ok() {
  local in=$1 s=$2 n=$1/ctl/control.nacp acc dev
  [ -f "$n" ] && [ -d "$s" ] || return 0
  read -r acc dev < <(/usr/bin/python3 -c 'import struct,sys; d = open(sys.argv[1], "rb").read(0x30A0); print(struct.unpack_from("<q", d, 0x3080)[0], struct.unpack_from("<q", d, 0x3090)[0])' "$n" 2> /dev/null) || { echo "【红】存档：读不出 $n 的存档大小（文件截断 / 损坏），不能确认 $s 的类型对不对，不起局"; return 1; }
  [ -d "$s/account" ] && [ "${acc:-0}" -le 0 ] && [ "${dev:-0}" -gt 0 ] && { echo "【红】存档：$s 是 account/，但这款游戏只用设备存档（control.nacp 账户 0、设备 ${dev}），类型放错，不起局"; return 1; }
  [ -d "$s/device" ] && [ "${dev:-0}" -le 0 ] && [ "${acc:-0}" -gt 0 ] && { echo "【红】存档：$s 是 device/，但这款游戏只用账户存档（control.nacp 设备 0、账户 ${acc}），类型放错，不起局"; return 1; }
  return 0
}
mac_save_prep() {
  local g=${1:?款} in=${2:?产物根} d=${3:?局目录} bid sa
  [ -n "${S2A_SAVE_DIR:-}" ] && { mac_save_kind_ok "$in" "$S2A_SAVE_DIR" || return 1; echo "存档：调用方显式给了 S2A_SAVE_DIR=${S2A_SAVE_DIR}，照用"; return 0; }
  [ -f "$in/exefs/main" ] || { echo "存档：产物根没有 exefs/main，不带存档"; return 0; }
  bid=$(xxd -s 0x40 -l 16 -p "$in/exefs/main" 2> /dev/null); sa=${S2A_SAVES:-${S2A_RUN_ROOT:-$HOME/.s2arm/run}/s2arm/saves}/${g}_$bid
  [ -d "$sa" ] || { echo "存档：没有 ${sa}，不带存档"; return 0; }
  local f; for f in 不兼容 待核; do [ -e "$sa/$f.txt" ] && { echo "存档：$(basename "$sa") 有 $f.txt（同 graphics/widen/scan/save_pick.sh：标了不能自动用），不带存档"; return 0; }; done
  mac_save_kind_ok "$in" "$sa" || return 1
  rm -rf "$d/save"; mkdir -p "$d"; cp -cR "$sa" "$d/save" 2> /dev/null || cp -R "$sa" "$d/save" || { echo "【红】存档：拷 $sa 失败"; return 1; }
  export S2A_SAVE_DIR=$d/save
  [ -z "${S2A_SYSTEM_TIME:-}" ] && [ -s "$sa/system_time" ] && export S2A_SYSTEM_TIME=$(cat "$sa/system_time")
  echo "存档：$(basename "$sa") 的副本 → $d/save（原件只读）"
}
