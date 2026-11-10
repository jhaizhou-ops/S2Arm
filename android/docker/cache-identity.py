#!/usr/bin/env python3
"""Stable identity for the offline APK gate's image and dependency inputs."""
import re
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import posixpath
import subprocess
import sys
import xml.etree.ElementTree as ET

SHARED = (
    'android/docker/cache-identity.py',
    'android/docker/gate-audit.py',
    'android/docker/gate-step.sh',
    'android/doctor/archive_valid.py',
    'android/cs/build.sh',
    'android/cs/archive_check.py',
    'android/codecs/build.sh',
    'android/openssl/build.sh',
    'android/tools/ndk_toolchain.sh',
    # 源码包共用下载 + 按 SHA 的共享缓存（docker/prepare.sh、codecs/build.sh、openssl/build.sh、services/*/build.sh 都 source）。
    'android/tools/fetch_source.sh',
    'services/opus/build.sh', 'services/opus/s2a_opus.c',
    'services/vpx/build.sh', 'services/vpx/s2a_vp8.c', 'services/vpx/s2a_vp9.c',
    'services/vpx/patches/0001-s2a-vp9-nvdec-hook.patch',
)
REQUIRED = {
    'docker': (
        'android/docker/Dockerfile',
        'android/docker/prepare.sh',
    ) + SHARED,
    'host': (
        'android/host/build.sh',
        'android/host/hostenv.sh',
        'android/host/prepare.sh',
        'android/host/gate-apk.sh',
        'android/tools/jdk17.sh',
        # 版本表的唯一来源（含 NDK / build-tools / CMake 版本）与实际组件配方。
        'android/tools/versions.sh',
        'android/docker/Dockerfile',
    ) + SHARED,
}
PROJECTS = ('android/cs/probe/S2A.Android.Probe.csproj',
            'android/cs/aot/S2A.Android.Aot.csproj')
SLOT_RE = re.compile(r's2a-apk-gate-receipt-[0-9a-f]{12}\.json\Z')


def slot_name(dependencies_sha256):
    """One receipt file per dependency identity; docker and host share the naming."""
    if (len(dependencies_sha256) != 64
            or any(c not in '0123456789abcdef' for c in dependencies_sha256)):
        raise ValueError('bad dependencies_sha256')
    return f's2a-apk-gate-receipt-{dependencies_sha256[:12]}.json'


def prune_slots(cache, keep=4):
    """Keep the most recently used receipt slots; never touch dependency payloads."""
    slots = []
    for candidate in Path(cache).glob('s2a-apk-gate-receipt-????????????.json'):
        if SLOT_RE.fullmatch(candidate.name) and not candidate.is_symlink() and candidate.is_file():
            slots.append((candidate.stat().st_mtime_ns, candidate))
    for _, path in sorted(slots, reverse=True)[keep:]:
        try:
            path.unlink()
        except FileNotFoundError:
            pass


def safe_file(source, rel):
    path = source / rel
    if not path.is_file() or path.is_symlink():
        raise ValueError(f'missing/unsafe dependency input: {rel}')
    return path


def local_dir_property(source, tracked, rel, xml, name):
    """Resolve a project-local MSBuild directory property defined from $(MSBuildThisFileDirectory), fail closed on overrides.
    Accepted: exactly one definition in the project, either unconditional (S2A.Dsh.csproj $(Ryu)) or a default ('$(Name)' == '', S2A.DirectCompiler.csproj $(RyuGpu))."""
    props = [node for node in xml.iter() if node.tag.rsplit('}', 1)[-1].lower() == name.lower()]
    cond = ''.join(props[0].get('Condition', '').split()) if len(props) == 1 else None
    if cond not in ('', f"'$({name})'==''"):
        raise ValueError(f'unsupported {name} definition in {rel}')
    value = (props[0].text or '').strip().replace('\\', '/')
    full = re.fullmatch(r"\$\(\[System\.IO\.Path\]::GetFullPath\('(\$\(MSBuildThisFileDirectory\)[^']*)'\)\)", value)
    if full: value = full.group(1)   # $([System.IO.Path]::GetFullPath('$(MSBuildThisFileDirectory)…')) (S2A.Dsh.csproj $(Nx)): the same directory, normalized
    prefix = '$(MSBuildThisFileDirectory)'
    if not value.startswith(prefix):
        raise ValueError(f'unsupported {name} value in {rel}')
    suffix = value[len(prefix):]
    if not suffix or any(x in suffix for x in ('$', '@', '*', ';')) or suffix.startswith('/'):
        raise ValueError(f'unsupported {name} value in {rel}')
    # An explicit project import or ancestor build config mentioning the property
    # could override its default before evaluation; do not guess its value.
    for node in xml.iter():   # an import may only be a tracked local file beside the project that never names the property (S2A.DirectCompiler.csproj DirectClosure.targets)
        if node.tag.rsplit('}', 1)[-1] != 'Import':
            continue
        imp = (node.get('Project') or '').replace('\\', '/')
        target = posixpath.normpath(posixpath.join(posixpath.dirname(rel), imp))
        if (not imp or any(x in imp for x in ('$', '@', '*', ';')) or imp.startswith('/') or target.startswith('../') or target not in tracked
                or name.lower() in safe_file(source, target).read_text().lower()):
            raise ValueError(f'unsupported import affecting {name} in {rel}')
    for directory in (PurePosixPath(rel).parent, *PurePosixPath(rel).parent.parents):
        for cfg_name in ('Directory.Build.props', 'Directory.Build.targets'):
            config = str(directory / cfg_name)
            if config in tracked and name.lower() in safe_file(source, config).read_text().lower():
                raise ValueError(f'{name} may be overridden in {config}')
    return posixpath.join(posixpath.dirname(rel), suffix)


