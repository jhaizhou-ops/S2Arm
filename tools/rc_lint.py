#!/usr/bin/env python3
"""只读检查 shell 写盘命令的返回码；不执行、source 或展开被扫描脚本。

用法：python3 tools/rc_lint.py [目录或 .sh 文件 ...]（缺省仓库 pack）。
S2A_RC_OK 可指定替代白名单；缺省 tests/rc_lint_ok.tsv。退出 0 表示已识别
写法全部已判或有人工登记，不代表完整 Bash 语义或实际出包安全。

复用 tests/shell_stdin_lint.py 的 F1 Lexer / command_words；只新增返回码控制流。
仅证明显式条件、终止兜底和直线 set -e；函数体不假设调用点的 errexit，
分支合流不传播新 set -e，未知调用/动态 shell 会使已有 errexit 证明失效。
"""
from __future__ import annotations

import os
from pathlib import Path
import re
import sys
from dataclasses import dataclass, field

ROOT = Path(__file__).resolve().parent.parent
# F1 模块 import 无副作用，已有引号/展开/heredoc/命令前缀测试；不复制另一份 lexer。
sys.path.insert(0, str(ROOT / 'tests'))
from shell_stdin_lint import Lexer, Parser as ShellParser, Token as ShellToken, command_words

WRITERS = {'cp', 'mv', 'ln', 'ditto', 'rsync', 'zip', 'tar', 'install'}
ABORT = {'fail', 'die', 'exit', 'return'}
REDIRS = ShellParser.REDIRS
END = {';', '\n', '&', '&&', '||', '|', '|&', '(', ')', '{', '}', ';;', ';&', ';;&'}


@dataclass
class Token:
    text: str
    line: int
    value: str = ''


@dataclass
class Node:
    kind: str
    words: list[Token] = field(default_factory=list)
    children: list[Node] = field(default_factory=list)
    ops: list[str] = field(default_factory=list)


@dataclass(frozen=True)
class Finding:
    line: int
    command: str
    why: str = '返回码未证明已判'


def flatten(tokens):
    """F1 的子 shell 组展平成语法符；数组值不是命令，展开内部则另行检查。"""
    out, embedded = [], []
    for index, token in enumerate(tokens):
        raw = token.raw.replace('\\\n', '')
        if token.kind == 'group':
            inner, subs = flatten(token.subs[0])
            embedded.extend(subs)
            previous = tokens[index - 1] if index else None
            if (previous and re.fullmatch(r'[A-Za-z_]\w*(?:\[[^]]*\])?\+?=', previous.raw)
                    and previous.end == token.start):
                # 原始数组 body 只保留为数据；其 $(...) 已在 subs 中收集。
                out[-1].text += '(' + ' '.join(t.text for t in inner) + ')'
            else:
                out.extend([Token('(', token.line), *inner, Token(')', token.line)])
        else:
            out.append(Token(raw, token.line, token.value))
            embedded.extend(token.subs)
    # [[ ... ]] 内的 && / || 属于条件表达式，不是 shell 命令连接符。
    merged, index = [], 0
    while index < len(out):
        token = out[index]
        if token.text == '[[':
            end = index + 1
            while end < len(out) and out[end].text != ']]':
                end += 1
            if end == len(out):
                raise ValueError('[[ 未闭合')
            text = ' '.join(t.text for t in out[index:end + 1])
            merged.append(Token(text, token.line, text))
            index = end + 1
        else:
            merged.append(token)
            index += 1
    return merged, embedded


def normalize(command):
    tokens, _ = flatten(Lexer(command).tokens())
    return ' '.join(token.text for token in tokens if token.text != '\n')


