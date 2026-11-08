#!/usr/bin/env python3
"""社区画面补丁应用层·出包期（直连线 10-27，jhz：社区资源集成进产品；10-30 jhz 改定：玩家包缺省不带上游补丁字节，只在 S2A_COMMUNITY_PATCHES=1 的内部开发 / 测试包里进包（pack/stage_rewrite.sh），宿主设置里运行时启停）：只解析补丁文本、不执行社区的任何脚本。
补丁（pchtxt / IPS）按「程序号 + 模块构建号」匹配本款 NSO；匹配上的每份（编号 × 模块）在改写阶段编成「双路 + 槽」，开关在运行时：
  · 代码段里原字是填充（全 0 / udf）的字：常写（补丁往空闲区写的新代码，关着时没有入口跳过来；照样经过改写器翻译）——改写器 w 行
  · 代码段里有效指令被改的字：双路跳板，读键页槽 2046 的本模块掩码、按本补丁的位分路——改写器 p 行（runtime/rewriter/rewriter.c cpatch_rows，Python 版同字节）
  · 代码段之后（ro / data）的字节：装载器按开关写补丁值或原值（runtime/src/cpatch.c）
  同一处被两份补丁改成不同值、模块内超过 64 份、改写器对某份记了缺口（点已是我方改写点 / 指令要翻译 / 解不出）→ 那份整份不进包，原因记 cpatch_plan.log

  cpatch.py scan <补丁索引目录（含 INDEX.tsv）>… --exefs <exefs 目录>
      标准输出：匹配上的补丁段，一行一段：模块 / 类别 / 段名 / 写入数 / 许可 / 路径
  cpatch.py plan <产物根> <缺省开的编号（逗号分隔，可空）> <补丁索引目录>…
      写 <产物根>/cpatch_rows.tsv（改写器输入，S2A_CPATCH_TSV）与 <产物根>/cpatch.tsv（装载器表）；标准错误：收 / 不收与原因
  cpatch.py prune <产物根>
      读各模块 <模块>.gaps.tsv 里的 cpatch 缺口，把出缺口的补丁记进 <产物根>/cpatch_excluded.tsv；退出码 0 = 没有要剔的，
      10 = 剔了：调用方重跑 plan（冲突重新判：被剔的那份让出位置，先前因与它冲突落选的可以轮上）再重跑改写
cpatch_rows.tsv：w|p <模块> <偏移> <原字> <新字> [位] # <编号>
cpatch.tsv：编号 / 模块 / 位 / 类别 / 段名 / 许可 / 来源 / 数据写入（偏移:原字节:新字节，空格分隔；偏移是模块映像偏移）/ 缺省开（0/1）
编号：<widescreen|fps|gfx>:<补丁内容 sha256 前 16 位，没有用包内路径散列>，与启动器 pack/jobs/community.py 同一算法
pchtxt：@nsobid-<构建号>；行首偏移是含 0x100 文件头的偏移，@flag offset_shift <整数> 从该行起加位移（常见 0x100 即行首就是映像偏移）；@enabled / @disabled 开一段、空行收段、@stop 整个文件到此为止；
  只收字节行（偏移 + 十六进制），字符串行 / 模板占位（{hex1}）/ 其他写法的段整段不收。IPS / IPS32：文件名是构建号，偏移含 0x100 文件头"""
import csv, hashlib, os, re, shutil, struct, subprocess, sys, tempfile
import os as _os, sys as _sys; _sys.path.insert(0, _os.path.join(_os.path.dirname(_os.path.abspath(__file__)), '../tools')); from nso_plain import plain as _nso_plain   # ZBIC（NSO 标志 0x80）先经 nx_unpack 规整成不压缩段，不各写一份解码（tools/nso_plain.py）

HDR = 0x100   # NSO 文件头：IPS 与不带 offset_shift 的 pchtxt 偏移都含它


def module_bid(path):
    """NSO 头 0x40 起 32 字节的构建号（十六进制大写，去掉尾部 0 字节）"""
    return trim(open(path, 'rb').read()[0x40:0x60].hex().upper())


def trim(h):
    h = h.upper()
    while len(h) >= 2 and h.endswith('00'): h = h[:-2]
    return h


def bid_match(ours, patch):
    """补丁写的构建号可短于 32 字节、尾部 0 字节可省（Atmosphere exefs_patches 同口径）"""
    p = trim(patch)
    return len(p) >= 16 and ours.startswith(p)


def parse_pchtxt(text):
    """→ (首个构建号, [{bid, name, enabled, writes, bad}])；每段按自身 bid 匹配。切块即结束上一段，不要求额外 @stop。
    语义同 IPSwitch 规范与 Ryujinx IPSwitchPatcher（11-02 根修，docs/研究/情报/20261028_60帧补丁与宽屏补丁规律.md 2.3 三处出入）：
      @stop：整个文件到此为止（原先只收当前段，之后的 @enabled 会重新开段，作者放在 @stop 后的实验 / 旧版地址被收进包）；
      @flag offset_shift <整数>：十进制或 0x，可为负，从这一行起对后面的行生效（原先全块正则只认 0x100）；行首偏移 + 位移 = 含 0x100 文件头的偏移；
      空行：结束当前段（同 Ryujinx；之后的字节行没有段，不收）。
    """
    blocks, lines, have_bid = [], [], False
    for line in text.splitlines():
        if line.strip().split()[:1] == ['@stop']: break
        if line.strip().startswith('@nsobid'):
            if have_bid: blocks.append('\n'.join(lines)); lines = []
            have_bid = True
        lines.append(line)
    blocks.append('\n'.join(lines))
    secs, first_bid = [], ''
    for block in blocks:
        m = re.search(r'@nsobid-([0-9A-Fa-f]+)', block)
        bid = m.group(1).upper() if m else ''
        cur, name, shift = None, '', 0
        for line in block.splitlines():
            s = line.strip()
            if not s: cur = None; continue
            if s.startswith('//') or s.startswith('#'):
                if s.startswith('//') or s.startswith('#'): name = s.lstrip('/#').strip()
                continue
            if s.startswith('@'):
                w = s.split()[0]
                if w in ('@enabled', '@disabled'): cur = {'bid': bid, 'name': name, 'enabled': w == '@enabled', 'writes': [], 'bad': ''}; secs.append(cur)
                elif w == '@flag':
                    f = s.split()
                    if len(f) >= 3 and f[1] == 'offset_shift':
                        try: shift = int(f[2], 0)
                        except ValueError:
                            if cur is not None: cur['bad'] = cur['bad'] or f'offset_shift 值看不懂：{f[2][:20]}'
                elif not w.startswith('@nsobid'): name = s[1:].strip()
                continue
            if cur is None: continue
            mm = re.match(r'^([0-9A-Fa-f]{8})\s+(\S.*)$', s)
            if not mm: cur['bad'] = cur['bad'] or f'看不懂的行：{s[:40]}'; continue
            v = re.sub(r'\s*//.*$', '', mm.group(2)).strip()
            if not re.fullmatch(r'(?:[0-9A-Fa-f]{2})+', v): cur['bad'] = cur['bad'] or ('字符串 / 模板写法' if v.startswith('"') or '{' in v else f'不是十六进制字节：{v[:20]}'); continue
            off = int(mm.group(1), 16) + shift - HDR
            if off < 0: cur['bad'] = cur['bad'] or '偏移落在文件头里'; continue
            cur['writes'].append((off, bytes.fromhex(v)))
        if not first_bid: first_bid = bid
    return first_bid, secs


