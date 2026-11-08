#!/usr/bin/env python3
"""F3：shell 里「失败当成功」的两种形状（11-01 18:00 全量审计「失败当成功能不能一条规则拦住」：只有 shell 能一条规则收）。

只读、不执行；词法与语法树复用 tests/shell_stdin_lint.py 的 Lexer / Parser（heredoc 正文是数据、引号与替换已处理）。

① tail_rc(source)：没打开 pipefail 的脚本里，管道最后一段是 tail / head，前段成败就丢了（管道退出码是 tail 的 0），又没读 PIPESTATUS：
   A 管道退出码被当成成败读：if / while / until 条件、后接 || / &&、下一句读 $?、是整份脚本最后一句（脚本退出码）；
     v=$(… | tail …) 的赋值同理（|| / && / $? / 条件）。
   B 跑一个程序、2>&1 把日志并进管道再 tail / head，退出码谁也不看：
     B1 单独成句（出包阶段 shaders.sh 四次收集的形状）；
     B2 v=$(跑程序 2>&1 | tail …)，之后只在 v 里 grep 到失败记号才判红（grep … && 判红；图形门禁宏表检查的形状）——
        按成功记号判（[ "$v" = 期望 ]、grep -q 一致 || 判红）的是失败即红，不报。
   不报：下一句读 PIPESTATUS（shaders.sh 收回那次）、先收退出码再缩短日志（services/build.mk）、版本探测（--version）、
   前段是纯文本工具（grep / sed / cat …）、文件里打开了 pipefail。|| true 不在本规则里，不一律当红。
② skip_exit0(source)：会被顶层门禁自动收的单测，在「跳过 / 未验证」分支里 exit 0（应 exit 75：门禁记环境未就绪、不当绿）。
   同一命令列表里先有 echo / printf 打「跳过 / skip / 未验证」、后有 exit 0；子 shell 与命令替换里的 exit 不是退出单测，不报。
"""
import os
import re
import sys
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from shell_stdin_lint import Lexer, Node, Parser, command_words

SHORTEN = {'tail', 'head'}
TEXT = {'echo', 'printf', 'cat', 'grep', 'egrep', 'fgrep', 'rg', 'sed', 'awk', 'sort', 'uniq', 'cut', 'tr', 'wc', 'ls', 'find',
        'jq', 'column', 'nl', 'tac', 'rev', 'fold', 'strings', 'xxd', 'od', 'hexdump', 'diff', 'cmp', 'comm', 'join', 'paste',
        'date', 'ps', 'pgrep', 'lsof', 'df', 'du', 'stat', 'file', 'readlink', 'basename', 'dirname', 'which', 'type', 'sysctl',
        'uname', 'tail', 'head', 'tee', 'xargs', 'shasum', 'md5', 'sha256sum'}
PROBE = {'--version', '-version'}
SKIP = re.compile(r'跳过|未验证|\bskip', re.I)
PIPEFAIL = re.compile(r'(?m)^[^#\n]*\bset\s+(?:[-+][A-Za-z]+\s+)*-[A-Za-z]*o\s+pipefail\b')
ASSIGN = re.compile(r'^([A-Za-z_][A-Za-z_0-9]*)=')


class TreeParser(Parser):
    """在 F1 语法树上补三样本规则要的信息：每条命令后面的分隔符（sep）、节点种类（if / brace / subshell）、行号。"""

    def sequence(self, stops=()):
        nodes = []
        while self.i < len(self.ts) and self.ts[self.i].syntax not in stops:
            if self.ts[self.i].syntax in self.SEPS:
                if nodes:
                    nodes[-1].sep = nodes[-1].sep or self.ts[self.i].syntax
                self.take()
                continue
            line = self.ts[self.i].line
            node = self.command()
            parts = [node]
            while self.peek('|') or self.peek('|&'):
                node.pipe_err = self.take().syntax == '|&'
                while self.peek('\n'):
                    self.take()
                parts.append(self.command())
                node = parts[-1]
            node = Node('pipe', children=parts) if len(parts) > 1 else parts[0]
            node.line, node.sep = line, ''
            nodes.append(node)
        return Node('list', children=nodes)

    def command(self):
        t = self.ts[self.i]
        kind = 'subshell' if t.kind == 'group' else 'brace' if t.is_word('{') else 'if' if t.is_word('if') else None
        node = super().command()
        if kind and node.kind == 'group':
            node.kind = kind
        return node


