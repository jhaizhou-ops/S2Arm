#!/usr/bin/env python3
# 游戏自己要的帧率（10-21 jhz 拍板：帧率口径 = 游戏请求的交换间隔，零配置不查表）：从 host.log 里帧率能耗线打的「帧节拍」行取
#   格式：[gal] 帧节拍：交换间隔 <N>，每帧 <ms> ms（<fps> 帧/秒）——生效的交换间隔每变一次打一行，取最后一行；N = 0 = 游戏关了垂直同步（不限）→ 按 60 判。
#   取不到 → 按 60 判，ok = False（调用方据此判红并写明「取不到帧节拍」）。
#   帧率真值表（10-26 总指挥定）：host.log「程序号」在 tools/fps_truth.tsv 里有行，就以表里的目标帧率为准。表由 Ryujinx 关垂直同步实测生成
#   （compat/truth/run_fps.sh + tools/fps_truth.py），不按款手写。这样分得出「游戏声明间隔 1 但自己限到 30」（异度神剑3）和「我方慢到 30」：只看上屏间隔分不出（3848fe787 已撤）。
#   帧率表优先于真值表（10-26 总指挥定）：包里带了 60 帧表（runtime/fps，host.log「帧率表 …：出图间隔放开」），目标就是 60——
#   真值表量的是游戏原生帧率（如异度神剑3 原生 30），表把它放开到 60 后再按原生判会把「没跑到 60」判成绿。没带表才回到真值表。
# 用法：python3 tools/game_fps.py <局目录或 host.log>   → 打印「<fps>\t<说明>」，取不到退出 1
import os, re, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import fps_truth, ab_span
RE = re.compile(r'帧节拍：交换间隔 (\d+)，每帧 ([0-9.]+) ms（([0-9.]+) 帧/秒）')
PID = re.compile(r'程序号 ([0-9a-fA-F]{16})')
FT = re.compile(r'帧率表 (\S+)：(?:60 帧开；)?出图间隔放开')   # 宿主现行格式「帧率表 <路径>：60 帧开；出图间隔放开…」（runtime/src/fps.c）；10-29 之前只认旧格式，带表的款从没按 60 判

def target(hl):
    """hl = host.log 全文 → (目标帧率, 说明, 取到没有)。MARK 后改出帧状态的段（逻辑速度同局 A/B，tools/ab_span.py）里切 60 帧打的帧节拍行不算"""
    hl = ab_span.strip(hl or '')
    m = RE.findall(hl)
    if not m: return 60.0, '取不到帧节拍（host.log 没有「帧节拍：交换间隔」行），按 60 帧/秒判', False
    n, ms, fps = m[-1]
    ft = FT.search(hl)
    if ft: return 60.0, f'包里带的帧率表 {os.path.basename(ft.group(1))} 放开了出图间隔（runtime/fps，优先于真值表），按 60 帧/秒判', True
    p = PID.search(hl); t = fps_truth.load().get(p.group(1).lower()) if p else None
    if t: return float(t['目标帧率']), f'帧率真值表：Ryujinx 关垂直同步实测中位 {t["实测中位帧率"]} 帧（GPU 队列 {t["GPU队列中位%"]}%，{t["证据"]}），按 {t["目标帧率"]} 帧/秒判；游戏请求交换间隔 {n}', True
    if int(n) == 0: return 60.0, '游戏关了垂直同步（交换间隔 0），按 60 帧/秒判', True
    return float(fps), f'游戏请求交换间隔 {n}（{float(fps):g} 帧/秒）', True

def of_dir(o):
    p = o if os.path.isfile(o) else os.path.join(o, 'host.log')
    try: return target(open(p, errors='replace').read())
    except OSError: return target('')

if __name__ == '__main__':
    f, why, ok = of_dir(sys.argv[1]); print(f'{f:g}\t{why}'); sys.exit(0 if ok else 1)