def parse_ips(data):
    """→ [(映像偏移, bytes)]；不是 IPS / IPS32 返回 None"""
    if data[:5] == b'PATCH': p, ow, end = 5, 3, b'EOF'
    elif data[:5] == b'IPS32': p, ow, end = 5, 4, b'EEOF'
    else: return None
    out = []
    while p + len(end) <= len(data):
        # 标记也可能是合法偏移；仅末尾（或三字节截断扩展前）才结束。
        if data[p:p + len(end)] == end and len(data) - p - len(end) in (0, 3):
            return out
        if p + ow + 2 > len(data): return None
        off = int.from_bytes(data[p:p + ow], 'big'); n = int.from_bytes(data[p + ow:p + ow + 2], 'big'); p += ow + 2
        if n == 0:
            if p + 3 > len(data): return None
            n = int.from_bytes(data[p:p + 2], 'big'); b = data[p + 2:p + 3] * n; p += 3
        else:
            b = data[p:p + n]; p += n
            if len(b) != n: return None
        if off < HDR: return None
        out.append((off - HDR, b))
    return None   # 没有结束标记 = 截断的补丁（下载 / 拷贝中断），整份不收（审计 #829 F-cpatch-ips-no-eof）


def program_id(npdm):
    b = open(npdm, 'rb').read(); a = struct.unpack_from('<I', b, 0x70)[0]
    return '%016X' % struct.unpack_from('<Q', b, a + 0x10)[0]


def fps_of(*texts):
    """目标帧率：索引 target_fps 列是单个数就用它；否则从路径 / 段名里找「<数> fps」（大小写不论、可带空格或连字符），各处只出现一个数才算；取不到 → None"""
    for t in texts:
        t = (t or '').strip()
        if re.fullmatch(r'\d{2,3}', t): return int(t)
        v = {int(x) for x in re.findall(r'(?<!\d)(\d{2,3})\s*-?\s*fps', t, re.I)}
        if len(v) == 1: return v.pop()
    return None


def romfs_need(path, romfs_roots):
    """补丁要不要 romfs 参数表（我方不打 romfs，要 = 缺）：补丁在「<模组根>/exefs/」下时，同一索引里有「<模组根>/romfs/…」行（不论进没进包）= 要（2）、
    没有 = 不要（0）；不在 exefs/ 目录里（Atmosphere exefs_patches/<名>/<构建号>.ips、压平的路径）看不出模组根 = 判不了（1）"""
    if '/exefs/' not in path: return 1
    return 2 if path.rsplit('/exefs/', 1)[0] in romfs_roots else 0


