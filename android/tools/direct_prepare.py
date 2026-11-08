#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""W2 extraction audit and optional enumerated compute REQUEST candidates.

Reads extract.sh's pkg/ and split/ outputs without executing extractors, loading
private captures, or accepting shader_facts as binding-state evidence. Without
target options, all stages remain deferred (audit-only compatibility).
With --profile/--identity/--candidate-dir, headerless CS inputs may produce
both alignment REQUEST variants, with remaining assumptions in the local report. No proven runtime identity,
descriptor or library is produced. --identity-encoder additionally produces a
programs manifest using the native encoder and explicitly recorded assumptions. Exit 0 means candidates
generated, NOT compiled/adopted; 2 means report only; 1 means invalid input/output.
Reports are local provenance diagnostics, not a new compiler/cache artifact format.
Graphics reports describe native source windows and field-level missing facts only;
source labels and available C1 bytes do not prove program membership or draw state.
"""
import argparse
import base64
import hashlib
import json
import math
import os
from pathlib import Path, PurePosixPath
import re
import stat
import struct
import subprocess
import sys
import tempfile

import direct_library

LIMIT = 64 << 20
TOTAL_LIMIT = 256 << 20
KEY = re.compile(r'[0-9a-f]{16}\Z')
FACT_DEPTH = 64   # 事实 JSON 最深嵌套层数：自己判、不靠解析器递归上限（11-02 合入线：Python 3.14 的 C 版 json 解 2 万层不再抛 RecursionError，判据随解释器漂）
STAGES = {'vertex', 'pixel', 'compute', 'hull', 'domain', 'geometry'}


class PrepareError(ValueError):
    pass


def require(condition, message):
    if not condition:
        raise PrepareError(message)


class Inputs:
    """Read each confined regular file once; no symlink component is followed.

    Not a multi-file filesystem snapshot: caller must supply a completed immutable
    extraction. In-memory bytes prevent subsequent producer reads seeing changes.
    """
    def __init__(self, root):
        self.root = Path(root).resolve(strict=True)
        self.cache = {}
        self.total = 0

    def read(self, name):
        require(isinstance(name, str) and name and '\\' not in name and '\0' not in name,
                'invalid input path')
        parts = name.split('/')
        require(not PurePosixPath(name).is_absolute() and all(p not in ('', '.', '..') for p in parts),
                'input path escapes root or is not canonical')
        if name in self.cache:
            return self.cache[name]
        fd = os.open(self.root, os.O_RDONLY | os.O_DIRECTORY)
        try:
            for part in parts[:-1]:
                nxt = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
                os.close(fd)
                fd = nxt
            file_fd = os.open(parts[-1], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=fd)
            with os.fdopen(file_fd, 'rb') as stream:
                info = os.fstat(stream.fileno())
                require(stat.S_ISREG(info.st_mode), 'input is not a regular file')
                require(info.st_size <= LIMIT, 'input exceeds per-file limit')
                raw = stream.read(LIMIT + 1)
                require(len(raw) <= LIMIT, 'input exceeds per-file limit')
        finally:
            os.close(fd)
        self.total += len(raw)
        require(self.total <= TOTAL_LIMIT, 'extraction exceeds read budget')
        self.cache[name] = raw
        return raw


def lines(raw):
    for number, line in enumerate(raw.decode('utf-8').splitlines(), 1):
        if line and not line.startswith('#'):
            yield number, line.split('\t')


def records(raw):
    """Read the existing BTCDBTCD layout; validate boundaries, never split blindly."""
    result, offset = [], 0
    while offset < len(raw):
        require(len(raw) - offset >= 0x38 and raw[offset:offset + 8] == b'BTCDBTCD',
                'invalid package record header')
        ctl_n, code_n = struct.unpack_from('<II', raw, offset + 0x28)
        require(0 < code_n <= 16 << 20 and 0x24 <= ctl_n <= LIMIT, 'invalid source lengths')
        end = offset + 0x38 + code_n + ctl_n
        require(end <= len(raw), 'truncated package record')
        code = raw[offset + 0x38:offset + 0x38 + code_n]
        control = raw[offset + 0x38 + code_n:end]
        require(b'BTCDBTCD' not in code + control, 'ambiguous embedded package separator')
        result.append((code, control))
        offset = end
    require(result, 'empty package')
    return result


def extraction_key(code, control):
    # Existing extract/merge index rule ONLY; not runtime canonical identity.
    size = struct.unpack_from('<I', control, 0x20)[0]
    size = size if 0x760 <= size < 0x880 else 0x880
    require(len(control) >= size, 'control shorter than extraction key range')
    return hashlib.sha256(control[:size] + code).hexdigest()[:16]


def unique_object(pairs):
    value = {}
    for key, item in pairs:
        require(key not in value, 'duplicate JSON object key')
        value[key] = item
    return value


def json_depth(text):   # 字符串外 [ / { 的最深层数（只数结构，不解析）
    depth = top = 0; in_str = esc = False
    for ch in text:
        if in_str:
            if esc: esc = False
            elif ch == '\\': esc = True
            elif ch == '"': in_str = False
        elif ch == '"': in_str = True
        elif ch in '[{':
            depth += 1; top = max(top, depth)
        elif ch in ']}': depth -= 1
    return top


def finite_float(token):
    # parse_constant only handles NaN/Infinity tokens, not exponent overflow.
    value = float(token)
    require(math.isfinite(value), 'nonfinite JSON')
    return value


def load_target(profile_path, identity_path):
    """Read existing target formats, not a new metadata contract or runtime proof."""
    def read(path):
        p = Path(path)
        raw = Inputs(p.parent).read(p.name)
        return json.loads(raw.decode('utf-8'), object_pairs_hook=unique_object,
                          parse_float=finite_float,
                          parse_constant=lambda _: (_ for _ in ()).throw(PrepareError('nonfinite JSON')))
    profile, identity = read(profile_path), read(identity_path)
    require(isinstance(profile, dict) and isinstance(identity, dict), 'target must be JSON objects')
    require(profile.get('schema') == 's2a-direct-profile-v1', 'invalid profile schema')
    require(identity.get('schema') == 's2a-direct-identity-v1', 'invalid compiler identity schema')
    require(isinstance(profile.get('translatorClosure'), str) and
            re.fullmatch(r's2a-dc1-[0-9a-f]{64}', profile['translatorClosure']), 'invalid target closure')
    require(type(profile.get('directABI')) is int and profile['directABI'] >= 1 and
            type(identity.get('directABI')) is int, 'invalid target directABI')
    require(profile.get('translatorClosure') == identity.get('translatorClosure'), 'target closure mismatch')
    require(profile.get('directABI') == identity.get('directABI'), 'target directABI mismatch')
    require(profile.get('runtimeCompilerABI') == identity.get('compilerABI') == 's2a-direct-compile-v1',
            'target compiler ABI mismatch')
    support = profile.get('supportLayout')
    require(isinstance(support, dict) and isinstance(identity.get('supportLayout'), str) and
            re.fullmatch(r'sha256-[0-9a-f]{64}', identity['supportLayout']) and
            support.get('hash') == identity['supportLayout'], 'target supportLayout mismatch')
    return profile


def compute_candidate(key, code, control, profile, unaligned):
    """Produce one explicit alignment variant, never proof of runtime adoption.

    Invalid/unknown source layouts stay deferred. Successful generation is not a
    claim that the translator accepts the code or that any device can adopt it.
    """
    require(type(unaligned) is bool, 'alignment variant must be boolean')
    require(0 < len(code) <= 16 << 20 and len(code) % 4 == 0, 'unsupported CS code length')
    require(0x75c <= len(control) <= 64 << 10, 'unsupported CS control length')
    # A headerless CS is the minimal supported input. Other extractors use a
    # 0x100-byte CS prefix; do not mistake that prefix for instructions.
    require(code[:4] not in (bytes.fromhex('79563412'), bytes.fromhex('78563412')),
            'prefixed CS code requires an explicit source-layout adapter')
    require(control[:4] == bytes.fromhex('34127698'), 'invalid extraction control magic')
    require(struct.unpack_from('<I', control, 0x704)[0] == len(code),
            'control code-area length mismatch')
    x, y, z, shared, local_memory = struct.unpack_from('<5I', control, 0x748)
    require(local_memory <= 0x100000, 'CS local memory outside contract')
    require(x > 0 and y > 0 and z > 0 and x * y * z <= 1024 and shared <= 0x10000,
            'invalid CS local/shared control facts')
    begin, end = struct.unpack_from('<II', control, 0x700)
    joined = code + control
    require(begin <= end <= len(joined) and end - begin <= 64 << 10, 'invalid C1 range')
    c1 = joined[begin:end]
    b64 = lambda raw: base64.b64encode(raw).decode('ascii')
    request = {'schema': 's2a-direct-compile-v1', 'session': 1, 'generation': 1,
               'requestId': 'offline-candidate-' + key + ('-unaligned-true' if unaligned else '-unaligned-false'), 'directABI': profile['directABI'],
               'translatorClosure': profile['translatorClosure'],
               'runtimeCompilerABI': profile['runtimeCompilerABI'], 'sourceParserVersion': 1,
               'profile': profile, 'program': {
                   'kind': 'compute', 'stages': [{'stage': 'cs', 'code': b64(code),
                       'control': b64(control), 'c1': b64(c1), 'constantBufferUse': 0}],
                   'computeState': {'localSize': [x, y, z], 'sharedMemoryBytes': (shared + 15) // 16 * 16,
                                    'localMemoryBytes': local_memory, 'hasUnalignedStorageBuffer': unaligned},
                   'textures': [], 'samplerArrayLength': 1, 'textureArrayLength': 1,
                   'transformFeedbackEnabled': False}}
    raw = (json.dumps(request, ensure_ascii=False, separators=(',', ':')) + '\n').encode()
    # Reuse the existing request structural validator. Full translation and its
    # dependencies remain pending; this checker is not the C# semantic validator.
    direct_library.validate_request(raw, 'offline conservative candidate')
    facts = {'computeState.localMemoryBytes': 'control+0x758:u32le',
             'computeState.localSize': 'control+0x748:3xu32le',
             'computeState.sharedMemoryBytes': 'control+0x754:u32le; align16',
             'program.stages[].c1': 'control+0x700/+0x704 range in code||control',
             'program.stages[].code': 'headerless extraction CS bytes',
             'program.stages[].control': 'extraction control bytes'}
    assumptions = {
        'constantBufferUse': '0; conservative, not proof of no cbuf; dynamic cbuf queries require review',
        'textures': '[]; no captured texture facts, NOT proof of resource-free code; compiler may reject',
        'samplerArrayLength': '1; offline candidate placeholder, NOT actual pool capacity',
        'textureArrayLength': '1; offline candidate placeholder, NOT actual pool capacity',
        'transformFeedbackEnabled': 'false; compute-only candidate',
        'session/generation': '1/1; offline transport identifiers, NOT a device session'}
    return raw, facts, assumptions



# Native field names, not an encoder layout. Values are deliberately explicit in
# provenance; no claim that this unused graphics state came from a compute draw.
GRAPHICS_INTS = """rt_count has_tess_mode constant_buffer_use_overflow
has_alpha_to_coverage alpha_to_coverage_enable alpha_to_coverage_dither
has_alpha_test has_blend dual_source_blend has_depth_mode depth_mode has_y_negate
y_negate has_origin origin_upper_left has_halve_primitive_id halve_primitive_id
has_cb_draw_params cb_draw_params has_point_size program_point_size_enable
has_alpha_test_reference has_unaligned_ssbo unaligned_ssbo has_geometry_shader
host_supports_quads early_z_force viewport_transform_disable""".split()


def candidate_identity(raw, encoder):
    """Pass explicit candidate facts to the linked native canonical encoder.

    Source window follows the existing NVN capture rule; no Python canonical
    encoding, request hash identity, or runtime matching policy is introduced.
    """
    request = json.loads(raw)
    program = request['program']
    stage = program['stages'][0]
    code, control = (base64.b64decode(stage[k], validate=True) for k in ('code', 'control'))
    own = struct.unpack_from('<I', control, 0x20)[0]
    own = own if 0x760 <= own < 0x880 else 0x880
    require(len(control) >= own, 'missing complete source control')
    # Uncaptured tails are excluded from runtime source identity. Reject them
    # here rather than assigning the same identity to different compiler inputs.
    require(len(control) == own, 'candidate identity requires exact captured control length')
    source_sha = hashlib.sha256(control + code).hexdigest()
    profile_bytes = json.dumps(request['profile'], ensure_ascii=False, separators=(',', ':')).encode()
    gfx = dict.fromkeys(GRAPHICS_INTS, 0)
    gfx.update(topology=None, alpha_test_compare=None, tess_mode=0, point_size=0,
               alpha_test_reference=0, fragment_output_types=[None] * 8,
               attribute_types=[None] * 32)
    facts = {'direct_abi': request['directABI'], 'translator_closure': request['translatorClosure'],
             'profile_sha': hashlib.sha256(profile_bytes).hexdigest(), 'stage_mask': 32,
             'source_present': 1, 'keys': [source_sha[:16]] + ['0' * 16] * 5,
             'stages': [{'source_sha': source_sha,
                 'code_bytes': len(code), 'control_bytes': len(control)}],
             'ubo_use': [0, 0, 0, 0, 0, stage['constantBufferUse']],
             'texture_array_length': program['textureArrayLength'],
             'sampler_array_length': program['samplerArrayLength'],
             'transform_feedback_enabled': int(program['transformFeedbackEnabled']),
             'gfx': gfx, 'textures': program['textures'],
             'compute_has_unaligned_ssbo': 1,
             'compute_unaligned_ssbo': int(program['computeState']['hasUnalignedStorageBuffer'])}
    result = subprocess.run([str(Path(encoder).resolve(strict=True))],
                            input=json.dumps(facts).encode(), capture_output=True, timeout=30)
    require(result.returncode == 0, 'native candidate identity rejected: ' +
            result.stderr.decode('utf-8', errors='replace')[:512])
    encoded = json.loads(result.stdout, object_pairs_hook=unique_object)
    require(isinstance(encoded, dict) and set(encoded) == {'identity', 'canonical'} and
            isinstance(encoded['identity'], str) and re.fullmatch(r'[0-9a-f]{64}', encoded['identity']) and
            isinstance(encoded['canonical'], str) and re.fullmatch(r'[0-9a-f]{2,8192}', encoded['canonical']) and
            len(encoded['canonical']) % 2 == 0, 'invalid native encoder output')
    require(hashlib.sha256(bytes.fromhex(encoded['canonical'])).hexdigest() == encoded['identity'],
            'native encoder output digest mismatch')
    return encoded, facts


# DirectGraphicsFacts.Keys, not defaults or a second identity encoder. These
# draw facts have no archive source; keep each unknown field visible in reports.
GRAPHICS_STATE_FIELDS = """earlyZForce topology tessCw tessPatchType tessSpacing
alphaToCoverageEnable alphaToCoverageDitherEnable viewportTransformDisable depthMode
programPointSizeEnable pointSize alphaTestCompare alphaTestReference attributeTypes
hasConstantBufferDrawParameters fragmentOutputTypes dualSourceBlendEnable
yNegateEnabled originUpperLeft halvePrimitiveId hasUnalignedStorageBuffer""".split()


def graphics_source_window(stage, code, control):
    """Describe source slices only; do not invent draw facts or runtime identity.

    Match the existing nvn_vk_draw.c header removal and source_store.c C1 range.
    A raw extraction may retain a control tail that NVN capture never includes.
    Keep raw hashes above this preview; never use the transformed code as a key.
    """
    own = struct.unpack_from('<I', control, 0x20)[0]
    own = own if 0x760 <= own < 0x880 else 0x880
    captured = control[:own]  # extraction_key already required the complete window
    offset = 0x30 if len(code) > 0x30 and code[:4] == bytes.fromhex('78563412') else 0
    begin, end = struct.unpack_from('<II', captured, 0x700)
    c1 = {'status': 'unavailable', 'range': [begin, end]}
    if begin >= end:
        c1['reason'] = 'empty-or-reversed'
    elif end > len(code) + len(captured):
        c1['reason'] = 'outside-captured-source'
    elif end - begin > 64 << 10:
        c1['reason'] = 'exceeds-64KiB'
    else:
        # Offsets are relative to raw code BEFORE the 0x30 header is removed.
        raw = code[begin:min(end, len(code))] if begin < len(code) else b''
        if end > len(code):
            raw += captured[max(0, begin - len(code)):end - len(code)]
        c1.update(status='available', bytes=len(raw), sha256=hashlib.sha256(raw).hexdigest())
    return {'scope': 'static-source-window; not runtime identity or capture proof',
            'stage': {'vertex': 'vs', 'pixel': 'fs'}[stage],
            'code': {'offset': offset, 'bytes': len(code) - offset,
                     'sha256': hashlib.sha256(code[offset:]).hexdigest()},
            'control': {'bytes': len(captured), 'uncapturedTailBytes': len(control) - len(captured),
                        'sha256': hashlib.sha256(captured).hexdigest()},
            'c1': c1}


def ingest(root, target=None, candidates=None, encoder=None):
    inputs = Inputs(root)
    require(inputs.read('ok').strip(), 'missing extraction completion marker')
    packages, stages, locations = {}, {}, set()
    snapshots = {}
    for number, row in lines(inputs.read('split/shader_map.tsv')):
        if row == ['package', 'index', 'stage', 'dm_ctl_sha16', 'source']:
            continue
        require(len(row) == 5, f'map line {number}: expected five columns')
        package, index, stage, key, source = row
        require(index.isascii() and index.isdecimal(), f'map line {number}: invalid index')
        index = int(index)
        require(stage in STAGES and KEY.fullmatch(key) and source, f'map line {number}: invalid stage/key/source')
        require((package, index) not in locations and key not in stages, 'duplicate source row/key')
        locations.add((package, index))
        if package not in packages:
            packages[package] = records(inputs.read('pkg/' + package))
        require(index < len(packages[package]), 'package index out of range')
        code, control = packages[package][index]
        require(extraction_key(code, control) == key, 'extraction key mismatch')
        if target is not None and stage == 'compute':
            snapshots[key] = (code, control)
        stages[key] = {'scope': 'raw-extraction', 'stage': stage, 'package': package, 'index': index,
                       'sourceLabel': source,
                       'codeBytes': len(code), 'controlBytes': len(control),
                       'codeSha256': hashlib.sha256(code).hexdigest(),
                       'controlSha256': hashlib.sha256(control).hexdigest()}
        if stage in ('vertex', 'pixel'):
            stages[key]['requestSource'] = graphics_source_window(stage, code, control)
    require(stages, 'empty shader map')
    pairs = set()
    for _, row in lines(inputs.read('split/shader_pairs.tsv')):
        require(len(row) == 2 and all(KEY.fullmatch(k) for k in row), 'invalid pair row')
        a, b = row
        require(a in stages and b in stages, 'pair references unknown stage')
        require(stages[a]['stage'] == 'vertex' and stages[b]['stage'] == 'pixel', 'pair has wrong stages')
        require((a, b) not in pairs, 'duplicate pair')
        pairs.add((a, b))
    facts = set()
    for _, row in lines(inputs.read('split/shader_facts.tsv')):
        require(len(row) == 2 and KEY.fullmatch(row[0]), 'invalid fact row')
        key, value = row
        require(key in stages and key not in facts, 'unknown or duplicate fact key')
        require(json_depth(value) <= FACT_DEPTH, 'fact JSON nesting exceeds parser limit')
        try:
            parsed = json.loads(value, object_pairs_hook=unique_object, parse_float=finite_float,
                                parse_constant=lambda _: (_ for _ in ()).throw(PrepareError('nonfinite JSON')))
        except RecursionError as error:
            raise PrepareError('fact JSON nesting exceeds parser limit') from error
        require(isinstance(parsed, dict), 'fact must be an object')
        facts.add(key)
    entries = []
    for key, source in sorted(stages.items()):
        missing = ['programMembership', 'constantBufferUse', 'textureArrayLength',
                   'samplerArrayLength', 'textures', 'transformFeedbackEnabled']
        if target is None:
            missing.extend(('targetProfile', 'compilerIdentity'))
        if source['stage'] == 'compute':
            missing.append('computeState.localMemoryBytes')
        else:
            missing.extend('graphicsState.' + field for field in GRAPHICS_STATE_FIELDS)
        entry = {'extractKey': key, 'source': source, 'status': 'deferred',
                 'missing': missing, 'factsRequireProvenance': key in facts}
        if source['stage'] != 'compute':
            entry['conditionalMissing'] = {'textureBufferLengths':
                'required only for slots queried by translation; no static source'}
        if target is not None and key in snapshots:
            try:
                variants = [(unaligned, *compute_candidate(key, *snapshots[key], target, unaligned))
                            for unaligned in (False, True)]
            except PrepareError as error:
                entry['candidateDeferredReason'] = str(error)
            else:
                for unaligned, raw, static, assumptions in variants:
                    variant = dict(entry)
                    name = key + ('.unaligned-true' if unaligned else '.unaligned-false') + '.request.json'
                    encoded, identity_facts = candidate_identity(raw, encoder) if encoder else (None, None)
                    candidates.append((name, raw))
                    variant.update(status='enumerated-candidate', missing=[], candidateRequest=name,
                                 requestSha256=hashlib.sha256(raw).hexdigest(), staticSources=static,
                                 assumptions=assumptions,
                                 enumeratedFacts={'computeState.hasUnalignedStorageBuffer': unaligned},
                                 enumerationScope='pack-time exhaustive enumeration',
                                 compilerValidation='pending',
                                 runtimeIdentityProven=False, runtimeAdoption='not-validated')
                    if encoded is not None:
                        variant.update(identity=encoded['identity'], canonical=encoded['canonical'],
                                     candidateIdentityFacts=identity_facts,
                                     identityScope='candidate assumptions only; no compute runtime registration')
                        variant['assumptions']['identity.keys[1:6]'] = 'zero inactive packed-key slots; explicit candidate assumption'
                        variant['assumptions']['identity.gfx'] = 'explicit zero/null fields; unused compute graphics state, not observed'
                        variant['assumptions']['identity.profile_sha'] = 'SHA256 of compact REQUEST profile JSON; runtime must use identical bytes'
                    entries.append(variant)
                continue
        entries.append(entry)
    count = len(candidates) if candidates is not None else 0
    return {'status': 'enumerated-candidates' if count else 'no-compilable-input',
            'requests': count, 'deferred': len(entries) - count,
            'candidatePairs': len(pairs), 'provenPairs': 0, 'entries': entries}


def publish_bytes(raw, path, input_root):
    path = Path(path)
    parent = path.parent.resolve(strict=True)
    root = Path(input_root).resolve(strict=True)
    require(parent != root and root not in parent.parents, 'report must be outside extraction')
    target = parent / path.name
    require(not os.path.lexists(target), 'report already exists')
    fd, name = tempfile.mkstemp(prefix='.direct-prepare-', dir=parent)
    try:
        with os.fdopen(fd, 'wb') as stream:
            stream.write(raw)
            stream.flush()
            os.fsync(stream.fileno())
        os.link(name, target)  # Atomic no-clobber publication; existing revisions survive.
    finally:
        os.unlink(name)


def publish_report(report, path, input_root):
    raw = (json.dumps(report, sort_keys=True, ensure_ascii=False, indent=1) + '\n').encode()
    publish_bytes(raw, path, input_root)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--extract-root', required=True)
    parser.add_argument('--report', required=True)
    parser.add_argument('--profile', help='existing effective target profile JSON')
    parser.add_argument('--identity', help='existing CLI identity JSON for that profile')
    parser.add_argument('--identity-encoder', help='built native direct_identity_host executable; emit programs.v1.json')
    parser.add_argument('--candidate-dir', help='new local REQUEST directory; never a runtime library')
    args = parser.parse_args(argv)
    try:
        options = (args.profile, args.identity, args.candidate_dir)
        require(all(options) or not any(options), 'candidate options must be supplied together')
        require(not args.identity_encoder or all(options), 'identity encoder requires candidate options')
        target = load_target(args.profile, args.identity) if all(options) else None
        candidates = []
        report = ingest(args.extract_root, target, candidates, args.identity_encoder)
        created, written = None, []
        try:
            # Report is the completion marker. Never expose it before all REQUEST
            # files are durably published. No-clobber applies to both outputs.
            require(not os.path.lexists(args.report), 'report already exists')
            if candidates:
                output = Path(args.candidate_dir)
                output = output.parent.resolve(strict=True) / output.name
                root = Path(args.extract_root).resolve(strict=True)
                require(output != root and root not in output.parents, 'candidate directory must be outside extraction')
                require(output.name not in ('', '.', '..'), 'invalid candidate directory')
                output.mkdir()  # Exclusive creation; existing directories/symlinks are never reused.
                created = output
                for name, raw in candidates:
                    publish_bytes(raw, output / name, args.extract_root)
                    written.append(output / name)
                if args.identity_encoder:
                    manifest = {'schema': 's2a-direct-programs-v1', 'directABI': target['directABI'],
                                'translatorClosure': target['translatorClosure'],
                                'profileHash': target['profileHash'], 'sourceParserVersion': 1,
                                'entries': [{'identity': e['identity'], 'request': e['candidateRequest']}
                                            for e in report['entries'] if 'identity' in e]}
                    publish_bytes((json.dumps(manifest, sort_keys=True) + '\n').encode(),
                                  output / 'programs.v1.json', args.extract_root)
                    written.append(output / 'programs.v1.json')
            publish_report(report, args.report, args.extract_root)
        except BaseException:
            for path in written:
                path.unlink()
            if created is not None:
                created.rmdir()
            raise
        print(f'{report["requests"]} enumerated candidates (compiler pending, not runtime-adopted); '
              f'{report["deferred"]} stages deferred')
        return 0 if candidates else 2
    except (PrepareError, OSError, UnicodeError, ValueError, RecursionError, direct_library.LibraryError, subprocess.TimeoutExpired) as error:
        print(json.dumps({'error': 'INVALID_INPUT_OR_REPORT', 'message': str(error)}), file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
