#!/bin/bash
# tools/ns2_survey.py 单测：现造最小的合成 exefs（sdk / main 两个 NSO0 + main.npdm）和一棵最小我方源码树，不要游戏。期望按构造手算：
#   sdk：接口 nn::test::IFoo 的客户端代理虚表（RTTI 名 N2nn4test9CmifProxyINS0_4IFooEiEE、偏移到顶 0），前 4 槽是析构 / 引用计数，接口槽 3 个：
#     槽 0 = mov w1,#100; bl → 100；槽 1 = mov w8,#10500; str w8,[sp,#8]; mov w1,#1; bl → 栈传优先 10500；槽 2 = mov w2,#3; mov w3,#2000; bl → 最高号寄存器 2000
#   导出函数：nn::test::Use → bl Helper；Helper：ldr x8,[x0]; ldr x8,[x8,#0x28]; blr x8 → 槽偏移 0x28 → 下标 0x28/8−4 = 1 → 10500；
#     GetOther：同样的虚调用、偏移 0x30 → 下标 2 → 2000，没人调；代码里另有一条 svc #0x20
#   main 导入 nn::test::Use；npdm 许可服务 test:u、系统调用 0x01 / 0x20 / 0x28；我方类 Foo 实现 100（GetThing），Syscall.cs 有 0x01、0x28；外部 Eden 表给 2000 = 空·GetOther
#   ① 代理解码 IFoo = [100, 10500, 2000]
#   ② 10500：Use → Helper 可达、唯一候选 → 游戏可达「是」、我方缺 → P0；2000：封装 GetOther 名字对上、但不可达 → 「否(SDK有封装、游戏不可达)」→ P3；
#      100：我方已实现 → 优先级「—」、名字 = 我方方法名 GetThing
#   ③ 系统调用：缺 0x20（sdk 有这条指令）；0x01 / 0x28 我方有，不报
#   负对照：④ main 不导入 Use → 10500 不再可达（P0 = 0）；⑤ 槽 1 的 str 换成 nop → 解出 1 而不是 10500（栈传解码起作用）；
#          ⑥ 不给 --eden → 2000 没有命令名、封装认不出 → 退回「接口级」P2
# 门禁覆盖：tools/ns2_survey.py tools/nso_sym.py tests/ns2_survey_test.sh
set -u
H=$(cd "$(dirname "$0")/.." && pwd)
PY=${S2A_PY:-$HOME/.s2arm/venv/bin/python3}   # 钉版解释器（capstone / lz4，与改写器同一份 tools/rewriter-requirements.txt）
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
"$PY" - "$H" "$T" << 'EOF'
import os, struct, sys, csv
H, T = sys.argv[1], sys.argv[2]
sys.path.insert(0, os.path.join(H, 'tools'))
import ns2_survey as S

