#!/usr/bin/env python3
# 合并编译等价性核对（gal_offline.py GAL_UNITY_N > 1）：同一份 MSL 逐支编出的 .air 与合编出的 .air，逐个入口函数比 AIR。
# 用法：unity_check.py <逐支编的 msl 目录（含 <键>.air）> <合编的 msl 目录（含 <首键>_u<n>[_<阶段>].air）> [抽样数，缺省全部]
# 比法：air-opt -S 转文本 IR；每个入口（函数名 s<16 位十六进制>…，合编里靠 [[host_name]] 保名）取「闭包」= 入口 + 它直接 / 间接调用的本模块函数 + 引用到的全局常量；
#   符号按首次出现次序改名为 @f0 / @g0…（合编把内部函数包进 namespace，修饰名不同），去掉属性组号 #N 与元数据挂件编号（模块内编号次序不同）；
#   入口的 air.vertex / air.fragment / air.kernel 元数据节点（参数 / 绑定描述）递归展开成文本一并比。
# 输出：比了多少个入口、一致多少、不一致清单（前 20 个，附首个不同行）；退出 0 = 全一致。
import os, re, subprocess, sys, random, concurrent.futures as cf
sdk = os.environ.get('UNITY_CHECK_SDK', 'iphoneos')

def ll_of(air):
    p = subprocess.run(['xcrun', '-sdk', sdk, 'air-opt', '-S', air, '-o', '-'], capture_output=True, text=True)
    if p.returncode: raise RuntimeError(f'air-opt {air}：{p.stderr[-300:]}')
    return p.stdout

_DEF = re.compile(r'^define [^@]*@("?[\w.$"]+"?)\(.*?^\}', re.M | re.S)
_GLB = re.compile(r'^@("?[\w.$"]+"?) = (.*)$', re.M)
_MDN = re.compile(r'^!(\d+) = (.*)$', re.M)
_NAMED = re.compile(r'^!(air\.(?:vertex|fragment|kernel)) = !\{(.*)\}$', re.M)

_TYPE = re.compile(r'^(%[^ ]+) = type (.*)$', re.M)
_NSTY = re.compile(r'%"((?:struct|class|union)\.)n[0-9a-f]{16}\w*::([^"]+)"')
_TYREF = re.compile(r'%(?:"[^"]+"|[\w.]+)')

def tnorm(t):
    # 合编把类型包进 namespace n<键>：%"struct.n<键>::Foo" → %struct.Foo；无引号且含 :: 外的名字照旧
    t = _NSTY.sub(lambda m: '%' + m.group(1) + m.group(2) if re.fullmatch(r'[\w.]+', m.group(2)) else '%"' + m.group(1) + m.group(2) + '"', t)
    # LLVM 对同名不同来源的类型加 .N 去重后缀，编号随模块内出现次序变：去掉（布局另行比）
    return re.sub(r'(%"?(?:struct|class|union)\.[^" ,)]*?)\.\d+(?=["\s,)*]|$)', r'\1', t)

def parse(txt):
    types = {m.group(1): m.group(2) for m in _TYPE.finditer(txt)}   # 原名作键：合编里各文件的同名类型去 namespace 后会撞名
    funcs = {m.group(1).strip('"'): m.group(0) for m in _DEF.finditer(txt)}
    glbs = {m.group(1).strip('"'): m.group(2) for m in _GLB.finditer(txt)}
    md = {m.group(1): m.group(2) for m in _MDN.finditer(txt)}
    ent_md = {}   # 入口名 → 元数据节点号
    for m in _NAMED.finditer(txt):
        for r in re.findall(r'!(\d+)', m.group(2)):
            node = md.get(r, '')
            f = re.search(r'ptr @("?[\w.$"]+"?)', node)
            if f: ent_md[f.group(1).strip('"')] = (m.group(1), r)
    return funcs, glbs, md, ent_md, types

def expand_md(md, r, depth=0, seen=None):
    seen = seen if seen is not None else set()
    if depth > 12 or r in seen: return '!…'
    seen = seen | {r}
    node = md.get(r, '?')
    node = re.sub(r'ptr @("?[\w.$"]+"?)', 'ptr @ENTRY', node, count=1)
    return re.sub(r'!(\d+)', lambda m: '{' + expand_md(md, m.group(1), depth + 1, seen) + '}', node)

def closure(name, funcs, glbs):
    order, seen, stack = [], set(), [name]
    while stack:
        n = stack.pop(0)
        if n in seen: continue
        seen.add(n); order.append(n)
        body = funcs.get(n)
        if body is None: continue
        for r in re.findall(r'@("?[\w.$"]+"?)', body):
            r = r.strip('"')
            if r not in seen and (r in funcs or r in glbs): stack.append(r)
    return order

