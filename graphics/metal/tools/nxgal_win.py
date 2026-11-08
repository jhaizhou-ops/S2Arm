#!/usr/bin/env python3
"""Windows 出包机的 libnxgal 小库（#1100 W6，11-04 Windows 出包线）：nxgal_win.py <输出 nxgal.dll>
纯 C 改写：颜色出口 gal_colorround.c、SPIR-V 加固 gal_spvx.c、计算核共享内存溢出 gal_spill.c（同 graphics/metal/Makefile 的 Linux 目标，#783），
另加曲面翻译段 gal_tessxc.c + 顶点自取纯 C 部分 gal_vpullc.c，并链仓库内置 SPIRV-Cross（同 Makefile SPVC_SRC / SPVC_DEF / -std=c++17 -O2）：
  11-05 天眼出巫师3 缺 22 支外壳 / 域着色器——S2A.Dsh 曲面阶段 DllImport 调 nxgal_dmsh_xc_tess，旧小库没有这个导出，每支翻译失败、只记成缺键。
宏开关、头文件目录、告警即错同 Makefile，C 源另预包含 tools/win_posix.h 补 Windows 没有的 asprintf / memmem；Windows 没有 make，这里用 PATH 上的 LLVM clang / clang++（或 S2A_CC / S2A_CXX）直接编。
COFF 不认 gal_abi.h 的 visibility("default")，导出表按 C 源码里标 NXGAL_API 的函数名生成（/EXPORT），不改 gal_abi.h（改它会换 ABI 指纹与 Mac 整库字节）。
输出已存在且比全部输入新就不重编；编在同目录临时名再改名（并发两路只会有一份完整产物）。
"""
import concurrent.futures
import os
import re
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__)); GAL = os.path.dirname(HERE); ROOT = os.path.abspath(os.path.join(GAL, '..', '..'))
SPVC_DIR = os.path.join(ROOT, 'graphics', 'third_party', 'spirv_cross')
SRCS = ['gal_colorround.c', 'gal_spvx.c', 'gal_spill.c', 'gal_tessxc.c', 'gal_vpullc.c']
HDRS = ['gal_colorround.h', 'gal_spvx.h', 'gal_spill.h', 'gal_log.h', 'gal_abi.h', 'gal_tess.h', 'gal_tessxc.h']
SPVC_UNITS = ['spirv_cfg', 'spirv_cross', 'spirv_cross_c', 'spirv_cross_parsed_ir', 'spirv_glsl', 'spirv_msl', 'spirv_parser']   # = Makefile SPVC_SRC
SPVC_DEF = ['-DSPIRV_CROSS_C_API_MSL=1', '-DSPIRV_CROSS_C_API_GLSL=1']   # = Makefile SPVC_DEF
COMPAT = os.path.join(HERE, 'win_posix.h')   # Windows C 运行库缺的 asprintf / memmem
DEFS = ['-DGAL_COLORROUND_STANDALONE', '-DGAL_SPILL_STANDALONE']
EXPORT = re.compile(r'^NXGAL_API\b[^(]*?\b(nxgal_\w+)\s*\(', re.M)


def exports():
    names = []
    for s in SRCS:
        names += EXPORT.findall(open(os.path.join(GAL, s), encoding='utf-8').read())
    return sorted(set(names))


def build(out):
    spvc = [os.path.join(SPVC_DIR, f) for f in sorted(os.listdir(SPVC_DIR)) if f.endswith(('.cpp', '.hpp', '.h'))]
    ins = [os.path.join(GAL, f) for f in SRCS + HDRS] + spvc + [COMPAT, os.path.abspath(__file__)]
    if os.path.exists(out) and os.path.getmtime(out) >= max(os.path.getmtime(p) for p in ins): return 0
    names = exports()
    if not names: print('【红】C 源码里找不到 NXGAL_API 导出函数', file=sys.stderr); return 1
    os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
    tmp = f'{out}.{os.getpid()}.tmp.dll'
    cc, cxx = os.environ.get('S2A_CC') or 'clang', os.environ.get('S2A_CXX') or 'clang++'
    with tempfile.TemporaryDirectory(prefix='nxgal-', dir=os.path.dirname(os.path.abspath(out))) as od:
        jobs = [[cc, '-std=gnu11', '-O2', '-Wall', '-Wextra', '-Wno-unused-parameter', '-Werror', *DEFS, '-include', COMPAT, '-I' + SPVC_DIR,
                 '-c', os.path.join(GAL, s), '-o', os.path.join(od, s + '.o')] for s in SRCS]
        jobs += [[cxx, '-std=c++17', '-O2', *SPVC_DEF, '-c', os.path.join(SPVC_DIR, u + '.cpp'), '-o', os.path.join(od, u + '.o')] for u in SPVC_UNITS]
        with concurrent.futures.ThreadPoolExecutor(os.cpu_count() or 4) as ex: rcs = list(ex.map(lambda c: subprocess.run(c).returncode, jobs))
        bad = [os.path.basename(c[c.index('-c') + 1]) for c, r in zip(jobs, rcs) if r]
        if bad: print(f'【红】nxgal.dll 编不出：{" ".join(bad)}', file=sys.stderr); return 1
        r = subprocess.run([cxx, '-shared', '-o', tmp, *sorted(os.path.join(od, f) for f in os.listdir(od) if f.endswith('.o')), *['-Wl,/EXPORT:' + n for n in names]])
    if r.returncode:
        for f in (tmp, tmp[:-4] + '.lib', tmp[:-4] + '.exp'):
            if os.path.exists(f): os.unlink(f)
        print(f'【红】nxgal.dll 链接失败（退出 {r.returncode}）', file=sys.stderr); return 1
    os.replace(tmp, out)
    for ext in ('.lib', '.exp'):   # 链接器顺带出的导入库，出库不用
        f = tmp[:-4] + ext
        if os.path.exists(f): os.unlink(f)
    return 0


if __name__ == '__main__':
    if len(sys.argv) != 2: sys.exit(__doc__)
    sys.exit(build(sys.argv[1]))
