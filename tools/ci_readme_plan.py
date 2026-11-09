#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""Only regular edits to the two root READMEs may skip the public code jobs.

PRs compare merge-base to head; pushes compare before to after. Added, deleted,
renamed or non-regular files, unknown events and unavailable history use full CI.
Reads GITHUB_EVENT_NAME / GITHUB_EVENT_PATH and appends to GITHUB_OUTPUT.
"""
import json
import os
from pathlib import Path
import re
import subprocess

READMES = frozenset(('README.md', 'README.zh-CN.md'))


def git(repo, *args):
    return subprocess.run(['git', '-C', str(repo), *args], check=True,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=15).stdout


def valid_sha(value):
    return (isinstance(value, str) and
            re.fullmatch(r'(?:[0-9a-f]{40}|[0-9a-f]{64})', value) is not None and
            bool(value.strip('0')))


def readme_only(repo, event_name, event):
    """Fail closed: False selects the existing full Linux and macOS checks."""
    try:
        if event_name == 'pull_request':
            base = event['pull_request']['base']['sha']
            head = event['pull_request']['head']['sha']
        elif event_name == 'push':
            base, head = event['before'], event['after']
        else:
            return False
        if not valid_sha(base) or not valid_sha(head):
            return False
        if event_name == 'pull_request':
            base = git(repo, 'merge-base', base, head).decode('ascii').strip()
        raw = git(repo, 'diff', '--no-ext-diff', '--no-textconv', '--no-renames',
                  '--name-status', '-z', base, head, '--')
        records = raw.decode('utf-8').split('\0')
        if len(records) < 3 or records[-1] != '' or len(records) % 2 != 1:
            return False
        paths = set()
        for status, path in zip(records[0:-1:2], records[1:-1:2]):
            if status != 'M' or path not in READMES:
                return False
            paths.add(path)
        for revision in (base, head):
            entries = git(repo, 'ls-tree', '-z', revision, '--', *sorted(paths))
            regular = set()
            for entry in entries.decode('utf-8').split('\0'):
                if not entry:
                    continue
                metadata, path = entry.split('\t', 1)
                mode, kind, _ = metadata.split()
                if mode != '100644' or kind != 'blob':
                    return False
                regular.add(path)
            if regular != paths:
                return False
        return bool(paths)
    except (KeyError, TypeError, ValueError, UnicodeError, OSError,
            subprocess.CalledProcessError, subprocess.TimeoutExpired):
        return False


def main():
    try:
        event = json.loads(Path(os.environ['GITHUB_EVENT_PATH']).read_text(encoding='utf-8'))
    except (KeyError, ValueError, OSError):
        event = {}
    lightweight = readme_only(Path.cwd(), os.environ.get('GITHUB_EVENT_NAME', ''), event)
    print('CI plan: README-only' if lightweight else 'CI plan: full')
    if os.environ.get('GITHUB_OUTPUT'):
        with open(os.environ['GITHUB_OUTPUT'], 'a', encoding='utf-8', newline='\n') as output:
            output.write(f'readme_only={str(lightweight).lower()}\n')


if __name__ == '__main__':
    main()
