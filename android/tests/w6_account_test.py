#!/usr/bin/env python3
"""W6 全账解析回归：已知事件必须得到确定读数，未知字段保持 unavailable/None。

不依赖设备：构造与生产日志同格式的行，验证窗口、四态、GPU 完成读取和缺失字段口径。
"""
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
TOOL = os.path.join(HERE, '..', 'tools', 'w6_account.py')


def load_tool():
    spec = importlib.util.spec_from_file_location('w6_account', TOOL)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class Args:
    log = ''
    pid = 1234
    window = 0
    since = None
    until = None
    serial = None
    package = None
    sf_before = None
    sf_after = None
    seconds = 0


def line(ts, msg, level='I', pid=1234):
    return f'10-29 {ts} {pid} 2345 {level} S2Arm   : {msg}\n'


def fixture():
    rows = [
        line('12:00:00.000', 'frame timing(近16帧, frame=160): gap=16.7ms p50=16.5 p95=25.2 '
                             'max=25.2 (n=16) exec=6.9ms present=4.1ms other=5.7ms commands=173 fps=60.0'),
        line('12:00:00.100', 'longframe(本帧): frame=160 gap=41.2ms exec=38.0ms'
                             '（其中 编译 +1 次 12.5ms、管线创建 +1 次 8.0ms）| 等待/其它 3.2ms'),
        line('12:00:00.200', 'gpu frame(retire): 12.34 ms (frame=9, 24 passes, parity=1)'),
        line('12:00:00.300', 'present account: submitted=100 draw_completed_sync=0 '
                             'presentation_retired=98 pending=2 retained=0 deferred_retired=99 | '
                             'fail(submit=0 present=0 fence_timeout=0 retire_timeout=0 acquire_timeout=0) | '
                             'gpu=valid'),
        line('12:00:00.400', 'present 拆分(延迟)：等GPU画完=0 us | acquire=80 us | '
                             '录blit+提交=430 us | present+vsync=700 us'),
        line('12:00:00.500', 'draw timing(batch): avg=33 us over 100 draws'),
        line('12:01:01.000', 'frame timing(近16帧, frame=3680): gap=16.6ms p50=16.4 p95=24.0 '
                             'max=30.0 (n=16) exec=7.0ms present=4.0ms other=5.6ms commands=172 fps=60.2'),
        line('12:01:01.100', 'present account: submitted=3700 draw_completed_sync=0 '
                             'presentation_retired=3690 pending=2 retained=0 deferred_retired=3699 | '
                             'fail(submit=0 present=0 fence_timeout=0 retire_timeout=0 acquire_timeout=0) | '
                             'gpu=valid'),
        line('12:01:01.200', 'present lifecycle: submitted=3700 draw_completed=0 '
                             'presentation_retired=3700 pending=0 retained=0'),
        line('12:01:01.300', 'E S2Arm: present defer: the previous frame has no completion proof; '
                             'resources retained', level='E'),
    ]
    fd, path = tempfile.mkstemp(suffix='.log')
    with os.fdopen(fd, 'w', encoding='utf-8') as f:
        f.writelines(rows)
    return path