class Parser:
    """有界的 Bash 控制结构读取器；不求值条件，不解释任意 shell 程序。"""
    def __init__(self, tokens):
        self.tokens, self.i = tokens, 0

    def peek(self, offset=0):
        i = self.i + offset
        return self.tokens[i].text if i < len(self.tokens) else ''

    def take(self, expected=None):
        if not self.peek() or expected is not None and self.peek() != expected:
            raise ValueError(f'控制结构未闭合/不支持：期望 {expected}')
        token = self.tokens[self.i]
        self.i += 1
        return token

    def blanks(self):
        while self.peek() in (';', '\n'):
            self.i += 1

    def block(self, stops=()):
        children = []
        self.blanks()
        while self.peek() and self.peek() not in stops:
            before = self.i
            node = self.andor()
            if self.peek() == '&':
                self.take()
                node = Node('async', children=[node])
            children.append(node)
            self.blanks()
            if self.i == before:
                raise ValueError(f'不支持的控制词：{self.peek()}')
        return Node('list', children=children)

    def andor(self):
        children, ops = [self.pipeline()], []
        while self.peek() in ('&&', '||'):
            ops.append(self.take().text)
            while self.peek() == '\n':
                self.take()
            children.append(self.pipeline())
        return Node('andor', children=children, ops=ops)

    def pipeline(self):
        if self.peek() == 'time':
            self.take()
            if self.peek() == '-p':
                self.take()
        negate = self.peek() == '!'
        if negate:
            self.take()
        children = [self.command()]
        while self.peek() in ('|', '|&'):
            self.take()
            while self.peek() == '\n':
                self.take()
            children.append(self.command())
        node = Node('pipeline', children=children)
        return Node('not', children=[node]) if negate else node

    def command(self):
        head = self.peek()
        if head in ('{', '('):
            self.take()
            body = self.block(('}' if head == '{' else ')',))
            self.take('}' if head == '{' else ')')
            redirected = False
            while self.peek() in REDIRS or self.peek().isdigit() and self.peek(1) in REDIRS:
                if self.peek().isdigit():
                    self.take()
                self.take()
                self.take()
                redirected = True
            return Node('group' if head == '{' else 'subshell', children=[body],
                        ops=['redirected'] if redirected else [])
        if head == 'function' or self.peek(1) == '(' and self.peek(2) == ')':
            if head == 'function':
                self.take()
                self.take()
            else:
                self.take()
            if self.peek() == '(':
                self.take()
                self.take(')')
            self.blanks()
            return Node('function', children=[self.command()])
        if head == 'if':
            self.take()
            children = []
            while True:
                children.append(self.block(('then',)))
                self.take('then')
                children.append(self.block(('elif', 'else', 'fi')))
                if self.peek() != 'elif':
                    break
                self.take()
            if self.peek() == 'else':
                self.take()
                children.append(self.block(('fi',)))
            self.take('fi')
            return Node('if', children=children)
        if head in ('while', 'until'):
            self.take()
            condition = self.block(('do',))
            self.take('do')
            body = self.block(('done',))
            self.take('done')
            return Node('loop', children=[condition, body])
        if head in ('for', 'select'):
            self.take()
            while self.peek() and self.peek() != 'do':
                self.take()
            self.take('do')
            body = self.block(('done',))
            self.take('done')
            return Node('for', children=[body])
        if head == 'case':
            self.take()
            while self.peek() and self.peek() != 'in':
                self.take()
            self.take('in')
            children = []
            self.blanks()
            while self.peek() and self.peek() != 'esac':
                while self.peek() and self.peek() != ')':
                    self.take()
                self.take(')')
                children.append(self.block((';;', ';&', ';;&', 'esac')))
                if self.peek() in (';;', ';&', ';;&'):
                    self.take()
                self.blanks()
            self.take('esac')
            return Node('case', children=children)
        words = []
        while self.peek() and self.peek() not in END:
            words.append(self.take())
        if not words:
            raise ValueError(f'不支持的空命令/控制词：{head}')
        return Node('command', words=words)


def execution_operands(words):
    operands, index = [], 0
    while index < len(words):
        word = words[index]
        if word.text.isdigit() and index + 1 < len(words) and words[index + 1].text in REDIRS:
            index += 1
            word = words[index]
        if word.text in REDIRS:
            if index + 1 >= len(words):
                raise ValueError('重定向缺少目标')
            index += 2
        else:
            operands.append(ShellToken(word.value, word.text, word.line))
            index += 1
    return operands


def executable(words):
    values = command_words(execution_operands(words))
    return (os.path.basename(values[0].value), [word.value for word in values[1:]]) if values else ('', [])


