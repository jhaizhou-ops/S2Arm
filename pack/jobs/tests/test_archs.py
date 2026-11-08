#!/usr/bin/env python3
# archs.py 单测（10-29 总指挥定口径：出包目标对按用途推导，目标表 pack/pso_targets.tsv 只有一处）。期望按表手算，不跑被测推导：
#   仓库真表：测试 / 普查包缺省 iOS = 测试机两对 {g18p, g19p} × ios27；Mac = 三台跑局机各自那一对 {g17s.macos26, g15g.macos27, g16s.macos27}，
#     且每台跑局机的那一对都是表里 Metal 4「出」（普查三台缺桩 0）
#   夹具表（S2A_PSO_TARGETS / S2A_OUR_DEVICES）：模拟用户设备恰好那一对；用户包拿不到设备、不在表、工具链拒、跑局机不在表、大版本不是整数 → TargetError；
#     用途只有 pso（直连链接版 10-29 已删，给 link 报错）；全集 = 表里本平台全部「出」的行；显式给的覆盖缺省
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).parent.parent))
import archs

REAL_DEVICES = bool(os.environ.get('S2A_OUR_DEVICES')) or (Path(archs.ROOT) / 'pack' / 'our_devices.tsv').exists()
NO_REAL = '我方真机表 pack/our_devices.tsv 是维护方私有（S2A_OUR_DEVICES 指它才测）'
ENV = ('S2A_PSO_ARCHS', 'S2A_PSO_ARCHS_ALL', 'S2A_PACK_PURPOSE', 'S2A_PSO_OS', 'S2A_MAC_OS', 'S2A_PSO_TARGETS', 'S2A_OUR_DEVICES', 'S2A_HOST_PAIR')


