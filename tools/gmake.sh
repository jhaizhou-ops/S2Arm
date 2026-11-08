# 开发机工具：取 GNU Make ≥ 4 的路径（出壳等 -j 构建用；玩家出包链不用，不在 userenv 扫描的出包链目录里）。
#   系统 /usr/bin/make 是 3.81：-j 令牌在「最后一个子进程恰在读令牌前退出」时永远等（11-06 出包速度线，docs/坑记录.md）。
#   用法：source tools/gmake.sh; MK=$(s2a_gmake) || exit 1   —— 先认 S2A_GMAKE，再找 PATH 里的 gmake；版本 < 4 或找不到打红、返回 1
s2a_gmake() {
  local mk=${S2A_GMAKE:-$(command -v gmake || true)}
  if [ -n "$mk" ] && "$mk" --version 2>/dev/null | head -1 | /usr/bin/grep -qE 'GNU Make ([4-9]|[1-9][0-9])\.'; then echo "$mk"; return 0; fi
  echo "【红】要 GNU Make 4 以上（gmake）：brew install make；或 S2A_GMAKE 指到它（系统 make 3.81 的 -j 会卡死）" >&2; return 1
}