def scan(index_dirs, exefs):
    """→ [{module, cat, name, writes, license, path, base}]：程序号（前 13 位，含更新 / 追加内容的号）与模块构建号都对上的补丁段（只收开着的段、没有看不懂的行）。
    只比构建号会串款：sdk 等公共模块各游戏同一份二进制、构建号相同（10-27 暗黑3 的 sdk 匹配上古惑狼 / 奥日的帧率补丁）"""
    pid = program_id(os.path.join(exefs, 'main.npdm'))[:13]
    mods = {f: module_bid(os.path.join(exefs, f)) for f in sorted(os.listdir(exefs)) if f not in ('rtld',) and not f.endswith('.npdm') and os.path.isfile(os.path.join(exefs, f))}
    out, skipped, taken = [], {}, {}   # taken：跨目录按编号去重（第二轮合集原样含第一轮文件，两轮同时在盘上时同一份补丁只收一次，否则写入翻倍）；编号 → 选份依据（重复出现时补全判不了的项）
    for base in index_dirs:
        cat = os.path.basename(os.path.normpath(base))
        idx = os.path.join(base, 'INDEX.tsv')
        if not os.path.exists(idx): continue
        seen = set(); rd = csv.DictReader(open(idx, encoding='utf-8', errors='replace'), delimiter='\t')
        # 编号（同启动器 pack/jobs/community.py：表头有 aspect 的是 widescreen、有 target_fps 的是 fps、其余 gfx；补丁内容 sha256 前 16 位，没有就用包内路径散列）
        kind_id = 'widescreen' if 'aspect' in (rd.fieldnames or []) else 'fps' if 'target_fps' in (rd.fieldnames or []) else 'gfx'
        rows = list(rd)
        romfs_roots = {(r.get('path') or '').split('/romfs/')[0] for r in rows if (r.get('title_id') or '').upper()[:13] == pid and '/romfs/' in (r.get('path') or '')}
        for r in rows:
            path = r.get('path') or ''; kind = (r.get('kind') or r.get('type') or '').lower()
            if (r.get('title_id') or '').upper()[:13] != pid: continue
            if path in seen or (r.get('in_pack') or 'yes') != 'yes': continue
            seen.add(path)
            # 社区索引来自下载的包，不当可信清单（审计 #829 F-cpatch-index-trust）：路径规范化后必须仍在索引目录内；
            # 编号取文件内容 SHA-256 前 16 位，索引列（有就核）与内容不符整份不收——合法索引下编号与索引列相同，启动器的编号不变
            root_real = os.path.realpath(base); full = os.path.realpath(os.path.join(base, path))
            if os.path.commonpath([root_real, full]) != root_real or full == root_real:
                skipped['路径逃出索引目录'] = skipped.get('路径逃出索引目录', 0) + 1; continue
            if not os.path.isfile(full): continue
            digest = hashlib.sha256(open(full, 'rb').read()).hexdigest()
            col = (r.get('sha256') or '').strip().lower()
            if col and not (len(col) >= 16 and digest.startswith(col)):
                skipped['索引哈希与内容不符'] = skipped.get('索引哈希与内容不符', 0) + 1; continue
            uid = f"{kind_id}:{digest[:16]}"
            meta = {'fps': fps_of(r.get('target_fps'), path), 'romfs': romfs_need(path, romfs_roots)}
            if uid in taken:
                m0 = taken[uid]
                if m0['fps'] is None: m0['fps'] = meta['fps']
                if m0['romfs'] == 1: m0['romfs'] = meta['romfs']
                continue
            taken[uid] = meta
            if kind == 'pchtxt' or path.endswith('.pchtxt'):
                _, secs = parse_pchtxt(open(full, encoding='utf-8', errors='replace').read())
                for s in secs:
                    ms = [m for m, b in mods.items() if s['bid'] and bid_match(b, s['bid'])]
                    if not ms: continue
                    if not s['enabled'] or not s['writes']: continue
                    if s['bad']: skipped[s['bad'][:12]] = skipped.get(s['bad'][:12], 0) + 1; continue
                    if meta['fps'] is None: meta['fps'] = fps_of(s['name'])
                    out.append({'module': ms[0], 'cat': cat, 'name': s['name'], 'writes': s['writes'], 'license': r.get('license') or '', 'path': path, 'base': base, 'id': uid, 'meta': meta})
            elif kind == 'ips' or path.lower().endswith('.ips'):
                bid = os.path.splitext(os.path.basename(path))[0]
                ms = [m for m, b in mods.items() if re.fullmatch(r'[0-9A-Fa-f]{16,64}', bid) and bid_match(b, bid)]
                if not ms: continue
                w = parse_ips(open(full, 'rb').read())
                if w is None: skipped['IPS 格式不对'] = skipped.get('IPS 格式不对', 0) + 1; continue
                if w: out.append({'module': ms[0], 'cat': cat, 'name': os.path.basename(os.path.dirname(path)), 'writes': w, 'license': r.get('license') or '', 'path': path, 'base': base, 'id': uid, 'meta': meta})
    for k, v in sorted(skipped.items()): print(f'跳过 {v} 段：{k}', file=sys.stderr)
    return out


def nso_image(path):
    """→ (头 0x100 字节, [(段内存偏移, 段字节)×3])，按段解压"""
    b = _nso_plain(open(path, 'rb').read(), path); fl = struct.unpack_from('<I', b, 0xC)[0]; segs = []
    for k in range(3):
        fo, mo, sz = struct.unpack_from('<III', b, 0x10 + 0x10 * k); csz = struct.unpack_from('<I', b, 0x60 + 4 * k)[0]; d = b[fo:fo + csz]
        if fl >> k & 1:
            import lz4.block
            d = lz4.block.decompress(d, uncompressed_size=sz)
        segs.append((mo, d[:sz]))
    return b[:HDR], segs


# —— 数据流旁路检查（11-01 动森 3.0.3 fps:370eb70 冷启 4/4 崩定因后加，通用规则、不按款）——
# 补丁片段在区间里某处 D 设寄存器 R、后面某处 U 读 R（U 处原指令不读 R，是补丁新引入的依赖）：补丁作者假定「到 U 必先经过 D」。
# 若原版代码有路从区间外（直接 b / bl / 条件跳 / 可解析的跳转表 / 区间顶上顺序落入）进到 D 之后、U 之前，那条路上 R 是原代码留下的值
# （动森：原版 7 条路跳到 +0x1468a68 / a6c，绕过 +0x1468a5c 的 ldr x24，+0x1468a74 读 x24(=1)+0x50 崩），且落点上原版已不再用 R（_live_orig：往后先写后读 /
# 到返回都不读）→ 整份不收、原因写进 cpatch_plan.log。落点上原版还读 R = 补丁接着原状态写（动森 SpeedFix +0x7bcd5c 钩子，原指令 str w22,[x21]），不算。
# 补丁后走不到的来源（只能从被补丁改成跳走的指令落下来的原代码）不算入口（is_dead）。
# 换空闲寄存器修不了这一类：旁路上没有任何指令给 U 读的寄存器写补丁要的值，换成哪个寄存器读到的都是原代码的值；换寄存器只能修「补丁写坏
# 原代码还要读的活寄存器」那一类（后续项）。区间 = 本份改动字按间隔 ≤ 0x20 字节聚成的段（含段内没改的原指令）；分析走补丁后的指令流。
# 寄存器读写按操作数位置自己判（capstone 5 的 regs_access / 操作数 access 对 cmp、fmov 立即数、cbz 等是错的，实测），判不准的一律按「既读又写」
# ——对本检查是保守方向（读多 = 候选多；写不算定义 = 往回走不停，旁路照样找得到）
_GAP = 0x20
_FLAGS = 64
_NODEST = {'cmp', 'cmn', 'tst', 'ccmp', 'ccmn', 'fcmp', 'fcmpe', 'fccmp', 'fccmpe', 'cbz', 'cbnz', 'tbz', 'tbnz', 'br', 'blr', 'ret', 'b', 'bl',
           'msr', 'prfm', 'prfum', 'dc', 'ic', 'tlbi', 'at', 'sys', 'hint', 'nop', 'yield', 'wfe', 'wfi', 'sev', 'sevl', 'dmb', 'dsb', 'isb',
           'clrex', 'brk', 'hlt', 'svc', 'hvc', 'smc', 'udf', 'braa', 'brab', 'blraa', 'blrab', 'retaa', 'retab', 'braaz', 'brabz', 'blraaz', 'blrabz'}
