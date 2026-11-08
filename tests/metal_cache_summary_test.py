#!/usr/bin/env python3
"""N01 汇总口径：启动累计行、严格慢帧阈值、缺失/截断数据不能报零或成功。"""
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
from metal_cache_summary import cache_samples, frame_window


def row(frame, duration):
    return dict(frame=str(frame), wall_us=str(duration), shader_miss='0', pso_n='0', rb_us='0')


class CacheSummaryTest(unittest.TestCase):
    def test_window_excludes_startup_and_is_strictly_over_100ms(self):
        rows = [row(1, 0), row(2, 100000), row(3, 100001), row(4, 799999)]
        result = frame_window(rows, 0, 1)
        self.assertEqual(result['frames'], 3)
        self.assertEqual(result['over_100ms_frames'], 2)
        self.assertEqual(result['end_to_end_fps'], 3)
        self.assertEqual(result['first_frame'], 2)

    def test_boundary_is_exclusive(self):
        result = frame_window([row(1, 0), row(2, 2000000), row(3, 1000000)], 2, 1)
        self.assertEqual(result['first_frame'], 3)
        self.assertEqual(result['frames'], 1)

    def test_short_window_is_not_a_valid_measurement(self):
        with self.assertRaisesRegex(ValueError, '不足'):
            frame_window([row(1, 0), row(2, 100000)], 0, 60)

    def test_missing_library_is_not_zero(self):
        line = 'malloc 采样 [第 1 分钟]：估在用 9.1 MB（表满丢 2 / 3）；按调用镜像： s2arm-host 8.1 MB； Metal 1.0 MB；'
        sample = cache_samples(line)[0]
        self.assertIsNone(sample['corefscache_live_mib_estimate'])
        self.assertEqual(sample['table_drops'], [2, 3])
        self.assertEqual(sample['smallest_listed_image_mib'], 1.0)

    def test_actual_library_and_missing_diagnostic(self):
        line = 'malloc 采样 [收局]：估在用 20.0 MB（表满丢 0 / 0）；按调用镜像： libCoreFSCache.dylib 15.8 MB； Metal 4.2 MB；'
        self.assertEqual(cache_samples(line)[0]['corefscache_live_mib_estimate'], 15.8)
        self.assertEqual(cache_samples('只有普通日志'), [])


if __name__ == '__main__':
    unittest.main()