def tree(source):
    return TreeParser(Lexer(source).tokens()).sequence()


def raw(node):
    """节点里出现过的全部原文（含替换、重定向目标）：判 $? / PIPESTATUS / 变量引用用。"""
    out = [w.raw for w in node.words] + [t.raw for _, _, t in node.redirs]
    for c in node.children:
        out.append(raw(c))
    return ' '.join(out)


def head(node):
    """紧跟着的那一条简单命令（if / 组 / 管道取第一条）：「下一句读 $? / PIPESTATUS」只看它，不看整块。"""
    while node is not None and node.kind != 'simple':
        node = node.children[0] if node.children else None
    return node


def name(node):
    if node.kind != 'simple':
        return None
    ws = command_words(node.words)
    return ws[0].value.rsplit('/', 1)[-1] if ws else None


def merged_err(front):
    return getattr(front, 'pipe_err', False) or any(fd == 2 and op == '>&' and t.value == '1' for fd, op, t in front.redirs)


def is_run(front):
    """前段是在跑一个程序（脚本 / 编译器 / 工具），不是纯文本工具，也不是版本探测。"""
    n = name(front)
    if not n or n in TEXT:
        return False
    return not any(w.value in PROBE for w in command_words(front.words))


def shortened(node):
    """管道最后一段是 tail / head → 返回前段；否则 None。"""
    if node.kind == 'pipe' and name(node.children[-1]) in SHORTEN:
        return node.children[0]
    return None


def subst_pipe(node):
    """v=$(… | tail …) 这句：返回 (变量名, 替换里的那条管道)。只认整句只有赋值的。"""
    if node.kind != 'simple' or not node.words or node.redirs:
        return None
    if not all(ASSIGN.match(w.raw) for w in node.words):
        return None
    for w in node.words:
        m = ASSIGN.match(w.raw)
        if w.raw[m.end():].startswith('$(') and w.raw.endswith(')') and len(w.subs) == 1:
            body = TreeParser(w.subs[0]).sequence().children
            if body and shortened(body[-1]) is not None:
                return m.group(1), body[-1], body
    return None