_RW = {'movk', 'bfi', 'bfxil', 'bfm', 'bfc'}
_FLAG_W = {'cmp', 'cmn', 'tst', 'ccmp', 'ccmn', 'fcmp', 'fcmpe', 'fccmp', 'fccmpe', 'adds', 'subs', 'ands', 'bics', 'adcs', 'sbcs', 'negs', 'ngcs'}
_FLAG_R = {'csel', 'csinc', 'csinv', 'csneg', 'cset', 'csetm', 'cinc', 'cinv', 'cneg', 'fcsel', 'ccmp', 'ccmn', 'fccmp', 'fccmpe', 'adc', 'adcs', 'sbc', 'sbcs', 'ngc', 'ngcs'}
_ATOMIC = re.compile(r'^(ld(add|clr|eor|set|smax|smin|umax|umin)|swp|cas)[a-z]*$')
_cs = None


def _reg(name):
    """寄存器名 → 编号：x/w 0–30、fp 29、lr 30；b/h/s/d/q/v → 32+n；sp / 零寄存器 → None"""
    if name in ('fp', 'x29', 'w29'): return 29
    if name in ('lr', 'x30', 'w30'): return 30
    m = re.fullmatch(r'([xw])(\d+)|([bhsdqv])(\d+)', name)
    if not m: return None
    return int(m.group(2)) if m.group(1) else 32 + int(m.group(4))


def _rname(r):
    return 'nzcv' if r == _FLAGS else f'x{r}' if r < 32 else f'v{r - 32}'


def _dec(word, addr):
    """→ (读集合, 写集合, 种类, 目标)；种类：seq 顺序 / b 无条件跳 / cond 条件跳（可落下）/ call bl（可落下）/ end 不落下（ret / br / brk / 解不出）"""
    global _cs
    if _cs is None:
        import capstone   # 出包解释器钉死 capstone 5.0.7（tools/rewriter-requirements.txt）；全是 nop 的补丁不走到这里
        _cs = capstone.Cs(capstone.CS_ARCH_ARM64, capstone.CS_MODE_ARM); _cs.detail = True
    from capstone import arm64 as A
    ins = next(_cs.disasm(struct.pack('<I', word), addr), None)
    if ins is None or ins.mnemonic == 'udf': return set(), set(), 'end', None
    m = ins.mnemonic; base = m.split('.')[0]; rd, wr = set(), set(); regs = []; mem = []; has_mem = False
    for o in ins.operands:
        if o.type == A.ARM64_OP_REG:
            r = _reg(ins.reg_name(o.reg))
            if r is not None: regs.append((r, o.vector_index != -1))
        elif o.type == A.ARM64_OP_MEM:
            has_mem = True   # 基址是 sp 时 mem 列表为空，形状判断看这个
            for x in (o.mem.base, o.mem.index):
                r = _reg(ins.reg_name(x)) if x else None
                if r is not None: mem.append(r)
    rd |= set(mem)
    if ins.writeback and mem: wr.add(mem[0])
    if base in _NODEST or base.startswith('b.') or m.startswith('b.'):
        rd |= {r for r, _ in regs}
    elif m.startswith('st') and not m.startswith('stx') and not m.startswith('stlx'):
        rd |= {r for r, _ in regs}
    elif m.startswith(('stx', 'stlx')):
        if regs: wr.add(regs[0][0]); rd |= {r for r, _ in regs[1:]}
    elif _ATOMIC.match(m):
        rd |= {r for r, _ in regs}; wr |= {r for r, _ in regs}
    elif m.startswith('ld') and has_mem:
        lane = any(v for _, v in regs)
        wr |= {r for r, _ in regs}
        if lane: rd |= {r for r, _ in regs}
    elif regs:
        d, lane = regs[0]; wr.add(d); rd |= {r for r, _ in regs[1:]}
        neon = d >= 32 and (lane or re.search(r'\bv\d+\.', ins.op_str))
        if m in _RW or lane or neon: rd.add(d)   # 部分写 / 向量指令目的按读改写算（保守）
    if base in _FLAG_W or m in _FLAG_W: wr.add(_FLAGS)
    if base in _FLAG_R or m.startswith('b.'): rd.add(_FLAGS)
    if m in ('bl', 'blr'): wr.add(30)
    if m == 'ret' and not regs: rd.add(30)
    t = None
    if m in ('b', 'bl') or m.startswith('b.') or base in ('cbz', 'cbnz', 'tbz', 'tbnz'):
        t = ins.operands[-1].imm
    kind = 'b' if m == 'b' else 'call' if m == 'bl' else 'cond' if t is not None else 'end' if m in ('ret', 'br', 'brk', 'hlt') or m.startswith(('ret', 'bra', 'eret')) else 'seq'
    return rd, wr, kind, t


def _branch_pairs(text):
    """原版代码段里所有直接跳转（b / bl / b.cond / cbz / cbnz / tbz / tbnz）→ (目标, 来源) 按目标排好的两列；每模块算一次"""
    try:
        import numpy as np
        w = np.frombuffer(text[:len(text) & ~3], dtype='<u4').astype(np.int64); a = np.arange(len(w), dtype=np.int64) * 4
        b26 = w & 0x3ffffff; b26 = np.where(b26 & 0x2000000, b26 - 0x4000000, b26) * 4
        i19 = (w >> 5) & 0x7ffff; i19 = np.where(i19 & 0x40000, i19 - 0x80000, i19) * 4
        i14 = (w >> 5) & 0x3fff; i14 = np.where(i14 & 0x2000, i14 - 0x4000, i14) * 4
        m26 = (w & 0x7c000000) == 0x14000000; m19 = ((w & 0xff000010) == 0x54000000) | ((w & 0x7e000000) == 0x34000000); m14 = (w & 0x7e000000) == 0x36000000
        src = np.concatenate([a[m26], a[m19], a[m14]]); tgt = np.concatenate([a[m26] + b26[m26], a[m19] + i19[m19], a[m14] + i14[m14]])
        o = np.argsort(tgt, kind='stable'); return tgt[o].tolist(), src[o].tolist()
    except ImportError:
        pairs = []
        for k, (x,) in enumerate(struct.iter_unpack('<I', text[:len(text) & ~3])):
            if (x & 0x7c000000) == 0x14000000: d = (x & 0x3ffffff) - ((x & 0x2000000) << 1)
            elif (x & 0xff000010) == 0x54000000 or (x & 0x7e000000) == 0x34000000: d = ((x >> 5) & 0x7ffff) - (((x >> 5) & 0x40000) << 1)
            elif (x & 0x7e000000) == 0x36000000: d = ((x >> 5) & 0x3fff) - (((x >> 5) & 0x2000) << 1)
            else: continue
            pairs.append((k * 4 + d * 4, k * 4))
        pairs.sort(); return [t for t, _ in pairs], [s_ for _, s_ in pairs]


