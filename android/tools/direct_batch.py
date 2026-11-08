#!/usr/bin/env python3
"""直连程序库宿主批编（W2.4）：请求集 → 本机编译器批编 → 装库 + 描述文件。

输入是**请求集清单**，不是设备的编译结果：
  programs.v1.json
    {"schema": "s2a-direct-programs-v1", "directABI": 1,
     "translatorClosure": "s2a-dc1-…", "profileHash": "sha256-…",
     "sourceParserVersion": 1,
     "entries": [{"identity": "<64hex>", "request": "req/0001.json"}, …]}

身份（identity）由产生请求的一侧给出（它是完整规范输入的摘要，见
native/direct/input_identity.c），本工具不重算、不猜。translatorClosure 必须等于
本机编译器构建身份（cli identity），否则拒绝——不接受按游戏手写的假身份。

批编在宿主完成；编译产物由同一 DirectShaderCompiler 产生。装库复用
direct_library.py 的同一套校验与容器格式（不新增库格式，也不另写校验）。

用法：
  direct_batch.py build --programs p.json --out <库根> --descriptor <graphics.v1.json> \\
      --title-id <16hex> --identity <cli identity 的 JSON> [--cli <dll|csproj>]
      [--jobs N] [--index <index.tsv>] [--report <report.json>]
  direct_batch.py verify --lib <库根> --descriptor <graphics.v1.json>

退出码：0 = 库、描述文件及指定的报告都出成；1 = 输入/编译/装库/报告失败。
报告必须是库外的新文件；报告发布失败会保留已经完整发布的库与描述文件，并在错误中
列明路径，不删除它们或声称已回滚。这三个路径不是跨文件的崩溃原子事务。
"""
import argparse
import json
import os
import re
import stat
import shutil
import subprocess
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import direct_library  # noqa: E402  （同一份生产端规则与容器格式）

REPO = Path(__file__).resolve().parents[2]
PROGRAMS_SCHEMA = 's2a-direct-programs-v1'
PROGRAM_KEYS = frozenset(('schema', 'directABI', 'translatorClosure', 'profileHash',
                          'sourceParserVersion', 'entries'))
ENTRY_KEYS = frozenset(('identity', 'request'))
DEFAULT_CLI = REPO / 'graphics/tools/direct/compiler/cli'

# 编译失败里属于"这条程序暂时算不出"的：记 deferred，不进库，不算成功，也不让整批失败。
DEFERRED_CODES = frozenset(('MISSING_FACT', 'UNSUPPORTED_PROFILE'))


class BatchError(Exception):
    pass


def _read_json(path, what):
    try:
        raw = Path(path).read_bytes()
    except OSError as error:
        raise BatchError(f'{what}: cannot read {path}: {error.strerror or error}')
    try:
        return json.loads(raw)
    except ValueError as error:
        raise BatchError(f'{what}: is not valid JSON: {error}')


