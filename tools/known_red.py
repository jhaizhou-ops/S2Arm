#!/usr/bin/env python3
"""main 已知红（10-30 总指挥批）：归责粒度从「步」降到「失败项 + 错误原文」。
门禁一步（如 graphics/gate.sh）里有上百个子检查，main 上其中一项红，原先整步判「main 也红」、所有路由到这一步的批整批挂起。
现在按失败特征比对：批的红只落在 main 已知红的那几项、且错误原文全等 → 不算本批的红；有任何一项对不上 → 照原规则处理。

失败特征：门禁日志里红步（🔴 行及其后「    | 」明细行）中带失败标记的段（按「 / 」切），归一化（临时目录、秒数换占位）后的「项名：错误原文」。
已知红表（tools/train.sh 维护，$TD/known_red.tsv，制表符分隔）：
  步  特征  确认它的 main 提交  登记时刻（秒）  属主线  路由改动集（空格分隔）  上次复核（秒）  上次提醒（秒）
用法：
  known_red.py sig <门禁日志>                       打出「步<TAB>特征」，一行一项
  known_red.py covered <已知红表> <门禁日志>        红步全部有特征、且每一项都在表里（同步同特征）→ 退出 0 并打出命中的项；否则退出 1
  known_red.py register <已知红表> <门禁日志> <main 提交> <仓库> <列车目录> <改动集文件>   把日志里的失败项登记进表（已有的不重复，属主按 owner 推）；打出「步<TAB>特征<TAB>属主线」
  known_red.py remind <已知红表> <小时> <间隔小时>  该提醒的已知红项（不稳定项不催，由 expire 撤）打「步<TAB>特征<TAB>属主<TAB>已挂小时」并记提醒时刻
  known_red.py steps <已知红表>                    表里的步与路由改动集（复核用）
  known_red.py hist-add <记录> <日志> <成员>        失败项记进近 48 小时失败记录（成员 = 本批各支，逗号分隔；干净 main 写 @main）
  known_red.py classify <表> <记录> <日志> <成员> [小时]  每个失败项判 已知 / 不稳定（近 24 小时在不含本批的批或 main 上出现过）/ 新
  known_red.py expire <表> <记录> <小时>            「不稳定」项近 <小时> 没再出现 → 撤销
已知红表第 9 列 = 类别（已知红 / 不稳定），缺省已知红
  known_red.py uncovered <已知红表> <门禁日志>      红步里有失败项不在表里的步（含取不出明细的），一行一个；空 = 红全是已知红
  known_red.py generic <门禁日志>                  红了但取不出失败项明细的步
  known_red.py owner <仓库> <列车目录> <步> <特征>  这项失败对应的单测文件最后经列车合入的那支的属主线
  known_red.py recheck <已知红表> <步> <复核日志>   用干净 main 上这一步的复核日志更新：步绿或某项不再出现 → 撤销那几项（打出「撤<TAB>步<TAB>特征<TAB>属主线」）；
                                                    仍红的项记上次复核时刻
"""
import os, re, sys, time

STEP = re.compile(r'^\s*(↳ )?(🔴|🟢|⏹|🟡) (.+?)(?:［[^］]*］)? (\d+) 秒')
FAIL = re.compile(r'（退出 [1-9]\d*）|✗|失败 [1-9]|不通|有失败|→ 红|【红】|Error|Traceback')
RUNLOG = re.compile(r'^\s*\[[A-Za-z][A-Za-z0-9_.-]*\] ')   # 运行时诊断行的标签前缀：[s2a] / [dm] / [nvn] / [nvn-mtl] …，不是判定结果
LIMIT = re.compile(r'(\d+)\s*（基线\s*≤\s*(\d+)')   # 「227（基线 ≤ 226）」：超基线也是失败项（gfx 钩子的计数类判据不带退出码）


def isfail(seg):
    if FAIL.search(seg): return True
    return any(int(n) > int(m) for n, m in LIMIT.findall(seg))


