#!/usr/bin/env python3
# 出包目标对（10-29 总指挥定口径）：管线归档（gal_pso / pso）、函数体动态库（gal_dl / dl）都绑「GPU 架构 × 系统大版本」，按对出，对不上的设备整份不命中。
#   目标表只有一处：pack/pso_targets.tsv（平台 / 系统大版本 / 架构 / Metal 档 / 工具链出不出得来）；跑局机清单：pack/our_devices.tsv。
# 为什么不复用 pack/jobs/target.py：出包链（graphics/tools/shader_pack.sh、pack/stage_*.sh）会调本模块，
#   tools/stage_inputs.py 把它和它的 import 一起算进出包阶段键；target.py 顶部带启动器代码（diag / core），进了键就成了
#   「改界面一行 → 九款直连库整份重出」。本模块只用标准库。
# 缺省按包的用途推导，不靠人记（优先级从高到低）：
#   1. 显式 S2A_PSO_ARCHS（覆盖用）：给的架构 × 给的大版本（macOS 读 S2A_MAC_OS、iOS 读 S2A_PSO_OS，空格分隔；没给 = macOS 本机 / iOS SDK 大版本）
#   2. S2A_PSO_ARCHS_ALL=1：目标表里本平台全部「出」的行（社区共享缓存这类），不看大版本变量（tools/toolchain.sh 总会给 S2A_PSO_OS 缺省，看了就只剩一个版本）
#   3. 用户包（S2A_PACK_PURPOSE=user，启动器设）：这个包要装的设备那几对——iPhone 包由启动器按目标设备传 S2A_PSO_ARCHS / S2A_PSO_OS（走 1），
#      没传就报红、不猜；Mac 包 = 出包的这台 Mac（本机 GPU 架构 + 系统大版本）
#   4. 缺省（开发 / 测试 / 普查包）：跑局机清单 pack/our_devices.tsv 里本平台「在用」各台的那一对
#   推导出的每一对都要在目标表里且工具链出得来，否则报红（不出一个缺了那台的包）。
# 命令行：python3 pack/jobs/archs.py pairs <ios|macos> pso   → 每行「架构\t大版本\tMetal 档」，标准错误一行来源；推导不出 / 有对不在表里 → 打【红】、退出 2
# 环境（单测夹具）：S2A_PSO_TARGETS = 目标表文件、S2A_OUR_DEVICES = 跑局机清单文件、S2A_HOST_PAIR = 「架构 大版本」代替本机探测
from __future__ import annotations
import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]   # pack/jobs/archs.py → 仓库根
ARCH = re.compile(r'applegpu_g\d+[a-z]')


class TargetError(Exception):
    """推导不出目标对 / 推导出的对不在目标表或工具链拒：调用方报红、不出包"""


def developer_dir(explicit=None):
    """用哪套 Xcode：显式参数 > DEVELOPER_DIR（tools/toolchain.sh 已解析）> S2A_DEVELOPER_DIR（启动器选的、还没解析时）
    > 装着的最新 Xcode > xcode-select。与 tools/toolchain.sh 的选法同序——pack/stage_direct.sh 里解析架构排在 source toolchain.sh 之前，
    那时只有 S2A_DEVELOPER_DIR（启动器 / 本机配置给的）还没落到 DEVELOPER_DIR"""
    if explicit:
        return explicit
    for v in (os.environ.get('DEVELOPER_DIR'), os.environ.get('S2A_DEVELOPER_DIR')):
        if v:
            return v
    from toolchain import detect_xcode   # 都没给：装着的 Xcode 里最新的（同 tools/toolchain.sh 缺省，11-07），找不到再看 xcode-select
    found = detect_xcode()
    if found:
        return found
    try:
        return subprocess.run(['xcode-select', '-p'], capture_output=True, text=True, timeout=30).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return ''


def _rows(path):
    if not path.is_file():
        raise TargetError(f'表不存在：{path}')
    for line in path.read_text(encoding='utf-8').splitlines():
        if line.strip() and not line.startswith('#'):
            yield [c.strip() for c in line.split('\t')]


def target_table(path=None):
    """目标表 → {(平台, 大版本, 架构): (Metal 档, 工具链拒的原话或空串)}"""
    p = Path(path or os.environ.get('S2A_PSO_TARGETS') or ROOT / 'pack' / 'pso_targets.tsv')
    t = {}
    for c in _rows(p):
        if len(c) < 5 or c[0] not in ('ios', 'macos') or not c[1].isdigit() or not ARCH.fullmatch(c[2]) or c[3] not in ('3', '4'):
            raise TargetError(f'目标表 {p} 有坏行：{c}')
        t[(c[0], int(c[1]), c[2])] = (int(c[3]), '' if c[4] == '出' else c[4])
    if not t:
        raise TargetError(f'目标表 {p} 是空的')
    return t


