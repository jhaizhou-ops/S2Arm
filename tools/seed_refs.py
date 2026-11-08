#!/usr/bin/env python3
"""扫产物根 seed.txt 的 src= 路径，供 gc 与清盘清单做硬保护。
直接运行：打印所有被引用的 src（去重，一行一个）。
--check <路径…>：给的路径等于某个 src、是其祖先目录或在其下面 → 打印命中并退出 1；否则退出 0。
--missing：列出 src 指向但已不存在的路径（每行 <seed.txt路径>\t<src>）。
扫描目录：
  S2A_ROOTS       冒号分隔，若给则完全替换默认列表（单测与 gc 用）
  S2A_ROOTS_SHARED  冒号分隔，追加到默认或 S2A_ROOTS（gc 远端模式传 rpack 根用）
默认：~/.s2arm/run/s2arm/roots、~/.s2arm/run/s2arm/roots_priv（11-05 起不再含外接 SSD：S2A_SSD 已挪给天眼）"""
import os, sys


def _root_dirs():
    env = os.environ.get('S2A_ROOTS', '')
    if env:
        dirs = [d for d in env.split(':') if d]
    else:
        home = os.path.expanduser('~')
        dirs = [
            os.path.join(home, '.s2arm', 'run', 's2arm', 'roots'),
            os.path.join(home, '.s2arm', 'run', 's2arm', 'roots_priv'),
        ]
    shared = os.environ.get('S2A_ROOTS_SHARED', '')
    if shared:
        dirs += [d for d in shared.split(':') if d]
    return dirs


def _find_seeds(root_dirs):
    """找 seed.txt（最多 4 层）：roots/款@版/、roots_priv/名/款@版/、work/卷/roots/款@版/。
    不遍历产物根里面（11-02：原先 os.walk 把每个根的 romfs 目录项全列一遍，48 万项一个目录，一轮 gc 扫 18–22 分钟占满本机 IO）：
    某目录自己有 seed.txt 就是产物根，记下就不再往里走；没有的才列它的子目录往下找；第 4 层只看有没有 seed.txt、不列目录项。"""
    seeds = []

    def visit(d, depth):
        sp = os.path.join(d, 'seed.txt')
        if os.path.isfile(sp):
            seeds.append(sp)
            return
        if depth >= 4:
            return
        try:
            with os.scandir(d) as it:
                subs = [e.path for e in it if e.is_dir(follow_symlinks=False)]
        except OSError:
            return
        for sub in subs:
            visit(sub, depth + 1)

    for r in root_dirs:
        if not os.path.isdir(r):
            continue
        visit(r.rstrip(os.sep) or os.sep, 0)
    return seeds


def _read_src(seed_path):
    try:
        with open(seed_path, encoding='utf-8') as f:
            for line in f:
                if line.startswith('src='):
                    return line[4:].rstrip('\n')
    except OSError:
        pass
    return None


def _collect(root_dirs):
    """返回 {src路径: [seed_path, …]}。"""
    result = {}
    for seed in _find_seeds(root_dirs):
        src = _read_src(seed)
        if src:
            result.setdefault(src, []).append(seed)
            # src 经符号链接指到别处（10-29 运维线：ops_pkg/xc3_extract_221 是指向 SSD 的链接，按 src 原文核「有没有被引用」漏掉了链接后面的真实目录）：
            #   真实路径也算被引用，gc 硬保护与清盘清单都看得到
            real = os.path.realpath(src)
            if real != src.rstrip('/') and os.path.exists(src):
                result.setdefault(real, []).append(seed)
    return result


def _matches(candidate, src):
    """candidate 等于 src，或是 src 的祖先目录，或在 src 下面。"""
    c = candidate.rstrip('/') + '/'
    s = src.rstrip('/') + '/'
    return c.startswith(s) or s.startswith(c)


def main():
    args = sys.argv[1:]
    root_dirs = _root_dirs()
    srcs = _collect(root_dirs)

    if args and args[0] == '--check':
        candidates = args[1:]
        hit = False
        for c in candidates:
            for s in srcs:
                if _matches(c, s):
                    print(f'seed-protected: {c}  (src={s})')
                    hit = True
                    break
        sys.exit(1 if hit else 0)

    if args and args[0] == '--missing':
        for s in sorted(srcs):
            if not os.path.exists(s):
                for seed in srcs[s]:
                    print(f'{seed}\t{s}')
        sys.exit(0)

    for s in sorted(srcs):
        print(s)


if __name__ == '__main__':
    main()
