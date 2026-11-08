#!/usr/bin/env python3
"""Host-only producer contract for the generic compile-event evidence file."""
import json
import os
import subprocess
import tempfile
import sys
import unittest
from pathlib import Path

ANDROID = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ANDROID))
import compile_events
HARNESS = r'''
#include <stdint.h>
#include <stdlib.h>
int s2a_ce_init(const char *, uint64_t);
int s2a_ce_record(uint32_t, uint32_t, uint64_t, uint64_t);
int s2a_ce_flush(void);
uint64_t s2a_ce_now(void);
int main(int argc, char **argv) {
    if (argc != 2) return 10;
    if (s2a_ce_init(argv[1], 42) != 0) return 11;
    uint64_t start = s2a_ce_now(), end = s2a_ce_now();
    if (s2a_ce_record(1, 2, start, end) != 0) return 12;
    return s2a_ce_flush() == 0 ? 0 : 13;
}
'''

class EventFileContract(unittest.TestCase):
    def test_one_translation_is_complete_and_clocked(self):
        with tempfile.TemporaryDirectory(prefix='compile-events-') as td:
            td = Path(td); source = td/'fixture.c'; source.write_text(HARNESS)
            exe = td/'fixture'
            cmd = [os.environ.get('CC','cc'), '-std=c11', '-Wall', '-Wextra', '-Werror',
                   '-DS2A_CE_TESTING', '-pthread', str(source),
                   str(ANDROID/'native/nvn/nvn_vk_compile_events.c'),
                   str(ANDROID/'native/direct/sha256.c'), '-o', str(exe)]
            subprocess.run(cmd, check=True, timeout=30, capture_output=True, text=True)
            env = {**os.environ, 'S2A_CE_TEST_ENABLE':'1'}
            proc = subprocess.run([str(exe), str(td)], env=env, check=True, capture_output=True, text=True, timeout=10)
            files = list(td.glob('compile-events-*.jsonl'))
            self.assertEqual(len(files), 1)
            meta, event, footer = [json.loads(line) for line in files[0].read_text().splitlines()]
            self.assertEqual((meta['schema'], meta['clock'], meta['session']), ('s2a-compile-events-v2','CLOCK_BOOTTIME',42))
            self.assertEqual(meta['capacity'], 16384)
            self.assertGreater(meta['pid'], 0)
            self.assertGreater(meta['begin_us'], 0)
            self.assertGreaterEqual(footer['end_us'], meta['begin_us'])
            self.assertEqual((event['id'],event['kind'],event['result']), (1,'translation','miss'))
            self.assertLessEqual(meta['begin_us'], event['start_us'])
            self.assertLessEqual(event['end_us'], footer['end_us'])
            parsed = compile_events.parse(files[0].read_bytes(), pid=meta['pid'], session=42, window=(event['start_us'], event['end_us']))
            self.assertEqual(parsed['misses'], 1)
            self.assertEqual((footer['count'],footer['dropped'],footer['status']), (1,0,'complete'))

    def test_gate_off_and_full_buffer_fail_closed(self):
        with tempfile.TemporaryDirectory(prefix='compile-events-bound-') as name:
            td = Path(name); source = td/'fixture.c'; exe = td/'fixture'
            source.write_text(HARNESS.replace(
                'if (s2a_ce_record(1, 2, start, end) != 0) return 12;',
                'for (int i = 0; i < 4100; i++) if (s2a_ce_record(1, 2, start, end) != 0) return 12;'))
            subprocess.run([os.environ.get('CC','cc'), '-std=c11','-Wall','-Wextra','-Werror',
                '-DS2A_CE_TESTING','-pthread',str(source), str(ANDROID/'native/nvn/nvn_vk_compile_events.c'),
                str(ANDROID/'native/direct/sha256.c'),'-o',str(exe)],check=True,timeout=30)
            disabled=td/'disabled'; disabled.mkdir()
            subprocess.run([str(exe),str(disabled)],env={**os.environ,'S2A_CE_TEST_ENABLE':'0'},check=True,timeout=10)
            self.assertEqual(list(disabled.glob('compile-events-*.jsonl')),[])
            enabled=td/'enabled'; enabled.mkdir()
            subprocess.run([str(exe),str(enabled)],env={**os.environ,'S2A_CE_TEST_ENABLE':'1','S2A_CE_TEST_CAP':'4096'},check=True,timeout=10)
            path=next(enabled.glob('compile-events-*.jsonl')); lines=path.read_text().splitlines()
            header=json.loads(lines[0]); footer=json.loads(lines[-1])
            self.assertEqual((footer['count'],footer['dropped']), (4096,4))
            with self.assertRaisesRegex(ValueError,'dropped'):
                compile_events.parse(path.read_bytes(),pid=header['pid'],session=42,
                                     window=(header['begin_us'],footer['end_us']))