TMP = re.compile(r"(?:/private)?/var/folders/[^/\s]+/[^/\s]+/T/[^/\s'\",)）]+|/tmp/[^/\s'\",)）]+")   # 只换随机的临时目录那一级，后面的路径（链号目录等）保留


# 易变数字换占位符（10-30 总指挥：「line 26: 49158 Abort trap」带进程号，同一项下次红对不上登记 → 冤退）；
#   只换天然随机的（进程号 / 地址 / 时刻 / 时间戳），判据里的计数、基线、期望值、真结果不动
VOLATILE = [
    (re.compile(r'(line \d+: )\d+( (?:Abort trap|Segmentation fault|Killed|Terminated|Bus error|Illegal instruction|Trace/BPT trap|Hangup))'), r'\1<pid>\2'),
    (re.compile(r'\b(pid|PID)([ =:：]?)\d+'), r'\1\2<pid>'),
    (re.compile(r'(进程 ?)\d{2,}'), r'\1<pid>'),
    (re.compile(r'0x[0-9a-fA-F]{6,}'), '0x<addr>'),
    (re.compile(r'\b\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}(\.\d+)?\S*'), '<time>'),
    (re.compile(r'\b\d{1,2}:\d{2}:\d{2}(\.\d+)?\b'), '<time>'),
    (re.compile(r'\b1[6-9]\d{8}(\.\d+)?\b'), '<ts>'),
]


def SUMMARY(s):   # 汇总行：带「有不通 / 有失败」，又没有任何具体失败标记
    return bool(re.search(r'有不通|有失败', s)) and not re.search(r'（退出 [1-9]|✗|失败 [1-9]|→ 红|【红】|Error|Traceback|^不通 |\d+\s*（基线', s)


def norm(s):
    s = TMP.sub('<tmp>', s)
    for r_, t_ in VOLATILE: s = r_.sub(t_, s)
    s = re.sub(r'\d+(\.\d+)? 秒', 'N 秒', s)
    s = re.sub(r'\s+', ' ', s).strip(' ✗')
    return s


def failures(log):
    """{步: [特征…]}：每个红步的失败项；红步没有可取的明细 → 列表为空（覆盖不了，照原规则处理）"""
    out, cur, last = {}, None, None
    for l in open(log, encoding='utf-8', errors='replace'):
        l = l.rstrip('\n')
        m = STEP.match(l)
        if m:
            if m.group(1):   # 「↳ 本机另跑 …」子项（父步那行可能是绿的）：红就归它上面那一步
                cur = last if m.group(2) == '🔴' else None
            else:
                last = m.group(3); cur = last if m.group(2) == '🔴' else None
            if cur: out.setdefault(cur, [])
            continue
        if cur and l.startswith('    | '):
            body = re.sub(r'\s*✗\s*$', '', l[6:])   # 行尾的 ✗ 标的是整步红，不是最后那一项
            for seg in body.split(' / '):   # 不按「｜」切：子项自己的明细（如 ①191/300 …｜有失败）要整段留在一起，否则只剩一句「有失败」、谁都配得上
                seg = re.sub(r'^.*?→ 真结果 ', '', seg)   # 「期望 … → 真结果 」前缀不进特征：同一项不论排第几段特征都一样
                if re.match(r'\s*(通|✓|PASS)\b', seg): continue
                if RUNLOG.match(seg): continue   # 运行日志旁白（11-05 能耗线：「[s2a] 【红】地址窗口：读不到本款 main.npdm」每个不占窗口的单测进程都会打、单测照样过，跟着红组的日志尾巴带出来，被当成失败特征登记成不稳定）   # 通过的用例行（如「通 …失败：照跑…没有【红】」）字面带失败字样也不是失败项（10-30 mac_slot_test）
                if isfail(seg):
                    s = norm(seg)
                    # 汇总行（只有「有不通 / 有失败」这类汇总字样、没有任何具体失败标记，如「排查手册自检有不通」）不算失败项：谁的红都配得上，登记也不收；
                    #   10-30 先按「去掉失败字样不足 10 字」判，把「B 项：坏了（退出 1）」这种短而真的失败项也滤掉了 → 真红按已知红放行（train_test 已知红③）
                    # 通过的结果段（带 ✓、不带 ✗，如「过 47、不通 0 ✓」）不是失败项（10-30 回放：「不通」二字让它被当成失败，登记对不上）
                    if s and not ('✓' in s and '✗' not in s) and not SUMMARY(s) and s not in out[cur]: out[cur].append(s)
        elif not l.startswith('    '):
            cur = None if not l.startswith(('🔴', '🟢')) else cur
    return out


