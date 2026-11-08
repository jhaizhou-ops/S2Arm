#!/usr/bin/env python3
# 门禁手动：要传参数：S2A.ShBake、libnxgal.dylib 和 SPIR-V 目录（两套「按整数位写」判定的对拍），手动跑
# 片元「按整数位写」两套判定的对拍（10-25 总指挥：通用模式 5d 的 FoutStatic 与直连 fout-pso 的 FsUint / FsTyped 共用一条规则，用对拍代替重烘读数）：
#   python3 t_fout_rule.py <S2A.ShBake> <libnxgal.dylib> <SPIR-V 目录或 .spv …>
#   甲：SPIR-V 层 FoutStatic.IntWrittenTargets（S2A.ShBake fout-int-mask-list）——存进颜色输出 Location n 的值来自 int→float 的 OpBitcast → 位 n。
#   乙：同一支经 libnxgal nxgal_dmsh_xc（直连口径的 SPIRV-Cross）翻成 MSL，按直连 Dsh.FsUint 的写法逐个颜色输出看：out.<成员>(.分量) = as_type<float…>(…) → 该成员 [[color(n)]] 的位 n。
#   同一条规则在两层的写法，但乙只认「直接赋值」：SPIRV-Cross 把同一个位转换用到多处时先存进临时变量（float _19 = as_type<float>(…); out.m.x = _19;），
#   乙认不出、甲照认（10-25 手写 int_fs 实测：甲 0x5、乙 0）。所以判据：乙 ⊆ 甲（乙判出的位甲都有；乙多判 = 规则写错，退出 1），乙比甲少的计「乙漏判」逐支列出。
#   只比 as_type 那一条；FsUint 另有「全写常量」的清屏形状，不属本规则，不比。非片元（执行模型 ≠ Fragment）跳过。
#   报：片元支数（分母）、甲乙一致数、其中掩码非 0 的支数、乙漏判 / 乙多判 / MSL 翻译失败各多少（逐支前 20）
import ctypes, os, re, struct, subprocess, sys, tempfile

sb, nxgal, *ins = sys.argv[1:]
files = []
for a in ins:
    if os.path.isdir(a): files += sorted(os.path.join(a, f) for f in os.listdir(a) if f.endswith('.spv'))
    else: files.append(a)
def is_frag(b):   # OpEntryPoint（操作码 15）的第一个操作数是执行模型，Fragment = 4
    if len(b) < 20 or struct.unpack_from('<I', b)[0] != 0x07230203: return False
    i = 5; n = len(b) // 4
    while i < n:
        w = struct.unpack_from('<I', b, 4 * i)[0]; ln, op = w >> 16, w & 0xffff
        if ln == 0: return False
        if op == 15: return struct.unpack_from('<I', b, 4 * i + 4)[0] == 4
        i += ln
    return False
frags = [f for f in files if is_frag(open(f, 'rb').read())]
with tempfile.NamedTemporaryFile('w', suffix='.txt', delete=False) as t: t.write('\n'.join(frags)); lst = t.name
r = subprocess.run([sb, 'fout-int-mask-list', lst], capture_output=True, text=True); os.unlink(lst)
if r.returncode: sys.exit(f'S2A.ShBake fout-int-mask-list 失败：{r.stderr[-400:]}')
spv_mask = {ln.split('\t', 1)[1]: int(ln.split('\t', 1)[0]) for ln in r.stdout.splitlines() if '\t' in ln}
lib = ctypes.CDLL(nxgal)
xc = lib.nxgal_dmsh_xc; xc.argtypes = [ctypes.c_char_p, ctypes.c_uint64, ctypes.c_int32, ctypes.POINTER(ctypes.c_void_p), ctypes.c_char_p, ctypes.c_uint64]; xc.restype = ctypes.c_int32
fr = lib.nxgal_dmsh_xc_free; fr.argtypes = [ctypes.c_void_p]
def msl_mask(src):   # 直连 Dsh.FsUint 的成员与写入匹配（Dsh.cs FsMembers / FsUint 的 as_type 判定），逐个颜色输出给位
    st = re.search(r'struct main0_out\s*\{(.*?)\};', src, re.S)
    if not st: return 0
    m = 0
    for ty, nm, at in re.findall(r'^\s*(\w+)\s+(\w+)\s*(\[\[[^\]]*\]\])?;', st.group(1), re.M):
        c = re.search(r'color\((\d+)\)', at or '')
        if c and ty.startswith('float') and re.search(r'\bout\.' + nm + r'(?:\.\w+)? = as_type<float\d?>\(', src): m |= 1 << int(c.group(1))
    return m
same = nz = fail = 0; miss, extra, bad = [], [], []
for f in frags:
    b = open(f, 'rb').read(); out = ctypes.c_void_p(); err = ctypes.create_string_buffer(512)
    if xc(b, len(b), 0, ctypes.byref(out), err, 512): fail += 1; bad.append((f, err.value.decode()[:80])); continue
    src = ctypes.cast(out, ctypes.c_char_p).value.decode(); fr(out)
    a, c = spv_mask.get(f, -1), msl_mask(src)
    if a == c: same += 1; nz += a != 0
    elif c & ~a: extra.append((f, f'甲 {a:#x}', f'乙 {c:#x}'))
    else: miss.append((f, f'甲 {a:#x}', f'乙 {c:#x}'))
print(f'片元 {len(frags)} 支（共 {len(files)} 支 SPIR-V）：甲乙一致 {same}（其中掩码非 0 {nz}）；乙漏判 {len(miss)}、乙多判 {len(extra)}、MSL 翻译失败 {fail}')
for tag, l in (('乙多判', extra), ('乙漏判', miss), ('MSL 失败', bad)):
    for d in l[:20]: print('  ', tag, *d)
sys.exit(1 if extra or fail else 0)
