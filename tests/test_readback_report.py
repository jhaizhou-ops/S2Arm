#!/usr/bin/env python3
"""readback_report.py 的合成日志单测（#203）：不依赖真机局，造 frames.tsv + host.log 判分段与统计。

期望（手算）：12 帧，MARK=第 8 帧 → 加载期 7 帧、可操作期 5 帧；
  加载期 rb_us = [0,1000,0,0,3000,0,0] → 非零 2 帧、合计 4000us、最长 3000us；
  可操作期 rb_us 全 0 → 非零 0 帧；
  wall_us 合计：加载 7×10000=70000、可操作 5×20000=100000。
"""
import os, subprocess, sys, tempfile

HEAD = 'frame\twall_us\talloc_b\tgc0\tgc1\tgc2\trb_us\n'
FRAMES = [
    (1, 10000, 0), (2, 10000, 1000), (3, 10000, 0), (4, 10000, 0),
    (5, 10000, 3000), (6, 10000, 0), (7, 10000, 0),
    (8, 20000, 0), (9, 20000, 0), (10, 20000, 0), (11, 20000, 0), (12, 20000, 0),
]

def build(d):
    with open(os.path.join(d, 'frames.tsv'), 'w') as f:
        f.write(HEAD)
        for fr, wall, rb in FRAMES:
            f.write(f'{fr}\t{wall}\t0\t0\t0\t0\t{rb}\n')
    with open(os.path.join(d, 'host.log'), 'w') as f:
        f.write('[x] S2A 就绪\n')
        f.write('[x] S2A 标记 MARK：帧 8\n')
        f.write('[track] READFLUSH 累计：直接 6 段\n')
        # NXGAL_WAIT_SITE=1 的输出（两行：rb 累计更大，应排第一）
        f.write('[waitsite] rb 500.0 ms ×10 最长 80.0 ms 线程 Render（录制） ← libgal+0x1234 ← libgal+0x5678\n')
        f.write('[waitsite] bp 200.0 ms ×5 最长 40.0 ms 线程 GPU（非录制） ← libgal+0x9abc\n')

def main():
    d = tempfile.mkdtemp()
    build(d)
    out = subprocess.run([sys.executable, 'tools/readback_report.py', d, '--json'],
                         capture_output=True, text=True)
    assert out.returncode == 0, out.stderr
    import json
    r = json.loads(out.stdout)
    exp_mark, exp_load_n, exp_load_sum, exp_load_max = 8, 2, 4000, 3000
    exp_op_n, exp_rf = 0, 1
    checks = [
        ('mark_frame', r['mark_frame'], exp_mark),
        ('加载期非零帧', r['segments']['加载期']['rb']['n'], exp_load_n),
        ('加载期合计us', r['segments']['加载期']['rb']['sum_us'], exp_load_sum),
        ('加载期最长us', r['segments']['加载期']['rb']['max_us'], exp_load_max),
        ('可操作期非零帧', r['segments']['可操作期']['rb']['n'], exp_op_n),
        ('READFLUSH 行数', r['readflush_lines'], exp_rf),
        ('归因状态', r['attribution'], 'waitsite'),
        ('waitsite 条数', len(r['waitsites']), 2),
        ('waitsite 首条类型', r['waitsites'][0]['kind'], '读回/同步号'),
        ('waitsite 首条累计', r['waitsites'][0]['total_ms'], 500.0),
        ('waitsite 首条线程', r['waitsites'][0]['thread'], 'Render'),
        ('waitsite 次条类型', r['waitsites'][1]['kind'], '分配器环反压'),
    ]
    bad = 0
    for name, got, want in checks:
        ok = got == want
        print(('✓' if ok else '✗') + f' {name}：期望 {want} → 真结果 {got}')
        bad += 0 if ok else 1
    print(f'readback_report 单测：{len(checks)} 项，失败 {bad}')
    return 1 if bad else 0

if __name__ == '__main__':
    sys.exit(main())
