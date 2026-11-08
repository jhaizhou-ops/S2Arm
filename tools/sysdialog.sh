#!/bin/bash
# 测试机系统弹框分类（tools/dev_run.sh 心跳「前台失焦」时用；10-26 测试机2 挂的是「软件更新」框，旧执行器一律报成「无线数据」，提示 jhz 点错）：
#   sysdialog.sh <整屏截图.png> → 一行「类别<TAB>处理办法<TAB>屏上文字（前 120 字）」
#   类别：无线数据 / 软件更新 / 其他系统框 / 未识别（没截图或没认出字）。认字用 tools/screen_text.swift（系统 Vision，离线），
#   按源码哈希编一次缓存在 S2A_BIN_CACHE（缺省 ~/.s2arm/run/s2arm/bin）；S2A_OCR=<命令> 换认字命令（单测注入，命令收截图路径、往标准输出写文字）
set -u; P=${1:?用法：sysdialog.sh <整屏截图.png>}; H=$(cd "$(dirname "$0")" && pwd)
TXT=
if [ -s "$P" ]; then
  if [ -n "${S2A_OCR:-}" ]; then TXT=$($S2A_OCR "$P" 2> /dev/null)
  else
    K=$(shasum -a 256 < "$H/screen_text.swift" | cut -c1-12); BIN=${S2A_BIN_CACHE:-${S2A_RUN_ROOT:-$HOME/.s2arm/run}/s2arm/bin}/screen_text_$K
    [ -x "$BIN" ] || { mkdir -p "$(dirname "$BIN")" && swiftc -O "$H/screen_text.swift" -o "$BIN.tmp.$$" > /dev/null 2>&1 && mv "$BIN.tmp.$$" "$BIN"; rm -f "$BIN.tmp.$$"; }
    [ -x "$BIN" ] && TXT=$("$BIN" "$P" 2> /dev/null)
  fi
fi
ONE=$(printf '%s' "$TXT" | tr '\n\t' '  ' | cut -c1-120)
case "$TXT" in
  '') printf '未识别\t%s\t\n' "$([ -s "$P" ] && echo "截图没认出字，看 $(basename "$P") 手动处理" || echo "没截到图，到测试机上看屏幕手动处理")";;
  *无线数据*|*无线局域网与蜂窝*|*WLAN与蜂窝*|*"Wireless Data"*|*"WLAN & Cellular"*) printf '无线数据\t请 jhz 选「仅限无线局域网」（点「不允许」挡不住：包名禁网时 App 里一查网络就再弹）\t%s\n' "$ONE";;
  *软件更新*|*可以安装*|*"Software Update"*|*"available to install"*) printf '软件更新\t点「稍后」（别点「现在安装」）\t%s\n' "$ONE";;
  *) printf '其他系统框\t看截图 %s 手动处理\t%s\n' "$(basename "$P")" "$ONE";;
esac
