#!/bin/bash
# spirv-cross 按发行版本认身份（translator/dmsh_chain.py spirv_cross_identity，#1133，约 3 秒）：bash tests/dmsh_sc_identity_test.sh
# 本机 Homebrew 的 spirv-cross 拷进临时目录摆成四种布局，期望按构造写死（锁 = dmsh_chain.lock 的 spirv-cross 行）：
#   ① Homebrew Cellar 原文件布局 …/Cellar/spirv-cross/<锁版本>/bin/spirv-cross → 认作锁版本
#   ② S2Arm.app 布局 Runtime/bin/spirv-cross（做一次 codesign --force --sign - 重签）+ Runtime/versions.json（spirvCross = "spirv-cross <锁版本>"）→ 认作锁版本
#   ③ 同一份重签副本放进 …/Cellar/spirv-cross/1.4.357.0/bin/ → 1.4.357.0，与锁不符
#   ④ 裸副本（没有 versions.json、不在 Cellar 下）→ unknown，与锁不符
#   ⑤ 反证：旧逻辑（整文件 sha256 前 16 位）对 ② 的重签副本与原文件给出不同值，即旧锁认不出 App 自带的那份
#   ⑥ versions.json 列了两个版本（打包机装了两份）→ 说不清带的是哪份 → unknown
# 本机没有 spirv-cross 或 codesign 时跳过（退出 75 = 环境未就绪，不当绿；mini 与本机门禁都有，11-01 核；Linux 自检按 tools/contrib_tools.tsv 交 Mac 门禁）。
set -u; H=$(cd "$(dirname "$0")/.." && pwd); PY=${S2A_PY:-$HOME/.s2arm/venv/bin/python3}; [ -x "$PY" ] || PY=python3
SC=$(command -v spirv-cross || true); [ -n "$SC" ] && command -v codesign > /dev/null || { echo "— 本机没有 spirv-cross / codesign，跳过 dmsh_sc_identity_test"; exit 75; }
W=$(mktemp -d "${TMPDIR:-/tmp}/sc_id.XXXXXX"); trap 'rm -rf "$W"' EXIT
LOCKV=$(awk -F'\t' '$1 == "spirv-cross" {print $2}' "$H/translator/dmsh_chain.lock")
mkdir -p "$W/Cellar/spirv-cross/$LOCKV/bin" "$W/Cellar/spirv-cross/1.4.357.0/bin" "$W/Runtime/bin" "$W/Runtime2/bin" "$W/bare"
cp "$SC" "$W/Cellar/spirv-cross/$LOCKV/bin/spirv-cross"
cp "$SC" "$W/Runtime/bin/spirv-cross"; codesign --force --sign - "$W/Runtime/bin/spirv-cross" 2> /dev/null
printf '{"spirvCross": "spirv-cross %s"}\n' "$LOCKV" > "$W/Runtime/versions.json"
cp "$W/Runtime/bin/spirv-cross" "$W/Cellar/spirv-cross/1.4.357.0/bin/spirv-cross"; cp "$W/Runtime/bin/spirv-cross" "$W/bare/spirv-cross"
cp "$W/Runtime/bin/spirv-cross" "$W/Runtime2/bin/spirv-cross"; printf '{"spirvCross": "spirv-cross 1.4.357.0 %s"}\n' "$LOCKV" > "$W/Runtime2/versions.json"
"$PY" - "$H/translator" "$W" "$LOCKV" <<'PYEOF'
import sys, os, hashlib
sys.path.insert(0, sys.argv[1]); import dmsh_chain as c
W, L = sys.argv[2], sys.argv[3]; bad = 0
def ck(ok, what):
    global bad; bad += not ok; print(f'{"✓" if ok else "✗"} {what}')
idf = c.spirv_cross_identity
a = idf(f'{W}/Cellar/spirv-cross/{L}/bin/spirv-cross'); ck(a == L, f'① Cellar 原文件 → {a}（期望 {L}）')
b = idf(f'{W}/Runtime/bin/spirv-cross'); ck(b == L, f'② App 重签副本 + versions.json → {b}（期望 {L}）')
d = idf(f'{W}/Cellar/spirv-cross/1.4.357.0/bin/spirv-cross'); ck(d == '1.4.357.0' and d != L, f'③ 1.4.357.0 → {d}（期望 1.4.357.0，与锁 {L} 不符）')
e = idf(f'{W}/bare/spirv-cross'); ck(e.startswith('unknown: '), f'④ 裸副本 → {e[:20]}…（期望 unknown）')
old = lambda p: hashlib.sha256(open(p, 'rb').read()).hexdigest()[:16]
o1, o2 = old(f'{W}/Cellar/spirv-cross/{L}/bin/spirv-cross'), old(f'{W}/Runtime/bin/spirv-cross')
ck(o1 != o2, f'⑤ 反证：旧逻辑整文件指纹 原文件 {o1} / 重签副本 {o2}（期望不同 = 旧锁拦住 App 自带的那份）')
f = idf(f'{W}/Runtime2/bin/spirv-cross'); ck(f.startswith('unknown: '), f'⑥ versions.json 两个版本 → {f[:20]}…（期望 unknown）')
print(f'{"✓" if not bad else "✗"} dmsh_sc_identity_test：6 项，失败 {bad}'); sys.exit(1 if bad else 0)
PYEOF
