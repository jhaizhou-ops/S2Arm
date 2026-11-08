#!/bin/bash
# 门禁手动：要私有游戏数据：真实 Ryujinx 数据根 + save-identity.json + G05 导出的 .s2asave（用法见文件头），手动回归
# 用法：设置 S2A_SAVE_TRANSFER_SOURCE（真实 Ryujinx 数据根，只读）、S2A_SAVE_TRANSFER_GAME（匹配游戏的 save-identity.json）、S2A_SAVE_TRANSFER_MAC_ARCHIVE（G05 导出的真实 .s2asave）后运行本脚本。
# Real owned saves stay outside Git. Every mutation is made in a private temporary copy.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${S2A_SAVE_TRANSFER_SOURCE:?需要真实 Ryujinx 数据根（只读）}"
: "${S2A_SAVE_TRANSFER_GAME:?需要匹配游戏的 save-identity.json}"
: "${S2A_SAVE_TRANSFER_MAC_ARCHIVE:?需要 G05 导出的真实 .s2asave}"
"${DOTNET:-$HOME/.dotnet/dotnet}" run --project tests/save_transfer/SaveTransferTest.csproj -c Release -- \
  --source "$S2A_SAVE_TRANSFER_SOURCE" --game "$S2A_SAVE_TRANSFER_GAME" --g05 "$S2A_SAVE_TRANSFER_MAC_ARCHIVE"
