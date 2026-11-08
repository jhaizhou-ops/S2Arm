#!/usr/bin/env python3
# 门禁手动：辅助脚本，由 tools/sched.sh 局后处理调用出画面真值表（要传局目录与款），本身不是单测
"""画面格真值表：一局的检查点截图逐张对 Windows Ryujinx 真值（truth_cmp.py），出表给记分板（tools/score_cells.py --truth=<表>）。

用法：truth_table.py <局目录> <款> [--out <表>]（缺省 <局目录>/truth.tsv）
  我方截图：<局目录>/shots/<检查点>.png（文件名 = 真值检查点名，即 $S2A_TRUTH/<款>/<检查点>/ 的目录名）；也认逐秒序列目录 <局目录>/shots/<检查点>/（按 point.env 同规则挑帧）。
  比 16:9 宽的图（宽屏局）比宽屏真值 <检查点>_w<屏幕宽>[h<高>]（屏幕宽 = 1080 高折算，与截图宽高比一致；高 = 截图高，没写 h 的目录是 720 高的掌机档真值，
  主机档真值放 <检查点>_w<屏幕宽>h1080——同屏幕宽、不同档位的渲染分辨率不同，不能混比），整帧同一判据；
  该检查点没有对应宽度的宽屏真值 → 总判「无宽屏真值」（不拿 16:9 真值硬比、不放宽判据）。
  例外：宽屏真值 point.env 写了 CENTER_OF=<16:9 检查点>（宽屏真值本身有参照错误）→ 按该 16:9 真值判中间 16:9（truth_cmp --center16x9）。
表头：款<TAB>检查点<TAB>总判<TAB>说明；总判 = 过 / 不过 / 无真值 / 无宽屏真值。该局没有任何检查点截图 → 表只有表头，记分板该款画面真值记「未测」。
退出码：0 = 有行且全过；1 = 有不过 / 无真值 / 无宽屏真值；2 = 用法错；3 = 没有检查点截图。"""
import glob, os, re, subprocess, sys
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
TRUTH = os.environ.get('S2A_TRUTH', os.path.expanduser('~/.s2arm/run/s2arm/visual/truth'))


def center_of(d):
    """宽屏真值 point.env 的 CENTER_OF=<16:9 检查点>：这一点的宽屏真值本身不可信（例：tent 宽屏真值出自 Mac 版 Ryujinx，帐篷内偏暗，10-19 裁定属参照错误），
    改按那个 16:9 真值（Windows 仲裁版）判我方宽屏图的中间 16:9；扩展区由其他点的宽屏真值验（10-20 总指挥拍板）。"""
    f = os.path.join(d, 'point.env')
    for ln in open(f) if os.path.exists(f) else []:
        if ln.startswith('CENTER_OF='): return ln.split('=', 1)[1].strip() or None
    return None


def main():
    a = sys.argv[1:]
    if len(a) < 2: print(__doc__); return 2
    run, game = a[0], a[1]
    out = a[a.index('--out') + 1] if '--out' in a else os.path.join(run, 'truth.tsv')
    shots = sorted(glob.glob(os.path.join(run, 'shots', '*.png')) + [d for d in glob.glob(os.path.join(run, 'shots', '*')) if os.path.isdir(d)])
    rows = []
    for s in shots:
        point = os.path.splitext(os.path.basename(s))[0]
        if not os.path.isdir(os.path.join(TRUTH, game, point)):
            rows.append((game, point, '无真值', f'{TRUTH}/{game}/{point} 不存在')); continue
        tp = point
        if s.endswith('.png'):
            w, h = Image.open(s).size
            if w * 9 > h * 16 + 9:   # 宽屏局：找屏幕宽对得上的宽屏真值
                sw = w * 1080 / h; tp = next((os.path.basename(d) for d in sorted(glob.glob(os.path.join(TRUTH, game, point + '_w*')))
                                             if (m := re.fullmatch(r'(\d+)(?:h(\d+))?', d.rsplit('_w', 1)[1])) and abs(int(m[1]) - sw) <= 2 and int(m[2] or 720) == h), None)
                if tp is None: rows.append((game, point, '无宽屏真值', f'截图 {w}×{h}（屏幕宽 {sw:.0f}），{TRUTH}/{game}/{point}_w<宽> 没有对得上的')); continue
        cmd = [sys.executable, os.path.join(HERE, 'truth_cmp.py'), game, tp, s]
        co = center_of(os.path.join(TRUTH, game, tp)) if tp != point else None
        if co: cmd = [sys.executable, os.path.join(HERE, 'truth_cmp.py'), game, co, s, '--center16x9']; tp = f'{co}（中间 16:9，{tp}/point.env CENTER_OF）'
        r = subprocess.run(cmd, capture_output=True, text=True)
        tab = [l for l in r.stdout.split('\n') if l.startswith('| ') and '期望' not in l and '---' not in l]
        brief = '；'.join(l.strip('| ').replace(' | ', ' ') for l in tab if any(k in l for k in ('每格 SSIM 最低', '不达标格', '可判区域')))
        rows.append((game, point, '过' if r.returncode == 0 else '不过', ((f'宽屏真值 {tp}；' if tp != point else '') + brief) or r.stdout.strip()[-200:] or r.stderr.strip()[-200:]))
    with open(out, 'w') as f:
        f.write('款\t检查点\t总判\t说明\n')
        for row in rows: f.write('\t'.join(x.replace('\t', ' ').replace('\n', ' ') for x in row) + '\n')
    for row in rows: print('\t'.join(row))
    print(f'真值表 {out}：{len(rows)} 个检查点，过 {sum(r[2] == "过" for r in rows)}')
    return 3 if not rows else 0 if all(r[2] == '过' for r in rows) else 1


if __name__ == '__main__':
    sys.exit(main())
