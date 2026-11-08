# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""出包与装机重叠（pack/jobs/early.py + ipa.py installAfter，11-06 出包速度线）：一键出包与装机全换替身，只验编排。
期望按 early.py 头注手写：
  ① 旁路信号到 → 早装件（early_pack.sh）→ 签名装 App → 推早期资源包，都在出包结束之前；出包结束 → 装正式包 → 推正式资源包；返回的推送量 = 两次之和；早装件目录收尾删掉
  ② 早装件出不来（early_pack.sh 退 1）→ 不判整单失败、记一条进度消息、正式安装照装照推
  ③ 出包失败 → 抛出包的失败、不装正式包；没写信号时早装线程直接退出、不调早装件
  ④ 不带 installAfter → 不认设备、不设 S2A_EARLY_READY、不装
"""
import contextlib
import json
import os
import subprocess
import time
import unittest
from pathlib import Path
from unittest.mock import patch

from jobcase import JobCase
from core import Context, Failure
import build
import cache_retention
import early
import install
import ipa
import library


GID = '0100000000000000'


class EarlyInstallCase(JobCase):
    def run_ipa(self, suffix, *, install_after=True, signal=True, oneclick_fail=False, early_rc=0):
        c = Context(self.request | dict(taskId='early-' + suffix, operation='ipa', gameId=GID) | (dict(installAfter=True) if install_after else {}))
        calls, envs = [], []
        stamp = lambda what, *a: calls.append((time.time(), what) + a)

        def oneclick(args, log=None, env=None, **kwargs):   # 一键出包替身：先写旁路信号，「编直连库」2 秒，再交付
            envs.append(dict(env))
            out = Path(args[args.index('--out') + 1])
            if signal and env.get('S2A_EARLY_READY'):
                Path(env['S2A_EARLY_READY']).write_text('tfake@rx-1\n')
            time.sleep(2)
            stamp('出包结束')
            events = Path(args[args.index('--events') + 1])
            if oneclick_fail:
                events.write_text(json.dumps(dict(ev='result', ok=False, msg='替身出包失败')) + '\n')
                raise Failure('替身出包失败', code='tool_exit')
            (out / 'tfake.ipa').write_bytes(b'final'); (out / 'tfake资源包').mkdir(exist_ok=True)
            events.write_text(json.dumps(dict(ev='result', ok=True, ipa=str(out / 'tfake.ipa'), graphics_mode='direct', build_id='x')) + '\n')

        real_run = subprocess.run
        def sub_run(cmd, *a, **k):   # 只替 early_pack.sh：按退出码出 / 不出早装件
            if isinstance(cmd, list) and str(cmd[1]).endswith('pack/early_pack.sh'):
                stamp('早装件', cmd[2])
                d = Path(cmd[3]); d.mkdir(parents=True, exist_ok=True)
                if early_rc == 0: (d / f'{cmd[2]}.ipa').write_bytes(b'early'); (d / 'pack').mkdir(exist_ok=True)
                else: k['stdout'].write('【红】替身早装件失败\n')
                return subprocess.CompletedProcess(cmd, early_rc)
            return real_run(cmd, *a, **k)

        def sign(c_, ipa_path, gid, team, dev, udid, bid, steps=True): stamp('装 App', Path(ipa_path).name)
        seen_udid = self.seen_udid = []   # 两次推包都要带 UDID（tools/push_pack.py 据此走 s2a-devpush 流式写，11-06）
        def push(c_, ident, bid, pack, udid=None): stamp('推资源包', Path(pack).name); seen_udid.append(udid); return (3, 30) if Path(pack).name == 'pack' else (2, 20)
        game = dict(id=GID, packages=[])
        with contextlib.ExitStack() as st:
            for obj, name, value in (
                    (c, 'catalog', {'games': [game]}), (c, 'fonts_dir', self.root),
                    (library, 'require_game', None), (library, 'check_pack_space', None), (library, 'prune_build', None),
                    (build, 'ensure_extract', self.root), (build, 'seed_from_sibling', False),
                    (ipa, 'dotnet_sdk', (self.root, self.root / 'dotnet')), (ipa, '_iml_device_hint', None),
                    (ipa, 'resolve_target', None),
                    (cache_retention, 'trim', dict(accountingComplete=True, evictionErrors=0, diskErrors=0, pressureRemaining=False,
                                                    keepTitles=3, retainedBytes=0, removedEntries=0, freeBytes=100, minFreeBytes=0)),
                    (install, 'xcode_teams', [dict(id='TEAM1', name='t', free=True)]), (install, 'phone', dict(id='DEV1', name='测试机')),
                    (install, 'udid_of', 'UDID1')):
                st.enter_context(patch.object(obj, name, return_value=value))
            st.enter_context(patch.object(c, 'run', side_effect=oneclick))
            st.enter_context(patch.object(early.subprocess, 'run', side_effect=sub_run))
            st.enter_context(patch.object(install, 'sign_and_install', side_effect=sign))
            st.enter_context(patch.object(install, 'push_pack', side_effect=push))
            try: result, err = ipa.build(c), None
            except Failure as e: result, err = None, e
        return c, result, err, calls, envs

    def test_overlap_order_and_totals(self):
        c, r, err, calls, envs = self.run_ipa('ok')
        self.assertIsNone(err)
        what = [x[1:] for x in calls]
        end = next(t for t, w, *_ in calls if w == '出包结束')
        early_steps = [(w, *a) for t, w, *a in calls if t < end]
        self.assertEqual(early_steps, [('早装件', 'tfake'), ('装 App', 'tfake.ipa'), ('推资源包', 'pack')], what)   # ① 都在出包结束之前
        self.assertEqual(what[-2:], [('装 App', 'tfake.ipa'), ('推资源包', 'tfake资源包')], what)
        self.assertEqual((r['packFiles'], r['packBytes'], r['bundleId'], r['device']), (5, 50, install.bundle_id('TEAM1', GID), '测试机'))
        self.assertFalse((Path(r['outputPath']) / '.early').exists())
        self.assertTrue(envs[0]['S2A_EARLY_READY'].endswith('-early.ready'))
        self.assertEqual(self.seen_udid, ['UDID1', 'UDID1'])   # 早推与补推都把 UDID 交给推包（流式路径要它）

    def test_early_failure_falls_back_to_full_push(self):
        c, r, err, calls, _ = self.run_ipa('earlyred', early_rc=1)
        self.assertIsNone(err)   # ② 不判整单失败
        what = [x[1:] for x in calls]
        self.assertNotIn(('推资源包', 'pack'), what)
        self.assertEqual(what[-2:], [('装 App', 'tfake.ipa'), ('推资源包', 'tfake资源包')], what)
        msgs = [json.loads(l).get('message', '') for l in c.events.read_text().splitlines()]
        self.assertTrue(any('先装 App、先推资源没成' in m for m in msgs), msgs[-5:])

    def test_package_failure_no_final_install(self):
        c, r, err, calls, _ = self.run_ipa('pkgred', oneclick_fail=True, signal=False)
        self.assertIsNotNone(err)   # ③
        self.assertEqual([w for _, w, *_ in calls], ['出包结束'])

    def test_without_install_after_nothing_extra(self):
        c, r, err, calls, envs = self.run_ipa('plain', install_after=False)
        self.assertIsNone(err)   # ④
        self.assertNotIn('S2A_EARLY_READY', envs[0])
        self.assertEqual([w for _, w, *_ in calls], ['出包结束'])
        self.assertNotIn('bundleId', r)


if __name__ == '__main__':
    unittest.main()
