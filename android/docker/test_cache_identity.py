#!/usr/bin/env python3
"""Check tracked dependency identity without network or a Docker daemon."""
import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).with_name('cache-identity.py')
spec = importlib.util.spec_from_file_location('cache_identity', SCRIPT)
identity = importlib.util.module_from_spec(spec)
spec.loader.exec_module(identity)


class CacheIdentityTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='s2a-deps-test-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        subprocess.run(['git', 'init', '-q', str(self.root)], check=True)
        for name in (*identity.REQUIRED['docker'], *identity.REQUIRED['host'],
                     'services/a.csproj', 'services/b.csproj',
                     'graphics/metal/tests/session/Session.csproj', 'services/unrelated.cs',
                     'services/Directory.Build.props', 'android/app/build.gradle',
                     'android/probes/example/build.gradle',
                     'android/codecs/cache.sh', 'android/codecs/avc_source.py',
                     'android/doctor/doctor.py'):
            p = self.root / name
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text(name)
        for project in identity.PROJECTS:
            p = self.root / project
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text('<Project/>')
        (self.root / identity.PROJECTS[1]).write_text(
            '<Project><ItemGroup><ProjectReference Include="$(RepoRoot)services/a.csproj"/>'
            '</ItemGroup></Project>')
        (self.root / 'services/a.csproj').write_text(
            '<Project><ItemGroup><ProjectReference Include="b.csproj"/></ItemGroup></Project>')
        (self.root / 'services/b.csproj').write_text('<Project/>')
        subprocess.run(['git', '-C', str(self.root), 'add', '.'], check=True)

    def value(self):
        return identity.identity(self.root, self.root, 'docker',
                                 {'image_id': 'sha256:image', 'recipe': 'recipe'})

    def test_unrelated_project_and_probe_gradle_do_not_change_identity(self):
        first = self.value()
        (self.root / 'graphics/metal/tests/session/Session.csproj').write_text('unrelated project changed')
        (self.root / 'android/probes/example/build.gradle').write_text('unrelated probe changed')
        self.assertEqual(self.value(), first)

    def test_transitive_project_change_invalidates_receipt(self):
        first = self.value()
        (self.root / 'services/b.csproj').write_text('<Project><PropertyGroup/></Project>')
        self.assertNotEqual(self.value()['dependencies_sha256'], first['dependencies_sha256'])

    def test_ancestor_config_and_app_gradle_invalidate_receipt(self):
        first = self.value()
        (self.root / 'services/Directory.Build.props').write_text('changed')
        second = self.value()
        self.assertNotEqual(first['dependencies_sha256'], second['dependencies_sha256'])
        (self.root / 'android/app/build.gradle').write_text('changed')
        self.assertNotEqual(second['dependencies_sha256'], self.value()['dependencies_sha256'])

    def test_unresolved_reference_fails_closed(self):
        (self.root / 'services/a.csproj').write_text(
            '<Project><ItemGroup><ProjectReference Include="$(Unknown)/x.csproj"/></ItemGroup></Project>')
        with self.assertRaises(ValueError):
            self.value()

    def test_project_local_default_property_is_traversed_and_hashed(self):
        (self.root / 'services/a.csproj').write_text(
            "<Project><PropertyGroup><RyuGpu Condition=\"'$(RyuGpu)' == ''\">"
            "$(MSBuildThisFileDirectory)../nested</RyuGpu></PropertyGroup>"
            '<ItemGroup><ProjectReference Include="$(RyuGpu)/c.csproj"/></ItemGroup></Project>')
        nested = self.root / 'nested/c.csproj'
        nested.parent.mkdir()
        nested.write_text('<Project/>')
        subprocess.run(['git', '-C', str(self.root), 'add', 'nested/c.csproj'], check=True)
        first = self.value()
        nested.write_text('<Project><PropertyGroup/></Project>')
        self.assertNotEqual(first['dependencies_sha256'], self.value()['dependencies_sha256'])

    def test_property_override_or_unknown_value_is_rejected(self):
        project = self.root / 'services/a.csproj'
        project.write_text("<Project><PropertyGroup><RyuGpu Condition=\"'$(RyuGpu)' == ''\">"
                           "$(MSBuildThisFileDirectory)../nested</RyuGpu></PropertyGroup>"
                           '<ItemGroup><ProjectReference Include="$(RyuGpu)/c.csproj"/></ItemGroup></Project>')
        nested = self.root / 'nested/c.csproj'; nested.parent.mkdir(); nested.write_text('<Project/>')
        subprocess.run(['git', '-C', str(self.root), 'add', 'nested/c.csproj'], check=True)
        (self.root / 'services/Directory.Build.props').write_text('<Project><PropertyGroup><RyuGpu>elsewhere</RyuGpu></PropertyGroup></Project>')
        with self.assertRaises(ValueError): self.value()
        (self.root / 'services/Directory.Build.props').write_text('no overrides')
        project.write_text(project.read_text().replace('$(MSBuildThisFileDirectory)../nested', '$(Unknown)/nested'))
        with self.assertRaises(ValueError): self.value()

    def test_unconditional_dir_property_without_slash_is_traversed(self):
        # 10-30 S2A.Dsh.csproj：<Ryu>$(MSBuildThisFileDirectory)…/src/</Ryu>（无条件）+ Include="$(Ryu)X/x.csproj"（不带斜杠）
        project = self.root / 'services/a.csproj'
        project.write_text("<Project><PropertyGroup><Ryu>$(MSBuildThisFileDirectory)../tree/src/</Ryu></PropertyGroup>"
                           '<ItemGroup><ProjectReference Include="$(Ryu)Shader/s.csproj"/></ItemGroup></Project>')
        shader = self.root / 'tree/src/Shader/s.csproj'; shader.parent.mkdir(parents=True); shader.write_text('<Project/>')
        subprocess.run(['git', '-C', str(self.root), 'add', 'tree/src/Shader/s.csproj'], check=True)
        first = self.value()
        shader.write_text('<Project><!-- changed --></Project>')
        self.assertNotEqual(first['dependencies_sha256'], self.value()['dependencies_sha256'])
        project.write_text(project.read_text().replace('</PropertyGroup>', '<Ryu>$(MSBuildThisFileDirectory)../other/</Ryu></PropertyGroup>'))
        with self.assertRaises(ValueError): self.value()   # 反证：同名属性定义两次（可能被改写）→ 拒绝
        # S2A.Dsh.csproj $(Nx)：$([System.IO.Path]::GetFullPath('$(MSBuildThisFileDirectory)…/'))，与直接写目录等价
        project.write_text("<Project><PropertyGroup><Nx>$([System.IO.Path]::GetFullPath('$(MSBuildThisFileDirectory)../tree/'))</Nx></PropertyGroup>"
                           '<ItemGroup><ProjectReference Include="$(Nx)src/Shader/s.csproj"/></ItemGroup></Project>')
        self.assertNotEqual(first['dependencies_sha256'], self.value()['dependencies_sha256'])   # 着色器工程已改过：仍被追到、进哈希
        project.write_text(project.read_text().replace("GetFullPath('$(MSBuildThisFileDirectory)../tree/')", "GetFullPath('$(Elsewhere)/tree/')"))
        with self.assertRaises(ValueError): self.value()   # 反证：函数里不是本工程目录 → 拒绝
        # 本地 Import（S2A.DirectCompiler.csproj DirectClosure.targets）：已入库、不提该属性 → 放行；提到该属性 → 拒绝
        (self.root / 'services/local.targets').write_text('<Project><Target Name="T"/></Project>')
        subprocess.run(['git', '-C', str(self.root), 'add', 'services/local.targets'], check=True)
        project.write_text("<Project><PropertyGroup><Ryu>$(MSBuildThisFileDirectory)../tree/src/</Ryu></PropertyGroup>"
                           '<ItemGroup><ProjectReference Include="$(Ryu)Shader/s.csproj"/></ItemGroup><Import Project="local.targets"/></Project>')
        self.value()
        (self.root / 'services/local.targets').write_text('<Project><PropertyGroup><Ryu>elsewhere</Ryu></PropertyGroup></Project>')
        with self.assertRaises(ValueError): self.value()

    def test_openssl_ndk_helper_change_invalidates_receipt(self):
        first = self.value()
        (self.root / 'android/tools/ndk_toolchain.sh').write_text('changed')
        self.assertNotEqual(first['dependencies_sha256'], self.value()['dependencies_sha256'])

    def test_source_fetch_helper_change_invalidates_both_receipts(self):
        # 源码包共用下载 + 共享缓存：两条准备路线都经它取 openssl / libvpx / opus；docker 路线不再有 GitHub curl 垫片。
        self.assertIn('android/tools/fetch_source.sh', identity.SHARED)
        self.assertNotIn('android/docker/prepare-curl.sh', identity.REQUIRED['docker'])
        first, first_host = self.value(), self.host_value()
        (self.root / 'android/tools/fetch_source.sh').write_text('changed')
        self.assertNotEqual(first['dependencies_sha256'], self.value()['dependencies_sha256'])
        self.assertNotEqual(first_host['dependencies_sha256'], self.host_value()['dependencies_sha256'])

    def test_codec_recipe_change_invalidates_receipt(self):
        first = self.value()
        (self.root / 'android/codecs/cache.sh').write_text('new codec recipe')
        self.assertNotEqual(self.value()['dependencies_sha256'], first['dependencies_sha256'])

    def test_codec_python_validator_change_invalidates_receipt(self):
        first = self.value()
        (self.root / 'android/codecs/avc_source.py').write_text('new validator')
        self.assertNotEqual(self.value()['dependencies_sha256'], first['dependencies_sha256'])

    def test_missing_or_symlink_dependency_is_rejected(self):
        target = self.root / identity.REQUIRED['docker'][0]
        target.unlink()
        with self.assertRaises(ValueError):
            self.value()
        target.symlink_to(self.root / 'services/a.csproj')
        with self.assertRaises(ValueError):
            self.value()

    def host_value(self, uname='test'):
        env = {'uname': uname, 'ndk_source_properties_sha256': 'a' * 64,
               'ndk_prebuilt_tag': 'darwin-arm64', 'ndk_clang_version_sha256': 'b' * 64,
               'dotnet_version_sha256': 'c' * 64, 'javac_version_sha256': 'd' * 64,
               'sdk_packages_sha256': {}}
        return identity.identity(self.root, self.root, 'host', {'environment': env})

    def test_host_environment_change_invalidates_receipt(self):
        first, changed = self.host_value(), self.host_value(uname='other')
        self.assertNotEqual(first['environment_sha256'], changed['environment_sha256'])
        self.assertEqual(first['dependencies_sha256'], changed['dependencies_sha256'])

    def test_version_probe_timeout_fails_loudly_missing_tool_is_none(self):
        # 超时不许静默记成 None（同样输入在高负载下算出不同清单）；工具不存在才是 None
        with tempfile.TemporaryDirectory() as tmp:
            slow = Path(tmp, 'slow')
            slow.write_text('#!/bin/sh\nsleep 5\n'); slow.chmod(0o755)
            orig = identity.subprocess.run
            def short(*a, **k):
                k['timeout'] = 0.2
                return orig(*a, **k)
            identity.subprocess.run = short
            try:
                with self.assertRaises(SystemExit) as cm:
                    identity.bounded_version([slow, '--version'])
                self.assertIn('版本探测超时', str(cm.exception.code))
            finally:
                identity.subprocess.run = orig
            self.assertIsNone(identity.bounded_version([Path(tmp, 'absent'), '--version']))

    def test_host_missing_required_file_fails_closed(self):
        (self.root / 'android/host/hostenv.sh').unlink()
        with self.assertRaises(ValueError):
            self.host_value()

    def test_host_version_table_and_dockerfile_enter_the_manifest(self):
        # 版本表与实际装好的组件版本都来自这两个文件；只改它们而组件已装好时也必须失效。
        self.assertIn('android/tools/versions.sh', identity.REQUIRED['host'])
        self.assertIn('android/docker/Dockerfile', identity.REQUIRED['host'])

    def test_host_version_table_and_dockerfile_changes_invalidate_receipt(self):
        first = self.host_value()
        (self.root / 'android/tools/versions.sh').write_text('S2A_ANDROID_BUILD_TOOLS=changed\n')
        second = self.host_value()
        self.assertNotEqual(first['dependencies_sha256'], second['dependencies_sha256'])
        (self.root / 'android/docker/Dockerfile').write_text('FROM changed\n')
        self.assertNotEqual(second['dependencies_sha256'], self.host_value()['dependencies_sha256'])

    def test_doctor_change_does_not_invalidate_but_archive_valid_does(self):
        # doctor 只是 archive_valid 的一个消费者；拆出小模块后清单里不再放整份 doctor。
        self.assertNotIn('android/doctor/doctor.py', identity.SHARED)
        self.assertIn('android/doctor/archive_valid.py', identity.SHARED)
        first = self.value()
        (self.root / 'android/doctor/doctor.py').write_text('changed doctor\n')
        self.assertEqual(first, self.value())
        (self.root / 'android/doctor/archive_valid.py').write_text('changed archive rule\n')
        self.assertNotEqual(first['dependencies_sha256'], self.value()['dependencies_sha256'])


if __name__ == '__main__':
    unittest.main()