def _devices(path=None):
    p = Path(path or os.environ.get('S2A_OUR_DEVICES') or ROOT / 'pack' / 'our_devices.tsv')
    return p, list(_rows(p))


def our_devices_archs(repo_root=None):
    """我方 iPhone 测试机的 GPU 架构（pack/our_devices.tsv 平台 ios 的第 3 列，去重升序；pack/jobs/target.py 判目标设备在不在我方集合用）"""
    _, rows = _devices(Path(repo_root) / 'pack' / 'our_devices.tsv' if repo_root else None)
    out = sorted({c[2] for c in rows if len(c) >= 4 and c[3] == 'ios' and ARCH.fullmatch(c[2])})
    if not out:
        raise TargetError('我方真机表里没有 iPhone 的 GPU 架构')
    return out


def run_machines(plat):
    """跑局机清单里本平台「在用」各台的（架构, 大版本），去重升序"""
    p, rows = _devices()
    out = set()
    for c in rows:
        if len(c) < 5 or not ARCH.fullmatch(c[2]) or c[3] not in ('ios', 'macos') or not c[4].isdigit():
            raise TargetError(f'跑局机清单 {p} 有坏行（要 机型 / 名字 / 架构 / 平台 / 系统大版本）：{c}')
        if len(c) < 6 or c[5] not in ('是', '否'):
            raise TargetError(f'跑局机清单 {p} 第 6 列「在用」要填 是 / 否：{c}')
        if c[3] == plat and c[5] == '是':   # 不在用的机器不进缺省出包对（10-29 总指挥：Duo 没线在用，双人成行白出它那对链接版 70 多分钟）
            out.add((c[2], int(c[4])))
    if not out:
        raise TargetError(f'跑局机清单 {p} 里没有 {plat} 的机器')
    return sorted(out)


def host_pair():
    """出包的这台 Mac：（GPU 架构, macOS 大版本）。架构探测器同 shader_pack.sh：build/shbake/gpu_arch，没有就现编进临时目录"""
    if os.environ.get('S2A_HOST_PAIR'):
        a, v = os.environ['S2A_HOST_PAIR'].split()
        return a, int(v)
    import tempfile
    g = ROOT / 'build' / 'shbake' / 'gpu_arch'
    with tempfile.TemporaryDirectory() as td:
        if not os.access(g, os.X_OK):
            g = Path(td) / 'gpu_arch'
            c = subprocess.run(['clang', '-fobjc-arc', '-O1', '-o', str(g), str(ROOT / 'graphics' / 'tools' / 'shbake' / 'gpu_arch.m'), '-framework', 'Metal', '-framework', 'Foundation'],
                               capture_output=True, text=True)
            if c.returncode:
                raise TargetError(f'本机 GPU 架构探测器编不出：{c.stderr.strip()[-200:]}')
        a = subprocess.run([str(g)], capture_output=True, text=True).stdout.strip()
    v = subprocess.run(['sw_vers', '-productVersion'], capture_output=True, text=True).stdout.strip().split('.')[0]
    if not ARCH.fullmatch(a) or not v.isdigit():
        raise TargetError(f'探测不出本机 GPU 架构 / 系统大版本（{a!r} / {v!r}）')
    return a, int(v)


def _versions(plat):
    """显式大版本表（S2A_MAC_OS / S2A_PSO_OS，空格分隔）；没给 = 空表"""
    raw = os.environ.get('S2A_MAC_OS' if plat == 'macos' else 'S2A_PSO_OS', '').split()
    if not all(re.fullmatch(r'[1-9]\d*', x) for x in raw):
        raise TargetError(f'{"S2A_MAC_OS" if plat == "macos" else "S2A_PSO_OS"}={" ".join(raw)!r} 不是系统大版本（要整数、空格分隔，例 "26 27"）')
    return sorted({int(x) for x in raw})


