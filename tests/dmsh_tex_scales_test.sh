#!/bin/bash
# 门禁覆盖：graphics/tools/direct/dsh/* graphics/tools/direct/tests/dsh_cmp/* graphics/tools/direct/tests/dshfn.py tests/dmsh_tex_scales_test.sh
# 直连取图倍率表（S2A.Dsh DshCompiler.TexScales，经 dsh_cmp --fn tex_scales，约 10 秒）：bash tests/dmsh_tex_scales_test.sh
# 11-01 dsh 收敛到 C#：出包每键反射由 C# 批量进程做（离线链 dmsh_build.py 的 Python tex_scales 已删），本单测改测 C# 那份，手写期望不变。
# 翻译器给 [render_scale 下标, SPIR-V 绑定号, 是图像]，出库按 Ryujinx 命名（cb<槽>_ / tcb_ + 句柄）拼回贴图名、decode_tex 解出回放槽。期望按 c[2] 句柄表手算（不跑被测实现）：
#   贴图句柄 0xE、cbuf 槽 2：字 14 × 4 = 56 = TEX_BASE 0x20 + 8 × 3 → tex 槽 3
#   贴图句柄 0x10、tcb（cbuf 槽 −1，按 c2）：64 = 0x20 + 8 × 4 → tex 槽 4
#   图像句柄 0x4A、cbuf 槽 2：字 74 × 4 = 0x128 = IMG_BASE 0x120 + 8 × 1 → img 槽 1（同绑定号 5 的贴图与图像靠「是图像」分开）
#   绑定号 9 不在贴图表里 → 不出
# 期望：[[1,'tex',3],[2,'tex',4],[3,'img',1]]。旧代码反证：没有 tex_scales，红。
set -u; H=$(cd "$(dirname "$0")/.." && pwd); PY=${S2A_PY:-$HOME/.s2arm/venv/bin/python3}
got=$("$PY" - "$H" <<'PYEOF'
import os, sys
sys.path.insert(0, os.path.join(sys.argv[1], 'graphics/tools/direct/tests')); import dshfn
res = {'textures': [{'binding': 5, 'cbuf_slot': 2, 'handle': 0xE}, {'binding': 6, 'cbuf_slot': -1, 'handle': 0x10}],
       'images': [{'binding': 5, 'cbuf_slot': 2, 'handle': 0x4A}],
       'tex_scales': [[1, 5, False], [2, 6, False], [3, 5, True], [4, 9, False]]}
r = dshfn.batch([('tex_scales', [res])])[0]
print(r['ok'] if 'ok' in r else f'出错 {r}')
PYEOF
)
want="[[1, 'tex', 3], [2, 'tex', 4], [3, 'img', 1]]"
if [ "$got" = "$want" ]; then echo "通 取图倍率表映射到回放槽（实得：${got}）"; echo "✓ dmsh_tex_scales_test"; exit 0; fi
echo "不通 期望 ${want}，实得 ${got}"; echo "✗ dmsh_tex_scales_test"; exit 1