def _jump_tables(im, text_end, lo, hi, note, pairs=None):
    """[lo, hi) 附近（前后 64 KB）的跳转表 br：认 clang 两种形状「adrp+add 表基 / adr 锚点 / ldrb|ldrh|ldrsw 取项 / add 锚点, 项, lsl|sxtw #k / br」
    （锚点就是表基也认），表长取前面 cmp wI,#N + b.hi / b.hs；本块里没有就看跳进本块的条件跳（cmp wI,#N + b.ls / b.lo 跳来，pairs = _branch_pairs）；→ {目标: [br 地址…]}；形状像跳转表但解不出的记进 note（不当入口）"""
    out = {}; a0 = max(0, lo - 0x10000) & ~3; a1 = min(text_end, hi + 0x10000)
    word = lambda a: struct.unpack_from('<I', im, a)[0]
    for a in range(a0, a1, 4):
        w = word(a)
        if (w & 0xfffffc1f) != 0xd61f0000: continue
        d = (w >> 5) & 31; seq = []
        for k in range(1, 25):
            if a - 4 * k < 0: break
            seq.append((a - 4 * k, _dec(word(a - 4 * k), a - 4 * k)))
        add = next(((p, word(p)) for p, (_, wr, kind, _) in seq if d in wr), None)
        if not add or (add[1] & 0x7f200000) not in (0x0b000000, 0x0b200000): continue   # 不是 add 给出的目标：尾调用之类，跳到函数开头，不算区间内入口
        w2 = add[1]; xa, xb = (w2 >> 5) & 31, (w2 >> 16) & 31
        sh = (w2 >> 10) & 7 if w2 & 0x00200000 else (w2 >> 10) & 63
        def find(r, before):
            return next(((p, word(p)) for p, (_, wr, _, _) in seq if p < before and r in wr), (None, None))
        pl, wl = find(xb, add[0]); tbl = anchor = None; size = None; n = None
        try:
            if wl is None: raise ValueError
            if (wl & 0xffe0fc00) == 0x38606800 or (wl & 0xffe0fc00) == 0x38607800: size, signed = 1, False   # ldrb w, [xT, xI(, lsl #0)]
            elif (wl & 0xffe0ec00) == 0x78606800: size, signed = 2, False                                     # ldrh w, [xT, xI(, lsl #1)]
            elif (wl & 0xffe0ec00) == 0xb8a06800: size, signed = 4, True                                      # ldrsw x, [xT, xI(, lsl #2)]
            else: raise ValueError
            xt, xi = (wl >> 5) & 31, (wl >> 16) & 31
            ix = {xi}   # mov wI, wJ / and xI, xJ, #0xffffffff：表长判 J
            for p, _ in seq:
                x = word(p)
                if p < pl and x & 31 == xi:
                    if (x & 0x7fe0ffe0) == 0x2a0003e0: ix.add((x >> 16) & 31)
                    elif (x & 0xfffffc00) == 0x92407c00: ix.add((x >> 5) & 31)
            def addr_page(q, y): return (q & ~0xfff) + ((((((y >> 5) & 0x7ffff) << 2 | (y >> 29) & 3) ^ 0x100000) - 0x100000) << 12)   # adrp
            def addr_of(r, before):
                p, x = find(r, before)
                if x is None and r >= 19:   # 被调方保留寄存器里的表基：编译器提到函数开头算一次，按地址往回找最近一次写它（最多 4096 条）
                    for q in range(before - 4, max(0, before - 0x4000) - 4, -4):
                        if r in _dec(word(q), q)[1]:
                            p, x = q, word(q)
                            if (x & 0xff800000) == 0x91000000 and (word(q - 4) & 0x9f00001f) == 0x90000000 | ((x >> 5) & 31): return addr_page(q - 4, word(q - 4)) + ((x >> 10) & 0xfff) * (4096 if x & 0x400000 else 1)
                            break
                if x is None: raise ValueError
                if (x & 0x9f000000) == 0x10000000: return p + ((((x >> 5) & 0x7ffff) << 2 | (x >> 29) & 3) ^ 0x100000) - 0x100000   # adr
                if (x & 0xff800000) == 0x91000000:   # add xr, xs, #imm（前面 adrp）
                    q, y = find((x >> 5) & 31, p)
                    if y is None or (y & 0x9f000000) != 0x90000000: raise ValueError
                    return addr_page(q, y) + ((x >> 10) & 0xfff) * (4096 if x & 0x400000 else 1)
                raise ValueError
            tbl = addr_of(xt, pl); anchor = tbl if xa == xt else addr_of(xa, add[0])
            for p, (_, _, kind, _) in seq:
                x = word(p)
                if (x & 0x7f80001f) == 0x7100001f and (x >> 5) & 31 in ix:   # cmp wI, #N
                    nb = next((word(q) & 0xf for q, _ in seq if q > p and (word(q) & 0xff000010) == 0x54000000), None)
                    if nb == 8: n = ((x >> 10) & 0xfff) + 1
                    elif nb == 2: n = (x >> 10) & 0xfff
                    break
            for p, _ in seq:   # and wI, wX, #(2^k - 1)：项数 2^k
                x = word(p)
                if p < pl and (x & 0x7f800000) == 0x12000000 and x & 31 in ix and not n:
                    immr, imms = (x >> 16) & 63, (x >> 10) & 63
                    if immr == 0 and imms < 8: n = 1 << (imms + 1)
            if not n and pairs:   # 取表块是被「cmp wI,#N; b.ls / b.lo 取表块」跳来的
                import bisect
                st = next((p + 4 for p, (_, _, kind, _) in seq if kind in ('b', 'end', 'cond')), seq[-1][0])
                tg, sr = pairs
                for q in sr[bisect.bisect_left(tg, st):bisect.bisect_right(tg, st)]:
                    c = word(q)
                    if (c & 0xff000010) != 0x54000000 or c & 0xf not in (9, 3): continue
                    for k in range(1, 9):
                        x = word(q - 4 * k)
                        if (x & 0x7f80001f) == 0x7100001f and (x >> 5) & 31 in ix:
                            n = ((x >> 10) & 0xfff) + (1 if c & 0xf == 9 else 0); break
                    if n: break
            if not n or tbl < 0 or tbl + n * size > len(im): raise ValueError
            for k in range(n):
                v = int.from_bytes(im[tbl + k * size:tbl + (k + 1) * size], 'little', signed=signed)
                out.setdefault(anchor + (v << sh), []).append(a)
        except (ValueError, struct.error):
            note.append(f'{a:#x}')
    return out


