#!/usr/bin/env python3
# #1131：出包入口自动选后端（owner 定）——Darwin arm64 一律 host 原生；
# Linux 一律 docker，缺 docker 或 daemon 不健康直接报红，不退 host；其它系统报红。
# Darwin x86_64 宿主路径未实机验证，明确报红「未验证」而不是放行半通状态（owner 复审二选一口径）。
# 两个方向都没有自动回退，也没有手工开关。
import sys
import unittest
from unittest import mock

sys.path.insert(0, 'pack/targets/android')
import package


def env():
    return {'PATH': '/usr/bin:/bin'}


class BuildBackendTest(unittest.TestCase):
    def select(self, system, machine='arm64', docker=True, docker_rc=0):
        with mock.patch.object(package.platform, 'system', return_value=system), \
             mock.patch.object(package.platform, 'machine', return_value=machine), \
             mock.patch.object(package.shutil, 'which', return_value='/usr/bin/docker' if docker else None), \
             mock.patch.object(package.subprocess, 'run', return_value=mock.Mock(returncode=docker_rc)):
            return package.build_backend(env())

    def test_darwin_arm64_is_native_host(self):
        self.assertEqual('host', self.select('Darwin', 'arm64'))

    def test_darwin_arm64_never_picks_docker_even_when_present(self):
        self.assertEqual('host', self.select('Darwin', 'arm64', docker=True, docker_rc=0))

    def test_darwin_x86_64_is_red_unvalidated(self):
        for docker in (True, False):
            with self.assertRaises(ValueError) as cm:
                self.select('Darwin', 'x86_64', docker=docker, docker_rc=0)
            self.assertIn('未验证', str(cm.exception))

    def test_linux_with_healthy_docker_picks_docker(self):
        self.assertEqual('docker', self.select('Linux', 'x86_64', docker=True, docker_rc=0))
        self.assertEqual('docker', self.select('Linux', 'aarch64', docker=True, docker_rc=0))

    def test_linux_without_docker_is_red(self):
        with self.assertRaises(ValueError):
            self.select('Linux', 'x86_64', docker=False)
        with self.assertRaises(ValueError):
            self.select('Linux', 'aarch64', docker=False)

    def test_linux_docker_unhealthy_is_red(self):
        with self.assertRaises(ValueError):
            self.select('Linux', 'x86_64', docker=True, docker_rc=1)

    def test_linux_docker_timeout_is_red(self):
        with mock.patch.object(package.platform, 'system', return_value='Linux'), \
             mock.patch.object(package.platform, 'machine', return_value='x86_64'), \
             mock.patch.object(package.shutil, 'which', return_value='/usr/bin/docker'), \
             mock.patch.object(package.subprocess, 'run',
                               side_effect=package.subprocess.TimeoutExpired('docker', 10)):
            with self.assertRaises(ValueError):
                package.build_backend(env())

    def test_unknown_system_is_red(self):
        with self.assertRaises(ValueError):
            self.select('FreeBSD', 'amd64')


if __name__ == '__main__':
    unittest.main()