def owner_of(repo, td, step, sig):   # owner <仓库> <列车目录> <步> <特征>：这项失败对应的单测文件（步是钩子时，在钩子源码里找写着这项名字的那行点名的文件；
    #   步是「单测 x」就是 tests/x.sh；都找不到就用钩子文件本身）最后一次经列车合进 main 的那支的属主线；找不到打空
    import subprocess, glob
    cand = []
    if step.startswith('钩子 '):
        hook = step[3:]; label = sig.split('：')[0].strip()
        try:
            for l in open(os.path.join(repo, hook), encoding='utf-8', errors='replace'):
                if label and label in l: cand += re.findall(r'[A-Za-z0-9_./-]+\.(?:py|sh|m|c|cs)\b', l)
        except OSError: pass
        cand.append(hook)
    elif step.startswith('单测 '): cand.append(f'tests/{step[3:]}.sh')
    for f in cand:
        f = f.lstrip('./')
        if not os.path.exists(os.path.join(repo, f)): continue
        subj = subprocess.run(['git', '-C', repo, 'log', '-1', '--first-parent', '--format=%s', 'HEAD', '--', f], capture_output=True, text=True).stdout
        m = re.search(r"Merge branch '([^']+)'", subj)
        if not m: continue
        for d in sorted(glob.glob(os.path.join(td, 'done', '*')), key=os.path.getmtime, reverse=True):
            try:
                for l in open(d, encoding='utf-8', errors='replace'):
                    c = l.rstrip('\n').split('\t')
                    if m.group(1) in c and c.index(m.group(1)) + 1 < len(c): return c[c.index(m.group(1)) + 1]
            except OSError: pass
    return ''


def load(kr):
    rows = []
    if os.path.exists(kr):
        for l in open(kr, encoding='utf-8'):
            c = l.rstrip('\n').split('\t')
            if len(c) >= 8: c[1] = norm(c[1]); rows.append(c)   # 旧登记行也按当前口径归一化（规则加严后旧行仍能对上）
    return rows


HEADER = """# main 已知红 / 不稳定登记（tools/known_red.py 维护；# 开头的行不是登记，load 跳过）
# 列：步 / 特征 / 登记时 main 提交 / 登记时刻 / 属主线 / 路由改动集 / 上次提醒 / 复核计数 / 类别（已知红 | 不稳定）
# 规矩（10-30 总指挥，jhz「不稳定的测试不应该根修么」）：登记只是止血，不算完。
#   不稳定：属主 24 小时内必须有根修分支在队（把按时长的等待改成按事件同步、在高负载下复现到 0 红），否则升级总指挥；
#   根修合入后删登记。已知红：main 红了，弄红的属主当轮修。
"""


def save(kr, rows):
    tmp = kr + '.tmp'
    with open(tmp, 'w', encoding='utf-8') as f:
        f.write(HEADER)
        for c in rows: f.write('\t'.join(c) + '\n')
    os.replace(tmp, kr)