_ARGS = set(range(0, 9)) | set(range(32, 40))                 # 调用时被调方会读：x0–x8、v0–v7
_KEEP = set(range(19, 31)) | set(range(40, 48))                # 被调方保留：x19–x30、v8–v15（过调用不变；返回 / 尾调用时是调用方的值）
_RETV = set(range(0, 8)) | set(range(32, 40)) | _KEEP          # 返回时有意义：返回值 x0–x7 / v0–v7 + 被调方保留的


def _live_orig(im, text_end, t, r, budget=2048):
    """原版程序在 t 处寄存器 r 是否还有用（从 t 往后某条路先读后写）：True 有用 / False 没用；走满预算仍判不出按没用（对本检查是收紧方向：判不安全）。
    调用约定（AAPCS64）：bl / blr 读 x0–x8、v0–v7，冲掉 x9–x17、v16–v31 与标志；ret / br（按尾调用）时返回值与被调方保留的寄存器有用"""
    seen, todo = set(), [t]
    while todo:
        a = todo.pop()
        if a in seen or not (0 <= a < text_end): continue
        seen.add(a)
        if len(seen) > budget: return False
        m = struct.unpack_from('<I', im, a)[0]; rd, wr, kind, tg = _dec(m, a)
        call = kind == 'call' or (m & 0xfffffc1f) == 0xd63f0000   # bl / blr
        if call:
            if r in _ARGS or r in rd: return True
            if r not in _KEEP or r == 30: continue   # 被调用冲掉（x30 由 bl 写返回地址）
        elif r in rd: return True
        elif r in wr: continue
        if kind == 'end':
            if (m & 0xfffffc1f) in (0xd65f0000, 0xd61f0000) and r in _RETV: return True   # ret / br
            continue
        if kind in ('b', 'cond'): todo.append(tg)
        if kind != 'b': todo.append(a + 4)
    return False


def flow_hazard(im, text_end, mod, changed, text_cache):
    """changed：{字地址: (原字, 新字)}（本份补丁代码段里真改了的字）→ 不收原因（空串 = 安全）"""
    if all(nw == 0xd503201f for _, nw in changed.values()): return ''   # 全是 nop：不引入读写
    addrs = sorted(changed); iv = []
    for a in addrs:
        if iv and a - iv[-1][1] <= _GAP: iv[-1][1] = a + 4
        else: iv.append([a, a + 4])
    inside = lambda a: any(s <= a < e for s, e in iv)
    word0 = lambda a: struct.unpack_from('<I', im, a)[0] if 0 <= a and a + 4 <= text_end else 0
    P = lambda a: changed[a][1] if a in changed else word0(a)
    cache = {}
    def dp(a):
        if a not in cache: cache[a] = _dec(P(a), a)
        return cache[a]
    if mod not in text_cache: text_cache[mod] = _branch_pairs(im[:text_end])
    tg, sr = text_cache[mod]; ext = {}
    import bisect
    note = []; jt = {}
    for s, e in iv:   # 按段查：一份补丁的段可能散在整个代码段里
        for k in range(bisect.bisect_left(tg, s), bisect.bisect_left(tg, e)):
            if not inside(sr[k]): ext.setdefault(tg[k], []).append(sr[k])
        for t, ss in _jump_tables(im, text_end, s, e, note, text_cache[mod]).items(): jt.setdefault(t, []).extend(ss)   # 不筛到区间：下面判死代码也要用
    internal = {}
    for s, e in iv:
        for a in range(s, e, 4):
            _, _, kind, t = dp(a)
            if t is not None and kind in ('b', 'cond', 'call'): internal.setdefault(t, []).append(a)
    def falls(a): return (dp(a) if inside(a) else _dec(word0(a), a))[2] not in ('b', 'end')
    def all_preds(x):   # 补丁后的指令流里 x 的全部前驱（任意地址）
        out = [x - 4] if x - 4 >= 0 and falls(x - 4) else []
        out += [s_ for s_ in sr[bisect.bisect_left(tg, x):bisect.bisect_right(tg, x)] if not inside(s_)]
        return out + internal.get(x, []) + jt.get(x, [])
    dead = {}
    def is_dead(src):
        """区间外的来源在补丁后走不到（补丁把它前面的代码改成跳走了：SpeedFix 整段重写后原循环尾 +0x8ce8d8 的回跳）→ 不算入口。
        往回找前驱：碰到区间里的指令、或可能是函数入口（补丁后与原版都没有前驱）、或走满 256 条 → 走得到（保守）。原版有前驱、补丁后全没了
        （唯一的来路是被补丁改掉的跳转：SpeedFix 45 帧把 +0x237531c 的 tbz 改成 msub，+0x23754b8 起的守卫初始化段就走不到了）→ 死代码"""
        if src in dead: return dead[src]
        seen, todo, res = set(), [src], True
        while todo:
            x = todo.pop()
            if x in seen: continue
            seen.add(x)
            if len(seen) > 256: res = False; break
            ps = all_preds(x)
            if any(inside(q) for q in ps): res = False; break
            if not ps and not (x - 4 >= 0 and _dec(word0(x - 4), x - 4)[2] not in ('b', 'end')) and bisect.bisect_left(tg, x) == bisect.bisect_right(tg, x):
                res = False; break   # 原版里也没有前驱（不是落下来的、没有直接跳进来的）：可能是经指针调用的函数入口
            todo += ps
        dead[src] = res
        return res
    def preds(a):
        out = []   # (来源, 是否区间内)
        if inside(a - 4):
            if dp(a - 4)[2] not in ('b', 'end'): out.append((a - 4, True))
        elif a - 4 >= 0 and falls(a - 4) and not is_dead(a - 4): out.append((a - 4, False))
        out += [(s, True) for s in internal.get(a, [])]
        out += [(s, False) for s in ext.get(a, []) + jt.get(a, []) if not is_dead(s)]
        return out
    for u in addrs:
        ow, nw = changed[u]
        new_reads = dp(u)[0] - _dec(ow, u)[0]
        for r in sorted(new_reads):
            pdef, entries, seen, todo = None, [], set(), [(u, x) for x in preds(u)]
            while todo:
                into, (n, inn) = todo.pop()
                if (n, into) in seen: continue
                seen.add((n, into))
                if not inn:   # 从区间外进来：原版在落点上 r 还有用 = 补丁读的是原代码有意义的值（作者接着原状态写），没用 = 读到废值
                    if not _live_orig(im, text_end, into, r): entries.append((n, into))
                    continue
                rd, wr, _, _ = dp(n)
                if r in wr and r not in rd:
                    if n in changed: pdef = pdef or n
                    continue
                todo += [(n, x) for x in preds(n)]
            if pdef and entries:
                entries.sort(key=lambda e: (e[1], e[0])); e0 = entries[0]
                return (f'旁路读寄存器 {mod}+{u:#x} 读 {_rname(r)}：补丁在 +{pdef:#x} 设，原版 {len(entries)} 条路从区间外进到两者之间绕过设置、落点上原版已不用 {_rname(r)}'
                        f'（如 +{e0[0]:#x} → +{e0[1]:#x}；换寄存器补不上这条路上的值）')
    note = sorted(set(note), key=lambda x: int(x, 16))
    if note: print(f'提示：{mod} 补丁区间附近 {len(note)} 处像跳转表的 br 解不出（{" ".join(note[:4])}），未当入口', file=sys.stderr)
    return ''


