#!/usr/bin/env python3
"""Estimate batch makespan from measured per-shader compile times.

Input CSV has columns shader,seconds. Times must be independent, additive
estimates; each batch pays a fixed overhead. This model does not invoke Metal.
"""
import argparse
import csv
import heapq
import json
import math
import sys


def read_times(path):
    with open(path, newline='', encoding='utf-8') as f:
        reader = csv.DictReader(f)
        if reader.fieldnames is None or not {'shader', 'seconds'} <= set(reader.fieldnames):
            raise ValueError('CSV 必须包含 shader,seconds 列')
        rows = []
        names = set()
        for row in reader:
            name = (row['shader'] or '').strip()
            try:
                duration = float(row['seconds'])
            except (TypeError, ValueError):
                raise ValueError('seconds 必须是有限的非负数') from None
            if not name or name in names or not math.isfinite(duration) or duration < 0:
                raise ValueError('shader 必须非空且唯一，seconds 必须是有限的非负数')
            names.add(name)
            rows.append((name, duration))
        if not rows:
            raise ValueError('CSV 至少需要一个 shader')
        return rows


def batches(rows, count, strategy):
    if strategy == 'contiguous':
        # Equal-count chunks, preserving input order.
        q, r = divmod(len(rows), count)
        result, start = [], 0
        for i in range(count):
            size = q + (i < r)
            result.append(rows[start:start + size])
            start += size
        return result
    # Greedily place the largest shader in the lightest batch.
    result = [[] for _ in range(count)]
    ordered = sorted(rows, key=lambda x: (-x[1], x[0]))
    for i, row in enumerate(ordered[:count]):
        result[i].append(row)
    heap = [(row[1], i) for i, row in enumerate(ordered[:count])]
    heapq.heapify(heap)
    for row in ordered[count:]:
        total, i = heapq.heappop(heap)
        result[i].append(row)
        heapq.heappush(heap, (total + row[1], i))
    return result


def simulate(rows, count, strategy, workers, overhead):
    grouped = batches(rows, count, strategy)
    durations = [sum(value for _, value in group) + overhead for group in grouped]
    if any(not math.isfinite(duration) for duration in durations):
        raise ValueError('批次耗时超出可表示范围')
    # List scheduling: longest batch first, stable ties by batch index.
    slots = [(0.0, i) for i in range(workers)]
    assignments = []
    for index in sorted(range(count), key=lambda i: (-durations[i], i)):
        start, worker = heapq.heappop(slots)
        end = start + durations[index]
        if not math.isfinite(end):
            raise ValueError('调度耗时超出可表示范围')
        heapq.heappush(slots, (end, worker))
        assignments.append({'batch': index, 'worker': worker, 'start': start, 'end': end})
    return {'strategy': strategy, 'batch_count': count,
            'makespan_seconds': max(x[0] for x in slots),
            'batch_seconds': durations,
            'batch_shaders': [[name for name, _ in group] for group in grouped],
            'assignments': assignments}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('csv', help='CSV: shader,seconds')
    parser.add_argument('--workers', type=int, default=8)
    parser.add_argument('--overhead', type=float, default=0, help='fixed seconds per batch')
    parser.add_argument('--max-batches', type=int, default=64, help='upper bound of candidate batch counts')
    args = parser.parse_args(argv)
    if args.workers < 1 or args.max_batches < 1 or not math.isfinite(args.overhead) or args.overhead < 0:
        parser.error('workers/max-batches 必须为正整数，overhead 必须为有限非负数')
    try:
        rows = read_times(args.csv)
    except (OSError, ValueError, csv.Error) as e:
        parser.error(str(e))
    try:
        candidates = [simulate(rows, count, strategy, args.workers, args.overhead)
                      for count in range(1, min(len(rows), args.max_batches) + 1)
                      for strategy in ('contiguous', 'balanced')]
    except ValueError as e:
        parser.error(str(e))
    best = min(candidates, key=lambda c: (c['makespan_seconds'], c['batch_count'], c['strategy']))
    json.dump({'workers': args.workers, 'overhead_seconds': args.overhead,
               'shader_count': len(rows), 'candidate_count': len(candidates),
               'best': best, 'candidates': candidates,
               'limitations': '最优仅限所列候选；编译时间按加法和固定批次开销估算，不模拟共享编译、内存竞争或真实调度。'},
              sys.stdout, ensure_ascii=False, indent=2)
    print()


if __name__ == '__main__':
    main()
