#!/usr/bin/env python3
"""Explicit, network-enabled dependency preparation; never called by tests/builds."""
import argparse
import hashlib
import io
import json
from pathlib import Path
import tarfile
import urllib.request

SOURCES = {
    'capstone': ('5.0.7', '796bdd69b05fa124fc2aa2e74b9a0b3d4c4e7f3e02add5e583cf2f3bca282ede'),
    'lz4': ('4.4.5', '5f0b9e53c1e82e88c10d7c180069363980136b9d7a8306c4dca4f760d60c39f0'),
}

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    args = parser.parse_args()
    args.directory.mkdir(parents=True, exist_ok=True)
    for name, (version, digest) in SOURCES.items():
        archive = args.directory / f'{name}-{version}.tar.gz'
        if not archive.exists():
            with urllib.request.urlopen(f'https://pypi.org/pypi/{name}/{version}/json', timeout=60) as response:
                metadata = json.load(response)
            source = next(item for item in metadata['urls'] if item['packagetype'] == 'sdist')
            if source['digests']['sha256'] != digest:
                raise SystemExit(f'{name}: PyPI archive digest changed')
            with urllib.request.urlopen(source['url'], timeout=60) as response:
                data = response.read()
            if hashlib.sha256(data).hexdigest() != digest:
                raise SystemExit(f'{name}: download checksum mismatch')
            archive.write_bytes(data)
        data = archive.read_bytes()
        if hashlib.sha256(data).hexdigest() != digest:
            raise SystemExit(f'{name}: cached archive checksum mismatch')
        # Python 3.12 data filter blocks traversal and unsafe links. Refuse to
        # overwrite existing extracted sources; choose a fresh dependency root.
        destination = args.directory / f'{name}-{version}'
        if destination.exists():
            raise SystemExit(f'{destination} already exists; use a fresh directory')
        with tarfile.open(fileobj=io.BytesIO(data)) as source:
            source.extractall(args.directory, filter='data')
        print(f'{name} {version}: sha256={digest}')

if __name__ == '__main__':
    main()