def load_programs(path):
    doc = direct_library._object(_read_json(path, 'programs manifest'), 'programs manifest')
    unknown = set(doc) - PROGRAM_KEYS
    if unknown:
        raise BatchError(f'programs manifest: unknown key(s) {sorted(unknown)}')
    if direct_library._string(doc.get('schema'), 'programs manifest.schema') != PROGRAMS_SCHEMA:
        raise BatchError(f'programs manifest.schema is not {PROGRAMS_SCHEMA}')
    entries = direct_library._array(doc.get('entries'), 'programs manifest.entries')
    if not entries:
        raise BatchError('programs manifest.entries is empty')
    loaded, seen_identity, seen_request = [], set(), set()
    base = Path(path).resolve().parent
    for index, entry in enumerate(entries):
        where = f'programs manifest.entries[{index}]'
        entry = direct_library._object(entry, where)
        unknown = set(entry) - ENTRY_KEYS
        if unknown:
            raise BatchError(f'{where}: unknown key(s) {sorted(unknown)}')
        identity = direct_library._string(entry.get('identity'), f'{where}.identity', pattern=direct_library.HEX64)
        if identity in seen_identity:
            raise BatchError(f'{where}: duplicate identity {identity}')
        seen_identity.add(identity)
        name = direct_library._string(entry.get('request'), f'{where}.request')
        rel = direct_library._relative_path(name, f'{where}.request')
        request_path = (base / rel).resolve()
        if base not in request_path.parents:
            raise BatchError(f'{where}.request escapes the manifest directory')
        if name in seen_request:
            raise BatchError(f'{where}: request {name!r} listed twice')
        seen_request.add(name)
        loaded.append({'identity': identity, 'request': request_path, 'request_name': rel})
    return {
        'direct_abi': direct_library._integer(doc.get('directABI'), 'programs manifest.directABI', 1),
        'translator_closure': direct_library._string(doc.get('translatorClosure'),
                                                     'programs manifest.translatorClosure',
                                                     pattern=direct_library.CLOSURE),
        'profile_hash': direct_library._content_root(doc.get('profileHash'),
                                                     'programs manifest.profileHash'),
        'source_parser_version': direct_library._integer(doc.get('sourceParserVersion'),
                                                         'programs manifest.sourceParserVersion', 1),
        'entries': loaded,
    }


def load_identity(path):
    doc = direct_library._object(_read_json(path, 'compiler identity'), 'compiler identity')
    if direct_library._string(doc.get('schema'), 'compiler identity.schema') != 's2a-direct-identity-v1':
        raise BatchError('compiler identity.schema is not s2a-direct-identity-v1')
    return {
        'closure': direct_library._string(doc.get('translatorClosure'),
                                          'compiler identity.translatorClosure',
                                          pattern=direct_library.CLOSURE),
        'sources_digest': doc.get('sourcesDigest'),
        'rule': doc.get('rule'),
    }


def cli_command(cli):
    cli = Path(cli)
    if cli.suffix == '.dll' or (cli.is_file() and cli.suffix != '.csproj'):
        return ['dotnet', str(cli)]
    project = cli if cli.suffix == '.csproj' else (cli / 'S2A.DirectCompiler.Cli.csproj')
    return ['dotnet', 'run', '-c', 'Release', '--project', str(project), '--']


def compile_one(command, entry, staging):
    index = entry['index']
    output = staging / 'results' / f'{index:04d}'
    if output.exists():
        raise BatchError(f'refusing to reuse an existing output {output}')
    proc = subprocess.run(command + ['compile', '--request', str(entry['request']),
                                     '--output', str(output)],
                          capture_output=True, text=True)
    if proc.returncode == 0 and (output / 'program.json').is_file():
        return {'index': index, 'status': 'compiled', 'result': output / 'program.json'}
    code, message = 'UNKNOWN', (proc.stderr or proc.stdout).strip()[:400]
    for line in reversed((proc.stderr or '').splitlines()):
        line = line.strip()
        if not line.startswith('{'):
            continue
        try:
            parsed = json.loads(line)
        except ValueError:
            continue
        error = parsed.get('error') if isinstance(parsed, dict) else None
        if isinstance(error, dict):
            code = str(error.get('code', code))
            message = str(error.get('message', message))[:400]
        break
    status = 'deferred' if code in DEFERRED_CODES else 'failed'
    return {'index': index, 'status': status, 'code': code, 'message': message}


def report_destination(path, out_dir, descriptor_path):
    """Reject predictable report collisions before compiling or publishing anything."""
    path = Path(path)
    # Check before resolving the leaf: dangling links are existing outputs too.
    if os.path.lexists(path):
        raise BatchError(f'report {path} already exists; refusing to overwrite it')
    parent = path.parent.resolve(strict=True)
    if not parent.is_dir():
        raise BatchError(f'report parent {parent} is not a directory')
    target = parent / path.name
    if (target == out_dir or out_dir in target.parents or target in out_dir.parents or
            target == descriptor_path or target in descriptor_path.parents):
        raise BatchError('report must be separate from the library and descriptor outputs')
    return target


