#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""Read-only captured/replayed program comparison. See docs/direct-qa-compare.md.

No compiler, subprocess, network or library publication. Input identities are
producer assertions, NOT recomputed from stripped requests. Only fixed failure
codes, counts and hashed keys leave this tool; validation exception text may
contain shader bytes or filenames and must never be printed.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import stat
import sys

import direct_library as library

COHORT = ('directABI', 'translatorClosure', 'sourceParserVersion', 'profileHash')
MAX_TOTAL = 2 << 30
MAX_ENTRIES = 100000


class Rejected(Exception):
    def __init__(self, code):
        self.code = code


def require(ok, code):
    if not ok:
        raise Rejected(code)


class Reader:
    """Confined, bounded regular-file reads. The supplied root itself is trusted."""
    def __init__(self, root):
        self.root = Path(root)
        self.total = 0
        self.inodes = set()

    def read(self, name, limit):
        try:
            library._relative_path(name, 'input')
            fd = os.open(self.root, os.O_RDONLY | os.O_DIRECTORY)
            try:
                parts = name.split('/')
                for part in parts[:-1]:
                    child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
                    os.close(fd)
                    fd = child
                file_fd = os.open(parts[-1], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=fd)
                with os.fdopen(file_fd, 'rb') as stream:
                    info = os.fstat(stream.fileno())
                    require(stat.S_ISREG(info.st_mode) and info.st_size <= limit, 'READ')
                    inode = (info.st_dev, info.st_ino)
                    require(inode not in self.inodes, 'READ')
                    self.inodes.add(inode)
                    remaining = MAX_TOTAL - self.total
                    require(info.st_size <= remaining, 'BUDGET')
                    raw = stream.read(min(limit + 1, remaining))
                    self.total += len(raw)
                    require(len(raw) <= limit and len(raw) == info.st_size, 'READ')
                    return raw, inode
            finally:
                os.close(fd)
        except (OSError, ValueError, library.LibraryError):
            raise Rejected('READ') from None


def catalog(reader):
    try:
        doc = library._object(library.parse_json(
            reader.read('capture.v1.json', library.MAX_CAPTURE_MANIFEST)[0], 'manifest'), 'manifest')
        require(set(doc) == {'schema', 'entries', *COHORT}, 'MANIFEST')
        require(doc['schema'] == library.CAPTURE_SCHEMA, 'MANIFEST')
        library._integer(doc['directABI'], 'abi', 1)
        library._integer(doc['sourceParserVersion'], 'parser', 1)
        library._string(doc['translatorClosure'], 'closure', pattern=library.CLOSURE)
        library._content_root(doc['profileHash'], 'profile')
        entries = library._array(doc['entries'], 'entries')
        require(0 < len(entries) <= MAX_ENTRIES, 'MANIFEST')
        result, paths = {}, {'capture.v1.json'}
        for entry in entries:
            require(isinstance(entry, dict) and set(entry) == {'identity', 'request', 'result'}, 'MANIFEST')
            key = library._string(entry['identity'], 'identity', pattern=library.HEX64)
            require(key not in result, 'MANIFEST')
            for field in ('request', 'result'):
                path = library._relative_path(entry[field], 'path')
                require(path not in paths, 'MANIFEST')
                paths.add(path)
            result[key] = entry
        # Exact file inventory rejects accidental leftovers and unpaired outputs.
        # Walk without following links; never include the paths in the report.
        present = set()
        def walk_error(error):
            raise Rejected('FILE_SET')
        for base, dirs, files in os.walk(reader.root, followlinks=False, onerror=walk_error):
            for name in dirs + files:
                path = Path(base) / name
                require(not path.is_symlink(), 'FILE_SET')
            present.update((Path(base) / name).relative_to(reader.root).as_posix() for name in files)
        require(present == paths, 'FILE_SET')
        return {key: doc[key] for key in COHORT}, result
    except (OSError, ValueError, TypeError, KeyError, library.LibraryError):
        raise Rejected('MANIFEST') from None


def compiler_closure(path):
    path = Path(path)
    reader = Reader(path.parent)
    try:
        doc = library._object(library.parse_json(reader.read(path.name, 1 << 20)[0], 'compiler'), 'compiler')
        require(doc.get('schema') == 's2a-direct-identity-v1', 'COMPILER_IDENTITY')
        return library._string(doc.get('translatorClosure'), 'closure', pattern=library.CLOSURE)
    except (ValueError, TypeError, KeyError, library.LibraryError):
        raise Rejected('COMPILER_IDENTITY') from None


