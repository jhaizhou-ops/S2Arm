#!/usr/bin/env python3
# 门禁手动：要传参数：--dependencies 预构建托管依赖 DLL 目录（门禁机没有固定的依赖目录）+ --vulkan-source / --output
"""Compile complete real Vulkan sources and exercise real Rebind, offline and without a GPU."""
import argparse
import glob
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import xml.etree.ElementTree as ET

REFERENCES = (
    'Ryujinx.Common', 'Ryujinx.Graphics.GAL', 'Ryujinx.Graphics.Shader', 'Spv.Generator',
    'Silk.NET.Core', 'Silk.NET.Shaderc', 'Silk.NET.Vulkan',
    'Silk.NET.Vulkan.Extensions.EXT', 'Silk.NET.Vulkan.Extensions.KHR', 'Gommon',
)
CONTROLS = {
    'first-word': (
        'BitMapStruct.cs',
        'int masks = masksSpan.Length;\n            for (int i = 0; i < masks; i++)',
        'int masks = 1;\n            for (int i = 0; i < masks; i++)',
        'set/overlap semantics',
    ),
    'inclusive-endpoint': (
        'DescriptorSetUpdater.cs',
        'return offset < bindingOffset + (int)info.Range && (offset + size) > bindingOffset;',
        'return offset <= bindingOffset + (int)info.Range && (offset + size) >= bindingOffset;',
        'set/overlap semantics',
    ),
    'omit-union': (
        'DescriptorSetUpdater.cs',
        '_uniformMirrored.Union(_uniformSet).SignalSet(ref uniform);',
        '_uniformMirrored.SignalSet(ref uniform);',
        'set/overlap semantics',
    ),
    'clear-mirror': (
        'DescriptorSetUpdater.cs',
        '_owner._uniformSet.Clear(binding);',
        '_owner._uniformSet.Clear(binding);\n                                _owner._uniformMirrored.Clear(binding);',
        'mirrored bitmap must not be cleared',
    ),
}


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2, ensure_ascii=False) + '\n', encoding='utf-8')


def source_files(source):
    project = source / 'Ryujinx.Graphics.Vulkan.csproj'
    xml = ET.parse(project).getroot()
    files = {p for p in source.rglob('*.cs')
             if not any(part in ('bin', 'obj', '.git') for part in p.relative_to(source).parts)
             and not p.name.startswith('._')}
    # Keep the real project's linked DeviceFeatureSnapshot/WSI sources too. Unknown
    # compile rules must be reviewed, rather than silently compiling a smaller seam.
    for group in xml:
        for item in group:
            if item.tag.rsplit('}', 1)[-1] != 'Compile':
                continue
            if group.get('Condition') or 'Include' not in item.attrib or set(item.attrib) - {'Include', 'Link'}:
                raise ValueError('Unsupported conditional/Remove/Update Compile item; inspect the real project.')
            include = item.attrib['Include'].replace('\\', '/')
            if any(token in include for token in ('$', '@', '%', ';')):
                raise ValueError('Computed Compile input must be supported explicitly: ' + include)
            matches = [Path(p) for p in glob.glob(str(source / include), recursive=True)]
            if not matches or any(not p.is_file() or p.suffix != '.cs' for p in matches):
                raise ValueError('Missing/non-C# linked Compile input: ' + include)
            files.update(matches)
    if not files or any(p.is_symlink() for p in files):
        raise ValueError('Expected complete regular production C# sources, without symlink inputs.')
    return project, sorted({p.resolve(strict=True) for p in files})


def create_project(path, source, fixture, dependencies, legacy):
    project = ET.Element('Project', Sdk='Microsoft.NET.Sdk')
    properties = ET.SubElement(project, 'PropertyGroup')
    values = {
        'OutputType': 'Exe', 'TargetFramework': 'net10.0',
        'AssemblyName': 'Ryujinx.Graphics.Vulkan', 'LangVersion': 'preview',
        'AllowUnsafeBlocks': 'true', 'EnableDefaultCompileItems': 'false',
        'Optimize': 'true', 'Nullable': 'disable', 'NuGetAudit': 'false',
        'ImportDirectoryBuildProps': 'false', 'ImportDirectoryBuildTargets': 'false',
    }
    if not legacy:
        values['DefineConstants'] = 'VALUE_LISTENER'
    for name, value in values.items():
        ET.SubElement(properties, name).text = value
    items = ET.SubElement(project, 'ItemGroup')
    ET.SubElement(items, 'Compile', Include=str(source / '**/*.cs'))
    ET.SubElement(items, 'Compile', Include=str(fixture))
    for name in REFERENCES:
        ET.SubElement(items, 'Reference', Include=str(dependencies / (name + '.dll')))
    ET.ElementTree(project).write(path, encoding='unicode')


