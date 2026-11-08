#!/usr/bin/env python3
"""P0-2 采样器映射：宿主反例 + 变异控制（精确 / 经验证的等价 / 准确拒绝 三分类）。

只编纯映射函数（nvn_vk_sampler_from），不建 Vulkan 设备：宿主 Vulkan 头桩 + android 系统属性桩。
生产实现必须让 nvn_vk_sampler_mapping_test.c 全过；三个变异体各自把「关键修复」撤掉，必须变红，
且失败项要对得上（镜像映射 / 自定义边界色 / reduction），否则说明用例没钉住那一处。

判定表见 android/native/nvn/nvn_vk_sampler.c 顶部注释。
"""
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
SOURCE = HERE.parent / 'native/nvn/nvn_vk_sampler.c'
FIXTURE = HERE / 'nvn_vk_sampler_mapping_test.c'

INCLUDES = [
    HERE / 'vkhost', HERE / 'hostvk', HERE.parent / 'native', HERE.parent / 'native/nvn',
    ROOT / 'graphics/nvn/gfx/nvn', ROOT / 'graphics/nvn/gfx/nvn/include', ROOT / 'graphics/nvn/gfx/tex',
    ROOT / 'graphics/nvn/third_party/vulkan-headers/include',
]

# (变异名, 生产源码里的锚点, 替换成, 变红时必须出现的断言名)
MUTANTS = [
    ('mirror-clamp-as-mirrored-repeat',
     'case NVN_WRAP_MODE_MIRROR_CLAMP: *o = VK_SAMPLER_ADDRESS_MODE_MIRROR_CLAMP_TO_EDGE;',
     'case NVN_WRAP_MODE_MIRROR_CLAMP: *o = VK_SAMPLER_ADDRESS_MODE_MIRRORED_REPEAT;',
     'wrap-mirror-clamp-equiv'),
    ('custom-border-accepted-silently',
     'if (white || transparent || opaque_black) return 0;',
     'if (1) return 0;   /* 变异：自定义边界色静默按最近枚举色 */',
     'border-custom-reachable-rejected'),
    ('reduction-accepted-silently',
     'if (reduction_reduces(p)) {',
     'if (0) {   /* 变异：min/max reduction 静默落到 AVERAGE */',
     'reduction-min-multi-rejected'),
]


def build(cc, out, source, tag):
    cmd = [cc, '-std=gnu11', '-Wall', '-Wextra'] + [f'-I{i}' for i in INCLUDES] + [
        f'-DSAMPLER_SOURCE="{source}"', str(FIXTURE), '-o', str(out / tag)]
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError(f'compile {tag} failed:\n{result.stdout}\n{result.stderr}')


class SamplerMappingTest(unittest.TestCase):
    def run_source(self, cc, out, source, tag):
        build(cc, out, source, tag)
        return subprocess.run([str(out / tag)], capture_output=True, text=True)

    def test_mapping_table_and_mutants(self):
        cc = shutil.which('cc')
        self.assertIsNotNone(cc)
        with tempfile.TemporaryDirectory() as td:
            td = Path(td)
            prod = self.run_source(cc, td, SOURCE, 'production')
            self.assertEqual(prod.returncode, 0, prod.stdout + prod.stderr)
            self.assertIn('nvn-vk-sampler-mapping: ok', prod.stdout)
            original = SOURCE.read_text()
            for name, old, new, failed_case in MUTANTS:
                self.assertEqual(original.count(old), 1, f'变异锚点在源码里不唯一/不存在：{name}')
                mutant = td / f'{name}.c'
                mutant.write_text(original.replace(old, new))
                result = self.run_source(cc, td, mutant, name)
                self.assertNotEqual(result.returncode, 0, f'变异 {name} 没被用例抓住')
                self.assertIn(f'FAIL {failed_case}', result.stdout,
                              f'变异 {name} 变红，但不是目标用例：{result.stdout}')


if __name__ == '__main__':
    unittest.main()
