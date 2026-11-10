#!/usr/bin/env python3
"""直连库要多少盘（作业预检 pack/jobs/library.py 与直连阶段开工前复核 pack/stage_direct.sh 共用这一份规则，#265）。
按着色器抽取量（产物根 extract/）估，不再用固定 15 GB：11-09 本机实测两款，直连持久缓存约 8× 抽取量、包里的直连库约 1.6–4.7×——
  怪猎崛起 抽取 488 MB → 缓存 4053 MB + 库 922 MB；泰拉瑞亚 抽取 28 MB → 缓存 222 MB + 库 45 MB。
  缓存记 9×（向上取整留余量），库与编译临时目录记 3×（库的上限 + 编译期在写的第二份），合计 12×；小游戏两边各有 1 GB 底。
  已在盘上的同款缓存（重出包复用）从缓存那份里扣掉。抽取量不知道（冷出包，还没抽）时调用方沿用按原包大小的经验值。
CLI：space_rule.py direct-check <抽取目录> <直连缓存目录> <输出目录> → 够：退 0；不够：打「磁盘空间不足」原话、退 1（S2A_SPACE_OVERRIDE=1 时只打黄、退 0）"""
import os, shutil, sys

CACHE_PER_EXTRACT, OUT_PER_EXTRACT, FLOOR = 9, 3, 1 << 30


def tree_bytes(path):
    """目录实际分配的字节（不跟软链，按 inode 去重）；不在 = 0"""
    seen, total, stack = set(), 0, [os.fspath(path)]
    while stack:
        p = stack.pop()
        try: st = os.lstat(p)
        except OSError: continue
        if (st.st_dev, st.st_ino) in seen or os.path.islink(p): continue
        seen.add((st.st_dev, st.st_ino))
        total += st.st_blocks * 512 if hasattr(st, "st_blocks") else st.st_size
        if os.path.isdir(p):
            try: stack.extend(os.path.join(p, n) for n in os.listdir(p))
            except OSError: pass
    return total


def direct_need(extract_bytes, cached_bytes=0):
    """→ (缓存那份, 库与临时那份) 还要的字节"""
    cache = max(FLOOR, CACHE_PER_EXTRACT * extract_bytes)
    return max(0, cache - cached_bytes), max(FLOOR, OUT_PER_EXTRACT * extract_bytes)


def _existing(path):
    path = os.fspath(path)
    while path and not os.path.exists(path): path = os.path.dirname(path)
    return path or "/"


def _free(vol):
    """盘余量；S2A_DISK_FREE_G（GB，单测注入，与 ipa.sh / refresh 同名口径）给了就用它，单测结果不随本机磁盘余量变（11-09 门禁机余量紧时
    直接真跑 direct_lib.sh 的单测被复核拦下、桩工具没调起）"""
    g = os.environ.get("S2A_DISK_FREE_G")
    return shutil.disk_usage(vol) if not g else shutil._ntuple_diskusage(0, 0, int(float(g) * 1e9))


def direct_check(extract_dir, cache_dir, out_dir, free=_free):
    """→ None（够）或给玩家看的一句（不够）。cache_dir / out_dir 在同一块盘时两份加起来核"""
    e = tree_bytes(extract_dir)
    cache_need, out_need = direct_need(e, tree_bytes(cache_dir))
    c, o = _existing(cache_dir), _existing(out_dir)
    if os.stat(c).st_dev == os.stat(o).st_dev:
        checks = [(o, cache_need + out_need, CACHE_PER_EXTRACT + OUT_PER_EXTRACT)]
    else:
        checks = [(c, cache_need, CACHE_PER_EXTRACT), (o, out_need, OUT_PER_EXTRACT)]
    for vol, need, k in checks:
        have = free(vol).free
        if have < need:
            return f"磁盘空间不足：直连库预计还要 {need / 1e9:.1f} GB（着色器抽取 {e / 1e9:.2f} GB × {k}），这块盘只剩 {have / 1e9:.1f} GB"
    return None


if __name__ == "__main__":
    if len(sys.argv) != 5 or sys.argv[1] != "direct-check": sys.exit("用法：space_rule.py direct-check <抽取目录> <直连缓存目录> <输出目录>")
    why = direct_check(*sys.argv[2:])
    if why and os.environ.get("S2A_SPACE_OVERRIDE") == "1": print(f"【黄】{why}；已按你的选择仍然继续"); sys.exit(0)
    if why: print(f"【红】{why}"); sys.exit(1)