def main():
    a = sys.argv[1:]
    if not a: sys.exit(__doc__)
    if a[0] == 'sig':
        for st, ss in failures(a[1]).items():
            for s in ss: print(f'{st}\t{s}')
    elif a[0] == 'covered':
        known = {(c[0], c[1]) for c in load(a[1])}
        f = failures(a[2])
        if not f or any(not ss for ss in f.values()): sys.exit(1)
        hit = [(st, s) for st, ss in f.items() for s in ss]
        if all(h in known for h in hit):
            for st, s in hit: print(f'{st}\t{s}')
            return
        sys.exit(1)
    elif a[0] == 'uncovered':   # 红步里不是全部失败项都已知的步（含取不出明细的红步），一行一个；空 = 这份日志的红全是 main 已知红
        # 门禁末行「红步<TAB>…」里的步也算：提不出失败项的红步（退出 75、超时、宿主证明之类没有 🔴 明细行的）原先看不见，
        #   空输出被当成「全是已知红」照合（10-30 kr-header 后登记表恒非空，env75 / 缺宿主证明的支被这样放进 main）；
        #   一个红步都没有、也一项失败都提不出 → 打「?」，调用方一律不当已知红
        known = {(c[0], c[1]) for c in load(a[1])}; fl = failures(a[2]); rs = []
        for l in open(a[2], encoding='utf-8', errors='replace'):
            if l.startswith('红步\t'): rs = [x for x in l.rstrip('\n').split('\t')[1:] if x]
        out = [st for st in dict.fromkeys(rs + list(fl)) if not fl.get(st) or any((st, x) not in known for x in fl[st])]
        if not rs and not any(fl.values()): out = ['?']
        for st in out: print(st)
    elif a[0] == 'generic':   # 红了但取不出任何失败项明细的步（整步超时 / 只打一行）：这种只能按步处理（原挂起规则）
        for st, ss in failures(a[1]).items():
            if not ss: print(st)
    elif a[0] == 'owner':
        print(owner_of(*a[1:5]))
    elif a[0] == 'hist-add':   # hist-add <记录> <日志> <本批成员，逗号分隔；干净 main 写 @main>：失败项记进近期失败记录（只留近 48 小时）
        hp, log, mem = a[1:4]; now = int(time.time()); keep = []
        if os.path.exists(hp):
            keep = [l for l in open(hp, encoding='utf-8') if l.split('\t')[0].isdigit() and now - int(l.split('\t')[0]) < 48 * 3600]
        for st, ss in failures(log).items():
            for x in ss: keep.append(f'{now}\t{st}\t{x}\t{mem}\n')
        tmp = hp + '.tmp'; open(tmp, 'w', encoding='utf-8').write(''.join(keep)); os.replace(tmp, hp)
    elif a[0] == 'classify':   # classify <已知红表> <记录> <日志> <本批成员，逗号分隔> [小时，缺省 24]：每个失败项打「类<TAB>步<TAB>特征」，类 = 已知 / 不稳定 / 新；
        #   不稳定 = 近 <小时> 小时里在「不含本批任何一支」的批或干净 main 上出现过同步同特征的失败；红步取不出明细打「新<TAB>步<TAB>」
        kr, hp, log, mem = a[1:5]; hrs = float(a[5]) if len(a) > 5 else 24.0
        known = {(c[0], c[1]) for c in load(kr)}; me = {x for x in mem.split(',') if x}; now = int(time.time()); seen = set()
        if os.path.exists(hp):
            for l in open(hp, encoding='utf-8'):
                c = l.rstrip('\n').split('\t')
                if len(c) < 4 or not c[0].isdigit() or now - int(c[0]) > hrs * 3600: continue
                if c[3] == '@main' or not (me & {x for x in c[3].split(',') if x}): seen.add((c[1], c[2]))
        for st, ss in failures(log).items():
            if not ss: print(f'新\t{st}\t'); continue
            for x in ss: print(f'{"已知" if (st, x) in known else "不稳定" if (st, x) in seen else "新"}\t{st}\t{x}')
    elif a[0] == 'expire':   # expire <已知红表> <记录> <小时>：「不稳定」项近 <小时> 小时没再出现 → 撤销，打「撤<TAB>步<TAB>特征<TAB>属主」
        kr, hp, hrs = a[1], a[2], float(a[3]); now = int(time.time()); recent = set()
        if os.path.exists(hp):
            for l in open(hp, encoding='utf-8'):
                c = l.rstrip('\n').split('\t')
                if len(c) >= 3 and c[0].isdigit() and now - int(c[0]) <= hrs * 3600: recent.add((c[1], c[2]))
        keep = []
        for c in load(kr):
            if len(c) > 8 and c[8] == '不稳定' and (c[0], c[1]) not in recent and now - int(c[3]) > hrs * 3600:
                print(f'撤\t{c[0]}\t{c[1]}\t{c[4]}'); continue
            keep.append(c)
        save(kr, keep)
    elif a[0] == 'register':   # register <表> <日志> <main 提交> <仓库> <列车目录> <改动集文件>：新登记的项打「步<TAB>特征<TAB>属主线」
        kr, log, commit, repo, td, chf = a[1:7]; kind = '已知红'; only = None
        if len(a) > 8 and a[7] == '--unstable':   # 只登记 classify 判为「不稳定」的项（来源是近期别的批 / main，不是这份日志里的 main 基线）
            kind = '不稳定'; only = {tuple(l.rstrip('\n').split('\t')[1:3]) for l in open(a[8], encoding='utf-8') if l.startswith('不稳定\t')}
        rows = load(kr); have = {(c[0], c[1]) for c in rows}; now = str(int(time.time()))
        ch = ' '.join(open(chf, encoding='utf-8').read().split()) if os.path.exists(chf) else ''
        for st, ss in failures(log).items():
            for s in ss:
                if (st, s) in have or len(FAIL.sub('', s).strip()) < 10: continue   # 太笼统的（只剩失败标记）不登记：谁的红都能配上
                if only is not None and (st, s) not in only: continue
                o = owner_of(repo, td, st, s) or '总指挥'
                rows.append([st, s, commit, now, o, ch, now, '0', kind]); have.add((st, s)); print(f'{st}\t{s}\t{o}')
        save(kr, rows)
    elif a[0] == 'remind':   # remind <表> <小时> <间隔小时>：挂了超过 <小时> 且距上次提醒超过 <间隔> 的项打「步<TAB>特征<TAB>属主<TAB>已挂小时」，并记上次提醒
        kr, hrs, gap = a[1], float(a[2]), float(a[3]); now = int(time.time()); rows = load(kr)
        for c in rows:
            # 「不稳定」项不是 main 已知红：按 24 小时没再出现由 expire 撤，不催（11-02 pack_jobs_test 不稳定项在 main 已绿后仍按「已知红已挂 12 小时」催属主）
            if len(c) > 8 and c[8] == '不稳定': continue
            if now - int(c[3]) >= hrs * 3600 and now - int(c[7]) >= gap * 3600:
                print(f'{c[0]}\t{c[1]}\t{c[4]}\t{(now - int(c[3])) // 3600}'); c[7] = str(now)
        save(kr, rows)
    elif a[0] == 'steps':   # steps <表>：表里的步与它的路由改动集（复核用），一行「步<TAB>改动集」
        seen = {}
        for c in load(a[1]): seen.setdefault(c[0], c[5])
        for st, ch in seen.items(): print(f'{st}\t{ch}')
    elif a[0] == 'recheck':
        kr, step, log = a[1:4]
        f = failures(log); still = set(f.get(step, [])); now = str(int(time.time())); keep = []
        for c in load(kr):
            if c[0] == step and (len(c) < 9 or c[8] == '已知红') and c[1] not in still: print(f'撤\t{c[0]}\t{c[1]}\t{c[4]}'); continue   # 不稳定项不靠复核撤（偶发的复核一次绿不说明修好），按 24 小时没再出现撤
            if c[0] == step: c[6] = now
            keep.append(c)
        save(kr, keep)
    else:
        sys.exit(__doc__)


if __name__ == '__main__':
    main()
