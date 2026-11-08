"""F2: scan literal timeout invocations, without executing shell source.

This is a token-level check, not shell expansion: eval, shell -c, aliases and
commands inside quoted substitutions are outside its scope. Heredoc bodies
are data here. The existing shell syntax gate remains responsible for syntax.
"""

import re
import shlex
import sys
from pathlib import Path


TOKEN = re.compile(r'''\n|\#[^\n]*|<<-|[;&|()<>]+|(?:[^\s;&|()<>'"\\]+|'[^']*'|"(?:\\[\s\S]|[^"\\])*"|\\[\s\S])+''')
DURATION = re.compile(r'(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)[smhd]?\Z')
ASSIGNMENT = re.compile(r'[A-Za-z_][A-Za-z0-9_]*=')


def literal(word):
    """Remove shell quotes/escapes from one token, without any expansion."""
    parts = shlex.split(word, comments=False)
    return parts[0] if len(parts) == 1 else word


def commands(source):
    # Keep original offsets/line numbers when folding escaped newlines.
    original = source
    source = re.sub(r'\\\n', '  ', source)
    pending = []
    heredoc = None
    command = []
    skip_until = 0
    line = 1
    previous_end = 0
    for match in TOKEN.finditer(source):
        if match.start() < skip_until:
            continue
        line += original.count('\n', previous_end, match.start())
        previous_end = match.start()
        word = match.group()
        if word.startswith('#'):
            continue
        if heredoc is not None:
            pending.append((literal(word), heredoc == '<<-'))
            heredoc = None
            continue
        if word in ('<<', '<<-'):
            heredoc = word
            continue
        if word == '\n' or word[0] in ';&|()':
            if command:
                yield command
            command = []
            if word == '\n' and pending:
                pos = match.end()
                for delimiter, tabs in pending:
                    while pos < len(source):
                        end = source.find('\n', pos)
                        end = len(source) if end < 0 else end + 1
                        body = source[pos:end].rstrip('\n')
                        pos = end
                        if (body.lstrip('\t') if tabs else body) == delimiter:
                            break
                skip_until = pos
                pending = []
            continue
        command.append((word, line))
    if command:
        yield command


def violations(source):
    """Return (original line, variable name) for literal malformed commands."""
    for command in commands(source):
        words = [literal(word) for word, _ in command]
        while words and (ASSIGNMENT.match(words[0]) or words[0] in
                         ('if', 'then', 'elif', 'else', 'while', 'until', 'do',
                          '!', '{', 'command', 'exec')):
            words.pop(0)
            command.pop(0)
        if not words or words.pop(0).rsplit('/', 1)[-1] not in ('timeout', 'gtimeout'):
            continue
        command.pop(0)
        # GNU timeout options before DURATION (including -- and -k/-s values).
        while words and words[0].startswith('-'):
            option = words.pop(0)
            command.pop(0)
            if option == '--':
                break
            if option in ('-k', '-s', '--kill-after', '--signal') and words:
                words.pop(0)
                command.pop(0)
        if len(words) >= 2 and DURATION.fullmatch(words[0]):
            assignment = ASSIGNMENT.match(words[1])
            if assignment:
                yield command[1][1], assignment.group()[:-1]


def main():
    failed = False
    for name in sys.argv[1:]:
        for line, variable in violations(Path(name).read_text(encoding='utf-8')):
            print(f'{name}:{line}: timeout 把 {variable}=… 当命令；改为 timeout N env {variable}=… cmd')
            failed = True
    return int(failed)


if __name__ == '__main__':
    sys.exit(main())
