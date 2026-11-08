#!/usr/bin/env python3
"""只读汇总 N01 诊断局：python3 tools/metal_cache_summary.py <局目录> --after-frame N。

帧边界由调用者依据实测场景确定；本工具不制造 MARK、不判兼容性或缓存开关有效性。
输出不含日志全文、环境变量、游戏文件或个人路径。MB 日志实际除以 2**20，输出用 MiB。
"""

import argparse
import csv
import hashlib
import json
from pathlib import Path
import re

from frame_gate import split0
from game_fps import target


def cache_samples(log):
    samples = []
    for line in log.splitlines():
        match = re.search(
            r'malloc 采样 \[([^]]+)\].*?估在用 ([\d.]+) MB.*?表满丢 (\d+) / (\d+).*?按调用镜像：(.*)',
            line,
        )
        if not match:
            continue
        images = re.findall(r'([^；]+?) ([\d.]+) MB', match[5])
        sizes = {name.strip(): float(size) for name, size in images}
        samples.append({
            'stage': match[1],
            'total_live_mib_estimate': float(match[2]),
            'corefscache_live_mib_estimate': sizes.get('libCoreFSCache.dylib'),
            # 未进入前十不能记成 0；只保留最小已列值作为显示截断的参考。
            'smallest_listed_image_mib': min(sizes.values()) if sizes else None,
            'table_drops': [int(match[3]), int(match[4])],
        })
    return samples


def frame_window(rows, after_frame, seconds):
    if after_frame < 0 or seconds <= 0:
        raise ValueError('帧边界必须非负，窗口秒数必须为正')
    _, rows = split0(rows)
    window, wall = [], 0
    for row in rows:
        if int(row['frame']) <= after_frame:
            continue
        duration = int(row['wall_us'])
        if duration <= 0:
            raise ValueError('非启动帧 wall_us 必须为正')
        window.append(row)
        wall += duration
        if wall >= seconds * 1e6:
            break
    if wall < seconds * 1e6:
        raise ValueError(f'窗口不足 {seconds:g} 秒，实际 {wall / 1e6:.3f} 秒')
    return {
        'after_frame': after_frame,
        'first_frame': int(window[0]['frame']),
        'last_frame': int(window[-1]['frame']),
        'frames': len(window),
        'wall_seconds': wall / 1e6,
        'end_to_end_fps': len(window) * 1e6 / wall,
        'over_100ms_frames': sum(int(r['wall_us']) > 100000 for r in window),
        'max_frame_ms': max(int(r['wall_us']) for r in window) / 1000,
        'shader_misses': sum(int(r['shader_miss']) for r in window),
        'pso_creations': sum(int(r['pso_n']) for r in window),
        'readback_block_ms': sum(int(r['rb_us']) for r in window) / 1000,
    }


def summarize(directory, after_frame, seconds=60):
    log_path, frames_path = directory / 'host.log', directory / 'frames.tsv'
    log = log_path.read_text()
    with frames_path.open() as stream:
        raw = list(csv.DictReader(stream, delimiter='\t'))
    startup, rows = split0(raw)
    first = re.search(r'首帧上屏.*?\+([\d.]+) ms（本段 ([\d.]+) ms', log)
    samples = cache_samples(log)
    if not first or not samples:
        raise ValueError('缺少首帧或 malloc 采样读数，不能汇总为有效缓存实验')
    fps, _, known = target(log)
    return {
        'schema': 1,
        'first_frame_from_start_ms': float(first[1]),
        'nnmain_to_first_frame_ms': float(first[2]),
        'requested_fps': fps if known else None,
        'window': frame_window(raw, after_frame, seconds),
        'cache_samples': samples,
        'thermal_states': sorted(set(re.findall(r'热状态 (\w+)', log))),
        'red_lines': log.count('【红】'),
        'whole_run_over_100ms_frames': sum(int(r['wall_us']) > 100000 for r in rows),
        'whole_run_shader_misses': sum(int(r['shader_miss']) for r in raw if r['frame'].isdigit()),
        'whole_run_pso_creations': sum(int(r['pso_n']) for r in raw if r['frame'].isdigit()),
        'startup_cumulative_frame': int(startup['frame']) if startup else None,
        'evidence_sha256': {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in (log_path, frames_path)},
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    parser.add_argument('--after-frame', type=int, required=True, help='人工确认场景后的帧边界；不写回 MARK')
    parser.add_argument('--seconds', type=int, default=60)
    args = parser.parse_args()
    try:
        result = summarize(args.directory, args.after_frame, args.seconds)
    except (OSError, ValueError, KeyError) as error:
        parser.error(str(error))
    print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
