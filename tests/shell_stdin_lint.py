#!/usr/bin/env python3
"""F1: statically identifiable remote stdin consumers in while/read bodies.

This is a bounded lexical check, not a Bash interpreter. It follows shell words,
compound-command boundaries, substitutions and explicit descriptor redirects;
never evaluates variables, eval, shell -c strings, aliases or arbitrary sourced
call chains. Unknown dynamic command names are not claimed as checked calls.
The existing shell_lint_test.sh owns repository enumeration and older rules.
"""
from dataclasses import dataclass, field
from pathlib import Path
import re
import sys


class ScanError(ValueError):
    pass


@dataclass
class Token:
    value: str
    raw: str
    line: int
    start: int = 0
    end: int = 0
    kind: str = "word"
    subs: list = field(default_factory=list)
    quoted: bool = False

    @property
    def syntax(self):
        return self.raw.replace("\\\n", "")

    def is_word(self, value):
        return self.kind == "word" and self.syntax == value


class Lexer:
    OPS = (";;&", "<<<", "<<-", "&>>", "&&", "||", ";;", ";&", "|&",
           "<<", ">>", "<&", ">&", "<>", ">|", "&>")

    def __init__(self, source, line=1):
        self.s, self.i, self.line = source, 0, line

    def take(self, count=1):
        s = self.s[self.i:self.i + count]
        self.i += count
        self.line += s.count("\n")
        return s

    def expansion(self, subs):
        """Consume an expansion; executable substitutions retain token trees."""
        start = self.i
        if self.s.startswith("$((", self.i):
            self.take(3)
            depth = 2
            while self.i < len(self.s) and depth:
                if self.s.startswith("$(", self.i):
                    self.expansion(subs)
                else:
                    c = self.take()
                    depth += (c == "(") - (c == ")")
            if depth:
                raise ScanError(f"{self.line}: unclosed arithmetic expansion")
        elif self.s.startswith("$(", self.i) or self.s[self.i:self.i + 2] in ("<(", ">("):
            self.take(2)
            subs.append(self.tokens(")"))
        elif self.s.startswith("${", self.i):
            self.take(2)
            depth = 1
            while self.i < len(self.s) and depth:
                if self.s.startswith("$(", self.i):
                    self.expansion(subs)
                elif self.s[self.i] == "\\":
                    self.take(min(2, len(self.s) - self.i))
                else:
                    c = self.take()
                    depth += (c == "{") - (c == "}")
            if depth:
                raise ScanError(f"{self.line}: unclosed parameter expansion")
        elif self.s[self.i] == "`":
            self.take()
            line, text = self.line, ""
            while self.i < len(self.s) and self.s[self.i] != "`":
                if self.s[self.i] == "\\" and self.i + 1 < len(self.s):
                    pair = self.take(2)
                    text += pair[1] if pair[1] in "\\$`" else pair
                else:
                    text += self.take()
            if self.i == len(self.s):
                raise ScanError(f"{line}: unclosed backtick substitution")
            self.take()
            subs.append(Lexer(text, line).tokens())
        return self.s[start:self.i]

    def word(self):
        start, line, value, subs, quoted = self.i, self.line, "", [], False
        while self.i < len(self.s):
            c = self.s[self.i]
            if c in " \t\r\n;|&()<>" and self.s[self.i:self.i + 2] not in ("<(", ">("):
                break
            if c == "\\":
                self.take()
                if self.i < len(self.s):
                    q = self.take()
                    if q != "\n":
                        quoted = True
                        value += q
            elif c in "'\"" or self.s.startswith("$'", self.i):
                quoted = True
                ansi = self.s.startswith("$'", self.i)
                if ansi:
                    self.take()
                quote = self.take()
                while self.i < len(self.s) and self.s[self.i] != quote:
                    if quote == '"' and (self.s.startswith(("$(", "${"), self.i) or self.s[self.i] == "`"):
                        value += self.expansion(subs)
                    elif (quote == '"' or ansi) and self.s[self.i] == "\\":
                        pair = self.take(min(2, len(self.s) - self.i))
                        if len(pair) == 2 and pair[1] != "\n":
                            value += pair[1] if pair[1] in '\\$`"' else pair
                    else:
                        value += self.take()
                if self.i == len(self.s):
                    raise ScanError(f"{line}: unclosed quote")
                self.take()
            elif self.s.startswith(("$(", "${", "<(", ">("), self.i) or c == "`":
                value += self.expansion(subs)
            else:
                value += self.take()
        if self.i == start:
            raise ScanError(f"{line}: cannot tokenize {self.s[start:start + 8]!r}")
        return Token(value, self.s[start:self.i], line, start, self.i, subs=subs, quoted=quoted)

    def heredoc(self, target, strip_tabs):
        body, line = "", self.line
        while self.i < len(self.s):
            end = self.s.find("\n", self.i)
            end = len(self.s) if end < 0 else end + 1
            raw = self.take(end - self.i)
            compare = raw.rstrip("\n")
            if strip_tabs:
                compare = compare.lstrip("\t")
            if compare == target.value:
                if not target.quoted:
                    # Unquoted heredocs expand substitutions but are not shell code.
                    lex = Lexer(body, line)
                    while lex.i < len(lex.s):
                        if lex.s[lex.i] == "\\":
                            lex.take(min(2, len(lex.s) - lex.i))
                        elif lex.s.startswith(("$(", "${"), lex.i) or lex.s[lex.i] == "`":
                            lex.expansion(target.subs)
                        else:
                            lex.take()
                return
            body += raw
        raise ScanError(f"{line}: unclosed heredoc {target.value!r}")

    def tokens(self, stop=None):
        out, pending, here_op, cases = [], [], None, []
        while self.i < len(self.s):
            c = self.s[self.i]
            if stop and c == stop and not (cases and cases[-1] == "pattern"):
                self.take()
                return out
            if c in " \t\r":
                self.take()
                continue
            if self.s.startswith("\\\n", self.i):
                self.take(2)
                continue
            if c == "#":
                while self.i < len(self.s) and self.s[self.i] != "\n":
                    self.take()
                continue
            start, line = self.i, self.line
            if c == "\n":
                self.take()
                out.append(Token("\n", "\n", line, start, self.i, "op"))
                for target, tabs in pending:
                    self.heredoc(target, tabs)
                pending.clear()
                continue
            if self.s.startswith("((", self.i):
                # Arithmetic commands / for headers have no shell keyword syntax.
                self.take(2)
                depth, subs = 2, []
                while self.i < len(self.s) and depth:
                    if self.s.startswith("$(", self.i):
                        self.expansion(subs)
                    else:
                        ch = self.take()
                        depth += (ch == "(") - (ch == ")")
                if depth:
                    raise ScanError(f"{line}: unclosed arithmetic command")
                raw = self.s[start:self.i]
                out.append(Token(raw, raw, line, start, self.i, subs=subs))
                continue
            op = None if self.s[self.i:self.i + 2] in ("<(", ">(") else next(
                (x for x in self.OPS if self.s.startswith(x, self.i)), None)
            if not op and c in ";|&()<>" and self.s[self.i:self.i + 2] not in ("<(", ">("):
                op = c
            if op:
                self.take(len(op))
                # A plain subshell has its own nested token stream.
                if op == "(" and not (cases and cases[-1] == "pattern"):
                    children = self.tokens(")")
                    out.append(Token("(", "(", line, start, self.i, "group", [children]))
                else:
                    out.append(Token(op, op, line, start, self.i, "op"))
                    if op in ("<<", "<<-"):
                        here_op = op
                    if cases and op == ")" and cases[-1] == "pattern":
                        cases[-1] = "body"
                    elif cases and op in (";;", ";&", ";;&"):
                        cases[-1] = "pattern"
                continue
            t = self.word()
            at_start = not out or out[-1].syntax in (";", "\n", "&&", "||", "&", "|", "do", "then", "else", "{", "!", ";;", ";&", ";;&")
            if t.is_word("case") and at_start:
                cases.append("expression")
            elif t.is_word("in") and cases and cases[-1] == "expression":
                cases[-1] = "pattern"
            elif t.is_word("esac") and cases and at_start:
                cases.pop()
            out.append(t)
            if here_op:
                pending.append((t, here_op == "<<-"))
                here_op = None
        if stop:
            raise ScanError(f"{self.line}: unclosed {stop!r} group")
        if pending:
            raise ScanError(f"{self.line}: missing heredoc body")
        return out


