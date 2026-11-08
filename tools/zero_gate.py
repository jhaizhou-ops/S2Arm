#!/usr/bin/env python3
"""「必须为 0」计数闸门（10-20 共性根因 C 类：静态覆盖漏项要在出包后第一局 Mac 局就暴露，不等 iPhone）。
用法：python3 tools/zero_gate.py <局目录>   读 <局目录>/frames.tsv 与 host.log；退出 0 = 全 0，1 = 有非 0（逐项点名），2 = 没有读数
判的六项（任一非 0 即红，并打出是哪一个）：
  现翻着色器  frames.tsv shader_miss 合计；名字取 host.log「着色器现编：…」行（帧率能耗线打，前 16 个）
  现建管线    frames.tsv pso_n 合计；名字取「管线现建：顶点 … 片元 …」行
  当场翻译    frames.tsv xlate_n 合计；名字取「当场翻译：…」行（帧率能耗线打，前 16 个）
  未实现服务 / 系统调用  host.log「【红】未实现服务：…」「未实现系统调用：…」汇总行（「无」= 0）与逐次的「【红】未实现…」行
  未解析导入  host.log「【红】<模块>: 导入 <名> 没有任何模块定义」行（汇总行「未解析导入：N 个」核数）
  着色器越界 / 循环到上限  host.log 渲染器最后一条「着色器越界计数…：越界 a 支 合计 b 次；循环到上限 c 支 合计 d 次」（10-21，graphics/metal/gal_draw.m）；
              名字取「【红】着色器越界：程序 <键> 次数 <n>（<类别>…」「【红】循环到上限：程序 <键> 次数 <n>」行；没有汇总行 = 未测（计数没开 / 局没收尾）
计数列不在 frames.tsv 里 = 未测（不算红，单列出来）。名字行缺失但计数非 0 时照样红，并注明「没打名字」。"""
import csv, os, re, sys

D = sys.argv[1] if len(sys.argv) > 1 else sys.exit('用法：zero_gate.py <局目录>')
fr, hl = os.path.join(D, 'frames.tsv'), os.path.join(D, 'host.log')
log = open(hl, encoding='utf-8', errors='replace').read().split('\n') if os.path.exists(hl) else []
sums, cols = {}, set()
if os.path.exists(fr):
    with open(fr, encoding='utf-8', errors='replace') as f:
        r = csv.DictReader(f, delimiter='\t'); cols = set(r.fieldnames or [])
        for row in r:
            for k in ('shader_miss', 'pso_n', 'xlate_n'):
                try: sums[k] = sums.get(k, 0) + int(row.get(k))
                except (ValueError, TypeError): pass


def names(pat, n=6):
    got = []
    for l in log:
        m = re.search(pat, l)
        if m and m.group(1).strip() not in got: got.append(m.group(1).strip())
    return got[:n], len(got)


red, untested, ok = [], [], []
for k, label, pat in (('shader_miss', '现翻着色器', r'着色器现编：(.+)'), ('pso_n', '现建管线', r'管线现建：(.+)'), ('xlate_n', '当场翻译', r'当场翻译：(.+)')):
    if k not in cols: untested.append(f'{label}（frames.tsv 没有 {k} 列）'); continue
    if k not in sums: untested.append(f'{label}（没有数字读数）'); continue
    n = sums[k]
    if not n: ok.append(f'{label} 0'); continue
    nm, tot = names(pat)
    red.append(f'{label} {n}：' + ('；'.join(nm) + (f' 等 {tot} 个' if tot > len(nm) else '') if nm else '没打名字（等打点）'))
svc = [l.split('未实现服务：', 1)[1].strip() for l in log if '未实现服务：' in l]
svc_once = [re.sub(r'^.*【红】', '', l)[:80] for l in log if re.search(r'【红】未实现服务(命令)? ', l)]
if svc and svc[-1] not in ('无', '0', ''): red.append(f'未实现服务：{svc[-1][:200]}')
elif svc_once: red.append(f'未实现服务 {len(svc_once)} 次：' + '；'.join(list(dict.fromkeys(svc_once))[:6]))
elif svc and svc[-1] in ('无', '0'): ok.append('未实现服务 0')
else: untested.append('未实现服务（没有有效汇总行）')
sc = [l.split('未实现系统调用：', 1)[1].strip() for l in log if '未实现系统调用：' in l]
if sc and sc[-1] not in ('无', '0', ''): red.append(f'未实现系统调用：{sc[-1][:200]}')
elif (not sc or not sc[-1]) and any('【红】未实现：系统调用' in l for l in log):
    red.append('未实现系统调用：' + '；'.join(dict.fromkeys(re.search(r'系统调用/(\S+?)（', l).group(1) for l in log if re.search(r'【红】未实现：系统调用/\S+?（', l))))
elif sc and sc[-1] in ('无', '0'): ok.append('未实现系统调用 0')
else: untested.append('未实现系统调用（没有汇总行：局没正常收尾）')
imp, ntot = names(r'【红】(\S+: 导入 \S+) 没有任何模块定义')
cnt = [int(m.group(1)) for l in log for m in [re.search(r'未解析导入：(\d+) 个', l)] if m]
if imp or (cnt and cnt[-1]): red.append(f'未解析导入 {max(ntot, cnt[-1] if cnt else 0)}：' + ('；'.join(imp) if imp else '没打名字'))
elif cnt: ok.append('未解析导入 0')
else: untested.append('未解析导入（没有汇总行）')
oc = [m for l in log for m in [re.search(r'着色器越界计数\S*：越界 (\d+) 支 合计 (\d+) 次；循环到上限 (\d+) 支 合计 (\d+) 次', l)] if m]
if oc and (int(oc[-1].group(2)) or int(oc[-1].group(4))):
    a, b, c, d = (int(x) for x in oc[-1].groups())
    on = list(dict.fromkeys(f'{m.group(1)}×{m.group(2)}（{m.group(3)}）' for l in log for m in [re.search(r'【红】着色器越界：程序 (\S+) 次数 (\d+)（([^；）]*)', l)] if m))
    ln = list(dict.fromkeys(f'{m.group(1)}×{m.group(2)}' for l in log for m in [re.search(r'【红】循环到上限：程序 (\S+) 次数 (\d+)', l)] if m))
    if b: red.append(f'着色器越界 {a} 支 {b} 次：' + '；'.join(on[-6:]))
    if d: red.append(f'循环到上限 {c} 支 {d} 次：' + '；'.join(ln[-6:]))
elif oc: ok.append('着色器越界 / 循环到上限 0')
else: untested.append('着色器越界计数（没有汇总行：计数没开或局没收尾）')
if red: print('🔴 必须为 0 的计数非 0：' + ' | '.join(red) + (f'（未测：{"、".join(untested)}）' if untested else ''))
elif ok: print('🟢 必须为 0 的计数全 0：' + '、'.join(ok) + (f'（未测：{"、".join(untested)}）' if untested else ''))
else: print('未测：必须为 0 的计数没有可用读数（' + '、'.join(untested) + '）')
sys.exit(1 if red else 0 if ok else 2)