class HitAggregationContract(unittest.TestCase):
    def test_many_hits_do_not_displace_misses_and_capacity_is_enforced(self):
        harness = r'''
#include <stdint.h>
#include <stdlib.h>
int s2a_ce_init(const char *, uint64_t);
int s2a_ce_record(uint32_t, uint32_t, uint64_t, uint64_t);
int s2a_ce_flush(void);
uint64_t s2a_ce_now(void);
int main(int argc, char **argv) {
    if (argc != 2 || s2a_ce_init(argv[1], 42)) return 1;
    uint64_t t = s2a_ce_now();
    for (int i=0; i<100000; i++) if (s2a_ce_record(1,1,t,t)) return 2;
    for (int i=0; i<3; i++) if (s2a_ce_record(1,2,t,t)) return 3;
    if (s2a_ce_record(1,3,t,t) || s2a_ce_record(2,2,t,t)) return 4;
    return s2a_ce_flush() == 0 ? 0 : 5;
}
'''
        with tempfile.TemporaryDirectory(prefix='ce-hits-') as td:
            root=Path(td); source=root/'test.c'; exe=root/'test'; source.write_text(harness)
            subprocess.run([os.environ.get('CC','cc'),'-std=c11','-Wall','-Wextra','-Werror',
                '-DS2A_CE_TESTING','-pthread',str(source),str(ANDROID/'native/nvn/nvn_vk_compile_events.c'),
                str(ANDROID/'native/direct/sha256.c'),'-o',str(exe)],check=True,timeout=30)
            env={**os.environ,'S2A_CE_TEST_ENABLE':'1','S2A_CE_TEST_CAP':'5'}
            subprocess.run([str(exe),str(root)],env=env,check=True,timeout=30)
            raw=next(root.glob('compile-events-*.jsonl')).read_bytes()
            rows=[json.loads(line) for line in raw.splitlines()]
            self.assertEqual((rows[-1]['count'],rows[-1]['dropped']), (5,0))
            self.assertEqual(rows[0]['schema'],'s2a-compile-events-v2')
            self.assertEqual(rows[0]['capacity'],5)
            self.assertEqual(rows[-1]['hits'],100000)
            self.assertEqual([r['result'] for r in rows[1:-1]],['miss','miss','miss','failure','miss'])
            parsed=compile_events.parse(raw,pid=rows[0]['pid'],session=42,
                                       window=(rows[0]['begin_us'],rows[-1]['end_us']))
            self.assertEqual((parsed['records'],parsed['misses'],parsed['hits']),(5,3,100000))
            for bad in ('0', '65537', '-1', '2x'):
                directory=root/('bad-'+bad.replace('-', 'n')); directory.mkdir()
                badenv={**env, 'S2A_CE_TEST_CAP':bad}
                self.assertNotEqual(subprocess.run([str(exe),str(directory)],env=badenv,timeout=10).returncode,0)
                self.assertEqual(list(directory.glob('compile-events-*.jsonl')),[])

if __name__=='__main__': unittest.main()
