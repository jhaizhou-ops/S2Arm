# 包号（内测问题回报要填准，10-23 总指挥）：s2a_build_id <包键 PK> → <代码提交号>-<整串包键（含末尾换行）的 sha256 前 8 位>
#   与产物根 .stage_pkg（ipa.sh 写 echo "$PK"）按文件算的结果相同；写进 IPA 的 Info.plist（S2ABuildID）、pack/oneclick/oneclick.sh 结尾打印同一个
#   公式唯一实现在 pack/ipa_tail.py build_id（Windows 的 Python 编排同用）
_BID_H=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
s2a_build_id() { "${S2A_PY:-python3}" "$_BID_H/ipa_tail.py" build-id "$1"; }