def publish_report(report, path):
    """Publish complete report bytes without replacing an existing file or link.

    A temporary-file cleanup failure after the link is only a warning: the report
    has already been published. Never roll back or unlink public output paths.
    """
    raw = (json.dumps(report, ensure_ascii=False, indent=1) + '\n').encode('utf-8')
    fd, name = tempfile.mkstemp(prefix='.direct-batch-report-', dir=path.parent)
    published = False
    try:
        with os.fdopen(fd, 'wb') as stream:
            stream.write(raw)
            stream.flush()
            os.fsync(stream.fileno())
        os.link(name, path)
        published = True
    finally:
        try:
            os.unlink(name)
        except OSError as error:
            state = 'published' if published else 'not published'
            print(f'⚠ direct batch: report {state}; cannot remove temporary file {name}: {error}',
                  file=sys.stderr)


def build(programs_path, out_dir, descriptor_path, title_id, identity_path, cli, jobs,
          index_path=None, report_path=None, game_content_root=None, module_set_digest=None):
    programs = load_programs(programs_path)
    identity = load_identity(identity_path)
    if programs['translator_closure'] != identity['closure']:
        raise BatchError('programs manifest.translatorClosure is not this compiler build\'s closure '
                         f'({programs["translator_closure"]} != {identity["closure"]})')
    out_dir = Path(out_dir).resolve()
    descriptor_path = Path(descriptor_path).resolve()
    for path in (out_dir, descriptor_path):
        if os.path.lexists(path):
            raise BatchError(f'{path} already exists; a library is immutable, publish a new revision')
    if report_path is not None:
        report_path = report_destination(report_path, out_dir, descriptor_path)

    staging = Path(tempfile.mkdtemp(prefix='s2a-direct-batch-'))
    try:
        checked = []
        for index, entry in enumerate(programs['entries']):
            raw = entry['request'].read_bytes()
            try:
                request = direct_library.validate_request(raw, f'programs manifest.entries[{index}]')
            except direct_library.LibraryError as error:
                raise BatchError(f'{entry["request"]}: {error}')
            if request['_translatorClosure'] != programs['translator_closure']:
                raise BatchError(f'{entry["request"]}: request closure is not the manifest closure')
            if request['_directABI'] != programs['direct_abi']:
                raise BatchError(f'{entry["request"]}: request directABI is not the manifest directABI')
            if request['_profileHash'] != programs['profile_hash']:
                raise BatchError(f'{entry["request"]}: request profile is not the manifest profile')
            checked.append({'index': index, 'identity': entry['identity'],
                            'request': entry['request'], 'request_name': entry['request_name'],
                            'raw': raw})

        command = cli_command(cli)
        with ThreadPoolExecutor(max_workers=max(1, jobs)) as pool:
            outcomes = list(pool.map(lambda e: compile_one(command, e, staging), checked))

        by_index = {item['index']: item for item in outcomes}
        adopted = [e for e in checked if by_index[e['index']]['status'] == 'compiled']
        deferred = [item for item in outcomes if item['status'] == 'deferred']
        failed = [item for item in outcomes if item['status'] == 'failed']
        if failed:
            detail = '; '.join(f'#{item["index"]} {item["code"]}: {item["message"]}' for item in failed)
            raise BatchError('compilation failed for ' + str(len(failed)) + ' program(s): ' + detail)
        if not adopted:
            raise BatchError('no program compiled; refusing to publish an empty library')

        capture = staging / 'capture'
        (capture / 'requests').mkdir(parents=True)
        (capture / 'results').mkdir(parents=True)
        manifest = {'schema': direct_library.CAPTURE_SCHEMA,
                    'directABI': programs['direct_abi'],
                    'translatorClosure': programs['translator_closure'],
                    'sourceParserVersion': programs['source_parser_version'],
                    'profileHash': programs['profile_hash'],
                    'entries': []}
        for entry in adopted:
            name = f'{entry["index"]:04d}.json'
            shutil.copyfile(entry['request'], capture / 'requests' / name)
            shutil.copyfile(by_index[entry['index']]['result'], capture / 'results' / name)
            manifest['entries'].append({'identity': entry['identity'],
                                        'request': 'requests/' + name,
                                        'result': 'results/' + name})
        (capture / 'capture.v1.json').write_text(
            json.dumps(manifest, ensure_ascii=False, indent=1) + '\n', encoding='utf-8')

        rows = direct_library.read_index(index_path) if index_path else None
        summary = direct_library.build(str(capture), str(out_dir), str(descriptor_path), title_id,
                                       rows=rows, game_content_root=game_content_root,
                                       module_set_digest=module_set_digest)
        report = {'schema': 's2a-direct-batch-report-v1',
                  'translatorClosure': programs['translator_closure'],
                  'sourcesDigest': identity.get('sources_digest'),
                  'compiled': len(adopted), 'deferred': len(deferred), 'failed': 0,
                  'entries': [{'index': item['index'], 'status': item['status'],
                               'code': item.get('code')} for item in outcomes],
                  'library': summary}
        if report_path is not None:
            try:
                publish_report(report, report_path)
            except OSError as error:
                raise BatchError(f'report publication failed for {report_path}: {error}; '
                                 f'completed library retained at {out_dir}; '
                                 f'completed descriptor retained at {descriptor_path}; '
                                 'no output rollback was attempted') from error
        return report
    finally:
        shutil.rmtree(staging, ignore_errors=True)