def mutate(source, name):
    filename, before, after, _ = CONTROLS[name]
    path = source / filename
    text = path.read_text(encoding='utf-8')
    prefix = ''
    if name == 'first-word':
        start = text.index('        public void SignalSet<TListener>')
        prefix, text = text[:start], text[start:]
    if text.count(before) != 1:
        raise ValueError('Production boundary changed; ambiguous negative control: ' + name)
    original = sha256(path)
    path.write_text(prefix + text.replace(before, after), encoding='utf-8')
    return {'name': name, 'file': str(path), 'before_sha256': original,
            'after_sha256': sha256(path), 'expected_failure': CONTROLS[name][3]}


def execute(command, name, output, environment, timeout, record):
    stdout = output / (name + '.stdout')
    stderr = output / (name + '.stderr')
    step = {'name': name, 'command': [str(arg) for arg in command], 'returncode': None,
            'stdout': stdout.name, 'stderr': stderr.name, 'timeout_seconds': timeout}
    record['commands'].append(step)
    with stdout.open('w') as out_stream, stderr.open('w') as err_stream:
        try:
            result = subprocess.run(step['command'], cwd=output, env=environment,
                                    stdout=out_stream, stderr=err_stream, timeout=timeout)
            step['returncode'] = result.returncode
        except subprocess.TimeoutExpired:
            step.update(returncode=None, timed_out=True)
        except OSError as error:
            step['error'] = str(error)
            raise
    return step


