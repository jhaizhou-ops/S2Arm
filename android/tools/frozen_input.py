#!/usr/bin/env python3
"""Create the path-free public identity at the W7 freeze boundary.

The caller must independently revalidate the W7 producer, source containers,
selection and system data. This transformation is not a source verifier.
"""
import hashlib
import codecs
import json
import os
from pathlib import Path, PurePosixPath
import re
import subprocess
import sys

# 仓库里唯一的 RomFS 遍历（graphics/nvn/tools/romfs_list.py：walk 同 os.walk）
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'graphics' / 'nvn' / 'tools'))
import romfs_list

FEATURE = 's2arm.android-input-roles-v1'
EXTENSION = 's2arm.android-input'
INITIAL = frozenset(['main', 'sdk'] + [f'subsdk{i}' for i in range(10)])
HEX = re.compile(r'^[0-9a-f]{64}$')
HOST_PATH_PREFIXES = (b'/Users/', b'/home/', b'/private/tmp/', b'/private/var/folders/',
                      b'/tmp/s2arm', b'C:\\Users\\')
TEXT_SUFFIXES = frozenset(('.json', '.xml', '.txt', '.tsv', '.properties', '.md', '.csv',
                           '.ini', '.yaml', '.yml', '.log', '.synth', '.strings'))
ABSOLUTE_TEXT_PATH = re.compile(rb"(?<![A-Za-z0-9._:/-])(?:/[^\s\"'<>]+|[A-Za-z]:[\\/][^\s\"'<>]+)")


class InvalidInput(ValueError):
    pass