def canon(name, funcs, glbs, types):
    names = closure(name, funcs, glbs)
    ren = {}
    for n in names:
        if n == name: ren[n] = '@ENTRY'
        elif n in funcs: ren[n] = f'@f{sum(1 for v in ren.values() if v.startswith("@f"))}'
        else: ren[n] = f'@g{sum(1 for v in ren.values() if v.startswith("@g"))}'
    out = []
    for n in names:
        t = funcs[n] if n in funcs else f'@{n} = {glbs[n]}'
        t = re.sub(r'@("?[\w.$"]+"?)', lambda m: ren.get(m.group(1).strip('"'), '@' + m.group(1).strip('"')), t)
        t = re.sub(r' #\d+', '', t)
        t = re.sub(r', ![\w.]+ !\d+', '', t)          # 指令上的元数据挂件（!tbaa !12 等）
        t = re.sub(r' !\w[\w.]* !\d+', '', t)
        t = re.sub(r'^; .*$', '', t, flags=re.M)        # 注释行（函数属性注释等）
        out.append(t.strip())
    # 闭包里用到的结构体类型定义（递归）也一并比，防布局不同；按原名追，输出时再去 namespace
    body = '\n'.join(out); seen = []; todo = [r for r in _TYREF.findall(body) if r in types]
    while todo:
        r = todo.pop(0)
        if r in seen: continue
        seen.append(r); todo += [x for x in _TYREF.findall(types[r]) if x in types and x not in seen]
    return tnorm(body) + ''.join(sorted(f'\nTYPE {tnorm(r)} = {tnorm(types[r])}' for r in seen))

def entries_of(funcs):
    return [n for n in funcs if re.fullmatch(r's[0-9a-f]{16}\w*', n)]

def main():
    d1, d2 = sys.argv[1], sys.argv[2]; k = int(sys.argv[3]) if len(sys.argv) > 3 else 0
    singles = sorted(f for f in os.listdir(d1) if re.fullmatch(r'[0-9a-f]{16}\w*\.air', f))
    batches = sorted(f for f in os.listdir(d2) if re.fullmatch(r'[0-9a-f]{16}_u\d+(?:_[a-z?])?\.air', f))   # 批按阶段拆的子批带 _v / _f / _k 后缀（gal_offline.py，10-24）
    # 合编里退回逐支编的那些也直接是 <键>.air：它们与逐支一致无需比，但要认账
    batch_keys = {}
    with cf.ThreadPoolExecutor(os.cpu_count() or 8) as ex:
        for f, txt in zip(batches, ex.map(lambda f: ll_of(os.path.join(d2, f)), batches)):
            fs, gs, md, em, ty = parse(txt)
            for e in entries_of(fs): batch_keys[e] = (f, fs, gs, md, em, ty)
    if k: random.Random(1).shuffle(singles); singles = singles[:k]
    n = same = 0; diff = []; miss = []
    def one(f):
        txt = ll_of(os.path.join(d1, f)); fs, gs, md, em, ty = parse(txt); res = []
        for e in entries_of(fs):
            if e not in batch_keys: res.append(('miss', e, '')); continue
            bf, bfs, bgs, bmd, bem, bty = batch_keys[e]
            a = canon(e, fs, gs, ty); b = canon(e, bfs, bgs, bty)
            ma = tnorm(expand_md(md, em[e][1])) if e in em else ''; mb = tnorm(expand_md(bmd, bem[e][1])) if e in bem else ''
            if a == b and ma == mb: res.append(('same', e, ''))
            else:
                la, lb = (a + '\nMD ' + ma).split('\n'), (b + '\nMD ' + mb).split('\n')
                i = next((j for j in range(min(len(la), len(lb))) if la[j] != lb[j]), min(len(la), len(lb)))
                res.append(('diff', e, f'{bf} 第 {i} 行：逐支「{la[i][:120] if i < len(la) else "∅"}」 合编「{lb[i][:120] if i < len(lb) else "∅"}」'))
        return res
    with cf.ThreadPoolExecutor(os.cpu_count() or 8) as ex:
        for res in ex.map(one, singles):
            for kind, e, why in res:
                n += 1
                if kind == 'same': same += 1
                elif kind == 'miss': miss.append(e)
                else: diff.append((e, why))
    print(f'unity_check：比了 {n} 个入口（{len(singles)} 支逐支 .air，合编 {len(batches)} 批），一致 {same}，不一致 {len(diff)}，合编里没有 {len(miss)}')
    for e, why in diff[:20]: print(f'  不一致 {e}：{why}')
    for e in miss[:10]: print(f'  合编里没有 {e}（可能该批退回了逐支编）')
    sys.exit(0 if not diff and not miss else 1)

if __name__ == '__main__': main()