class TestPairs(unittest.TestCase):
    def setUp(self):
        self.saved = {k: os.environ.pop(k, None) for k in ENV}
        self.tmp = tempfile.mkdtemp()

    def tearDown(self):
        import shutil
        shutil.rmtree(self.tmp, ignore_errors=True)
        for k, v in self.saved.items():
            os.environ.pop(k, None)
            if v is not None:
                os.environ[k] = v

    def fixture(self, targets, devices=None):
        t = Path(self.tmp) / 'targets.tsv'; t.write_text('# 夹具\n' + ''.join('\t'.join(map(str, r)) + '\n' for r in targets), encoding='utf-8')
        os.environ['S2A_PSO_TARGETS'] = str(t)
        if devices is not None:
            d = Path(self.tmp) / 'devices.tsv'; d.write_text('# 夹具\n' + ''.join('\t'.join(map(str, r)) + '\n' for r in devices), encoding='utf-8')
            os.environ['S2A_OUR_DEVICES'] = str(d)

    # ---- 仓库真表 ----
    @unittest.skipUnless(REAL_DEVICES, NO_REAL)
    def test_real_ios_dev_is_test_phones(self):
        """测试机包只有在用测试机那一对：两台 iPhone 17 Pro Max 都是 g18p / iOS 27；Duo（g19p）标不在用，不出（10-29 总指挥）"""
        self.assertEqual(archs.pairs('ios', 'pso')[0], [('applegpu_g18p', 27, 4)])

    @unittest.skipUnless(REAL_DEVICES, NO_REAL)
    def test_real_mac_dev_each_run_machine(self):
        """普查三台：各台只出自己那一对，且三对都是 Metal 4「出」（缺桩 0）——不是三架构 × 两版本的 6 对"""
        want = [('applegpu_g17s', 26, 4), ('applegpu_g15g', 27, 4), ('applegpu_g16s', 27, 4)]
        self.assertEqual(archs.pairs('macos', 'pso')[0], want)
        t = archs.target_table()
        for a, v, _ in want:
            self.assertEqual(t[('macos', v, a)], (4, ''))

    def test_real_toolchain_rejects_marked(self):
        """工具链拒的组合在表里标明、推导到就报红：g17s × macOS 15（芯片随 macOS 26 发布）"""
        self.assertIn('无此组合', archs.target_table()[('macos', 15, 'applegpu_g17s')][1])
        os.environ.update(S2A_PSO_ARCHS='applegpu_g17s', S2A_MAC_OS='15')
        with self.assertRaisesRegex(archs.TargetError, 'applegpu_g17s.macos15'):
            archs.pairs('macos', 'pso')

    @unittest.skipUnless(REAL_DEVICES, NO_REAL)
    def test_real_our_devices_archs_ios_only(self):
        """pack/jobs/target.py 用的我方 iPhone 架构集合：表里加了 Mac 行也只取 iOS"""
        self.assertEqual(archs.our_devices_archs(), ['applegpu_g18p', 'applegpu_g19p'])

    # ---- 夹具 ----
    T = [('ios', 26, 'applegpu_g16p', 4, '出'), ('ios', 27, 'applegpu_g16p', 4, '出'), ('ios', 27, 'applegpu_g18p', 4, '出'),
         ('ios', 18, 'applegpu_g12p', 3, '出'), ('ios', 27, 'applegpu_g12p', 3, '出'), ('ios', 18, 'applegpu_g9p', 3, '拒：工具链拒绝（夹具）'),
         ('macos', 15, 'applegpu_g13g', 3, '出'), ('macos', 27, 'applegpu_g15g', 4, '出')]

    def test_user_device_exact(self):
        """模拟一台用户设备（g16p / iOS 26）：出的恰好那一对"""
        self.fixture(self.T)
        os.environ.update(S2A_PACK_PURPOSE='user', S2A_PSO_ARCHS='applegpu_g16p', S2A_PSO_OS='26')
        self.assertEqual(archs.pairs('ios', 'pso')[0], [('applegpu_g16p', 26, 4)])

    def test_user_ios_without_device_red(self):
        """用户包拿不到目标设备：报红，不猜、不退到跑局机清单"""
        self.fixture(self.T, [('iPhone18,2', '测试机', 'applegpu_g18p', 'ios', 27, '是', '-')])
        os.environ['S2A_PACK_PURPOSE'] = 'user'
        with self.assertRaisesRegex(archs.TargetError, '目标设备'):
            archs.pairs('ios', 'pso')

    def test_user_mac_host_metal3(self):
        """用户 Mac 包 = 出包这台 Mac；macOS 15 是 Metal 3 档，照出（Metal 档列 3）"""
        self.fixture(self.T)
        os.environ.update(S2A_PACK_PURPOSE='user', S2A_HOST_PAIR='applegpu_g13g 15')
        self.assertEqual(archs.pairs('macos', 'pso')[0], [('applegpu_g13g', 15, 3)])

    def test_dev_from_run_machines(self):
        """开发 / 测试 / 普查包缺省：跑局机清单里本平台各台那一对"""
        self.fixture(self.T, [('iPhone18,2', '测试机', 'applegpu_g18p', 'ios', 27, '是', '-'), ('mac-air', 'Air', 'applegpu_g15g', 'macos', 27, '是', '-')])
        self.assertEqual(archs.pairs('ios', 'pso')[0], [('applegpu_g18p', 27, 4)])
        self.assertEqual(archs.pairs('macos', 'pso')[0], [('applegpu_g15g', 27, 4)])

    def test_run_machine_not_in_table_red(self):
        """推导出的跑局机不在表里：报红，不出缺了那台的包"""
        self.fixture(self.T, [('iPhone18,2', '测试机', 'applegpu_g18p', 'ios', 27, '是', '-'), ('iPhone19,4', 'Duo', 'applegpu_g19p', 'ios', 27, '是', '-')])
        with self.assertRaisesRegex(archs.TargetError, r'applegpu_g19p\.ios27（不在目标表'):
            archs.pairs('ios', 'pso')

    def test_explicit_overrides_and_rejected(self):
        """显式给的覆盖缺省（架构 × 大版本）；其中有工具链拒的就整份报红"""
        self.fixture(self.T, [('iPhone18,2', '测试机', 'applegpu_g18p', 'ios', 27, '是', '-')])
        os.environ.update(S2A_PSO_ARCHS='applegpu_g16p', S2A_PSO_OS='26 27')
        self.assertEqual(archs.pairs('ios', 'pso')[0], [('applegpu_g16p', 26, 4), ('applegpu_g16p', 27, 4)])
        os.environ.update(S2A_PSO_ARCHS='applegpu_g12p applegpu_g9p', S2A_PSO_OS='18')
        with self.assertRaisesRegex(archs.TargetError, r'applegpu_g9p\.ios18（工具链拒：工具链拒绝'):
            archs.pairs('ios', 'pso')

    def test_explicit_ios_sdk_failure(self):
        """未给 OS：探测失败要保留真正原因，不得得到 ios0 / 吞非零退出。"""
        self.fixture([('ios', 18, 'applegpu_g13g', 3, '出')])
        os.environ['S2A_PSO_ARCHS'] = 'applegpu_g13g'
        cases = [(1, '', 'SDK unavailable', '读取 iOS SDK 失败'),
                 (1, '18.2', 'SDK unavailable', '读取 iOS SDK 失败'),
                 (0, '', '', '版本输出为空或非法'),
                 (0, 'not-a-version', '', '版本输出为空或非法'),
                 (0, '18.bad', '', '版本输出为空或非法')]
        for rc, stdout, stderr, reason in cases:
            with self.subTest(rc=rc, stdout=stdout), patch.object(archs.subprocess, 'run',
                    return_value=subprocess.CompletedProcess([], rc, stdout, stderr)):
                with self.assertRaises(archs.TargetError) as caught:
                    archs.pairs('ios', 'pso')
                message = str(caught.exception)
                self.assertIn(reason, message)
                self.assertIn('xcrun --sdk iphoneos --show-sdk-version', message)
                self.assertIn(f'退出码：{rc}', message)
                self.assertNotIn('ios0', message)
                if stderr:
                    self.assertIn(stderr, message)

    def test_explicit_ios_sdk_unavailable(self):
        self.fixture(self.T)
        os.environ['S2A_PSO_ARCHS'] = 'applegpu_g13g'
        cases = [(FileNotFoundError('missing xcrun'), '未启动'),
                 (subprocess.TimeoutExpired('xcrun', 60, stderr=b'timed out'), '未取得（超时）')]
        for error, reason in cases:
            with self.subTest(error=type(error).__name__), patch.object(archs.subprocess, 'run', side_effect=error):
                with self.assertRaises(archs.TargetError) as caught:
                    archs.pairs('ios', 'pso')
                self.assertIn(reason, str(caught.exception))
                self.assertIn('xcrun --sdk iphoneos --show-sdk-version', str(caught.exception))

    def test_explicit_ios_sdk_major_and_explicit_os(self):
        self.fixture([('ios', 18, 'applegpu_g13g', 3, '出')])
        os.environ['S2A_PSO_ARCHS'] = 'applegpu_g13g'
        with patch.object(archs.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, '18.2\n', '')) as run:
            self.assertEqual(archs.pairs('ios', 'pso'), ([('applegpu_g13g', 18, 3)], '显式 S2A_PSO_ARCHS'))
            run.assert_called_once_with(['xcrun', '--sdk', 'iphoneos', '--show-sdk-version'],
                                        capture_output=True, text=True, timeout=60)
        os.environ['S2A_PSO_OS'] = '18'
        with patch.object(archs.subprocess, 'run', side_effect=AssertionError('explicit OS must not probe')):
            self.assertEqual(archs.pairs('ios', 'pso')[0], [('applegpu_g13g', 18, 3)])

    def test_explicit_ios_sdk_cli(self):
        """真实 Python CLI 入口，只有 xcrun subprocess 结果受控：失败仍为 2、无 traceback。"""
        self.fixture([('ios', 18, 'applegpu_g13g', 3, '出')])
        os.environ['S2A_PSO_ARCHS'] = 'applegpu_g13g'
        for rc, output, expected_rc in [(1, '', 2), (0, 'not-a-version', 2), (0, '18.2', 0)]:
            with self.subTest(rc=rc, output=output):
                script = ("import runpy,sys,subprocess; from unittest.mock import patch; "
                          f"sys.argv={[str(Path(archs.__file__)), 'pairs', 'ios', 'pso']!r}; "
                          f"p=patch('subprocess.run',return_value=subprocess.CompletedProcess([], {rc}, {output!r}, 'sdk diagnostic')); "
                          "p.start(); runpy.run_path(sys.argv[0],run_name='__main__')")
                result = subprocess.run([sys.executable, '-B', '-c', script], capture_output=True, text=True, env=os.environ)
                self.assertEqual(result.returncode, expected_rc, result.stderr)
                self.assertNotIn('Traceback', result.stderr)
                if expected_rc:
                    self.assertEqual(result.stdout, '')
                    self.assertIn('【红】出包目标', result.stderr)
                    self.assertIn('xcrun --sdk iphoneos --show-sdk-version', result.stderr)
                else:
                    self.assertEqual(result.stdout, 'applegpu_g13g\t18\t3\n')

    def test_all_is_table(self):
        """全集只在 S2A_PSO_ARCHS_ALL=1：表里本平台全部「出」的行（拒的不出，不看大版本变量）"""
        self.fixture(self.T)
        os.environ.update(S2A_PSO_ARCHS_ALL='1', S2A_PSO_OS='27')
        self.assertEqual(archs.pairs('ios', 'pso')[0], [('applegpu_g12p', 18, 3), ('applegpu_g16p', 26, 4), ('applegpu_g12p', 27, 3), ('applegpu_g16p', 27, 4), ('applegpu_g18p', 27, 4)])

    def test_link_use_gone(self):
        """直连链接版已删（10-29）：用途 link 不再认，报用法错"""
        self.fixture(self.T)
        with self.assertRaisesRegex(archs.TargetError, '用法'):
            archs.pairs('ios', 'link')

    def test_bad_version_red(self):
        """大版本不是整数（26.4）：报红（原先出成 macos26.4，运行时永远找不到）"""
        self.fixture(self.T)
        os.environ.update(S2A_PSO_ARCHS='applegpu_g15g', S2A_MAC_OS='26.4')
        with self.assertRaisesRegex(archs.TargetError, '不是系统大版本'):
            archs.pairs('macos', 'pso')

    def test_cli(self):
        """命令行：每行「架构\\t大版本\\tMetal 档」；出不了 → 【红】、退出 2"""
        import subprocess
        self.fixture(self.T, [('iPhone18,2', '测试机', 'applegpu_g18p', 'ios', 27, '是', '-')])
        r = subprocess.run([sys.executable, str(Path(archs.__file__)), 'pairs', 'ios', 'pso'], capture_output=True, text=True, env=os.environ)
        self.assertEqual((r.returncode, r.stdout), (0, 'applegpu_g18p\t27\t4\n'))
        r = subprocess.run([sys.executable, str(Path(archs.__file__)), 'pairs', 'ios', 'pso'], capture_output=True, text=True, env={**os.environ, 'S2A_PACK_PURPOSE': 'user'})
        self.assertEqual(r.returncode, 2); self.assertIn('【红】', r.stderr)


    def test_not_in_use_skipped(self):
        """在用 = 否 的机器不进缺省出包对；在用列填错报红"""
        self.fixture(self.T, [('iPhone18,2', '测试机', 'applegpu_g18p', 'ios', 27, '是', '-'), ('iPhone16,1', '旧机', 'applegpu_g16p', 'ios', 27, '否', '-')])
        self.assertEqual(archs.pairs('ios', 'pso')[0], [('applegpu_g18p', 27, 4)])
        self.fixture(self.T, [('iPhone18,2', '测试机', 'applegpu_g18p', 'ios', 27, '备注')])
        with self.assertRaisesRegex(archs.TargetError, '在用'):
            archs.pairs('ios', 'pso')


if __name__ == '__main__':
    unittest.main()
