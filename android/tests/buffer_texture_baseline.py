#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""Opt-in historical red probe. Not registered as a green gate or device proof."""
import os
from pathlib import Path
import shlex
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def function(text, marker):
    if text.count(marker) != 1:
        raise RuntimeError('production marker changed: ' + marker)
    start = text.index(marker)
    level = 0
    for i in range(text.index('{', start), len(text)):
        if text[i] == '{':
            level += 1
        elif text[i] == '}':
            level -= 1
            if not level:
                return text[start:i + 1] + '\n'
    raise RuntimeError('unclosed production function')


def main():
    source = (ROOT / 'android/native/direct/vk_record.c').read_text()
    guard = '''            if (copy.flags || copy.has_view || copy.r.xoffset || copy.r.yoffset || copy.r.zoffset)
                return fail(result, S2A_RECORD_UNSUPPORTED, header.op,
                            "buffer/texture copy with view/flags/offset is not wired yet");'''
    if source.count(guard) != 1:
        raise RuntimeError('record guard changed; review baseline, do not silently adapt')
    with tempfile.TemporaryDirectory(prefix='s2a-bt-baseline-') as temp:
        path = Path(temp)
        (path / 'buffer_texture_record.inc').write_text(function(source, 'static int copy_image_buffer('))
        (path / 'buffer_texture_guard.inc').write_text(guard + '\n')
        cmd = shlex.split(os.environ.get('CC', 'cc')) + ['-std=c11', '-Wall', '-Wextra', '-Werror']
        cmd += shlex.split(os.environ.get('CFLAGS', ''))
        cmd += ['-I' + str(path), '-I' + str(ROOT / 'android/tests/vkhost'),
                '-I' + str(ROOT / 'graphics/nvn/third_party/vulkan-headers/include')]
        binary = path / 'baseline'
        subprocess.run(cmd + [str(Path(__file__).with_suffix('.c')), '-o', str(binary)], check=True, timeout=30)
        return subprocess.run([str(binary)], timeout=10).returncode


if __name__ == '__main__':
    raise SystemExit(main())