def current_shell_name(words):
    """writer 可解包外部前缀；set/exit 证明却必须确属当前 shell。"""
    values = [word.value for word in execution_operands(words)]
    while values and re.match(r'[A-Za-z_]\w*=', values[0]):
        values.pop(0)
    if values and values[0] in ('command', 'builtin'):
        values.pop(0)
        while values and values[0] in ('--', '-p'):
            values.pop(0)
        # command 不调用 fail/die 函数；builtin 也没有这两个内建命令。
        return values[0] if values and values[0] in ('set', 'exit', 'return', 'break', 'continue', 'eval', 'source', '.') else ''
    return values[0] if values else ''


def may_skip_handler_exit(node):
    if node.kind == 'command':
        return current_shell_name(node.words) in ('break', 'continue', 'eval', 'source', '.')
    if node.kind not in ('list', 'andor', 'pipeline', 'group'):
        return True  # 复杂控制流不推断「一定走到末尾」，交白名单确认。
    return any(may_skip_handler_exit(child) for child in node.children)


def terminates(node):
    if node.kind == 'command':
        return not any(word.text in REDIRS for word in node.words) and current_shell_name(node.words) in ABORT
    if node.kind in ('pipeline', 'andor'):
        return len(node.children) == 1 and terminates(node.children[0])
    if node.kind == 'group':
        # 兜底块本身的重定向失败时，exit 根本不会执行。
        return not node.ops and terminates(node.children[0])
    if node.kind == 'list':
        return (bool(node.children) and not any(may_skip_handler_exit(child) for child in node.children[:-1])
                and terminates(node.children[-1]))
    return False


def analyze(node, findings, errexit=False, checked=False, ignored=False):
    kind, children = node.kind, node.children
    if kind == 'list':
        for index, child in enumerate(children):
            errexit = analyze(child, findings, errexit,
                              checked if index == len(children) - 1 else False, ignored)
        return errexit
    if kind == 'andor':
        guarded = set()
        for index, op in enumerate(node.ops):
            if op == '||' and terminates(children[index + 1]):
                guarded.add(index)
                j = index - 1
                while j >= 0 and node.ops[j] == '&&':
                    guarded.add(j)
                    j -= 1
        if checked:
            j = len(children) - 1
            guarded.add(j)
            while j > 0 and node.ops[j - 1] == '&&':
                j -= 1
                guarded.add(j)
        for index, child in enumerate(children):
            state = analyze(child, findings, errexit,
                            (checked or 'guard') if index in guarded else False,
                            ignored or bool(node.ops))
            # Branch-dependent set -e cannot establish safety after the chain.
            errexit = errexit and state if node.ops else state
        return errexit
    if kind == 'pipeline':
        for index, child in enumerate(children):
            last = index == len(children) - 1
            state = analyze(child, findings, errexit, checked if last else False,
                            ignored or not last or len(children) > 1)
        return state if len(children) == 1 else errexit
    if kind in ('not', 'async'):
        analyze(children[0], findings, False, checked if kind == 'not' and checked == 'condition' else False, True)
        return errexit
    if kind == 'function':
        # 条件位置调用函数会屏蔽整个函数体的 -e，体内 set -e 也不能恢复。
        analyze(children[0], findings, False, ignored=True)
        return errexit
    if kind in ('group', 'subshell'):
        state = analyze(children[0], findings, errexit, checked, ignored or checked)
        return state if kind == 'group' else errexit
    if kind in ('if', 'loop', 'for', 'case'):
        for index, child in enumerate(children):
            condition = kind == 'loop' and index == 0 or kind == 'if' and index % 2 == 0 and index < len(children) - 1
            analyze(child, findings, errexit, 'condition' if condition else False, ignored or checked or condition)
        return False  # 合流后保守；某支可能关闭 errexit。
    name, args = executable(node.words)
    writer = name in WRITERS or name == 'plutil' and any(arg in ('-insert', '-replace', '-remove') for arg in args)
    if writer and not (checked or errexit and not ignored):
        findings.append(Finding(node.words[0].line, ' '.join(word.text for word in node.words)))
    if name in ('bash', 'sh', 'zsh') and '-c' in args:
        at = args.index('-c') + 1
        if at < len(args) and args[at] is not None:
            findings.extend(scan(args[at], node.words[0].line))
    if name == 'set':
        if current_shell_name(node.words) != 'set':
            return False
        if any(word.text in REDIRS for word in node.words):
            return False  # 重定向先失败时，set 本身尚未执行，不能建立 -e。
        options = iter(args)
        for arg in options:
            if not arg or '$' in arg or '`' in arg:
                return False
            if arg == '--' or not arg.startswith(('-', '+')):
                break  # 后面只是位置参数，set -- -e 并不启用 errexit。
            if arg in ('-o', '+o'):
                option = next(options, None)
                if option == 'errexit':
                    errexit = arg == '-o' and not ignored
                elif option and ('$' in option or '`' in option):
                    return False
            elif re.fullmatch(r'[-+][a-zA-Z]+', arg) and 'e' in arg:
                errexit = arg.startswith('-') and not ignored
        return errexit
    # Known external writers and innocuous shell builtins cannot toggle caller -e.
    if name and name not in WRITERS | ABORT | {'plutil', ':', 'true', 'false', 'echo', 'printf', '[', 'test', 'cd', 'export', 'readonly', 'local', 'declare', 'unset'} and not name.startswith('[['):
        return False
    return errexit


