#!/usr/bin/env python3
"""Identify a Gitiles libavc tar by its files, modes and paths, not tar metadata."""
import hashlib
import json
from pathlib import PurePosixPath
import sys
import tarfile
import zlib


def content_digest(archive):
    records = []
    names = set()
    total = 0
    with tarfile.open(archive, mode="r:gz") as tar:
        for member in tar:
            name = member.name.rstrip("/")
            path = PurePosixPath(name)
            if (not name or name.startswith("/") or "\\" in name or
                    any(part in ("", ".", "..") for part in name.split("/")) or
                    str(path) != name or name in names):
                raise ValueError("invalid or duplicate archive path: " + repr(name))
            names.add(name)
            if len(names) > 20000:
                raise ValueError("archive has too many entries")
            if member.mode & 0o7000 or member.sparse is not None:
                raise ValueError("unsupported mode or sparse entry: " + name)
            if member.isdir():
                records.append([name, "dir", member.mode & 0o777])
            elif member.isfile():
                total += member.size
                if member.size > 128 * 1024 * 1024 or total > 512 * 1024 * 1024:
                    raise ValueError("archive contents exceed size limit")
                payload = tar.extractfile(member)
                if payload is None:
                    raise ValueError("missing file payload: " + name)
                digest = hashlib.sha256()
                for chunk in iter(lambda: payload.read(1024 * 1024), b""):
                    digest.update(chunk)
                records.append([name, "file", member.mode & 0o777, member.size, digest.hexdigest()])
            else:
                raise ValueError("unsupported archive entry: " + name)
    records.sort(key=lambda row: row[0].encode("utf-8"))
    data = json.dumps(records, ensure_ascii=True, separators=(",", ":")).encode("ascii")
    return hashlib.sha256(data).hexdigest()


def verify(archive, expected):
    actual = content_digest(archive)
    if actual != expected:
        raise ValueError("content SHA-256 mismatch: expected %s, got %s" % (expected, actual))
    return actual


if __name__ == "__main__":
    try:
        if len(sys.argv) != 3:
            raise ValueError("usage: avc_source.py ARCHIVE CONTENT_SHA256")
        verify(sys.argv[1], sys.argv[2])
    except (EOFError, OSError, ValueError, tarfile.TarError, zlib.error) as error:
        print("libavc source FAILED: %s" % error, file=sys.stderr)
        sys.exit(1)