@dataclass
class Node:
    kind: str
    words: list = field(default_factory=list)
    children: list = field(default_factory=list)
    redirs: list = field(default_factory=list)


class Parser:
    REDIRS = {"<", ">", "<<", "<<-", "<<<", ">>", "<&", ">&", "<>", ">|", "&>", "&>>"}
    SEPS = {"\n", ";", "&&", "||", "&", ";;", ";&", ";;&"}

    def __init__(self, tokens):
        self.ts, self.i = tokens, 0

    def peek(self, value):
        return self.i < len(self.ts) and self.ts[self.i].syntax == value

    def take(self):
        t = self.ts[self.i]
        self.i += 1
        return t

    def consume(self, value):
        if not self.peek(value):
            line = self.ts[self.i].line if self.i < len(self.ts) else (self.ts[-1].line if self.ts else 1)
            raise ScanError(f"{line}: expected {value!r}")
        return self.take()

    def sequence(self, stops=()):
        nodes = []
        while self.i < len(self.ts) and self.ts[self.i].syntax not in stops:
            if self.ts[self.i].syntax in self.SEPS:
                self.take()
                continue
            node = self.command()
            parts = [node]
            while self.peek("|") or self.peek("|&"):
                self.take()
                while self.peek("\n"):
                    self.take()
                parts.append(self.command())
            nodes.append(Node("pipe", children=parts) if len(parts) > 1 else node)
        return Node("list", children=nodes)

    def redirects(self, node):
        while self.i < len(self.ts):
            fd = None
            if (re.fullmatch(r"[0-9]+", self.ts[self.i].syntax) and not self.ts[self.i].quoted
                    and self.i + 1 < len(self.ts)
                    and self.ts[self.i].end == self.ts[self.i + 1].start
                    and self.ts[self.i + 1].raw in self.REDIRS):
                fd = int(self.take().value)
            if self.ts[self.i].raw not in self.REDIRS:
                break
            op = self.take()
            if self.i == len(self.ts):
                raise ScanError(f"{op.line}: missing redirect target")
            target = self.take()
            node.redirs.append((fd if fd is not None else (0 if op.raw.startswith("<") else 1), op.raw, target))
        return node

    def command(self):
        t = self.take()
        if t.is_word("!") or t.is_word("time"):
            if t.is_word("time") and self.peek("-p"):
                self.take()
            return self.command()
        if t.kind == "group":
            # name() is tokenized as a word followed by an empty group token.
            return self.redirects(Node("group", children=[type(self)(t.subs[0]).sequence()]))   # 子类（F3 shell_fail_shapes）的子 shell 也用子类解析
        if t.is_word("{"):
            body = self.sequence(("}",))
            self.consume("}")
            return self.redirects(Node("group", children=[body]))
        if t.is_word("while") or t.is_word("until"):
            cond = self.sequence(("do",))
            self.consume("do")
            body = self.sequence(("done",))
            self.consume("done")
            return self.redirects(Node(t.value, children=[cond, body]))
        if t.is_word("for") or t.is_word("select"):
            header = []
            while self.i < len(self.ts) and not self.peek("do"):
                header.append(self.take())
            self.consume("do")
            body = self.sequence(("done",))
            self.consume("done")
            return self.redirects(Node("for", words=header, children=[body]))
        if t.is_word("if"):
            children = []
            while True:
                children.append(self.sequence(("then",)))
                self.consume("then")
                children.append(self.sequence(("elif", "else", "fi")))
                if not self.peek("elif"):
                    break
                self.take()
            if self.peek("else"):
                self.take()
                children.append(self.sequence(("fi",)))
            self.consume("fi")
            return self.redirects(Node("group", children=children))
        if t.is_word("case"):
            words, children = [], []
            while self.i < len(self.ts) and not self.peek("in"):
                words.append(self.take())
            self.consume("in")
            while self.i < len(self.ts) and not self.peek("esac"):
                # Pattern parentheses are represented by lexer groups when optional '(' is used.
                while self.peek("\n"):
                    self.take()
                if self.peek("esac"):
                    break
                while self.i < len(self.ts) and not self.peek(")"):
                    pat = self.take()
                    words.append(pat)
                    if pat.kind == "group":
                        break
                else:
                    self.consume(")")
                children.append(self.sequence((";;", ";&", ";;&", "esac")))
                if not self.peek("esac"):
                    self.take()
            self.consume("esac")
            return self.redirects(Node("group", words=words, children=children))
        if t.is_word("function"):
            name = self.take()
            if self.i < len(self.ts) and self.ts[self.i].kind == "group" and not self.ts[self.i].subs[0]:
                self.take()
            while self.peek("\n"):
                self.take()
            return Node("function", words=[name], children=[self.command()])
        if (t.kind == "word" and re.fullmatch(r"[A-Za-z_][A-Za-z_0-9]*", t.raw) and self.i < len(self.ts) and self.ts[self.i].kind == "group"
                and not self.ts[self.i].subs[0]):
            self.take()
            while self.peek("\n"):
                self.take()
            return Node("function", words=[t], children=[self.command()])
        self.i -= 1
        node = Node("simple")
        while self.i < len(self.ts):
            cur = self.ts[self.i]
            if cur.raw in self.SEPS | {"|", "|&", "}", ")"}:
                break
            before = self.i
            self.redirects(node)
            if self.i == before:
                node.words.append(self.take())
        if not node.words and not node.redirs:
            raise ScanError(f"{t.line}: unexpected {t.raw!r}")
        return node