def unique(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise InvalidInput('duplicate JSON field')
        result[key] = value
    return result


def public_manifest(raw):
    """Return deterministic public bytes and SHA256, or fail closed.

    Its input is the private W7 output from this invocation, never an arbitrary
    caller-provided root. Only the listed public fields are copied. The W7 lock
    with absolute source paths remains private.
    """
    try:
        source = json.loads(raw, object_pairs_hook=unique,
                            parse_constant=lambda _: (_ for _ in ()).throw(InvalidInput('invalid number')))
        if not isinstance(source, dict) or type(source.get('version')) is not int or source['version'] != 1 or source.get('requiredFeatures'):
            raise InvalidInput('unsupported input version or features')
        lock = source['extensions']['s2arm.input-lock']
        if not isinstance(lock, dict) or lock.get('version') != 1 or lock.get('guestIsa') != 'aarch64':
            raise InvalidInput('missing supported W7 lock')
        selection = lock['selection']
        if selection['base'] != source['base']['contentId']:
            raise InvalidInput('base selection differs from source')
        update = source.get('update')
        if selection['update'] != (update['contentId'] if update is not None else None):
            raise InvalidInput('update selection differs from source')
        if (not isinstance(selection['dlc'], list) or
                sorted(selection['dlc']) != sorted(item['contentId'] for item in lock['dlc']) or
                sorted(item['id'] for item in lock['dlc']) != sorted(item['id'] for item in source.get('dlc', []))):
            raise InvalidInput('DLC selection differs from source')

        sources = []
        for item in lock['sources']:
            path, digest = item['path'], item['sha256']
            if not isinstance(path, str) or not os.path.isabs(path) or not isinstance(digest, str) or not HEX.fullmatch(digest):
                raise InvalidInput('invalid source identity')
            kind = Path(path).suffix.lower().lstrip('.')
            if kind not in ('nsp', 'xci'):
                raise InvalidInput('unsupported source type')
            sources.append({'type': kind, 'sha256': digest})
        if not sources or len({(s['type'], s['sha256']) for s in sources}) != len(sources):
            raise InvalidInput('missing or duplicate source identity')
        sources.sort(key=lambda item: (item['type'], item['sha256']))

        files = {}
        for entry in lock['files']:
            path = entry['path']
            if not isinstance(path, str) or path in files:
                raise InvalidInput('duplicate or invalid W7 file')
            files[path] = entry
        origins = {}
        for entry in lock['modules']:
            name = entry['name']
            if not isinstance(name, str) or name in origins:
                raise InvalidInput('duplicate or invalid module origin')
            origins[name] = entry
        roles, seen = [], set()
        for module in source['modules']:
            name = module['name']
            if name in seen:
                raise InvalidInput('duplicate module')
            seen.add(name)
            origin = origins[name]
            path = origin['path']
            if (not isinstance(path, str) or not path or '\\' in path or
                    PurePosixPath(path).is_absolute() or any(p in ('', '.', '..') for p in path.split('/'))):
                raise InvalidInput('unsupported module source path')
            if module['type'] == 'exefs' and path != 'exefs/' + name:
                raise InvalidInput('exefs module origin differs from name')
            if module['type'] == 'nro' and not path.startswith(('romfs/', 'aoc/', 'control/')):
                raise InvalidInput('unsupported NRO origin')
            if module['type'] not in ('exefs', 'nro'):
                raise InvalidInput('unsupported module type')
            f = files[path]
            if (not isinstance(origin['fullBuildId'], str) or
                    not HEX.fullmatch(origin['fullBuildId']) or
                    not isinstance(module['sha256'], str) or not HEX.fullmatch(module['sha256']) or
                    f['sha256'] != module['sha256'] or origin['fullBuildId'][:32] != module['buildId']):
                raise InvalidInput('module identity differs from W7 lock')
            role = 'initial' if module['type'] == 'exefs' and name in INITIAL else 'unresolved'
            roles.append({'name': name, 'sourceType': module['type'], 'sourcePath': path, 'role': role})
        if 'main' not in seen or seen != set(origins):
            raise InvalidInput('source module set differs from origin set')
        roles.sort(key=lambda item: item['name'])

        fields = ('version', 'titleId', 'name', 'displayVersion', 'base', 'update', 'dlc',
                  'systemData', 'modules', 'romfs', 'tool', 'createdAt')
        result = {key: source[key] for key in fields if key in source}
        result['requiredFeatures'] = [FEATURE]
        result['extensions'] = {EXTENSION: {'version': 1, 'sources': sources, 'modules': roles}}
        encoded = (json.dumps(result, ensure_ascii=False, sort_keys=True, separators=(',', ':'),
                              allow_nan=False) + '\n').encode('utf-8')
        # Search decoded strings as well as serialized bytes, including escaped names.
        # Relative module origins are allowed; host absolute paths are not.
        def check_strings(value):
            if isinstance(value, dict):
                for key, item in value.items():
                    check_strings(key); check_strings(item)
            elif isinstance(value, list):
                for item in value:
                    check_strings(item)
            elif isinstance(value, str):
                if (value.startswith(('\\', 'file:')) or
                        re.search(r'(?<![A-Za-z0-9._-])/[^\s/]+', value) or
                        re.search(r'(?<![A-Za-z0-9])[A-Za-z]:[\\/]', value)):
                    raise InvalidInput('public identity contains an absolute path')
        check_strings(result)
        return encoded, hashlib.sha256(encoded).hexdigest()
    except (AttributeError, IndexError, KeyError, TypeError, UnicodeError, json.JSONDecodeError) as error:
        raise InvalidInput('incomplete W7 input lock') from error


def snapshot_tree(root, destination, private):
    """Copy only W7-locked build inputs to a private immutable build snapshot.

    The caller is responsible for verifying W7's source identities before and
    after this call. Only the supported subset may be built; unknown execution,
    unrepresentable DLC layouts fail closed.
    """
    try:
        lock = private['extensions']['s2arm.input-lock']
        if any(m['type'] != 'exefs' or m['name'] not in INITIAL for m in private['modules']):
            raise InvalidInput('unresolved source module cannot be built')
        root, destination = Path(root), Path(destination)
        if not root.is_absolute() or root.resolve() != root or not root.is_dir():
            raise InvalidInput('product root is absent or redirected')
        dlc_by_id = {item['id']: item for item in private.get('dlc', [])}
        if len(dlc_by_id) != len(private.get('dlc', [])):
            raise InvalidInput('duplicate DLC title')
        dlc_states = {item['id']: item for item in lock['dlc']}
        if set(dlc_states) != set(dlc_by_id) or len(dlc_states) != len(lock['dlc']):
            raise InvalidInput('DLC identities differ from frozen selection')
        for state in dlc_states.values():
            data_ids = state['dataContentIds']
            if (not isinstance(data_ids, list) or len(data_ids) != (1 if state['state'] == 'data' else 0) or
                    any(not isinstance(x, str) or not re.fullmatch(r'[0-9a-f]{32}', x) for x in data_ids)):
                raise InvalidInput('DLC content set cannot be represented')
        dlc_content = {}
        expected = {}
        for entry in lock['files']:
            path = entry['path']
            if path.startswith(('exefs/', 'romfs/')):
                rel = path
            elif path == 'control/control.nacp':
                rel = 'ctl/control.nacp'
            elif path.startswith('aoc/'):
                parts = path.split('/')
                if len(parts) < 4 or parts[1] not in dlc_by_id or dlc_states[parts[1]]['state'] != 'data':
                    raise InvalidInput('DLC file has no selected data identity')
                old = dlc_content.setdefault(parts[1], parts[2])
                if old != parts[2] or parts[2] not in dlc_states[parts[1]]['dataContentIds']:
                    raise InvalidInput('multiple DLC data contents cannot be represented')
                idx = int(parts[1], 16) - int(private['titleId'], 16) - 0x1000
                if not 0 <= idx <= 0xfff:
                    raise InvalidInput('DLC title is outside the selected application')
                rel = 'aoc/' + str(idx) + '/' + '/'.join(parts[3:])
            else:
                continue
            parts = rel.split('/')
            if (rel in expected or any(part in ('', '.', '..') for part in parts) or
                    '\\' in rel or not isinstance(entry['bytes'], int) or entry['bytes'] < 0 or
                    not isinstance(entry['sha256'], str) or not HEX.fullmatch(entry['sha256'])):
                raise InvalidInput('invalid locked file')
            expected[rel] = entry
        if not {'exefs/main', 'exefs/main.npdm', 'ctl/control.nacp'} <= set(expected):
            raise InvalidInput('missing locked executable or control')
        for directory in ('exefs', 'romfs', 'ctl', 'aoc'):
            start = root / directory
            wanted = {name for name in expected if name.startswith(directory + '/')}
            if directory == 'aoc' and not wanted and not start.exists():
                continue
            if start.is_symlink() or not start.is_dir():
                raise InvalidInput('required input directory absent or redirected')
            found = set()
            for current, dirs, files in romfs_list.walk(start):
                for name in dirs + files:
                    path = Path(current) / name
                    if path.is_symlink() or not (path.is_file() or path.is_dir()):
                        raise InvalidInput('link or special input file')
                found.update((Path(current) / name).relative_to(root).as_posix() for name in files)
            if found != wanted:
                raise InvalidInput('input file set differs from frozen W7 view')
        destination.mkdir(mode=0o700)
        for rel, entry in sorted(expected.items()):
            src, dst = root / rel, destination / rel
            dst.parent.mkdir(parents=True, exist_ok=True)
            digest, total = hashlib.sha256(), 0
            with src.open('rb') as source, dst.open('xb') as target:
                while chunk := source.read(1 << 20):
                    digest.update(chunk); total += len(chunk); target.write(chunk)
            if (total, digest.hexdigest()) != (entry['bytes'], entry['sha256']):
                raise InvalidInput('actual build input differs from frozen W7 view')
        for module in private['modules']:
            data = (destination / 'exefs' / module['name']).read_bytes()
            if len(data) < 0x60 or data[:4] != b'NSO0' or data[0x40:0x50].hex() != module['buildId']:
                raise InvalidInput('actual NSO build identity differs from manifest')
        if dlc_by_id:
            rows = []
            for title, item in sorted(dlc_by_id.items(), key=lambda pair: str(int(pair[0], 16) - int(private['titleId'], 16) - 0x1000)):
                idx = int(title, 16) - int(private['titleId'], 16) - 0x1000
                if not 0 <= idx <= 0xfff or item['enabled'] is not True:
                    raise InvalidInput('invalid selected DLC identity')
                state = dlc_states[title]['state']
                if state not in ('data', 'license-only'):
                    raise InvalidInput('unsupported DLC state')
                prefix = f'aoc/{idx}/'
                files = [entry for rel, entry in expected.items() if rel.startswith(prefix)]
                if state == 'license-only' and files:
                    raise InvalidInput('license-only DLC has data')
                count = len(files) if state == 'data' else -1
                rows.append(f"{idx}\t{title.lower()}\t{item['version']}\t{count}\t{sum(f['bytes'] for f in files)}\n")
            (destination / 'aoc.tsv').write_text('idx\ttitle_id\tversion\tfiles\tbytes\n' + ''.join(rows))
        return destination
    except (KeyError, TypeError, OSError, ValueError) as error:
        if isinstance(error, InvalidInput):
            raise
        raise InvalidInput('cannot snapshot frozen build input') from error


def snapshot_system_data(destination, private):
    lock = private['extensions']['s2arm.input-lock']
    if private.get('systemData') is None:
        if lock.get('systemPath') is not None or lock.get('systemFiles'):
            raise InvalidInput('unexpected system data lock')
        return ''
    root = Path(lock['systemPath'])
    if not root.is_absolute() or root.resolve() != root or not root.is_dir():
        raise InvalidInput('system data source is missing or redirected')
    expected = {}
    for item in lock['systemFiles']:
        path = item['path']
        if (not isinstance(path, str) or path in expected or '\\' in path or path.startswith('/') or
                any(part in ('', '.', '..') for part in path.split('/')) or
                type(item['bytes']) is not int or item['bytes'] < 0 or
                not isinstance(item['sha256'], str) or not HEX.fullmatch(item['sha256'])):
            raise InvalidInput('invalid system data lock')
        expected[path] = item
    found = set()
    for current, dirs, files in os.walk(root, followlinks=False):
        for name in dirs + files:
            path = Path(current) / name
            if path.is_symlink() or not (path.is_dir() or path.is_file()):
                raise InvalidInput('system data contains a link or special file')
        found.update((Path(current) / name).relative_to(root).as_posix() for name in files)
    if found != set(expected):
        raise InvalidInput('system data file set differs from lock')
    destination = Path(destination); destination.mkdir(mode=0o700)
    for rel, item in sorted(expected.items()):
        dest = destination / rel; dest.parent.mkdir(parents=True, exist_ok=True)
        digest, size = hashlib.sha256(), 0
        with (root / rel).open('rb') as source, dest.open('xb') as target:
            while chunk := source.read(1 << 20):
                digest.update(chunk); size += len(chunk); target.write(chunk)
        if (size, digest.hexdigest()) != (item['bytes'], item['sha256']):
            raise InvalidInput('system data changed since freezing')
    return str(destination)


def read_locked(path, expected):
    path = Path(path)
    if (not path.is_absolute() or path.resolve() != path or not path.is_file() or
            not isinstance(expected, str) or not HEX.fullmatch(expected)):
        raise InvalidInput('invalid frozen input reference or digest')
    data = path.read_bytes()
    if len(data) > 16 * 1024 * 1024 or hashlib.sha256(data).hexdigest() != expected:
        raise InvalidInput('frozen input identity changed')
    return data


def revalidate_w7(dotnet, tool, tool_sha, keys, request, expected_private):
    """Re-resolve the explicit W7 request against its real source containers."""
    try:
        for path in (dotnet, tool, keys, request):
            p = Path(path)
            if not p.is_absolute() or p.resolve() != p or not p.is_file():
                raise InvalidInput('W7 input is absent or redirected')
        if Path(tool).name != 'nx_unpack.dll' or Path(dotnet).name != 'dotnet':
            raise InvalidInput('unsupported W7 executable reference')
        key_stat = Path(keys).stat()
        if key_stat.st_uid != os.getuid() or key_stat.st_mode & 0o077:
            raise InvalidInput('W7 key reference is not private')
        if not HEX.fullmatch(tool_sha) or hashlib.sha256(Path(tool).read_bytes()).hexdigest() != tool_sha:
            raise InvalidInput('W7 tool identity changed')
        process = subprocess.run([str(dotnet), str(tool), str(keys), 'games.resolve', str(request)],
                                 capture_output=True, check=False)
        if process.returncode or len(process.stdout) > 16 * 1024 * 1024 or process.stdout != expected_private:
            raise InvalidInput('W7 source selection no longer matches the frozen input')
        if hashlib.sha256(Path(tool).read_bytes()).hexdigest() != tool_sha:
            raise InvalidInput('W7 tool changed during source validation')
    except (OSError, TypeError) as error:
        raise InvalidInput('cannot revalidate W7 source selection') from error


def reject_private_stream(stream, protected_paths, check=lambda: None, *, text=None):
    secrets = {os.fsencode(os.path.realpath(path)) for path in protected_paths}
    if any(not value for value in secrets):
        raise InvalidInput('missing host path for privacy check')
    wide = {os.fsdecode(value).encode('utf-16le') for value in secrets | set(HOST_PATH_PREFIXES)}
    overlap = max([512, *map(len, secrets | set(HOST_PATH_PREFIXES) | wide)])
    previous = b''
    while chunk := stream.read(1 << 20):
        check()
        if text is None:
            sample = chunk[:4096]
            try:
                decoded = codecs.getincrementaldecoder('utf-8')('strict').decode(sample, final=False)
                text = bool(decoded) and '\0' not in decoded and sum(c.isprintable() or c in '\r\n\t' for c in decoded) / len(decoded) >= .95
            except UnicodeError:
                text = False
        data = previous + chunk
        if any(value in data for value in secrets | wide):
            raise InvalidInput('package contains a host absolute path')
        for prefix in HOST_PATH_PREFIXES:
            start = 0
            while (position := data.find(prefix, start)) >= 0:
                if not text or position == 0 or data[position - 1] not in b'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-':
                    raise InvalidInput('package contains a host absolute path')
                start = position + 1
        if text and ABSOLUTE_TEXT_PATH.search(data):
            raise InvalidInput('text contains an absolute path')
        previous = data[-overlap:] if overlap else b''


def reject_private_bytes(root, protected_paths):
    """Reject host identities in any staged package file before publication."""
    for path in Path(root).rglob('*'):
        if path.is_symlink() or not (path.is_file() or path.is_dir()):
            raise InvalidInput('package contains a link or special file')
        if not path.is_file():
            continue
        with path.open('rb') as stream:
            reject_private_stream(stream, protected_paths, text=True if path.suffix.lower() in TEXT_SUFFIXES else None)
