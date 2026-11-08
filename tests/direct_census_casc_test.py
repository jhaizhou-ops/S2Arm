#!/usr/bin/env python3
"""direct_census.casc_shaders 单测：暴雪 CASC 清单（data/*.psv）里的着色器枚举。

覆盖：没有 CASC 清单、build 优先、只有 base、非 /shaders/ 行不计、未知阶段前缀只计数不进阶段（阶段前缀大小写不敏感）、ESize 空不崩、头不对不算 CASC。
合成清单按真实格式造（FileId|KeyLayout|Chunk|Archive|CKey|CSize|EKey|ESize|Encoding|Path|Flags），不读任何游戏文件。
"""
import importlib.util
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent
TOOL = HERE / 'graphics/nvn/tools/direct_census.py'

HDR = 'FileId!STRING:0|KeyLayout!DEC:4|Chunk!DEC:8|Archive!DEC:8|CKey!HEX:16|CSize!DEC:4|EKey!HEX:16|ESize!DEC:4|Encoding!STRING:0|Path!STRING:0|Flags!STRING:0\n'


def load_tool():
    spec = importlib.util.spec_from_file_location('direct_census', TOOL)
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


def row(path, size='100', archive='3', enc='z'):
    # 按真实列序造一行：FileId 0 / KeyLayout 0 / Chunk 0 / Archive / CKey / CSize / EKey / ESize / Encoding / Path / Flags
    return f'0|0|0|{archive}|{"0" * 32}|{size}|{"0" * 32}|{size}|{enc}|{path}|\n'


def write(root, name, rows, header=HDR):
    d = root / 'romfs' / 'data'
    d.mkdir(parents=True, exist_ok=True)
    (d / name).write_text(header + ''.join(rows))


def main():
    m = load_tool()
    bad = []

    def check(name, got, want):
        if got != want:
            bad.append(f'{name}: 期望 {want!r}，实得 {got!r}')

    with tempfile.TemporaryDirectory() as t:
        base = Path(t)

        check('没有 romfs', m.casc_shaders(base), None)

        # 只有 build：4 个着色器（ps 2 / vs 1 / hs 1），1 个非着色器行不计
        r1 = base / 'c1'; r1.mkdir()
        write(r1, 'build_manifest.psv', [
            row('data:data/hd/shaders/ps_uber_p.bin', '1000'),
            row('data:data/hd/shaders/ps_water_p.bin', '500'),
            row('data:data/hd/shaders/vs_mesh_v.bin', '2000'),
            row('data:data/hd/shaders/hs_terrain_h.bin', '40'),
            row('data:data/global/ui/x.dc6', '999'),
        ])
        stages, n, size, name = m.casc_shaders(r1)
        check('只有 build 的阶段', stages, {'ps': 2, 'vs': 1, 'hs': 1})
        check('只有 build 的文件数', n, 4)
        check('只有 build 的字节数', size, 3540)
        check('只有 build 的 manifest 名', name, 'build_manifest.psv')

        # build 与 base 同时存在：build 优先
        r2 = base / 'c2'; r2.mkdir()
        write(r2, 'base_manifest.psv', [row('data:data/hd/shaders/ps_a_p.bin')])
        write(r2, 'build_manifest.psv', [row('data:data/hd/shaders/cs_b_c.bin'), row('data:data/hd/shaders/cs_c_c.bin')])
        stages, n, _, name = m.casc_shaders(r2)
        check('build 优先：阶段', stages, {'cs': 2})
        check('build 优先：文件数', n, 2)
        check('build 优先：manifest 名', name, 'build_manifest.psv')

        # 只有 base
        r3 = base / 'c3'; r3.mkdir()
        write(r3, 'base_manifest.psv', [row('data:data/hd/shaders/ds_terrain_d.bin'), row('data:data/hd/shaders/gs_grass_g.bin')])
        stages, n, _, name = m.casc_shaders(r3)
        check('只有 base：阶段', stages, {'ds': 1, 'gs': 1})
        check('只有 base：manifest 名', name, 'base_manifest.psv')

        # 未知阶段前缀：计入文件数，不伪造阶段
        r4 = base / 'c4'; r4.mkdir()
        write(r4, 'build_manifest.psv', [row('data:data/hd/shaders/zz_weird.bin'), row('data:data/hd/shaders/PS_upper.bin')])
        stages, n, _, _ = m.casc_shaders(r4)
        check('未知前缀：文件数', n, 2)
        # 阶段前缀大小写不敏感（清单里实测都是小写；大写也认，避免漏计）
        check('未知前缀：阶段', stages, {'ps': 1})

        # ESize 空 / 非数字不崩，按 0 计
        r5 = base / 'c5'; r5.mkdir()
        write(r5, 'build_manifest.psv', [row('data:data/hd/shaders/ps_x_p.bin', size='')])
        stages, n, size, _ = m.casc_shaders(r5)
        check('ESize 空：文件数', n, 1)
        check('ESize 空：字节数', size, 0)

        # 不是 CASC 的 psv（头不对）→ 不算
        r6 = base / 'c6'; r6.mkdir()
        write(r6, 'build_manifest.psv', [row('data:data/hd/shaders/ps_y_p.bin')], header='whatever|not-casc\n')
        check('头不对不算 CASC', m.casc_shaders(r6), None)

        # 目录里根本没有 psv
        r7 = base / 'c7'; (r7 / 'romfs').mkdir(parents=True)
        check('没有 psv', m.casc_shaders(r7), None)

    if bad:
        for b in bad:
            print('🔴', b)
        return 1
    print('CASC 清单：build 优先、base 兜底、非 shaders 行不计、未知前缀不伪造阶段、ESize 空不崩 → 通过')
    return 0


if __name__ == '__main__':
    sys.exit(main())