ASSIGN = re.compile(r"^[A-Za-z_][A-Za-z_0-9]*=")
# Verified wrappers at main 6f313c12: their non-local branches invoke ssh;
# remote.sh:rsh uses SSH=(ssh ...); pso_dist.sh:rs invokes tools/remote.sh.
WRAPPERS = {"tools/remote.sh": {"rsh"}, "tools/sched.sh": {"rsh"},
            "graphics/tools/shbake/pso_dist.sh": {"rx", "rs"}}


def command_words(words):
    """Unwrap only identifiable execution prefixes, not arbitrary arguments."""
    ws = list(words)
    while ws:
        name = ws[0].value.rsplit("/", 1)[-1]
        if ASSIGN.match(ws[0].value) or name == "!":
            ws.pop(0)
        elif name in ("command", "builtin", "exec", "time"):
            ws.pop(0)
            while ws and ws[0].value.startswith("-"):
                opt = ws.pop(0).value
                if name == "command" and opt in ("-v", "-V"):
                    return []  # command lookup does not execute the operand
                if name == "exec" and opt == "-a" and ws:
                    ws.pop(0)
                if opt == "--":
                    break
        elif name == "env":
            ws.pop(0)
            while ws and (ASSIGN.match(ws[0].value) or ws[0].value.startswith("-")):
                opt = ws.pop(0).value
                if opt in ("-u", "--unset", "-C", "--chdir") and ws:
                    ws.pop(0)
        elif name in ("timeout", "gtimeout"):
            ws.pop(0)
            while ws and ws[0].value.startswith("-"):
                opt = ws.pop(0).value
                if opt in ("-k", "--kill-after", "-s", "--signal") and ws:
                    ws.pop(0)
            if ws:
                ws.pop(0)  # duration (F1 only; no assignment/timeout rule here)
        else:
            return ws
    return ws


