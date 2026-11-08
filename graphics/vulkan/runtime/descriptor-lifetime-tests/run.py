#!/usr/bin/env python3
# 门禁手动：要传参数：--deps 与当前源码匹配的预构建托管运行时 DLL 目录（门禁机没有固定的依赖目录）+ --dotnet / --out
"""Offline, controlled Vulkan API regression; does not create a GPU device."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import sys
import xml.etree.ElementTree as ET


CASES = (
    'basic', 'descriptor-basic', 'rotate', 'mirror', 'cache-recording',
    'cache-pending', 'cache-all', 'cache-no-action', 'ubo-cache-recording',
    'ubo-cache-pending', 'ubo-rotate', 'coverage-identity', 'null-image',
    'null-buffer-texture', 'texel-format-fallback',
)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dotnet', type=Path, required=True)
    parser.add_argument('--deps', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--source-root', type=Path)
    parser.add_argument('--baseline', action='store_true',
                        help='Keep old physical-set identity assertions; semantic failures remain red.')
    args = parser.parse_args()
    here = Path(__file__).resolve().parent
    repo = (args.source_root or here.parents[3]).resolve(strict=True)
    source = repo / 'compat/tree/src/Ryujinx.Graphics.Vulkan'
    output = args.out.resolve()
    dependencies = args.deps.resolve(strict=True)
    if any(output.is_relative_to(p) for p in (repo, dependencies, here)):
        parser.error('--out must be outside source, dependencies and harness directories')
    output.mkdir(parents=True, exist_ok=False)

    # Reuse the existing complete-source discovery and bounded process runner.
    # Importing this module does not execute its main/test entry point.
    helper_path = here.parent / 'rebind-tests/run.py'
    spec = importlib.util.spec_from_file_location('rebind_test_helpers', helper_path)
    helper = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(helper)
    record = {'kind': 'controlled-host-api-not-gpu', 'commands': [], 'cases': [],
              'baseline': args.baseline, 'helper_sha256': helper.sha256(helper_path)}
    status = 1
    try:
        original_project = source / 'Ryujinx.Graphics.Vulkan.csproj'
        project_bytes = original_project.read_bytes()
        project_sha = hashlib.sha256(project_bytes).hexdigest()
        project, files = helper.source_files(source)
        common = Path(os.path.commonpath([str(p.parent) for p in files]))
        frozen = output / 'source'
        inputs = {}
        for path in files:
            target = frozen / path.relative_to(common)
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(path, target)
            inputs[str(path)] = helper.sha256(target)
        current_project, current_files = helper.source_files(source)
        if current_files != files or current_project != project or helper.sha256(project) != project_sha or any(
                helper.sha256(Path(p)) != digest for p, digest in inputs.items()):
            raise ValueError('Source changed while freezing')
        record['sources_sha256'] = inputs
        (output / 'input-project.csproj').write_bytes(project_bytes)
        record['project_sha256'] = project_sha
        deps = output / 'deps'
        deps.mkdir()
        record['dependencies_sha256'] = {}
        for name in helper.REFERENCES:
            path = dependencies / (name + '.dll')
            target = deps / path.name
            shutil.copyfile(path, target)
            record['dependencies_sha256'][path.name] = helper.sha256(target)
            if helper.sha256(path) != helper.sha256(target):
                raise ValueError('Dependency changed while freezing')
        record['harness_sha256'] = {}
        for name in ('run.py', 'Fixture.cs', 'Dispatch.cs', 'NuGet.Config'):
            target = output / name
            shutil.copyfile(here / name, target)
            record['harness_sha256'][name] = helper.sha256(target)
            if helper.sha256(here / name) != record['harness_sha256'][name]:
                raise ValueError('Harness changed while freezing')
        dotnet = args.dotnet.resolve(strict=True)
        record['dotnet_sha256'] = helper.sha256(dotnet)
        proof = output / 'Proof.csproj'
        helper.create_project(proof, frozen, output / 'Fixture.cs', deps, False)
        xml = ET.parse(proof)
        ET.SubElement(xml.getroot().find('ItemGroup'), 'Compile', Include=str(output / 'Dispatch.cs'))
        xml.write(proof, encoding='unicode')
        environment = dict(os.environ, EXPECT_COVERAGE_ISOLATION='0' if args.baseline else '1',
                           DOTNET_TieredCompilation='0', DOTNET_CLI_TELEMETRY_OPTOUT='1')
        build = helper.execute([dotnet, 'build', proof, '-c', 'Release', '--nologo',
                                '--configfile', output / 'NuGet.Config', '--disable-build-servers',
                                '-m:1', '-p:ImportDirectoryBuildProps=false',
                                '-p:ImportDirectoryBuildTargets=false'],
                               'build', output, environment, 120, record)
        if build['returncode'] != 0:
            raise ValueError('Real-source build failed; not a semantic failure')
        assembly = output / 'bin/Release/net10.0/Ryujinx.Graphics.Vulkan.dll'
        record['assembly_sha256'] = helper.sha256(assembly)
        for case in CASES:
            step = helper.execute([dotnet, assembly, case], case, output, environment, 30, record)
            lines = (output / step['stdout']).read_text().splitlines()
            result = json.loads(lines[-1]) if lines else {}
            record['cases'].append({'name': case, 'exit': step['returncode'], 'result': result})
        status = int(any(c['exit'] != 0 or c['result'].get('status') != 'PASS'
                         for c in record['cases']))
    except (OSError, ValueError, ET.ParseError) as error:
        record['error'] = str(error)
    finally:
        record['returncode'] = status
        helper.write_json(output / 'results.json', record)
    print(json.dumps({'output': str(output), 'returncode': status}))
    return status


if __name__ == '__main__':
    sys.exit(main())