def _ios_sdk_major():
    """只在显式架构缺 OS 时探测；保持标准库边界，不引入启动器依赖进阶段键。"""
    cmd = ['xcrun', '--sdk', 'iphoneos', '--show-sdk-version']

    def failure(reason, rc, stderr):
        if isinstance(stderr, bytes):
            stderr = stderr.decode('utf-8', errors='replace')
        lines = (stderr or '').strip().splitlines()
        tail = lines[-1] if lines else '（空）'
        return TargetError(f"{reason}；命令：{' '.join(cmd)}；退出码：{rc}；stderr 末行：{tail}")

    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
    except subprocess.TimeoutExpired as e:
        raise failure('读取 iOS SDK 超时（60 秒）', '未取得（超时）', e.stderr) from e
    except OSError as e:
        raise failure(f'无法启动 iOS SDK 探测：{e}', '未启动', None) from e
    if p.returncode:
        raise failure('读取 iOS SDK 失败', p.returncode, p.stderr)
    version = p.stdout.strip()
    if not re.fullmatch(r'[0-9]+(?:\.[0-9]+)*', version):
        raise failure(f'iOS SDK 版本输出为空或非法：{version!r}', p.returncode, p.stderr)
    try:
        return int(version.split('.')[0])
    except ValueError as e:
        raise failure('iOS SDK 版本数值非法', p.returncode, p.stderr) from e


def pairs(plat, use):
    """→ ([(架构, 大版本, Metal 档)], 来源说明)。use 只有 pso（管线归档 / 函数体动态库，Metal 3 / 4 档都出）"""
    if plat not in ('ios', 'macos') or use != 'pso':
        raise TargetError(f'用法：pairs <ios|macos> pso（给的 {plat} {use}）')
    table = target_table()
    vs = _versions(plat)
    if os.environ.get('S2A_PSO_ARCHS', '').strip():
        if not vs:
            vs = [host_pair()[1]] if plat == 'macos' else [_ios_sdk_major()]
        want, src = [(a, v) for v in vs for a in dict.fromkeys(os.environ['S2A_PSO_ARCHS'].split())], '显式 S2A_PSO_ARCHS'
    elif os.environ.get('S2A_PSO_ARCHS_ALL') == '1':
        want, src = [(a, v) for (p, v, a), (_, why) in sorted(table.items()) if p == plat and not why], '全集（S2A_PSO_ARCHS_ALL=1）'
    elif os.environ.get('S2A_PACK_PURPOSE') == 'user':
        if plat == 'ios':
            raise TargetError('用户包要目标设备：启动器 / 一键出包没传 S2A_PSO_ARCHS / S2A_PSO_OS（选的或连着的设备），不猜')
        want, src = [host_pair()], '用户包：出包的这台 Mac'
    elif not Path(os.environ.get('S2A_OUR_DEVICES') or ROOT / 'pack' / 'our_devices.tsv').exists():   # 公开仓不带我方真机表（维护方私有）
        if plat == 'ios':
            raise TargetError('没有我方真机表（S2A_OUR_DEVICES / pack/our_devices.tsv 为维护方私有）：给 S2A_PSO_ARCHS / S2A_PSO_OS，或 S2A_PSO_ARCHS_ALL=1 出全集')
        want, src = [host_pair()], '没有我方真机表：出包的这台 Mac'
    else:
        want, src = run_machines(plat), '跑局机清单 pack/our_devices.tsv'
    out, bad = [], []
    for a, v in want:
        if not ARCH.fullmatch(a):
            bad.append(f'{a}（不是 GPU 架构名）'); continue
        row = table.get((plat, v, a))
        if row is None:
            bad.append(f'{a}.{plat}{v}（不在目标表 pack/pso_targets.tsv）')
        elif row[1]:
            bad.append(f'{a}.{plat}{v}（工具链{row[1]}）')
        else:
            out.append((a, v, row[0]))
    if bad:
        raise TargetError(f'目标对推导自{src}，其中 {len(bad)} 对出不了：' + '；'.join(bad))
    return sorted(set(out), key=lambda x: (x[1], x[0])), src


if __name__ == '__main__':
    if len(sys.argv) != 4 or sys.argv[1] != 'pairs':
        print('用法：python3 pack/jobs/archs.py pairs <ios|macos> pso', file=sys.stderr); sys.exit(2)
    try:
        ps, src = pairs(sys.argv[2], sys.argv[3])
    except TargetError as e:
        print(f'【红】出包目标：{e}', file=sys.stderr); sys.exit(2)
    for a, v, m in ps:
        print(f'{a}\t{v}\t{m}')
    print(f'出包目标：{src}，{sys.argv[3]} {len(ps)} 对', file=sys.stderr)