def remote_call(words, path):
    ws = command_words(words)
    if not ws:
        return None
    first = ws[0]
    name = first.value.rsplit("/", 1)[-1]
    if name == "ssh":
        if any(w.value == "builtin" for w in words[:words.index(first)]):
            return None  # ssh is not a shell builtin
        options = ws[1:]
        i, safe = 0, False
        while i < len(options) and options[i].value.startswith("-"):
            opt = options[i].value
            if opt == "--":
                break
            chars = opt[1:]
            j = 0
            while j < len(chars):
                flag = chars[j]
                if flag in "nf":
                    safe = True
                if flag in "BbcDEeFIiJLlmOopQRSWw":
                    arg = chars[j + 1:]
                    if not arg:
                        i += 1
                        arg = options[i].value if i < len(options) else ""
                    if flag == "o" and re.fullmatch(r"(?i)stdinnull(?:=|\s+)yes", arg):
                        safe = True
                    break
                j += 1
            i += 1
        return None if safe else first
    if name in ("bash", "sh"):
        ws = ws[1:]
        while ws and ws[0].value.startswith("-"):
            opt = ws.pop(0).value
            if "c" in opt[1:] or "n" in opt[1:]:
                return None  # shell -c text / syntax-only invocation is not a script call
            if opt in ("-o", "-O") and ws:
                ws.pop(0)
        if not ws:
            return None
        first = ws[0]
    if first.value == "tools/remote.sh" or first.value.endswith("/tools/remote.sh"):
        return first
    if first.value in WRAPPERS.get(path, set()):
        return first
    return None


def fd_source(fds, fd):
    # Preserve identities, not only a dangerous/safe bit: read <&3 can consume
    # fd 3's inherited stream, and several descriptors can alias that stream.
    return fds.get(fd, ("inherited", fd))


