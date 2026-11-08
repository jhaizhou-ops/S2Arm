#!/usr/bin/env python3
# 帧率真值表（10-26 总指挥定，帧率能耗线）：目标帧率取 Ryujinx 上实测的帧率，不按款手写。
# 用法：python3 tools/fps_truth.py <款> <程序号> <run_fps.sh 输出的 stderr.txt> [--write]
#   读 [fps] 行（compat/truth/run_fps.sh：关垂直同步、每 5 秒一行），丢开头 2 行（加载）；只认 fifo < 50 的样本（GPU 命令队列有空闲 = Ryujinx 不是瓶颈）。
#   样本中位数 ≥ 58 → 60（关了垂直同步还能跑过 60，游戏靠交换间隔出帧）；在 30 ± 2 → 30（游戏自己限到 30）；别的 → 判不了，退出 1、不写表。
#   --write：按程序号写进 / 更新 tools/fps_truth.tsv（S2A_FPS_TRUTH_TSV 可改路径）。tools/game_fps.py 按 host.log 的程序号查这张表，表里有就以它为目标帧率。
import os, re, statistics, sys, time

HEAD = '程序号\t款\t目标帧率\t实测中位帧率\tGPU队列中位%\t样本数\t证据\t日期'
FPS = re.compile(r'\[fps\] game ([0-9.]+) fifo ([0-9.]+) frametime')

def path():
    return os.environ.get('S2A_FPS_TRUTH_TSV') or os.path.join(os.path.dirname(os.path.abspath(__file__)), 'fps_truth.tsv')

def judge(log):
    """[fps] 行全文 → (目标帧率或 None, 中位帧率, GPU 队列中位, 样本数, 说明)"""
    s = [(float(g), float(f)) for g, f in FPS.findall(log)][2:]
    ok = [g for g, f in s if f < 50 and g > 0]
    if not ok: return None, None, None, 0, f'没有可用样本（{len(s)} 行里 GPU 队列 < 50% 且帧率 > 0 的 0 行）'
    med = statistics.median(ok); fq = statistics.median(f for g, f in s if f < 50 and g > 0)
    if med >= 58: return 60, med, fq, len(ok), f'关垂直同步实测中位 {med:.1f} 帧 ≥ 58：游戏靠交换间隔出帧'
    if abs(med - 30) <= 2: return 30, med, fq, len(ok), f'关垂直同步实测中位 {med:.1f} 帧、GPU 队列 {fq:.0f}%：游戏自己限到 30'
    return None, med, fq, len(ok), f'实测中位 {med:.1f} 帧，既不 ≥ 58 也不在 30 ± 2，判不了'

def load(p=None):
    """程序号（小写 16 位）→ 行字典"""
    rows = {}
    try:
        for l in open(p or path(), encoding='utf-8'):
            c = l.rstrip('\n').split('\t')
            if l.startswith('程序号') or len(c) < 8: continue
            rows[c[0].lower()] = dict(zip(HEAD.split('\t'), c))
    except OSError: pass
    return rows

def main():
    a = [x for x in sys.argv[1:] if x != '--write']
    if len(a) != 3: print(__doc__ or '用法见文件头', file=sys.stderr); sys.exit(2)
    game, pid, logf = a[0], a[1].lower(), a[2]
    tgt, med, fq, n, why = judge(open(logf, errors='replace').read())
    print(f'{game}\t{pid}\t{tgt}\t{why}')
    if tgt is None: sys.exit(1)
    if '--write' in sys.argv:   # 证据：[fps] 行拷进表旁的 fps_truth/<款>.log（表里记相对路径；真值局的输出目录是临时的）
        ev = os.path.join(os.path.dirname(path()), 'fps_truth', f'{game}.log'); os.makedirs(os.path.dirname(ev), exist_ok=True)
        open(ev, 'w', encoding='utf-8').write(''.join(f'[fps] game {g} fifo {q} frametime\n' for g, q in FPS.findall(open(logf, errors='replace').read())))
        rows = load(); rows[pid] = dict(zip(HEAD.split('\t'), [pid, game, str(tgt), f'{med:.1f}', f'{fq:.0f}', str(n), f'fps_truth/{game}.log', time.strftime('%m-%d %H:%M')]))
        with open(path(), 'w', encoding='utf-8') as f:
            f.write(HEAD + '\n')
            for k in sorted(rows): f.write('\t'.join(rows[k][h] for h in HEAD.split('\t')) + '\n')

if __name__ == '__main__':
    main()