def validate_result(result, args):
    observed = result['fixture']
    expected = 2 if args.negative_control else 1 if args.legacy_listener else 0
    result['expected_test_returncode'] = expected
    if result['commands'][-1]['returncode'] != expected:
        raise ValueError('Unexpected fixture exit; inspect test stdout/stderr.')
    if args.negative_control:
        if observed.get('failure') != CONTROLS[args.negative_control][3]:
            raise ValueError('Negative control failed for an unrelated reason.')
    else:
        if (observed.get('semantics_checks'), observed.get('iterations'), observed.get('warmup_iterations')) != (1468, 100000, 30000):
            raise ValueError('Missing semantic assertions or allocation iterations.')
        counts = [observed.get(name) for name in ('empty_bytes', 'mirrored_bytes', 'null_program_bytes')]
        if any(type(value) is not int for value in counts):
            raise ValueError('Missing allocation measurements.')
        if args.legacy_listener and not all(value > 0 for value in counts):
            raise ValueError('Legacy source did not reproduce all three allocation red paths.')
        if not args.legacy_listener and any(counts):
            raise ValueError('Candidate allocated managed bytes.')
    result['expectation_matched'] = True
    return expected  # Expected red still returns red; never turn a failing guard green.


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dotnet', required=True, type=Path)
    parser.add_argument('--dependencies', required=True, type=Path)
    parser.add_argument('--vulkan-source', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument('--legacy-listener', action='store_true', help='Read untouched Action-listener source; expect allocation red (exit 1).')
    modes.add_argument('--negative-control', choices=sorted(CONTROLS), help='Mutate only the isolated copy; expect the named semantic red (exit 2).')
    parser.add_argument('--timeout-seconds', type=int, default=120)
    args = parser.parse_args()
    if args.timeout_seconds <= 0:
        parser.error('--timeout-seconds must be positive')
    dotnet = args.dotnet.resolve(strict=True)
    dependencies = args.dependencies.resolve(strict=True)
    source = args.vulkan_source.resolve(strict=True)
    output = args.output.resolve()
    harness = Path(__file__).resolve().parent
    if not dotnet.is_file() or not os.access(dotnet, os.X_OK):
        parser.error('--dotnet must be an existing executable')
    if not dependencies.is_dir() or not source.is_dir():
        parser.error('--dependencies and --vulkan-source must be directories')
    project, files = source_files(source)
    project_sha = sha256(project)
    roots = {source, dependencies, harness, *(p.parent for p in files)}
    if any(output.is_relative_to(p) or p.is_relative_to(output) for p in roots):
        parser.error('--output must be separate from all source, harness and dependency trees')
    output.mkdir(parents=True, exist_ok=False)
    result = {'schema': 's2arm.rebind-host-proof.v1', 'kind': 'host JIT only; no Vulkan device',
              'arguments': vars(args) | {'dotnet': str(dotnet)},
              'environment': {'DOTNET_TieredCompilation': '0', 'DOTNET_CLI_TELEMETRY_OPTOUT': '1'},
              'commands': [], 'expectation_matched': False}
    # Paths are explicit local evidence; never serialize the inherited environment.
    result['arguments'] = {key: str(value) if isinstance(value, Path) else value
                           for key, value in result['arguments'].items()}
    exit_code = 3  # Preparation/build/transport or unexpected outcomes are not semantic negative controls.
    try:
        common = Path(os.path.commonpath([str(source), *(str(p.parent) for p in files)]))
        frozen = output / 'source'
        source_records = {}
        for path in files:
            destination = frozen / path.relative_to(common)
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(path, destination)
            source_records[str(path)] = {'copy': str(destination.relative_to(output)), 'sha256': sha256(destination)}
        current_project, current_files = source_files(source)
        if current_files != files or sha256(current_project) != project_sha or any(
                sha256(Path(path)) != item['sha256'] for path, item in source_records.items()):
            raise ValueError('Production source changed while freezing; use a fixed source snapshot.')
        shutil.copyfile(current_project, output / 'input-project.csproj')
        frozen_dependencies = output / 'dependencies'
        frozen_dependencies.mkdir()
        dependency_records = {}
        for path in sorted(dependencies.glob('*.dll')):
            if path.name == 'Ryujinx.Graphics.Vulkan.dll':
                continue  # The tested Vulkan assembly must always come from the real source.
            destination = frozen_dependencies / path.name
            shutil.copyfile(path, destination)
            dependency_records[path.name] = {'source': str(path), 'sha256': sha256(destination)}
            if sha256(path) != dependency_records[path.name]['sha256']:
                raise ValueError('Dependency changed while freezing: ' + str(path))
        for name in REFERENCES:
            if name + '.dll' not in dependency_records:
                raise ValueError('Missing actual dependency: ' + name + '.dll')
        shutil.copyfile(harness / 'Fixture.cs', output / 'Fixture.cs')
        shutil.copyfile(harness / 'NuGet.Config', output / 'NuGet.Config')
        copied_vulkan = frozen / source.relative_to(common)
        manifest = {'sources': source_records, 'dependencies': dependency_records,
                    'input_project_sha256': sha256(output / 'input-project.csproj'),
                    'dotnet_sha256': sha256(dotnet),
                    'harness_sha256': {name: sha256(harness / name) for name in ('run.py', 'Fixture.cs', 'NuGet.Config')},
                    'excluded_dependency': 'Ryujinx.Graphics.Vulkan.dll',
                    'explicit_references': list(REFERENCES)}
        write_json(output / 'input-sha256.json', manifest)
        if args.negative_control:
            result['mutation'] = mutate(copied_vulkan, args.negative_control)
        write_json(output / 'compiled-source-sha256.json', {
            str(path.relative_to(output)): sha256(path) for path in sorted(frozen.rglob('*.cs'))})
        proof = output / 'Proof.csproj'
        create_project(proof, frozen, output / 'Fixture.cs', frozen_dependencies, args.legacy_listener)
        environment = dict(os.environ, **result['environment'])
        sdk = execute([dotnet, '--version'], 'sdk', output, environment, args.timeout_seconds, result)
        if sdk['returncode'] != 0:
            raise ValueError('SDK query failed or timed out.')
        build = execute([dotnet, 'build', proof, '-c', 'Release', '--configfile', output / 'NuGet.Config', '--nologo',
                         '-p:ImportDirectoryBuildProps=false', '-p:ImportDirectoryBuildTargets=false'],
                        'build', output, environment, args.timeout_seconds, result)
        if build['returncode'] != 0:
            raise ValueError('Real-source build failed or timed out; not an expected semantic red.')
        assembly = output / 'bin/Release/net10.0/Ryujinx.Graphics.Vulkan.dll'
        test = execute([dotnet, assembly], 'test', output, environment, args.timeout_seconds, result)
        if test.get('timed_out'):
            raise ValueError('Fixture timed out; not an expected semantic red.')
        result['fixture'] = json.loads((output / 'test.stdout').read_text(encoding='utf-8'))
        exit_code = validate_result(result, args)
    except (OSError, ValueError, ET.ParseError) as error:
        result['error'] = str(error)
        print(str(error), file=sys.stderr)
    finally:
        result['runner_returncode'] = exit_code
        write_json(output / 'results.json', result)
        write_json(output / 'output-sha256.json', {
            str(path.relative_to(output)): sha256(path)
            for path in sorted(output.rglob('*')) if path.is_file() and path.name != 'output-sha256.json'})
    print(json.dumps({'output': str(output), 'returncode': exit_code,
                      'expectation_matched': result['expectation_matched'], 'fixture': result.get('fixture')}, ensure_ascii=False))
    return exit_code


if __name__ == '__main__':
    sys.exit(main())
