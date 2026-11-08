#!/usr/bin/env python3
"""Synthetic #281 cases; no game, shader compiler, GPU, network or device."""
import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
import rt_recover as rr

# Share only the table names; the stamp oracle below stays independent of inputs().
chain_spec = importlib.util.spec_from_file_location(
    '_test_rt_chain', HERE.parents[3] / 'translator/dmsh_chain.py')
chain_module = importlib.util.module_from_spec(chain_spec)
chain_spec.loader.exec_module(chain_module)
INPUT_TABLES = tuple(chain_module.INPUT_TABLES)

V = '012345abcdef'
OLD = 'abcdef012345'
TID = '0100000000000001'


def digest(data):
    return hashlib.sha256(data).hexdigest()


class RecoverTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.rt = self.base / 'runtime'
        self.rt.mkdir()
        self.cache = self.base / 'cache'
        self.merged = self.cache / 'work/merged'
        (self.merged / 'pkg').mkdir(parents=True)
        self.library = self.cache / 'mac'
        self.lib = self.library / ('b-' + V)
        self.lib.mkdir(parents=True)
        self.tables = self.base / 'tables'
        self.tables.mkdir()
        for n in rr.TABLES:
            (self.tables / n).write_text('# independent synthetic context\n')
        (self.tables / 'game.tsv').write_text('id\t' + TID + '\nshader_test\t1\n')
        self.header = self.base / 'chain.h'
        self.header.write_text('#define DMSH_CHAIN "' + V + '"\n')
        self.control = bytearray(0x880)
        struct.pack_into('<I', self.control, 0x20, 0x880)
        self.control = bytes(self.control)
        self.code = bytes(range(64))
        # Oracle comes from the documented raw-key/record contract, not recover().
        self.key = digest(self.control + self.code)[:16]
        rec = bytearray(b'BTCDBTCD' + bytes(0x30))
        struct.pack_into('<II', rec, 0x28, len(self.control), len(self.code))
        self.record = bytes(rec) + self.code + self.control
        (self.merged / 'pkg/ps_test.bin').write_bytes(self.record)
        (self.merged / 'shader_map.tsv').write_text('ps_test.bin\t0\tpixel\t' + self.key + '\tsynthetic\n')
        (self.merged / 'union_keys.tsv').write_text(self.key + '\n')
        self.meta = {'key': self.key + '_b', 'stage': 'ps', 'chain': V}
        self.put_meta(self.rt, self.meta)
        self.put_meta(self.lib, self.meta)
        self.msl = b'// synthetic pixel source\n'
        self.source(self.rt).write_bytes(self.msl)
        self.source(self.lib).write_bytes(self.msl)
        (self.lib / (self.key + '_b.metallib')).write_bytes(b'synthetic inventory marker; not a GPU library')
        self.stamp()
        self.write_log()

    def source(self, directory):
        return directory / (self.key + '_b.metal')

    def put_meta(self, directory, value):
        (directory / (self.key + '_b.json')).write_text(json.dumps(value))

    def stamp(self):
        h = hashlib.sha256()
        for n in INPUT_TABLES:
            path = self.tables / n
            content = path.read_bytes() if path.exists() else b'missing'
            h.update(('game/' + n).encode() + b'\0' + content + b'\0')
        h.update(b'shader_test\t1\n')
        (self.lib / 'inputs.tsv').write_text('game\t' + TID + '\ninputs\t' + h.hexdigest()[:12] + '\n')

    def stamp_line(self):
        rows = dict(line.split('\t') for line in (self.lib / 'inputs.tsv').read_text().splitlines())
        return 'shader library stamp: game ' + TID + ', inputs ' + rows['inputs'] + '\n'

    def write_log(self):
        self.log = self.base / 'host.log'
        lines = [self.stamp_line()]
        count = 0
        for path in sorted(self.rt.glob('*_b.json')):
            meta = json.loads(path.read_text())
            if meta.get('chain') != V:
                continue
            count += 1
            word = {'ps': 'pixel', 'vs': 'vertex', 'gs': 'geometry'}[meta['stage']]
            lines.append('直连着色器现编 ' + str(count) + ' 次：' + meta['key'][:-2] + '（' + word + '，1.0 ms）\n')
        lines.append('直连着色器现编汇总：成功 ' + str(count) + '、失败 0、跳过 0、复用上局 0、输出类型变体 0（正常收局）\n')
        self.log.write_text(''.join(lines))

    def recover(self, dirs=None, log='default'):
        return rr.recover(dirs or [self.rt], self.cache, self.library, self.tables, self.header,
                          self.log if log == 'default' else log)

    def test_matching_host_library_stamp_without_sidecar(self):
        result = self.recover()
        self.assertEqual(result['rows'], [[self.key, 'ps', V, 'lib_miss', 'same']])
        self.assertEqual(result['exit_code'], 0)

    def test_profile_parser_matches_offline_whitespace_contract(self):
        (self.tables / 'game.tsv').write_text('  # comment\n id \t ' + TID + ' \n shader_test \t 1 \n')
        self.stamp()
        self.write_log()
        result = self.recover()
        self.assertEqual(result['rows'][0][-1], 'same')
        self.assertEqual(result['exit_code'], 0)

    def test_byte_difference_is_red(self):
        self.source(self.lib).write_bytes(self.msl + b'// different\n')
        result = self.recover()
        self.assertEqual(result['rows'][0][-1], 'diff')
        self.assertEqual(result['exit_code'], 1)

    def test_old_chain_skips_without_source_or_cache(self):
        self.put_meta(self.rt, {**self.meta, 'chain': OLD})
        self.source(self.rt).unlink()
        shutil.rmtree(self.cache)
        result = self.recover()
        self.assertEqual(result['rows'], [[self.key, 'ps', OLD, 'chain_skip', 'n/a']])
        self.assertEqual(result['counts']['chain_skip_entries'], 1)
        self.assertEqual(result['exit_code'], 0)

    def test_bad_json_and_non_object_are_reported(self):
        for value in ('{bad', '[]', 'null'):
            with self.subTest(value=value):
                (self.rt / (self.key + '_b.json')).write_text(value)
                result = self.recover()
                self.assertEqual(result['exit_code'], 1)
                self.assertEqual(result['counts']['invalid'], 1)
                self.assertEqual(result['rows'], [])

    def test_missing_runtime_msl_is_invalid(self):
        self.source(self.rt).unlink()
        self.assertEqual(self.recover()['exit_code'], 1)

    def test_orphan_msl_is_reported(self):
        (self.rt / (self.key + '_b.json')).unlink()
        result = self.recover()
        self.assertEqual(result['exit_code'], 1)
        self.assertIn('缺对应反射', result['issues'][0]['reason'])

    def test_missing_host_log_is_unverified_even_when_bytes_equal(self):
        result = self.recover(log=None)
        self.assertEqual(result['rows'][0][-1], 'n/a')
        self.assertEqual(result['exit_code'], 2)

    def test_changed_tables_are_not_a_byte_pass(self):
        (self.tables / 'shader_facts.tsv').write_text('# changed\n')
        result = self.recover()
        self.assertEqual(result['rows'][0][-1], 'n/a')
        self.assertEqual(result['exit_code'], 2)

    def test_input_tables_include_fout_once(self):
        self.assertIn('fout_want.tsv', INPUT_TABLES)
        self.assertEqual(len(INPUT_TABLES), len(set(INPUT_TABLES)))

    def test_missing_fout_table_invalidates_existing_stamp(self):
        fout = self.tables / 'fout_want.tsv'
        fout.write_text('# synthetic output types\n')
        self.stamp()
        self.write_log()
        before = self.recover()
        self.assertEqual(before['rows'][0][-1], 'same')
        self.assertEqual(before['exit_code'], 0)
        fout.unlink()
        result = self.recover()
        self.assertEqual(result['rows'][0][-1], 'n/a')
        self.assertEqual(result['exit_code'], 2)
        self.assertEqual(result['detail'][self.key]['comparison_reason'], '离线库输入戳与当前表不符')

    def test_added_or_changed_fout_table_invalidates_existing_stamp(self):
        fout = self.tables / 'fout_want.tsv'
        for initial in (None, '# synthetic output types\n'):
            with self.subTest(initial=initial):
                if initial is None:
                    fout.unlink(missing_ok=True)
                else:
                    fout.write_text(initial)
                self.stamp()
                self.write_log()
                before = self.recover()
                self.assertEqual(before['rows'][0][-1], 'same')
                self.assertEqual(before['exit_code'], 0)
                fout.write_text('# changed output types\n')
                result = self.recover()
                self.assertEqual(result['rows'][0][-1], 'n/a')
                self.assertEqual(result['exit_code'], 2)
                self.assertEqual(result['detail'][self.key]['comparison_reason'], '离线库输入戳与当前表不符')

    def test_bad_library_input_stamp_is_unverified(self):
        (self.lib / 'inputs.tsv').write_text('game\t' + TID + '\ninputs\tbad\n')
        self.assertEqual(self.recover()['rows'][0][-1], 'n/a')

    def test_missing_or_different_library_stamp_is_unverified(self):
        original = self.log.read_text()
        stamp = self.stamp_line()
        variants = [original.replace(stamp, ''), original.replace(TID, '0100000000000002'),
                    original.replace(stamp, 'shader library stamp: game ' + TID + ', inputs 000000000000\n'),
                    original + stamp, original + stamp.replace(TID, '0100000000000002'),
                    original + 'shader library stamp: game invalid, inputs bad\n',
                    original.replace(stamp, 'shader library stamp: game invalid, inputs bad\n')]
        for text in variants:
            with self.subTest(text=text):
                self.log.write_text(text)
                result = self.recover()
                self.assertEqual(result['rows'][0][-1], 'n/a')
                self.assertEqual(result['exit_code'], 2)

    def test_missing_fragment_inputs_is_unverified(self):
        (self.tables / 'ps_inputs.tsv').unlink()
        self.assertEqual(self.recover()['rows'][0][-1], 'n/a')

    def test_obsolete_sidecar_does_not_gate_comparison(self):
        (self.rt / 'rt_context.json').write_text('{obsolete')
        self.assertEqual(self.recover()['exit_code'], 0)

    def test_current_chain_wins_over_old_in_either_order(self):
        old = self.base / 'old'
        old.mkdir()
        self.put_meta(old, {**self.meta, 'chain': OLD})
        for dirs in ([old, self.rt], [self.rt, old]):
            result = self.recover(dirs)
            self.assertEqual(result['rows'][0], [self.key, 'ps', V, 'lib_miss', 'same'])
            self.assertEqual(result['counts']['chain_skip_entries'], 1)

    def test_duplicate_same_and_duplicate_conflict(self):
        other = self.base / 'other'
        shutil.copytree(self.rt, other)
        result = self.recover([self.rt, other])
        self.assertEqual(result['counts']['duplicate'], 1)
        self.assertEqual(len(result['rows']), 1)
        self.source(other).write_bytes(b'// conflict\n')
        result = self.recover([self.rt, other])
        self.assertEqual(result['counts']['duplicate_conflict'], 1)
        self.assertEqual(result['rows'][0][-1], 'n/a')
        self.assertEqual(result['exit_code'], 1)

    def test_truncated_record_and_wrong_key_are_invalid(self):
        package = self.merged / 'pkg/ps_test.bin'
        for data in (self.record[:-1], self.record[:-2] + b'ZZ'):
            with self.subTest(length=len(data)):
                package.write_bytes(data)
                result = self.recover()
                self.assertEqual(result['exit_code'], 1)
                self.assertIn('原料无效', result['detail'][self.key]['comparison_reason'])

    def test_stage_mismatch_is_invalid(self):
        (self.merged / 'shader_map.tsv').write_text('ps_test.bin\t0\tvertex\t' + self.key + '\tsynthetic\n')
        self.assertEqual(self.recover()['exit_code'], 1)

    def test_empty_union_is_extract_gap(self):
        (self.merged / 'union_keys.tsv').write_text('')
        result = self.recover()
        self.assertEqual(result['rows'][0][-2:], ['extract_gap', 'n/a'])
        self.assertEqual(result['exit_code'], 2)

    def test_unbuilt_library_reports_reason(self):
        (self.lib / (self.key + '_b.metallib')).unlink()
        (self.cache / 'work/build.log').write_text(self.key + ': synthetic translation failed\n')
        result = self.recover()
        self.assertEqual(result['rows'][0][-2:], ['build_fail', 'same'])
        self.assertIn('translation failed', result['detail'][self.key]['classification_reason'])

    def test_missing_union_is_not_extract_gap(self):
        (self.merged / 'union_keys.tsv').unlink()
        with self.assertRaises(OSError):
            self.recover()

    def test_complete_and_incomplete_single_run_log(self):
        log = self.base / 'host.log'
        event = '直连着色器现编 1 次：' + self.key + '（pixel，1.0 ms）\n'
        summary = '直连着色器现编汇总：成功 1、失败 0、跳过 0、复用上局 0、输出类型变体 0（正常收局）\n'
        log.write_text(self.stamp_line() + event + summary)
        self.assertEqual(self.recover(log=log)['exit_code'], 0)
        for text in (event, summary, event + summary.replace('正常收局', '超时收局'), event + summary + summary):
            with self.subTest(text=text):
                log.write_text(self.stamp_line() + text)
                result = self.recover(log=log)
                self.assertEqual(result['counts']['log_incomplete'], 1)
                self.assertEqual(result['rows'][0][-1], 'n/a')
                self.assertEqual(result['exit_code'], 2)

    def test_geometry_artifact_difference_and_missing_artifact(self):
        self.put_meta(self.rt, {**self.meta, 'stage': 'gs'})
        self.put_meta(self.lib, {**self.meta, 'stage': 'gs'})
        (self.merged / 'shader_map.tsv').write_text('ps_test.bin\t0\tgeometry\t' + self.key + '\tsynthetic\n')
        for d in (self.rt, self.lib):
            (d / (self.key + '_bg0.metal')).write_bytes(b'// synthetic geometry\n')
        self.write_log()
        self.assertEqual(self.recover()['rows'][0][-1], 'same')
        p = self.lib / (self.key + '_bg0.metal')
        p.write_bytes(b'// changed geometry\n')
        self.assertEqual(self.recover()['rows'][0][-1], 'diff')
        p.unlink()
        self.assertEqual(self.recover()['rows'][0][-1], 'n/a')

    def vertex_pair(self):
        code = bytes(reversed(range(64)))
        key = digest(self.control + code)[:16]
        record = bytearray(b'BTCDBTCD' + bytes(0x30))
        struct.pack_into('<II', record, 0x28, len(self.control), len(code))
        (self.merged / 'pkg/vs_test.bin').write_bytes(bytes(record) + code + self.control)
        with (self.merged / 'shader_map.tsv').open('a') as f:
            f.write('vs_test.bin\t0\tvertex\t' + key + '\tsynthetic\n')
        with (self.merged / 'union_keys.tsv').open('a') as f:
            f.write(key + '\n')
        for d in (self.rt, self.lib):
            (d / (key + '_b.json')).write_text(json.dumps({'key': key + '_b', 'chain': V, 'stage': 'vs'}))
            (d / (key + '_b.metal')).write_bytes(b'// synthetic vertex\n')
        (self.lib / (key + '_b.metallib')).write_bytes(b'synthetic inventory marker')
        (self.tables / 'shader_pairs.tsv').write_text(key + '\t' + self.key + '\n')
        self.stamp()
        self.write_log()
        return key

    def test_multiple_keys_and_vertex_fragment_context(self):
        key = self.vertex_pair()
        result = self.recover()
        self.assertEqual(len(result['rows']), 2)
        self.assertEqual(result['counts']['same'], 2)
        self.assertEqual(result['exit_code'], 0)
        (self.rt / (self.key + '_b.json')).unlink()
        self.source(self.rt).unlink()
        result = self.recover()
        self.assertEqual(result['exit_code'], 2)
        self.assertEqual(result['counts'].get('same', 0), 0)
        self.assertIn('配对片元', result['detail'][key]['comparison_reason'])

    def test_output_inside_input_is_rejected(self):
        out = self.rt / 'report'
        p = subprocess.run([sys.executable, str(HERE.parent / 'rt_recover.py'), '--fallback', str(self.rt),
                            '--direct-cache', str(self.cache), '--tables', str(self.tables),
                            '--chain-header', str(self.header), '--host-log', str(self.log), '--out', str(out)], capture_output=True, text=True)
        self.assertEqual(p.returncode, 1)
        self.assertFalse(out.exists())

    def test_cli_writes_interface_and_rejects_stale_output(self):
        out = self.base / 'out'
        command = [sys.executable, str(HERE.parent / 'rt_recover.py'), '--fallback', str(self.rt),
                   '--direct-cache', str(self.cache), '--tables', str(self.tables),
                   '--chain-header', str(self.header), '--host-log', str(self.log), '--out', str(out)]
        p = subprocess.run(command, capture_output=True, text=True)
        self.assertEqual(p.returncode, 0, p.stderr)
        rows = [s for s in (out / 'rt_recover.tsv').read_text().splitlines() if not s.startswith('#')]
        self.assertEqual(rows, ['\t'.join([self.key, 'ps', V, 'lib_miss', 'same'])])
        self.assertTrue((out / 'rt_recover.tsv').read_text().splitlines()[-1].startswith('# summary '))
        before = (out / 'rt_recover.tsv').read_bytes()
        p = subprocess.run(command, capture_output=True, text=True)
        self.assertEqual(p.returncode, 1)
        self.assertEqual((out / 'rt_recover.tsv').read_bytes(), before)


if __name__ == '__main__':
    unittest.main(verbosity=2)
