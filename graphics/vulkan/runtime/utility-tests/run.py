#!/usr/bin/env python3
"""Validate the utility modules actually embedded by the Vulkan project."""
import argparse
import hashlib
import json
import subprocess
import sys
import xml.etree.ElementTree as ET
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--vulkan-root', required=True, type=Path)
    parser.add_argument('--spirv-val', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    root = args.vulkan_root.resolve(strict=True)
    tool = args.spirv_val.resolve(strict=True)
    output = args.output.resolve()
    if output.exists() or output.is_relative_to(root):
        parser.error('output must be a new directory outside the input tree')
    version = subprocess.run([str(tool), '--version'], check=True, text=True,
                             capture_output=True, timeout=10).stdout
    if not version.startswith('SPIRV-Tools'):
        parser.error('the explicit tool must be spirv-val')
    project = root / 'Ryujinx.Graphics.Vulkan.csproj'
    resources = []
    for item in ET.parse(project).iter('EmbeddedResource'):
        name = item.attrib.get('Include', '').replace('\\', '/')
        if name.startswith('Shaders/SpirvBinaries/') and name.endswith('.spv'):
            path = (root / name).resolve(strict=True)
            if not path.is_relative_to(root):
                parser.error('embedded resource escapes the input tree')
            resources.append((name, path))
    if not resources or len({name for name, _ in resources}) != len(resources):
        parser.error('the actual project must contain a nonempty, unique utility resource list')
    output.mkdir(parents=True)
    results = []
    for name, path in resources:
        command = [str(tool), '--target-env', 'vulkan1.1',
                   '--uniform-buffer-standard-layout', str(path)]
        result = subprocess.run(command, text=True, capture_output=True, timeout=30)
        results.append({'resource': name, 'sha256': hashlib.sha256(path.read_bytes()).hexdigest(),
                        'argv': command, 'rc': result.returncode,
                        'stdout': result.stdout, 'stderr': result.stderr})
    receipt = {'project': str(project), 'project_sha256': hashlib.sha256(project.read_bytes()).hexdigest(),
               'validator': str(tool), 'validator_sha256': hashlib.sha256(tool.read_bytes()).hexdigest(),
               'validator_version': version, 'results': results,
               'scope': 'Vulkan1.1 module validation with required uniformBufferStandardLayout assumption; '
                        'not physical-device feature enablement, GPU output or gameplay proof'}
    (output / 'result.json').write_text(json.dumps(receipt, indent=2) + '\n')
    failures = sum(item['rc'] != 0 for item in results)
    print(json.dumps({'modules': len(results), 'passed': len(results) - failures,
                      'failed': failures, 'receipt': str(output / 'result.json')}))
    return 1 if failures else 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, subprocess.SubprocessError, ET.ParseError) as error:
        print(f'utility validation setup failed: {error}', file=sys.stderr)
        sys.exit(2)