def tail_rc(source):
    if PIPEFAIL.search(source):
        return []
    found = []

    def recovered(nxt):
        h = head(nxt)
        return h is not None and 'PIPESTATUS' in raw(h)

    def reads_rc(nxt):
        h = head(nxt)
        return h is not None and '$?' in raw(h) and not recovered(nxt)

    def ignored(c, nxt):   # 「… || true」「… || :」= 明说不看成败，不算把 tail 的 0 当成功
        return c.sep == '||' and name(head(nxt)) in ('true', ':')

    def walk(lst, cond=False, top=False, sub=False):
        kids = lst.children
        for k, c in enumerate(kids):
            nxt = kids[k + 1] if k + 1 < len(kids) else None
            last = nxt is None
            front = shortened(c)
            if front is not None and not recovered(nxt):
                if ((cond and last) or c.sep in ('||', '&&') or reads_rc(nxt) or (top and last)) and not ignored(c, nxt):
                    found.append((c.line, f'A：管道最后一段是 {name(c.children[-1])}，退出码是它的 0，被当成前段成败（读 PIPESTATUS 或先收前段退出码）'))
                elif merged_err(front) and is_run(front) and not cond and not sub:
                    found.append((c.line, f'B：{name(front)} … 2>&1 | {name(c.children[-1])} 丢了前段退出码，失败照样往下走（读 PIPESTATUS 判前段）'))
            sp = subst_pipe(c)
            if sp:
                var, pipe, body = sp
                if not recovered(nxt):   # 替换里管道后面读了 PIPESTATUS 的，body[-1] 不是管道，subst_pipe 不返回
                    if ((cond and last) or c.sep in ('||', '&&') or reads_rc(nxt)) and not ignored(c, nxt):
                        found.append((c.line, f'A：{var}=$(… | {name(pipe.children[-1])}) 的退出码是 {name(pipe.children[-1])} 的 0，被当成前段成败'))
                    elif merged_err(shortened(pipe)) and is_run(shortened(pipe)):
                        ref = re.compile(r'\$\{?' + var + r'\b')
                        for later in kids[k + 1:]:
                            text = raw(later)
                            if later.sep == '&&' and ref.search(text) and re.search(r'\bgrep\b', text):
                                found.append((c.line, f'B：{var}=$({name(shortened(pipe))} … 2>&1 | {name(pipe.children[-1])}) 丢了退出码，之后只在 {var} 里找到失败记号才判红（失败不打记号就当过）'))
                                break
            visit(c)
        return found

    def visit(node):
        for w in node.words:
            for toks in w.subs:
                if w.kind != 'group':
                    walk(TreeParser(toks).sequence(), sub=True)
        for _, _, t in node.redirs:
            for toks in t.subs:
                walk(TreeParser(toks).sequence(), sub=True)
        if node.kind == 'if':
            n = len(node.children) - len(node.children) % 2
            for i, ch in enumerate(node.children):
                walk(ch, cond=i < n and i % 2 == 0)
        elif node.kind in ('while', 'until'):
            walk(node.children[0], cond=True)
            walk(node.children[1])
        elif node.kind == 'pipe':
            for ch in node.children:
                visit(ch)
        else:
            for ch in node.children:
                if ch.kind == 'list':
                    walk(ch)
                else:
                    visit(ch)

    walk(tree(source), top=True)
    return sorted(set(found))


def skip_exit0(source):
    found = []

    def walk(lst):
        said = False
        for c in lst.children:
            if name(c) in ('echo', 'printf') and SKIP.search(' '.join(w.value for w in c.words[1:])):
                said = True
            ws = command_words(c.words) if c.kind == 'simple' else []
            if said and len(ws) == 2 and ws[0].value == 'exit' and ws[1].value == '0':
                found.append((c.line, '跳过分支 exit 0：门禁把它当绿，断言一次没跑；改 exit 75（环境未就绪）'))
            visit(c)

    def visit(node):
        if node.kind == 'subshell':
            return   # ( … ) 里的 exit 只退子 shell；命令替换不进
        if node.kind == 'pipe':
            return   # 管道各段在子 shell 里
        for ch in node.children:
            if ch.kind == 'list':
                walk(ch)
            else:
                visit(ch)

    walk(tree(source))
    return sorted(set(found))


def auto_tests(root):
    """被 tools/gate.sh 自动收的单测：tests/*_test.sh + gate_route.DECLARED_TEST_COVERAGE 里登记的 .sh（与 gate_route.py tests 同一来源）。"""
    sys.path.insert(0, os.path.join(root, 'tools'))
    from gate_route import DECLARED_TEST_COVERAGE
    out = {str(p.relative_to(root)) for p in Path(root, 'tests').glob('*_test.sh')}
    return sorted(out | {p for p in DECLARED_TEST_COVERAGE if p.endswith('.sh') and Path(root, p).is_file()})


def main(argv):
    failed = False
    for f in argv:
        src = Path(f).read_text(encoding='utf-8')
        for line, msg in tail_rc(src) + (skip_exit0(src) if re.search(r'(^|/)tests/[^/]+_test\.sh$', f) else []):
            print(f'{f}:{line}: {msg}')
            failed = True
    return int(failed)


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
