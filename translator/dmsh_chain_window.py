#!/usr/bin/env python3
# Chain window: lets the train merge translation chain changes together, so the chain version V (dmsh_chain.py) changes once per window and every game is rebuilt once,
# not once per merged branch (10-28: dmsh_chain.h changed 20 times on main in 7 days, each a full rebuild). Not one of V's inputs (V follows ABI alone): changing this file changes no chain.
# Usage: dmsh_chain_window.py --files                 the translator fingerprint's input files (dmsh_chain.xfp_files: S2A.Dsh.csproj DshXfpInput), repository paths, one per line
#        dmsh_chain_window.py --touches <base> <head>  whether <head> has another V than <base>, both read from git (no checkout): prints "V_base → V_head" and the files that differ;
#                                                      exit 0 = it changes the chain, 1 = it does not
#        dmsh_chain_window.py --resolve                in a merge whose only conflict is dmsh_chain.h: rewrite it from the merged files and stage it (exit 0);
#                                                      anything else conflicting (the chain's own files among them): exit 1, untouched
# Each run first checks that it hashes the working tree exactly as dmsh_chain.version() does (exit 2 if not), so the two cannot drift apart
import hashlib, os, re, subprocess, sys
HERE = os.path.dirname(os.path.abspath(__file__)); ROOT = os.path.normpath(os.path.join(HERE, '..'))   # repository root (translator → .)
def git(*a): return subprocess.run(['git', '-C', ROOT, *a], capture_output=True, check=True).stdout
if sys.argv[1:] == ['--resolve'] and git('diff', '--name-only', '--diff-filter=U').decode().split() != ['graphics/nvn/gfx/nvn/dmsh_chain.h']:
    sys.exit(1)   # checked before importing dmsh_chain: when it conflicts too (two ABI bumps) it holds conflict markers and cannot be imported
sys.path.insert(0, HERE); import dmsh_chain as dc

def repo_path(f): return os.path.relpath(os.path.normpath(os.path.join(dc.GFX, f)), ROOT)
# dmsh_chain.py 在本文件旁（translator/），read(f) 的路径相对 dc.GFX：按实际位置算，不写死布局（11-09：迁仓后仍读旧的 GFX/tools/dmsh_chain.py，FileNotFoundError）
CHAIN = os.path.relpath(os.path.join(HERE, 'dmsh_chain.py'), dc.GFX)
def version(read):   # dmsh_chain.version() over contents from read(f): V follows ABI alone (read off dmsh_chain.py at that revision)
    m = re.search(rb'^ABI = (\d+)', read(CHAIN), re.M)
    if m: return dc.version(int(m.group(1)))
    h = hashlib.sha256()   # a revision from before 10-30 (no ABI line): V was the digest of the translation tools themselves
    for f in dc.xfp_files():   # 10-30 前的老修订才走这里；那时的文件清单已不可考，按现行指纹输入近似（只用于比两个老修订之间变没变）
        try: h.update(f.encode() + b'\0' + read(os.path.relpath(os.path.join(ROOT, f), dc.GFX)) + b'\0')
        except (subprocess.CalledProcessError, OSError): pass   # a file added later did not exist then
    h.update(dc.options().encode())
    return h.hexdigest()[:12]

def at(rev): return version(lambda f: git('show', f'{rev}:{repo_path(f)}'))

if __name__ == '__main__':
    a = sys.argv[1:]
    if version(lambda f: open(os.path.join(dc.GFX, f), 'rb').read()) != dc.version(): sys.exit('[RED] dmsh_chain_window.py no longer hashes as dmsh_chain.version(): bring version() here in line')
    if a == ['--files']: print('\n'.join(dc.xfp_files()))
    elif len(a) == 3 and a[0] == '--touches':
        vb, vh = at(a[1]), at(a[2])
        diff = git('diff', '--name-only', f'{a[1]}...{a[2]}', '--', *dc.xfp_files()).decode().split()
        print(f'{vb} → {vh}' + ''.join(f'\n  {d}' for d in diff)); sys.exit(0 if vb != vh else 1)
    elif a == ['--resolve']:
        hp = os.path.relpath(dc.HEADER, ROOT)   # only dmsh_chain.h conflicts (checked above, before the import)
        open(dc.HEADER, 'w').write(dc.header_text(dc.version())); git('add', hp); print(dc.version())
    else: sys.exit('usage: see the file header')