def movz(rd, imm): return 0x52800000 | (imm << 5) | rd
def str_sp(rt, off): return 0xB9000000 | ((off // 4) << 10) | (31 << 5) | rt
def ldr(rt, rn, off): return 0xF9400000 | ((off // 8) << 10) | (rn << 5) | rt
def bl(at, to): return 0x94000000 | (((to - at) // 4) & 0x3ffffff)
BLR8, RET, NOP = 0xD63F0100, 0xD65F03C0, 0xD503201F

def nso(img, path):
    h = bytearray(0x100); h[:4] = b'NSO0'
    struct.pack_into('<III', h, 0x10, 0x100, 0, len(img)); struct.pack_into('<I', h, 0x60, len(img))
    for k in (1, 2):
        struct.pack_into('<III', h, 0x10 + 16 * k, 0x100 + len(img), len(img), 0)
    open(path, 'wb').write(bytes(h) + bytes(img))

def module(code, syms, rel):
    """code：{地址: [指令字]}；syms：[(名, 地址, 长)]（地址 0 = 导入）；rel：[(位置, 目标)] R_AARCH64_RELATIVE。"""
    img = bytearray(0x1000)
    struct.pack_into('<I', img, 4, 0x10); img[0x10:0x14] = b'MOD0'; struct.pack_into('<i', img, 0x14, 0x600 - 0x10)
    for at, ws in code.items():
        for i, w in enumerate(ws): struct.pack_into('<I', img, at + 4 * i, w)
    strtab, names = 0x700 + 24 * (len(syms) + 1), b'\0'
    for k, (n, a, sz) in enumerate(syms, 1):
        struct.pack_into('<IBBHQQ', img, 0x700 + 24 * k, len(names), 0x12, 0, 1 if a else 0, a, sz); names += n.encode() + b'\0'
    img[strtab:strtab + len(names)] = names
    for k, (at, to) in enumerate(rel): struct.pack_into('<QQq', img, 0xC00 + 24 * k, at, 0x403, to)
    for k, (tag, v) in enumerate(((6, 0x700), (5, strtab), (7, 0xC00), (8, 24 * len(rel)), (0, 0))): struct.pack_into('<qQ', img, 0x600 + 16 * k, tag, v)
    return img

def sdk(stack_str=True):
    code = {0x100: [movz(1, 100), bl(0x104, 0x180), RET],
            0x110: [movz(8, 10500), str_sp(8, 8) if stack_str else NOP, movz(1, 1), bl(0x11c, 0x180), RET],
            0x130: [movz(2, 3), movz(3, 2000), bl(0x138, 0x180), RET],
            0x180: [RET],
            0x200: [bl(0x200, 0x210), RET],
            0x210: [ldr(8, 0, 0), ldr(8, 8, 0x28), BLR8, RET],
            0x220: [ldr(8, 0, 0), ldr(8, 8, 0x30), BLR8, RET],
            0x240: [0xD4000001 | (0x20 << 5), RET]}
    img = module(code, [('_ZN2nn4test3UseEv', 0x200, 8), ('_ZN2nn4test6HelperEv', 0x210, 16), ('_ZN2nn4test8GetOtherEv', 0x220, 16)],
                 [(0x448, 0x400), (0x488, 0x440)] + [(0x490 + 8 * i, 0x180) for i in range(4)] + [(0x4b0, 0x100), (0x4b8, 0x110), (0x4c0, 0x130)])
    tn = b'N2nn4test9CmifProxyINS0_4IFooEiEE\0'; img[0x400:0x400 + len(tn)] = tn
    return img

def exefs(name, imports=True, stack_str=True):
    d = os.path.join(T, name); os.makedirs(d)
    nso(sdk(stack_str), os.path.join(d, 'sdk'))
    nso(module({}, [('_ZN2nn4test3UseEv', 0, 0)] if imports else [], []), os.path.join(d, 'main'))
    m = bytearray(0x100); m[:4] = b'META'; struct.pack_into('<I', m, 0x70, 0x80)
    a = 0x80; m[a:a + 4] = b'ACI0'; struct.pack_into('<Q', m, a + 0x10, 0x0100000000ABC000)
    struct.pack_into('<II', m, a + 0x28, 0x40, 7); m[a + 0x40:a + 0x47] = bytes([5]) + b'test:u'
    struct.pack_into('<II', m, a + 0x30, 0x50, 8)
    struct.pack_into('<II', m, a + 0x50, (0 << 29) | ((1 << 1) << 5) | 0x0F, (1 << 29) | (((1 << 8) | (1 << 16)) << 5) | 0x0F)
    open(os.path.join(d, 'main.npdm'), 'wb').write(bytes(m))
    return d

src = os.path.join(T, 'src')
os.makedirs(os.path.join(src, 'Ryujinx.Horizon/Test')); os.makedirs(os.path.join(src, 'Ryujinx.HLE/HOS/Kernel/SupervisorCall'))
open(os.path.join(src, 'Ryujinx.Horizon/Test/Foo.cs'), 'w').write(
    'namespace X\n{\n    partial class Foo : IServiceObject\n    {\n        [CmifCommand(100)]\n        public Result GetThing(out int x)\n        {\n            x = 0;\n'
    '            return Result.Success;\n        }\n    }\n    // Register(new Foo(), ServiceName.Encode("test:u"))\n}\n')
open(os.path.join(src, 'Ryujinx.HLE/HOS/Kernel/SupervisorCall/Syscall.cs'), 'w').write('[Svc(0x01)]\n[Svc(0x28)]\n')
eden = os.path.join(T, 'eden.tsv'); open(eden, 'w').write('接口\t命令号\t实现\t名字\nnn::test::IFoo\t2000\t空\tGetOther\n')
S.MAP['nn::test::IFoo'] = ('test:u', [('Test/Foo.cs', 'Foo')])

ok = bad = 0
def chk(name, cond, got=''):
    global ok, bad
    print(('通 ' if cond else '不通 ') + name + ('' if cond else f'  实得：{got}')); ok += cond; bad += not cond

def rows(res): return {r['cmd']: r for r in res['rows']}

d = exefs('base')
px = S.proxies(S.Module(S.nso_sym.load(os.path.join(d, 'sdk'))))
chk('① 代理解码 IFoo = [100, 10500, 2000]', px.get('nn::test::IFoo') == [100, 10500, 2000], px)
res = S.survey(d, src, eden); r = rows(res)
chk('② 10500：可达「是」、我方缺、P0、调用者 Helper', r[10500]['use'] == '是' and r[10500]['ours'] == '缺' and r[10500]['pr'] == 'P0' and r[10500]['name'] == 'Helper', r.get(10500))
chk('② 2000：有封装不可达、P3、Eden 空·GetOther', r[2000]['use'] == '否(SDK有封装、游戏不可达)' and r[2000]['pr'] == 'P3' and r[2000]['eden'] == '空·GetOther', r.get(2000))
chk('② 100：已实现、优先级 —、名字 GetThing', r[100]['ours'] == '已实现' and r[100]['pr'] == '—' and r[100]['name'] == 'GetThing', r.get(100))
chk('③ 缺 svc 只有 0x20、sdk 有', res['svc_missing'] == [(0x20, True)], res['svc_missing'])
chk('③ test:u 我方已注册、服务都映射到', res['sac_unregistered'] == [] and res['sac_unmapped'] == [], (res['sac_unregistered'], res['sac_unmapped']))
out = os.path.join(T, 'out'); S.write(res, out, src)
tsv = list(csv.DictReader(open(os.path.join(out, 'ns2_survey.tsv'), encoding='utf-8'), delimiter='\t'))
md = open(os.path.join(out, 'ns2_survey.md'), encoding='utf-8').read()
chk('② tsv 3 行、首行 P0 10500', len(tsv) == 3 and tsv[0]['优先级'] == 'P0' and tsv[0]['命令号'] == '10500', tsv[:1])
chk('③ md 列出 P0 行与 svc 0x20', '| P0 | test:u | IFoo | 10500 | Helper | 缺 |' in md and '| 0x20 | 是 |' in md, md[:400])

r = rows(S.survey(exefs('noimp', imports=False), src, eden))
chk('④ 负对照：不导入 Use → 10500 不可达、不是 P0', r[10500]['use'] != '是' and r[10500]['pr'] != 'P0', r.get(10500))
px = S.proxies(S.Module(S.nso_sym.load(os.path.join(exefs('nostack', stack_str=False), 'sdk'))))
chk('⑤ 负对照：去掉 str [sp,#8] → 槽 1 解成 1', px.get('nn::test::IFoo') == [100, 1, 2000], px)
r = rows(S.survey(d, src, None))
chk('⑥ 负对照：不给 Eden → 2000 退回接口级 P2、没有 Eden 列', r[2000]['use'] == '接口级(命名空间有导入)' and r[2000]['pr'] == 'P2' and 'eden' not in r[2000], r.get(2000))
print(f'通 {ok} / {ok + bad}')
sys.exit(1 if bad else 0)
EOF
