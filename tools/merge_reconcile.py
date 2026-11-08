#!/usr/bin/env python3
# 列车合入对账（10-30 众包线，总指挥批）：列车合入的是排队时钉住的提交，作者之后再推，PR 头就变了，GitHub 不会自动关 PR。
#   今天两例：#1000 合入 faefcc3bc，PR 头 58402ae25 只是作者合 main 的合并提交、内容无差，PR 一直开着；
#            #1002 合入旧版 46ac320ed，之后 4 个提交没合，PR 上看不出已合了一部分。
# 判法（只读，不改仓库）：
#   1. 在 <main> 历史里找列车的合并提交「Merge branch 'contrib/pr<N>'」，第二个父 = 列车合入的提交；找不到 = none（没合过）
#   2. PR 头是 <main> 的祖先，或 <main>..<头> 里没有普通提交、每个合并提交都等于按仓库合并规则自动合并的结果（只差空白也算）→ merged
#   3. 否则 partial：列出 <main>..<头> 之间不在 main 的非合并提交
# 用法：tools/merge_reconcile.py <PR 号> <PR 头> [--main <提交，缺省 origin/main>] [--repo <路径>]
#   输出一行 JSON：{"pr", "state", "merged", "main_merge", "head", "outstanding"}；退出码 0（none / merged / partial 都是正常结果），2 = 参数或 git 出错
import argparse, json, subprocess, sys


def git(repo, *args, check=True):
    p = subprocess.run(['git', '-C', repo, '-c', 'core.quotepath=off', *args], capture_output=True, text=True)
    if check and p.returncode:
        raise RuntimeError(f'git {" ".join(args)}: {p.stderr.strip()}')
    return p


def classify(repo, pr, head, main='origin/main'):
    main = git(repo, 'rev-parse', '--verify', f'{main}^{{commit}}').stdout.strip()
    head = git(repo, 'rev-parse', '--verify', f'{head}^{{commit}}').stdout.strip()
    line = git(repo, 'log', main, '--merges', '-1', '--format=%H %P',
               f'--grep=^Merge branch .contrib/pr{pr}. into').stdout.split()
    out = {'pr': pr, 'head': head, 'state': 'none', 'merged': None, 'main_merge': None, 'outstanding': []}
    if len(line) < 3:
        return out
    out['main_merge'], out['merged'] = line[0], line[2]
    if git(repo, 'merge-base', '--is-ancestor', head, main, check=False).returncode == 0:
        out['state'] = 'merged'
        return out
    out['outstanding'] = git(repo, 'log', '--no-merges', '--format=%H', f'{main}..{head}').stdout.split()
    if not out['outstanding'] and all(clean_merge(repo, m, main) for m in
                                      git(repo, 'log', '--merges', '--format=%H', f'{main}..{head}').stdout.split()):
        out['state'] = 'merged'   # 头只是作者合 main 的合并提交：没有自己的普通提交，合并时也没手改内容
        return out
    out['state'] = 'partial'
    return out


def clean_merge(repo, commit, attr_ref):
    """合并提交 = 按仓库合并规则（.gitattributes 的 merge=union）自动合并它的父提交得到的树，只差空白也算（#1000：union 段落间多一个空行）。"""
    parents = git(repo, 'log', '-1', '--format=%P', commit).stdout.split()
    if len(parents) != 2:
        return False
    mt = git(repo, '-c', f'attr.tree={attr_ref}', 'merge-tree', '--write-tree', *parents, check=False)
    if mt.returncode:
        return False   # 有冲突 = 作者手工解过，内容不能当作 main 里已有
    return git(repo, 'diff', '--quiet', '--ignore-all-space', '--ignore-blank-lines', mt.stdout.split()[0], commit,
               check=False).returncode == 0


if __name__ == '__main__':
    ap = argparse.ArgumentParser()
    ap.add_argument('pr', type=int)
    ap.add_argument('head')
    ap.add_argument('--main', default='origin/main')
    ap.add_argument('--repo', default='.')
    a = ap.parse_args()
    try:
        print(json.dumps(classify(a.repo, a.pr, a.head, a.main), ensure_ascii=False))
    except RuntimeError as e:
        print(f'【红】merge_reconcile：{e}', file=sys.stderr)
        sys.exit(2)
