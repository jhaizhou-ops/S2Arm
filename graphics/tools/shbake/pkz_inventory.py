#!/usr/bin/env python3
"""生成私有 PKZ 索引清单，不解码、不写成员文件、不启动游戏。

用法：pkz_inventory.py <PKZ 文件或资源目录> --output <新的私有 JSON 文件>
目录按魔数认 PKZ，不依赖扩展名。未知压缩方式仅保留为字段；清单成功
不代表抽取或直连出库成功。成员偏移以该容器起点为零，长度单位为字节。
"""

import argparse
import collections
from dataclasses import asdict
import hashlib
import json
import mmap
from pathlib import Path
import sys

import pkz


def archive_record(path, relative):
    with path.open('rb') as stream:
        if stream.read(4) != b'pkzl':
            raise pkz.FormatError('不是 PKZ')
        with mmap.mmap(stream.fileno(), 0, access=mmap.ACCESS_READ) as data:
            members = pkz.index_entries(data)
            return dict(path=relative, bytes=len(data), sha256=hashlib.sha256(data).hexdigest(),
                        members=[dict(index=i, **asdict(member))
                                 for i, member in enumerate(members)])


def inventory(source):
    if source.is_file():
        archives = [archive_record(source, source.name)]
    elif source.is_dir():
        archives = []
        for path in sorted(source.rglob('*')):
            if not path.is_file():
                continue
            with path.open('rb') as stream:
                magic = stream.read(4)
            if magic == b'pkzl':
                archives.append(archive_record(path, path.relative_to(source).as_posix()))
    else:
        raise ValueError('输入不是文件或目录')
    if not archives:
        raise ValueError('没有找到 PKZ 容器')
    counts = collections.Counter(member['compression']
                                 for archive in archives for member in archive['members'])
    return dict(schemaVersion=1, kind='pkz_index_inventory', contentDecoded=False,
                offsetOrigin='archive_start', lengthUnit='byte',
                summary=dict(archives=len(archives), members=sum(counts.values()),
                             compressionMembers=dict(sorted(counts.items()))), archives=archives)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    parser.add_argument('--output', type=Path, required=True,
                        help='新建私有 JSON 文件；不会覆盖已有文件')
    args = parser.parse_args()
    try:
        report = inventory(args.source)
        with args.output.open('x', encoding='utf-8') as stream:
            json.dump(report, stream, ensure_ascii=False, indent=2)
            stream.write('\n')
    except (OSError, ValueError) as error:
        print(f'PKZ 索引清单失败：{error}', file=sys.stderr)
        return 1
    print(json.dumps(dict(contentDecoded=False, **report['summary']), ensure_ascii=False))
    return 0


if __name__ == '__main__':
    sys.exit(main())
