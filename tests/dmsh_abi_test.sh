#!/bin/bash
# 门禁覆盖：graphics/tools/direct/dsh/Dsh.cs graphics/nvn/gfx/nvn/nvn_refl.m translator/dmsh_chain.py graphics/nvn/gfx/nvn/dmsh_chain.h tests/dmsh_abi_test.sh
# 宿主与直连库的接口版本纪律（10-30 去全局链号：库版本只跟 dmsh_chain.ABI 走，翻译器改动不再换库目录）。期望按构造写死：
#   ① 出库能写的反射种类除「?」（未实现，宿主绑空槽）外，宿主 nvn_refl.m 都认（isEqualToString:@"<种类>"）——工具新加了宿主不认的种类却没加 ABI，旧宿主就会误读新库；这里先红。
#      11-01 dsh 收敛到 C#：反射由 S2A.Dsh DshCompiler.Reflect 写（离线链 Python reflect 与它的 REFL_KINDS 已删），种类 = Reflect 里每个 Set("kind", …) 第一层的字符串字面量
#      （三目运算的两支都算；嵌套调用里的字面量如 Has(ty, "texture_buffer") 不算）。前提：抽出的种类里有 tex / cbuf / sbuf / img（抽空了不许绿）
#   ② 链头 dmsh_chain.h 的 DMSH_ABI = dmsh_chain.py 的 ABI
#   ③ 反证：在副本的 Reflect 里加一句 e.Set("kind", "t_new_kind") → ① 的判法必须红
set -u; R=$(cd "$(dirname "$0")/.." && pwd); PY=${S2A_PY:-$HOME/.s2arm/venv/bin/python3}
"$PY" - "$R" <<'PYEOF'
import re, sys
R = sys.argv[1]; bad = 0
def kinds_of(src):   # Reflect 方法体里 Set("kind", …) 第一层的字符串字面量；找不到 Reflect → None
    m = re.search(r'internal static List<object> Reflect\(string stage, string msl, JsonObject res\)(.*?)\n        internal static ', src, re.S)
    if not m: return None
    body, out = m.group(1), set()
    for s in re.finditer(r'\bSet\(\s*"kind"\s*,', body):
        i, depth = s.end(), 1
        while i < len(body) and depth:
            c = body[i]
            if c == '"' or body.startswith('@"', i):
                j = i + (2 if c == '@' else 1); verb = c == '@'
                while body[j] != '"' or (not verb and body[j - 1] == '\\'): j += 1
                if depth == 1: out.add(body[i + (2 if verb else 1):j])
                i = j + 1; continue
            depth += c == '('; depth -= c == ')'; i += 1
    return out
dsh = open(f'{R}/graphics/tools/direct/dsh/Dsh.cs').read(); host = set(re.findall(r'isEqualToString:@"([^"]+)"', open(f'{R}/graphics/nvn/gfx/nvn/nvn_refl.m').read()))
def missing(k): return sorted(k - {'?'} - host)
k = kinds_of(dsh)
ok = k is not None and {'tex', 'cbuf', 'sbuf', 'img'} <= k; bad += not ok
print(f'{"✓" if ok else "✗"} ① 前提：从 Reflect 抽出 {len(k or ())} 种反射种类（{sorted(k or ())}），含 tex / cbuf / sbuf / img')
ok = k is not None and not missing(k); bad += not ok
print(f'{"✓" if ok else "✗"} ① 出库能写的 {len(k or ())} 种反射种类宿主都认：宿主不认的 → {missing(k) if k is not None else "（Dsh.cs 里找不到 Reflect）"}（期望 []）')
abi_py = re.search(r'^ABI = (\d+)', open(f'{R}/translator/dmsh_chain.py').read(), re.M); abi_h = re.search(r'#define DMSH_ABI (\d+)', open(f'{R}/graphics/nvn/gfx/nvn/dmsh_chain.h').read())
ok = bool(abi_py and abi_h and abi_py.group(1) == abi_h.group(1)); bad += not ok
print(f'{"✓" if ok else "✗"} ② 链头 DMSH_ABI = dmsh_chain.ABI：期望 {abi_py and abi_py.group(1)} → 真结果 {abi_h and abi_h.group(1)}')
k2 = kinds_of(dsh.replace('e.Set("kind", "support");', 'e.Set("kind", "support"); e.Set("kind", "t_new_kind");', 1))
ok = k2 is not None and missing(k2) == ['t_new_kind']; bad += not ok
print(f'{"✓" if ok else "✗"} ③ 反证：副本加一个宿主不认的种类 → 判出 {missing(k2) if k2 is not None else "（没改到）"}（期望 [\'t_new_kind\']）')
print(f'{"✓" if not bad else "✗"} dmsh_abi_test：4 项，失败 {bad}')
sys.exit(1 if bad else 0)
PYEOF
