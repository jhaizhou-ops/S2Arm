#!/bin/bash
# 直连「未守卫新系统 API」棘轮快检（graphics/nvn/tools/avail_count.sh，约 7 秒；11-01 总指挥：gfx 钩子是合入后层的慢步，这项确定性检查放那里，
#   f7e9d0127 带进 2 处未守卫被钩子里的旧红淹没、44 小时没人发现 → 挪进合入前快步，同 tests/mtl4_ratchet_test.sh）：bash tests/avail_ratchet_test.sh
# 门禁只看：graphics/nvn/gfx/nvn/* graphics/nvn/gfx/gl/* graphics/nvn/gfx/tex/* graphics/nvn/Makefile graphics/nvn/tools/avail_count.sh graphics/nvn/tools/avail_baseline.txt
#   需要 iPhoneOS SDK（mini 有）；编不过的文件按「编译出错」退出 2，不当成告警少了
H=$(cd "$(dirname "$0")/.." && pwd)
o=$(bash "$H/graphics/nvn/tools/avail_count.sh" 2>&1); r=$?
echo "$o"
if [ $r = 0 ]; then echo "通 直连未守卫新系统 API 不超基线"; else echo "不通 直连未守卫新系统 API（rc=${r}）"; exit 1; fi