def import_requests(capture_dir, out_dir):
    """Preserve device-named identities and exact request bytes; never guess facts.

    The filename identity is producer evidence, not a digest of JSON. This step
    validates transport/cohort consistency, not whether a device really observed it.
    programs.v1.json is written last as the completion marker of a new directory.
    """
    capture = Path(capture_dir).resolve(strict=True)
    output = Path(out_dir)
    if os.path.lexists(output):
        raise BatchError(f'{output} already exists')
    if not capture.is_dir():
        raise BatchError('capture is not a directory')
    entries, cohort, seen = [], None, set()
    for path in sorted(capture.iterdir()):
        if not path.name.endswith('.compile-request.json'):
            continue
        match = re.fullmatch(r'(.+)-([0-9a-f]{64})\.compile-request\.json', path.name)
        if not match:
            raise BatchError(f'malformed request filename: {path.name}')
        prefix, identity = match.groups()
        if identity in seen:
            raise BatchError(f'duplicate identity: {identity}')
        if path.is_symlink() or not path.is_file():
            raise BatchError(f'request is not a regular non-symlink file: {path.name}')
        try:
            fd = os.open(path, os.O_RDONLY | getattr(os, 'O_NOFOLLOW', 0) | getattr(os, 'O_NONBLOCK', 0))
            with os.fdopen(fd, 'rb') as stream:
                info = os.fstat(stream.fileno())
                if not stat.S_ISREG(info.st_mode) or info.st_size > direct_library.MAX_REQUEST:
                    raise BatchError(f'invalid request type/size: {path.name}')
                raw = stream.read(direct_library.MAX_REQUEST + 1)
        except OSError as error:
            raise BatchError(f'cannot read request {path.name}: {error}') from error
        if len(raw) > direct_library.MAX_REQUEST:
            raise BatchError(f'request too large: {path.name}')
        request = direct_library.validate_request(raw, path.name)
        if prefix != request['_requestId']:
            raise BatchError(f'filename prefix does not match requestId: {path.name}')
        fields = {key: request['_' + key] for key in
                  ('directABI', 'translatorClosure', 'profileHash', 'sourceParserVersion')}
        if cohort is not None and fields != cohort:
            raise BatchError(f'mixed request profile/closure/ABI/parser cohort: {path.name}')
        cohort = fields
        seen.add(identity)
        entries.append((identity, raw))
    if not entries:
        raise BatchError('capture contains no compile requests')
    entries.sort(key=lambda item: item[0])
    manifest = {'schema': PROGRAMS_SCHEMA, **cohort, 'entries': []}
    # Exclusive mkdir owns rollback; never delete or overwrite a pre-existing path.
    output.mkdir()
    try:
        (output / 'requests').mkdir()
        for index, (identity, raw) in enumerate(entries):
            name = f'requests/{index:04d}.json'
            with (output / name).open('xb') as stream:
                stream.write(raw)
            manifest['entries'].append({'identity': identity, 'request': name})
        with (output / 'programs.v1.json').open('x', encoding='utf-8') as stream:
            stream.write(json.dumps(manifest, ensure_ascii=False, indent=1) + '\n')
    except BaseException:
        shutil.rmtree(output)
        raise
    return manifest


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest='command', required=True)

    build_parser = commands.add_parser('build', help='compile a request set on the host and pack a library')
    build_parser.add_argument('--programs', required=True, help='programs.v1.json request manifest')
    build_parser.add_argument('--out', required=True, help='new library root (packed at ' + direct_library.DIRECT_PREFIX + ')')
    build_parser.add_argument('--descriptor', required=True, help='new graphics.v1.json (outside --out)')
    build_parser.add_argument('--title-id', required=True, help='16-hex application id')
    build_parser.add_argument('--identity', required=True, help='compiler identity JSON (cli identity)')
    build_parser.add_argument('--cli', default=str(DEFAULT_CLI),
                              help='compiler CLI project or dll (default: the repo one)')
    build_parser.add_argument('--jobs', type=int, default=os.cpu_count() or 1)
    build_parser.add_argument('--index', help='index.tsv of the pack that will carry the library')
    build_parser.add_argument('--game-content-root', help='sha256-<64> of the game content (checked against --index)')
    build_parser.add_argument('--module-set-digest', help='sha256-<64> of the module set (checked against --index)')
    build_parser.add_argument('--report', help='new JSON report outside the library; never overwrite; '
                              'report failure retains completed library and descriptor')

    import_parser = commands.add_parser('import-requests', help='device request dumps to programs.v1.json')
    import_parser.add_argument('--capture', required=True, help='directory of device-named compile requests')
    import_parser.add_argument('--out', required=True, help='new request-set directory, never a runtime library')

    verify_parser = commands.add_parser('verify', help='re-check a built library and descriptor')
    verify_parser.add_argument('--lib', required=True)
    verify_parser.add_argument('--descriptor', required=True)

    args = parser.parse_args(argv)
    try:
        if args.command == 'import-requests':
            manifest = import_requests(args.capture, args.out)
            print(f"requests: {len(manifest['entries'])} imported; no programs compiled")
            return 0
        if args.command == 'verify':
            direct_library.verify_library(args.lib, direct_library.load_descriptor(args.descriptor))
            print(f'direct batch: library ok ({args.lib})')
            return 0
        report = build(args.programs, args.out, args.descriptor, args.title_id, args.identity,
                       args.cli, args.jobs, args.index, args.report,
                       args.game_content_root, args.module_set_digest)
        print(f'programs: {report["compiled"]} compiled, {report["deferred"]} deferred, '
              f'{report["failed"]} failed')
        print(f'library: {args.out} -> {report["library"]["entries"]} program(s)')
        return 0
    except direct_library.LibraryError as error:
        print(f'🔴 direct batch: {error}', file=sys.stderr)
        return 1
    except (BatchError, OSError) as error:
        print(f'🔴 direct batch: {error}', file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