def pair(reader, entry, cohort):
    request_raw, request_inode = reader.read(entry['request'], library.MAX_REQUEST)
    result_raw, result_inode = reader.read(entry['result'], library.PCACHE_MAX_PAYLOAD)
    try:
        request = library.validate_request(request_raw, 'request')
    except (ValueError, TypeError, KeyError, RecursionError, library.LibraryError):
        raise Rejected('REQUEST') from None
    require({key: request['_' + key] for key in COHORT} == cohort, 'COHORT')
    try:
        result = library.validate_result(result_raw, 'result', request=request)
    except (ValueError, TypeError, KeyError, RecursionError, library.LibraryError):
        raise Rejected('RESULT') from None
    transport = result['transport']
    for name in ('session', 'generation'):
        require(type(transport.get(name)) is int and transport[name] == request[name], 'TRANSPORT')
    require(set(transport) == {'session', 'generation', 'requestId'}, 'TRANSPORT')
    # Compare the entire enabled profile, not only the caller-supplied hash.
    profile = json.dumps(request['profile'], sort_keys=True, separators=(',', ':'), allow_nan=False)
    return request_raw, result_raw, profile, {request_inode, result_inode}


def compare(capture, replay, identity, scope):
    report = {'schema': 's2a-direct-qa-summary-v1', 'scope': scope,
              'identityEvidence': 'producer-supplied-not-recomputed',
              'keys': 0, 'passed': 0, 'failed': 0, 'errors': [], 'results': []}
    try:
        require(not os.path.samefile(capture, replay), 'SAME_INPUT')
        left, right = Reader(capture), Reader(replay)
        lc, le = catalog(left)
        rc, re = catalog(right)
        require(not (left.inodes & right.inodes), 'SAME_INPUT')
        require(lc == rc and lc['translatorClosure'] == compiler_closure(identity), 'COHORT')
        keys = sorted(set(le) | set(re))
        report['keys'] = len(keys)
        profile = None
        for key in keys:
            item = {'keyHash': hashlib.sha256(bytes.fromhex(key)).hexdigest(), 'status': 'pass'}
            try:
                require(key in le and key in re, 'KEY_SET')
                lrequest, lpayload, lprofile, linodes = pair(left, le[key], lc)
                rrequest, rpayload, rprofile, rinodes = pair(right, re[key], rc)
                require(lprofile == rprofile and (profile is None or profile == lprofile), 'PROFILE_CONTENT')
                profile = lprofile
                # Charge only the current key, but retain detection of links
                # to a different key already read on the opposite side.
                require(not ((linodes & right.inodes) or (rinodes & left.inodes)), 'SAME_INPUT')
                require(lrequest == rrequest, 'REQUEST_BYTES')
                require(lpayload == rpayload, 'PAYLOAD')
                report['passed'] += 1
            except Rejected as error:
                item.update(status='fail', code=error.code)
                report['failed'] += 1
                if error.code == 'BUDGET':
                    report['errors'].append('BUDGET')
                    report['results'].append(item)
                    break
            report['results'].append(item)
    except Rejected as error:
        report['errors'].append(error.code)
    except Exception:
        # No exception text or traceback may expose private input.
        report['errors'].append('INPUT')
    report['ok'] = not report['errors'] and report['failed'] == 0 and report['passed'] > 0
    return report


class Parser(argparse.ArgumentParser):
    def error(self, message):
        # argparse normally echoes offending argument values.
        self.exit(2, 'invalid arguments; use --help\n')


def main(argv=None):
    parser = Parser(description=__doc__)
    parser.add_argument('--capture', required=True)
    parser.add_argument('--replay', required=True)
    parser.add_argument('--compiler-identity', required=True)
    parser.add_argument('--scope', required=True, choices=('public-synthetic', 'qa-internal'))
    args = parser.parse_args(argv)
    report = compare(args.capture, args.replay, args.compiler_identity, args.scope)
    print(json.dumps(report, sort_keys=True, separators=(',', ':')))
    return 0 if report['ok'] else 1


if __name__ == '__main__':
    sys.exit(main())