class W6AccountTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tool = load_tool()
        cls.path = fixture()
        cls.rows = cls.tool.parse_log(cls.path)
        cls.args = Args()
        cls.args.log = cls.path
        cls.account = cls.tool.analyze(cls.rows, 1234, cls.args)

    @classmethod
    def tearDownClass(cls):
        os.unlink(cls.path)

    def test_window_and_pid(self):
        a = self.account
        self.assertEqual(a['provenance']['pid'], 1234)
        self.assertGreaterEqual(a['provenance']['durationSeconds'], 60.0)
        self.assertTrue(a['checks']['window_ge_60s'])

    def test_known_longframe_attribution(self):
        l = self.account['longFrame']
        self.assertEqual(l['count'], 1)
        self.assertEqual(l['compileCount'], 1)
        self.assertAlmostEqual(l['compileMs'], 12.5)
        self.assertEqual(l['pipelineCount'], 1)
        self.assertAlmostEqual(l['pipelineMs'], 8.0)

    def test_gpu_read_after_completion(self):
        g = self.account['gpu']
        self.assertEqual(g['valid'], 1)
        self.assertAlmostEqual(g['msMedian'], 12.34)
        self.assertIn('retire', g['readAfter'])

    def test_present_four_states(self):
        p = self.account['present']
        # 最后一条是 destroy 摘要：submitted == retired + pending + retained 的正常收尾。
        self.assertEqual(p['last']['submitted'], 3700)
        self.assertEqual(p['last']['retired'], 3700)
        self.assertEqual(p['last']['pending'], 0)
        self.assertTrue(self.account['checks']['present_states_consistent'])
        self.assertTrue(self.account['checks']['present_retained_zero'])

    def test_error_retained_is_reported(self):
        joined = '\n'.join(e['message'] for e in self.account['errors'])
        self.assertIn('resources retained', joined)

    def test_display_is_unavailable_without_serial(self):
        d = self.account['display']
        self.assertFalse(d['available'])
        self.assertIn('未采集 SurfaceFlinger', ' '.join(self.account['missing']))

    def test_retained_breaks_check(self):
        args = Args()
        args.log = self.path
        rows = list(self.rows)
        rows.append((rows[-1][0] + 1,
                     1234, 'I', 'S2Arm',
                     'present account: submitted=3701 draw_completed_sync=0 presentation_retired=3700 '
                     'pending=1 retained=1 deferred_retired=3700 | fail(submit=0 present=1 '
                     'fence_timeout=0 retire_timeout=0 acquire_timeout=0) | gpu=valid'))
        a = self.tool.analyze(rows, 1234, args)
        self.assertFalse(a['checks']['present_retained_zero'])
        self.assertEqual(a['present']['last']['retained'], 1)
        self.assertEqual(a['present']['last']['present_fail'], 1)

    def test_sf_timestats_histogram(self):
        dump = """SurfaceFlinger TimeStats:
statsStart = 100
statsEnd = 160
totalFrames = 190
layerName = e1426d8 SurfaceView[org.s2arm.game.t01001b300b9be000/org.s2arm.android.GameActivity](BLAST)#1
totalFrames = 100
droppedFrames = 1
averageFPS = 59.500
present2present histogram is as below:
16ms=90 24ms=8 33ms=2
"""
        sf = self.tool.parse_sf_timestats(dump, 'org.s2arm.game.t01001b300b9be000')
        self.assertTrue(sf['available'])
        self.assertEqual(sf['windowSeconds'], 60)
        self.assertEqual(sf['frames'], 100)
        self.assertAlmostEqual(sf['fps'], 59.5)
        self.assertEqual(sf['p50Ms'], 16)
        self.assertEqual(sf['p95Ms'], 24)
        self.assertEqual(sf['p99Ms'], 33)
        self.assertEqual(sf['maxMs'], 33)
        self.assertAlmostEqual(sf['slow25MsRatio'], 0.02)

    def test_sf_delta_matches_log_window(self):
        before = """SurfaceFlinger TimeStats:
layerName = abc SurfaceView[org.s2arm.game.t01001b300b9be000/org.s2arm.android.GameActivity](BLAST)#1
totalFrames = 100
droppedFrames = 0
averageFPS = 60.0
present2present histogram is as below:
16ms=90 24ms=10
"""
        after = """SurfaceFlinger TimeStats:
layerName = abc SurfaceView[org.s2arm.game.t01001b300b9be000/org.s2arm.android.GameActivity](BLAST)#1
totalFrames = 200
droppedFrames = 1
averageFPS = 60.0
present2present histogram is as below:
16ms=150 24ms=40 33ms=10
"""
        sf = self.tool.parse_sf_delta(before, after, 'org.s2arm.game.t01001b300b9be000', 10)
        self.assertTrue(sf['available'])
        self.assertEqual(sf['frames'], 100)
        self.assertAlmostEqual(sf['fps'], 10.0)
        self.assertEqual(sf['p50Ms'], 16)
        self.assertEqual(sf['p95Ms'], 33)
        self.assertEqual(sf['maxMs'], 33)
        self.assertAlmostEqual(sf['slow25MsRatio'], 0.1)

    def test_sf_delta_empty_baseline_same_session(self):
        # clear 后第一次 dump 还没建出 layer：同 statsStart 时基线按 0，after 就是窗口。
        before = 'SurfaceFlinger TimeStats:\nstatsStart = 1\nstatsEnd = 1\ntotalFrames = 2\n'
        after = ('SurfaceFlinger TimeStats:\nstatsStart = 1\nstatsEnd = 11\n'
                 'layerName = abc SurfaceView[org.s2arm.game.x](BLAST)#1\n'
                 'totalFrames = 100\ndroppedFrames = 0\n'
                 'present2present histogram is as below:\n16ms=100\n')
        sf = self.tool.parse_sf_delta(before, after, 'org.s2arm.game.x', 10)
        self.assertTrue(sf['available'])
        self.assertEqual(sf['frames'], 100)
        self.assertAlmostEqual(sf['fps'], 10.0)

    def test_sf_delta_layer_change_is_unavailable(self):
        before = 'layerName = one\ntotalFrames = 1\npresent2present histogram is as below:\n16ms=1\n'
        after = 'layerName = two\ntotalFrames = 2\npresent2present histogram is as below:\n16ms=2\n'
        sf = self.tool.parse_sf_delta(before, after, 'org.s2arm.game.x', 10)
        self.assertFalse(sf['available'])

    def test_sf_timestats_missing_layer_is_unavailable(self):
        sf = self.tool.parse_sf_timestats('statsStart = 1\nstatsEnd = 2\n', 'org.s2arm.game.x')
        self.assertFalse(sf['available'])

    def test_restart_breaks_pid_consistency(self):
        # 同一窗口出现第二个进程的帧行：不能当连续 60s，strict 必须失败。
        rows = list(self.rows)
        rows.append((rows[0][0] + 5, 999, 'I', 'S2Arm',
                     'frame timing(近16帧, frame=1): gap=16.7ms p50=16.5 p95=25.2 '
                     'max=25.2 (n=16) exec=6.9ms present=4.1ms other=5.7ms commands=1 fps=60.0'))
        args = Args()
        args.log = self.path
        a = self.tool.analyze(rows, 1234, args)
        self.assertFalse(a['checks']['pid_consistent'])
        self.assertIn(999, a['provenance']['s2armPids'])
        self.assertTrue(any('中途重启' in m for m in a['missing']))

    def test_strict_rejects_incomplete_account(self):
        # 只有 app 帧行：没有 GPU/present，strict 必须非 0，不能把“局部有数”当整份全账。
        rows = [line('12:00:00.000', 'frame timing(近16帧, frame=160): gap=16.7ms p50=16.5 '
                                     'p95=25.2 max=25.2 (n=16) exec=6.9ms present=4.1ms '
                                     'other=5.7ms commands=173 fps=60.0')]
        fd, path = tempfile.mkstemp(suffix='.log')
        with os.fdopen(fd, 'w', encoding='utf-8') as f:
            f.writelines(rows)
        try:
            result = subprocess.run([sys.executable, TOOL, '--log', path, '--pid', '1234',
                                     '--window', '0', '--strict'], capture_output=True, text=True)
            self.assertEqual(result.returncode, 2, result.stderr)
        finally:
            os.unlink(path)

    def test_missing_gpu_is_not_zero(self):
        args = Args()
        args.log = self.path
        rows = [r for r in self.rows if 'gpu frame' not in r[4]]
        a = self.tool.analyze(rows, 1234, args)
        self.assertEqual(a['gpu']['valid'], 0)
        self.assertIsNone(a['gpu'].get('msMedian'))
        self.assertTrue(any('不用 CPU 等待代替' in m for m in a['missing']))


if __name__ == '__main__':
    unittest.main()