def project_closure(source, tracked):
    pending = list(PROJECTS)
    projects = set()
    while pending:
        rel = pending.pop()
        if rel in projects:
            continue
        if rel not in tracked:
            raise ValueError(f'untracked project reference: {rel}')
        try:
            xml = ET.parse(safe_file(source, rel))
        except ET.ParseError as error:
            raise ValueError(f'invalid project {rel}: {error}') from error
        projects.add(rel)
        for item in xml.iter():
            if item.tag.rsplit('}', 1)[-1] != 'ProjectReference':
                continue
            include = item.get('Include')
            if not include:
                raise ValueError(f'unsupported ProjectReference in {rel}')
            include = include.replace('\\', '/')
            prop = re.match(r'\$\((\w+)\)', include)
            if prop and prop.group(1) != 'RepoRoot':   # a project-local directory property ($(RyuGpu)/…, $(Ryu)…)
                target = posixpath.join(local_dir_property(source, tracked, rel, xml, prop.group(1)), include[prop.end():].lstrip('/'))
            elif include.startswith('$(RepoRoot)'):
                target = include[len('$(RepoRoot)'):].lstrip('/')
            else:
                target = posixpath.join(posixpath.dirname(rel), include)
            target = posixpath.normpath(target)
            if ('$' in target or '@' in target or '*' in target or ';' in target or
                    target.startswith('../') or target.startswith('/') or target == '..'):
                raise ValueError(f'unsupported ProjectReference in {rel}: {include}')
            pending.append(target)
    return projects


def dependency_paths(source, tracked, backend):
    projects = project_closure(source, tracked)
    dirs = {PurePosixPath('.')}
    for project in projects:
        directory = PurePosixPath(project).parent
        dirs.add(directory)
        dirs.update(directory.parents)
    # dotnet is invoked from android/cs/build.sh; configs in its
    # ancestor directories can affect restore independently of project paths.
    directory = PurePosixPath('android')
    dirs.add(directory)
    dirs.update(directory.parents)
    selected = set(REQUIRED[backend]) | projects
    for rel in tracked:
        path = PurePosixPath(rel)
        name = path.name.lower()
        config = (name.startswith('directory.build.') or name in {
            'directory.packages.props', 'nuget.config', 'global.json',
            'packages.config', 'packages.lock.json'})
        gradle = (path.parent in {PurePosixPath('android'),
                                  PurePosixPath('android/app'),
                                  PurePosixPath('android/gradle/wrapper')} and
                  (name.endswith(('.gradle', '.gradle.kts')) or
                   name in {'gradle.properties', 'gradle-wrapper.properties'}))
        codec = (path.parent == PurePosixPath('android/codecs') and
                 name.endswith(('.sh', '.c', '.h', '.py')))
        if (path.parent in dirs and config) or gradle or codec:
            selected.add(rel)
    return selected


def bounded_version(argv):
    """Version-probe output only; 60 s bound, no environment emitted verbatim.
    Missing tool → None (not installed). Timeout → fail loudly: hashing None for a slow probe made the same
    inputs yield a different identity under load (11-01: host prepare reported "dependencies changed")."""
    try:
        p = subprocess.run([str(a) for a in argv], capture_output=True, timeout=60)
    except OSError:
        return None
    except subprocess.TimeoutExpired:
        raise SystemExit(f'【红】版本探测超时（60 秒）：{" ".join(str(a) for a in argv)}；依赖清单不可核实')
    return hashlib.sha256(p.stdout[:65536] + b'\0' + p.stderr[:65536]).hexdigest()