def redirected(fds, redirs):
    fds = dict(fds)
    for fd, op, target in redirs:
        value = target.value
        if op in ("<&", ">&"):
            if value == "-":
                fds[fd] = None
            elif value.rstrip("-").isdigit():
                other = int(value.rstrip("-"))
                fds[fd] = fd_source(fds, other)
                if value.endswith("-"):
                    fds[other] = None
            # Dynamic duplicates cannot prove that dangerous stdin was isolated.
        elif op in ("<", "<>"):
            match = re.fullmatch(r"/(?:dev/fd|proc/self/fd)/(\d+)", value)
            if value == "/dev/stdin":
                fds[fd] = fd_source(fds, 0)
            elif match:
                fds[fd] = fd_source(fds, int(match.group(1)))
            elif "$" not in value and "`" not in value:
                # A fresh open has an independent offset, even for the same path.
                fds[fd] = ("input", id(target))
        elif op in ("<<", "<<-", "<<<"):
            fds[fd] = ("input", id(target))
        elif op in (">", ">>", ">|"):
            fds[fd] = None
    return fds


def read_sources(node, fds):
    result = set()
    effective = redirected(fds, node.redirs)
    if node.kind == "simple":
        ws = command_words(node.words)
        if ws and ws[0].value == "read":
            fd, i = 0, 1
            while i < len(ws):
                value = ws[i].value
                match = re.fullmatch(r"-[A-Za-z]*u(\d*)", value)
                if match:
                    arg = match.group(1)
                    if not arg and i + 1 < len(ws):
                        i += 1
                        arg = ws[i].value
                    fd = int(arg) if arg.isdigit() else None
                i += 1
            if fd is not None:
                source = fd_source(effective, fd)
                if source is not None:
                    result.add(source)
    elif node.kind == "pipe":
        # Only the first pipeline element inherits the condition's input.
        return read_sources(node.children[0], effective)
    elif node.kind not in ("function", "while", "until", "for"):
        for child in node.children:
            result.update(read_sources(child, effective))
            if (child.kind == "simple" and child.words and child.words[0].value == "exec"
                    and not command_words(child.words)):
                effective = redirected(effective, child.redirs)
    return result


def lint(source, path=""):
    tree = Parser(Lexer(source).tokens()).sequence()
    diagnostics = []

    def substitutions(words, fds, hazards):
        for word in words:
            for tokens in word.subs:
                if word.kind == "group":
                    # Array literals / parenthesized word syntax are data, but
                    # their command substitutions still execute.
                    substitutions(tokens, fds, hazards)
                else:
                    visit(Parser(tokens).sequence(), dict(fds), hazards)

    def visit(node, fds, hazards):
        # Ordinary arguments expand before simple-command redirects. Heredocs
        # expand when their redirect is reached, after preceding redirects but
        # before the heredoc itself replaces the descriptor. Compound bodies
        # execute only after all their redirects have been applied.
        substitutions(node.words, fds, hazards)
        effective = dict(fds)
        for redirect in node.redirs:
            _, op, target = redirect
            substitutions([target], effective if op in ("<<", "<<-") else fds, hazards)
            effective = redirected(effective, [redirect])
        if node.kind == "simple":
            call = remote_call(node.words, path)
            if call and fd_source(effective, 0) in hazards:
                diagnostics.append((call.line, "F1: while read 循环中的远端调用会读取循环 stdin；ssh 用 -n，或给调用加 </dev/null"))
            ws = command_words(node.words)
            if node.words and node.words[0].value == "exec" and not ws:
                return effective
        elif node.kind == "list":
            for child in node.children:
                effective = visit(child, effective, hazards)
        elif node.kind == "pipe":
            for i, child in enumerate(node.children):
                local = dict(effective)
                if i:
                    local[0] = ("pipe", id(child))
                visit(child, local, hazards)
        elif node.kind in ("while", "until"):
            visit(node.children[0], dict(effective), hazards)
            local_hazards = set(hazards)
            if node.kind == "while":
                local_hazards.update(read_sources(node.children[0], effective))
            visit(node.children[1], dict(effective), local_hazards)
        elif node.kind == "function":
            # Definition does not execute in the surrounding loop; own loops do.
            for child in node.children:
                visit(child, {}, set())
        else:
            for child in node.children:
                visit(child, dict(effective), hazards)
        return fds

    visit(tree, {}, set())
    return sorted(set(diagnostics))


def main(argv=None):
    failed = False
    for name in sys.argv[1:] if argv is None else argv:
        try:
            messages = lint(Path(name).read_text(encoding="utf-8"), name)
        except (OSError, UnicodeError, ScanError) as exc:
            print(f"{name}: F1 扫描失败（未完成，不算通过）：{exc}", file=sys.stderr)
            return 2
        for line, message in messages:
            print(f"{name}:{line}: {message}")
        failed |= bool(messages)
    return int(failed)


if __name__ == "__main__":
    raise SystemExit(main())