def plan(root, default_on, index_dirs):
    exefs = os.path.join(root, 'exefs'); log = []
    xp = os.path.join(root, 'cpatch_excluded.tsv')
    excluded = {l.split('\t')[0] for l in open(xp).read().splitlines()} if os.path.exists(xp) else set()
    units = {}   # (编号, 模块) → {cat, name, license, path, writes}
    for c in scan(index_dirs, exefs):
        if c['id'] in excluded: continue
        u = units.setdefault((c['id'], c['module']), {'cat': c['cat'], 'name': c['name'], 'license': c['license'], 'path': c['path'], 'writes': [], 'meta': c['meta']})
        u['writes'] += c['writes']
    # 抢同一处时按目标选，不按索引先后（11-01 总指挥：先到先得 = 随机选，动森收进了 SpeedFix 120 帧版）。排在前面的先占位，后面同处的按「改同一处」落选：
    #   ① 帧率类：目标帧率 = 60 在前，取不到的其次，明确不是 60 的最后（我方目标 60 帧、只提画面帧；非帧率类不参与，视同第一档）
    #   ② 不要 romfs 参数表的在前，判不了的其次，要的最后（我方不打 romfs，缺参数表 = 逻辑速度保证不了）；判不了的若与某份判得了的
    #      写入逐字节相同（同一补丁的 IPS 与 pchtxt 两种格式）就沿用它的结论
    #   ③ 原顺序（索引顺序）作最后的平手规则，结果确定
    def flat(u): return frozenset((o + k, v) for o, b in u['writes'] for k, v in enumerate(b))
    known = {}
    for (uid, mod), u in units.items():
        if u['meta']['romfs'] != 1: known.setdefault((mod, flat(u)), u['meta']['romfs'])
    order = list(units)
    def rank(key):
        uid, mod = key; u = units[key]; m = u['meta']; rf = m['romfs'] if m['romfs'] != 1 else known.get((mod, flat(u)), 1)
        return (0 if not uid.startswith('fps:') or m['fps'] == 60 else 1 if m['fps'] is None else 2, rf, order.index(key))
    ranked = sorted(units, key=rank)
    if ranked != order:
        print('社区补丁按目标排序（帧率 60 优先、不缺 romfs 参数表优先）：' + ' '.join(f"{k[0]}/{k[1]}({units[k]['meta']['fps'] or '?'} 帧，参数表{('不缺', '判不了', '缺')[rank(k)[1]]})" for k in ranked), file=sys.stderr)
    units = {k: units[k] for k in ranked}
    images = {}
    def img(mod):
        if mod not in images:
            _, segs = nso_image(os.path.join(exefs, mod)); end = max(mo + len(d) for mo, d in segs); b = bytearray(end)
            for mo, d in segs: b[mo:mo + len(d)] = d
            images[mod] = (bytes(b), segs[0][0] + len(segs[0][1]))
        return images[mod]
    taken = {}   # 预筛：不带补丁时的改写点（<模块>.sites.tsv）与宽屏候选点（widen_sites.tsv；asp / aspcap 类占两条）——双路字落在这里 = 两套改动叠在同一条指令上，
    def taken_at(mod):   # 不等改写器一轮剔一份（暗黑3 实测 13 轮）；改写器自己那道检查照旧兜底
        if mod not in taken:
            t = set(); sp = os.path.join(root, f'{mod}.sites.tsv'); wp = os.path.join(root, 'widen_sites.tsv')
            if os.path.exists(sp): t |= {int(l.split('\t')[0], 16) for l in open(sp) if l.startswith('0x')}
            if os.path.exists(wp):
                for l in open(wp):
                    c = l.rstrip('\n').split('\t')
                    if len(c) >= 3 and c[0] == mod and c[1].startswith('0x'): o = int(c[1], 16); t.add(o); t.add(o + 4) if c[2] in ('asp', 'aspcap', 'aspcaps') else None
            taken[mod] = t
        return taken[mod]
    fp = os.path.join(root, 'fps.tsv')   # 本款已有我方帧率表（c 行改指令）：社区帧率类不收，免得两套在同一款里各改各的（帧率能耗线 10-27 约定）
    own_fps = os.path.exists(fp) and any(l.split('#', 1)[0].split()[:1] == ['c'] for l in open(fp, encoding='utf-8', errors='replace'))
    claim = {}; bits = {}; rows = []; table = []; branch_cache = {}
    for (uid, mod), u in units.items():
        im, text_end = img(mod); words = {}; data = {}; why = ''
        for off, b in u['writes']:
            if off < 0 or off + len(b) > len(im): why = f'写入 {off:#x}+{len(b)} 超出模块映像'; break
            for k, v in enumerate(b):
                o = off + k
                if o < text_end: w0 = o & ~3; words.setdefault(w0, bytearray(words.get(w0) or im[w0:w0 + 4]))[o - w0] = v
                else: data[o] = v
        if not why:
            for o in list(words) + list(data):
                prev = claim.get((mod, o))
                if prev and prev[0] != uid: why = f'与 {prev[0]} 改同一处 {mod}+{o:#x}'; break
        if not why:   # 数据补丁运行时由装载器写：代码段末页（向上取整到 16 KB 之前）与代码同页、只读可执行，写不了（同 runtime/src/widen.c aspf 的可写范围）
            low = sorted(o for o in data if o < (text_end + 0x3FFF) & ~0x3FFF)
            if low: why = f'数据写入 {mod}+{low[0]:#x} 落在代码段末页上（只读可执行，运行时写不了）'
        if not why:
            hit = sorted(w0 for w0, nb in words.items() if w0 in taken_at(mod) and int.from_bytes(im[w0:w0 + 4], 'little') >> 16)
            if hit: why = f'改到我方改写点 {mod}+{hit[0]:#x}（宽屏点 / x18 等，两套改动叠在同一条指令上）'
        if not why and own_fps and uid.startswith('fps:'): why = '本款已有我方帧率表（fps.tsv），社区帧率类不收'
        if not why and bits.get(mod, 0) >= 64: why = f'{mod} 已有 64 份补丁（槽 2046 位数用尽）'
        if not why:   # 数据流旁路（见 flow_hazard）：补丁设了又读的寄存器，原版有路从区间外跳进两者之间
            ch = {w0: (int.from_bytes(im[w0:w0 + 4], 'little'), int.from_bytes(nb, 'little')) for w0, nb in words.items() if bytes(nb) != im[w0:w0 + 4]}
            if ch: why = flow_hazard(im, text_end, mod, ch, branch_cache)
        if why: log.append(f'不收\t{uid}\t{mod}\t{u["name"][:40]}\t{why}'); continue
        bit = bits.get(mod, 0); bits[mod] = bit + 1
        for o in list(words) + list(data): claim[(mod, o)] = (uid,)
        for w0, nb in sorted(words.items()):
            orig = int.from_bytes(im[w0:w0 + 4], 'little'); new = int.from_bytes(nb, 'little')
            if new == orig: continue
            if orig == 0 or orig >> 16 == 0: rows.append(f'w\t{mod}\t{w0:x}\t{orig:08x}\t{new:08x}\t# {uid}')   # 填充（全 0 / udf #imm16）：常写
            else: rows.append(f'p\t{mod}\t{w0:x}\t{orig:08x}\t{new:08x}\t{bit}\t# {uid}')
        runs, cur = [], None
        for o in sorted(data):
            if cur and o == cur[0] + len(cur[1]): cur[1].append(data[o]); continue
            cur = [o, bytearray([data[o]])]; runs.append(cur)
        dw = ' '.join(f'{o:x}:{im[o:o + len(b)].hex()}:{bytes(b).hex()}' for o, b in runs)
        table.append((uid, mod, bit, u, dw))
        log.append(f'收\t{uid}\t{mod}\t{u["name"][:40]}\t位 {bit}，代码 {len(words)} 字、数据 {len(data)} 字节')
    on = set(x for x in default_on.split(',') if x)
    with open(os.path.join(root, 'cpatch_rows.tsv'), 'w') as f: f.write('\n'.join(rows) + ('\n' if rows else ''))
    with open(os.path.join(root, 'cpatch.tsv'), 'w') as f:
        f.write('编号\t模块\t位\t类别\t段名\t许可\t来源\t数据写入\t缺省开\n')
        for uid, mod, bit, u, dw in table:
            f.write('\t'.join([uid, mod, str(bit), u['cat'], re.sub(r'[\t\n]', ' ', u['name']), u['license'], u['path'], dw, '1' if uid in on else '0']) + '\n')
    with open(os.path.join(root, 'cpatch_plan.log'), 'a') as f: f.write('\n'.join(log) + '\n')
    print(f'社区补丁 {len(units)} 份匹配，进包 {len(table)} 份', file=sys.stderr)
    return 0