def host_environment(sdk_dir, ndk, dotnet, javac):
    """Native-host equivalent of image/recipe identity: OS, NDK payload, compiler/JDK/.NET
    version output and the installed SDK package metadata (package.xml), all hashed."""
    ndk = Path(ndk)
    tag = next((t for t in ('darwin-arm64', 'darwin-x86_64', 'linux-x86_64')
                if (ndk / 'toolchains/llvm/prebuilt' / t).is_dir()), None)
    source = ndk / 'source.properties'
    packages = {}
    for pkg in ('platforms', 'build-tools', 'ndk', 'cmake'):
        for p in sorted((Path(sdk_dir) / pkg).glob('*/package.xml')):
            packages[str(p.relative_to(sdk_dir))] = hashlib.sha256(p.read_bytes()).hexdigest()
    return {'uname': subprocess.check_output(['uname', '-sm']).decode().strip(),
            'ndk_source_properties_sha256': hashlib.sha256(source.read_bytes()).hexdigest() if source.is_file() else None,
            'ndk_prebuilt_tag': tag,
            'ndk_clang_version_sha256': bounded_version([ndk / 'toolchains/llvm/prebuilt' / tag / 'bin/clang', '--version']) if tag else None,
            'dotnet_version_sha256': bounded_version([dotnet, '--version']) if dotnet else None,
            'javac_version_sha256': bounded_version([javac, '-version']) if javac else None,
            'sdk_packages_sha256': packages}


def identity(repo, source, backend, evidence=None):
    paths = subprocess.check_output(['git', '-C', str(repo), 'ls-files', '-z']).split(b'\0')
    tracked = {os.fsdecode(p) for p in paths if p}
    if not set(REQUIRED[backend]) <= tracked:
        raise ValueError('missing tracked preparation input: '
                         + ', '.join(sorted(set(REQUIRED[backend]) - tracked)))
    selected = sorted(dependency_paths(source, tracked, backend))
    digest = hashlib.sha256()
    for rel in selected:
        data = safe_file(source, rel).read_bytes()
        digest.update(os.fsencode(rel) + b'\0' + hashlib.sha256(data).digest())
    if backend == 'docker':
        return {'schema': 2, 'image_id': evidence['image_id'], 'recipe_sha256': evidence['recipe'],
                'dependencies_sha256': digest.hexdigest(), 'dependency_files': len(selected)}
    environment = json.dumps(evidence['environment'], sort_keys=True)
    return {'schema': 3, 'backend': 'host',
            'environment_sha256': hashlib.sha256(environment.encode()).hexdigest(),
            'environment': evidence['environment'],
            'dependencies_sha256': digest.hexdigest(), 'dependency_files': len(selected)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo', type=Path)
    parser.add_argument('--source', type=Path)
    parser.add_argument('--backend', choices=['docker', 'host'], default='docker')
    parser.add_argument('--image-id')
    parser.add_argument('--recipe')
    parser.add_argument('--sdk', help='ANDROID_HOME for --backend host')
    parser.add_argument('--ndk', help='pinned NDK directory for --backend host')
    parser.add_argument('--dotnet', help='resolved dotnet executable for --backend host')
    parser.add_argument('--javac', help='resolved javac for --backend host')
    parser.add_argument('--slot', action='store_true',
                        help='print the receipt slot filename for the identity JSON on stdin')
    parser.add_argument('--prune', type=Path, metavar='DIR',
                        help='keep the four most recently used receipt slots in DIR')
    args = parser.parse_args()
    if args.slot:
        print(slot_name(json.load(sys.stdin)['dependencies_sha256']))
        return
    if args.prune is not None:
        prune_slots(args.prune)
        return
    if not (args.repo and args.source):
        parser.error('--repo and --source are required unless --slot/--prune')
    if args.backend == 'docker':
        if not args.image_id or not args.recipe:
            parser.error('--backend docker requires --image-id and --recipe')
        evidence = {'image_id': args.image_id, 'recipe': args.recipe}
    else:
        if not (args.sdk and args.ndk):
            parser.error('--backend host requires --sdk and --ndk')
        evidence = {'environment': host_environment(args.sdk, args.ndk, args.dotnet, args.javac)}
    print(json.dumps(identity(args.repo, args.source, args.backend, evidence),
                     sort_keys=True, separators=(',', ':')))


if __name__ == '__main__':
    main()