def scan_tokens(source_tokens):
    tokens, embedded = flatten(source_tokens)
    parser = Parser(tokens)
    tree = parser.block()
    if parser.peek():
        raise ValueError(f'剩余控制词：{parser.peek()}')
    findings = []
    analyze(tree, findings)
    for substitution in embedded:
        findings.extend(scan_tokens(substitution))
    return sorted(set(findings), key=lambda hit: (hit.line, hit.command))


def scan(text, first_line=1):
    return scan_tokens(Lexer(text, first_line).tokens())


def path_key(path):
    try:
        return path.resolve().relative_to(ROOT).as_posix()
    except ValueError:
        return str(path.resolve())


def main(argv=None):
    targets = [Path(arg).resolve() for arg in (sys.argv[1:] if argv is None else argv)] or [ROOT / 'pack']
    files, bad = set(), []
    for target in targets:
        if target.is_file():
            files.add(target)
        elif target.is_dir():
            files.update(path for path in target.rglob('*.sh') if path.is_file())
        else:
            bad.append(f'{target}：输入不存在')
    found = {}
    for path in sorted(files):
        try:
            for hit in scan(path.read_text(encoding='utf-8')):
                found.setdefault((path_key(path), hit.command), []).append(hit)
        except (OSError, UnicodeError, ValueError, RecursionError) as error:
            bad.append(f'{path_key(path)}：解析/读取失败：{error}')
    allow_path = Path(os.environ.get('S2A_RC_OK') or ROOT / 'tests/rc_lint_ok.tsv')
    allowed = set()
    try:
        for number, line in enumerate(allow_path.read_text(encoding='utf-8').splitlines(), 1):
            if not line.strip() or line.startswith('#'):
                continue
            parts = line.split('\t')
            if len(parts) != 3 or not all(part.strip() for part in parts):
                bad.append(f'白名单第 {number} 行：需要路径、命令、非空原因三列')
                continue
            path, command, _ = parts
            absolute = (Path(path) if Path(path).is_absolute() else ROOT / path).resolve()
            try:
                key = (path_key(absolute), normalize(command))
            except ValueError as error:
                bad.append(f'白名单第 {number} 行：{error}')
                continue
            # 子目录扫描只核自己范围，但目录内已删除的条目也必须报过期。
            if not any(absolute == target or target.is_dir() and absolute.is_relative_to(target) for target in targets):
                continue
            if key in allowed:
                bad.append(f'白名单第 {number} 行：重复条目 {path} {command}')
            elif key not in found:
                bad.append(f'白名单第 {number} 行：过期（命令已不存在/已修好）{path} {command}')
            else:
                allowed.add(key)
    except (OSError, UnicodeError) as error:
        bad.append(f'白名单读取失败：{error}')
    for (path, command), hits in sorted(found.items()):
        if (path, command) not in allowed:
            bad.extend(f'{path}:{hit.line}: {command}（{hit.why}）' for hit in hits)
    for message in bad:
        print(message)
    print(f'rc_lint：扫 {len(files)} 支 shell；待判 {sum(map(len, found.values()))} 处；白名单 {len(allowed)} 项；问题 {len(bad)} 项')
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())
