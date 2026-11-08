#!/usr/bin/env python3
"""Exercise Android's real rewrite entry with a controlled scanner and rewriter."""
import importlib.util
from pathlib import Path
from types import SimpleNamespace
from unittest import mock
import tempfile

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('make_pack', ROOT / 'android/tools/make_pack.py')
pack = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pack)


def run_case(kind):
    with tempfile.TemporaryDirectory(prefix='android-widen-test-') as temp:
        root = Path(temp)
        exefs, out = root / 'exefs', root / 'out'
        exefs.mkdir()
        (exefs / 'main').write_bytes(b'synthetic')
        (exefs / 'main.npdm').write_bytes(b'synthetic')
        (root / 's2a_caps.tsv').write_text('plat\tandroid\nwiden\t' + ('0' if kind == 'disabled' else '1') + '\n')
        rewritten = []

        def invoke(args, **kwargs):
            if str(args[1]).endswith('wide_scan.py'):
                if kind == 'start-error':
                    raise OSError('scanner unavailable')
                if kind == 'scan-error':
                    return SimpleNamespace(returncode=9, stdout='', stderr='synthetic scan error')
                if kind != 'missing-output':
                    Path(args[-1]).write_text('模块\t偏移\t种类\t证据\n' + ('' if kind == 'empty' else 'main\t0x1234\tf2w\ttest\n'))
                return SimpleNamespace(returncode=0, stdout='', stderr='')
            rewritten.append(args)
            assert len(args) == (4 if kind == 'disabled' else 5)
            if kind != 'disabled':
                assert Path(args[4]).is_file(), 'candidate table must outlive the rewriter'
                assert Path(args[4]).read_text().startswith('模块\t偏移')
            for suffix in ('sites.tsv', 'gaps.tsv'):
                (out / ('main.' + suffix)).write_text('')
            return SimpleNamespace(returncode=0, stdout='', stderr='')

        with mock.patch.object(pack, 'rewrite_command', return_value=['rewriter']), \
             mock.patch.object(pack, 'validate_module'), mock.patch.object(pack.subprocess, 'run', side_effect=invoke):
            try:
                pack.rewrite(str(exefs), str(out))
            except SystemExit as error:
                assert kind in ('scan-error', 'missing-output', 'start-error'), str(error)
                assert '红' in str(error), str(error)
                assert not rewritten, 'rewriter ran after scanner failure'
            else:
                assert kind in ('empty', 'sites', 'disabled'), f'{kind}: scanner failure treated as success'
                assert len(rewritten) == 1
    print(kind, 'PASS')


for case in ('scan-error', 'missing-output', 'start-error', 'empty', 'sites', 'disabled'):
    run_case(case)