def prune(root):
    """改写器对某份补丁记了 cpatch 缺口 → 那份整份剔掉；退出码 10 = 剔了（要重跑改写），0 = 稳定"""
    rp = os.path.join(root, 'cpatch_rows.tsv')
    if not os.path.exists(rp): return 0
    rows = open(rp).read().splitlines(); owner = {}
    for l in rows:
        c = l.split('\t'); owner[(c[1], int(c[2], 16))] = l.rsplit('# ', 1)[-1]
    bad = {}
    for g in os.listdir(root):
        if not g.endswith('.gaps.tsv'): continue
        mod = g[:-len('.gaps.tsv')]
        for l in open(os.path.join(root, g), encoding='utf-8', errors='replace'):
            c = l.rstrip('\n').split('\t')
            if len(c) >= 2 and c[1] == 'cpatch':
                try: o = int(c[0], 16)
                except ValueError: continue
                if (mod, o) in owner: bad.setdefault(owner[(mod, o)], f'{mod}+{o:#x} {c[2] if len(c) > 2 else ""}')
    if not bad: return 0
    with open(os.path.join(root, 'cpatch_excluded.tsv'), 'a') as f: f.write(''.join(f'{k}\t改写器缺口：{v}\n' for k, v in bad.items()))
    with open(os.path.join(root, 'cpatch_plan.log'), 'a') as f: f.write(''.join(f'不收\t{k}\t改写器缺口：{v}\n' for k, v in bad.items()))
    print(f'社区补丁：改写器对 {len(bad)} 份记了缺口，记进排除清单、重跑 plan', file=sys.stderr)
    return 10


def main(a):
    if len(a) >= 3 and a[0] == 'scan' and '--exefs' in a:
        i = a.index('--exefs'); dirs = a[1:i]; exefs = a[i + 1]
        for c in scan(dirs, exefs): print(f"{c['module']}\t{c['cat']}\t{c['name'][:60]}\t{len(c['writes'])}\t{c['license']}\t{c['path']}")
        return 0
    if len(a) >= 3 and a[0] == 'plan': return plan(a[1], a[2], a[3:])
    if len(a) == 2 and a[0] == 'prune': return prune(a[1])
    sys.exit(__doc__)


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
