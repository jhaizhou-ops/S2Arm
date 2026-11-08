#!/usr/bin/env python3
"""Unity 款「只放开交换间隔够不够 60 帧」静态判定（名单线 10-27）。

用法：python3 tools/unity_fps_judge.py <global-metadata.dat> <main.patched.bin> \
        [--image-base N] [--text-start N --text-size N]

对一款 IL2CPP（v29 / v31）/ AArch64 Unity 游戏，找游戏代码里对
Application.set_targetFrameRate / QualitySettings.set_vSyncCount 的直接 BL 调用点，
从调用前最后一条写 w0 的指令读出常量实参，按 Unity 语义判定：

- vSyncCount 常量非 0（如 1、2）：帧率由垂直同步决定。宿主 present display 每个显示
  节拍出一帧、把游戏设的交换间隔压成 1，等于社区「交换间隔压 0」补丁 → 够。
  （Unity 文档：vSyncCount 非 0 时 targetFrameRate 被忽略 → 只按垂直同步。）
- targetFrameRate 常量 <= 0（-1 / 0）：不按帧率等待，出图跟交换间隔 → 够。
- targetFrameRate 常量 >= 60：要求不低于 60，交换间隔放开后仍是 60 → 够。
- targetFrameRate 常量 1..59（如 30）：Unity 按该帧率等待，放开交换间隔也到不了 60
  → 不够，需另改（帧率表 w 行 / 补丁）。
- 实参不是常量（寄存器 / 内存 / 函数返回值）、或扫描跨过分支、或找不到调用
  → 判不出，不猜。
- 两个 setter 都映射到了，但游戏代码里一条直接调用都没有：缺省也判不出（无法从
  单趟 text 扫描证明「确实没调」，可能被内联 / 间接调用 / 反射）。加
  --absent-is-unlimited 才按「Unity 缺省 targetFrameRate = -1、不按帧率等待 → 够」
  下结论，输出里会写明这是假设。

退出码：0 = 够；1 = 不够；2 = 判不出（含定位失败）；64 = 用法错误。
只读输入、不执行游戏代码。metadata 支持 v29、v31（丝之歌 Unity 6000.0）；v24.0（空洞骑士 Unity 2017.4）
能解析元数据，但没有 CodeGenModule、方法地址查法不同，未实现，报判不出；其他版本拒绝并报判不出。
BL 命中是 text 内的指令模式，不能证明运行期可达；间接调用 / 内联 / 反射调用不在覆盖内。
"""
import argparse
import json
import struct
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import il2cpp_fps_loc as loc  # noqa: E402  同目录工具：IL2CPP 元数据解析与 setter 入口定位

MAX_BACK = 24          # 从 BL 往前最多看 24 条指令
VERDICT_EVIDENCE = {'Application.set_targetFrameRate': 'targetFrameRate',
                    'QualitySettings.set_vSyncCount': 'vSyncCount'}


def decode_bitmask(n, imms, immr, bits=32):
    """AArch64 logical immediate 解码（ORR w0, wzr, #imm 用）。"""
    combined = (n << 6) | (~imms & 0x3F)
    if combined == 0:
        return None
    size = combined.bit_length() - 1
    if size < 1:
        return None
    s = imms & (0x3F >> (6 - size))
    r = immr & (0x3F >> (6 - size))
    if s == (0x3F >> (6 - size)):
        return None
    esize = 1 << size
    welem = (1 << (s + 1)) - 1
    if r:
        welem = ((welem >> r) | (welem << (esize - r))) & ((1 << esize) - 1)
    value = 0
    for k in range(bits // esize):
        value |= welem << (k * esize)
    return value


def written_const(word, prefix_words):
    """若这条指令写 w0 且常量可知，返回整数；写 w0 但不可知返回 None；不写 w0 返回 False。"""
    if (word & 0x7F800000) == 0x52800000 and (word & 31) == 0:          # MOVZ w0, #imm16
        return ((word >> 5) & 0xFFFF) << (16 * ((word >> 21) & 3))
    if (word & 0x7F800000) == 0x12800000 and (word & 31) == 0:          # MOVN w0, #imm16
        return ~(((word >> 5) & 0xFFFF) << (16 * ((word >> 21) & 3))) & 0xFFFFFFFF
    if (word & 0x7F800000) == 0x72800000 and (word & 31) == 0:          # MOVK w0：往前找 MOVZ 拼接
        base = None
        for other in reversed(prefix_words):
            if (other & 0x7F800000) == 0x52800000 and (other & 31) == 0 and \
                    ((other >> 21) & 3) == ((word >> 21) & 3):
                base = ((other >> 5) & 0xFFFF) << (16 * ((other >> 21) & 3))
                break
        return None if base is None else (base & ~(0xFFFF << (16 * ((word >> 21) & 3)))) | \
            (((word >> 5) & 0xFFFF) << (16 * ((word >> 21) & 3)))
    if (word & 0x7F800000) == 0x32000000 and (word & 31) == 0 and ((word >> 5) & 31) == 31:
        return decode_bitmask((word >> 22) & 1, (word >> 10) & 0x3F, (word >> 16) & 0x3F)
    if (word & 0x7F000000) == 0x11000000 and (word & 31) == 0 and ((word >> 5) & 31) == 31:
        return ((word >> 10) & 0xFFF) << (12 * ((word >> 22) & 1))       # ADD w0, wzr, #imm
    if word == 0x2A1F03E0:                                              # MOV w0, wzr
        return 0
    writes = ((word & 0x7F800000) == 0x52800000 or (word & 0x7F800000) == 0x12800000
              or (word & 0x7F800000) == 0x72800000
              or ((word & 0x7F000000) in (0x11000000, 0x51000000, 0x32000000, 0x12000000)
                  and (word & 31) == 0)
              or (word & 0x7F000000) == 0x0B000000 and (word & 31) == 0     # ADD shifted reg
              or (word & 0x3B000000) == 0x39000000 and (word & 31) == 0     # LDR/STR 类（w0）
              or (word & 0x3B000000) == 0x18000000 and (word & 31) == 0     # LDR（字面量）w0
              or (word & 0x1F000000) == 0x0A000000 and (word & 31) == 0)    # 逻辑运算
    if writes:
        return None
    return False


def x0_at(text, text_start, pc):
    """从 BL 处往前找最后一条写 w0 的指令：返回 (常量或 None, 说明)。"""
    seen = []
    for step in range(1, MAX_BACK + 1):
        address = pc - 4 * step
        if address < text_start:
            return None, '扫描到 text 起点仍未见到 w0 赋值'
        word = struct.unpack_from('<I', text, address - text_start)[0]
        if (word & 0x7C000000) == 0x14000000 or (word & 0xFFFFFC1F) in (0xD61F0000, 0xD63F0000, 0xD65F0000):
            return None, '扫描跨过分支（调用点在条件块里，实参在前路径上不可知）'
        value = written_const(word, seen[::-1])
        if value is not False:
            if value is None:
                return None, 'w0 来自寄存器 / 内存 / 运算，不是常量'
            return value & 0xFFFFFFFF, 'w0 = %d' % (value - (1 << 32) if value & 0x80000000 else value)
        seen.append(word)
    return None, '往前 %d 条指令内没找到 w0 赋值' % MAX_BACK


def encode_const(value):
    """把 32 位常量还原成有符号整数（-1 而非 4294967295）。"""
    return value - (1 << 32) if value & 0x80000000 else value


def text_bounds(image, image_base, text_start, text_size):
    """text 区间：显式给了就用；否则从 MOD0 取 .bss 起点当 text 终点。"""
    if text_start is not None and text_size is not None:
        return text_start, text_size
    if len(image) < 8:
        raise loc.Invalid('image too short for MOD0')
    mod0 = struct.unpack_from('<I', image, 4)[0]
    if mod0 + 12 > len(image) or image[mod0:mod0 + 4] != b'MOD0':
        raise loc.Invalid('no MOD0 header; pass --text-start/--text-size')
    # MOD0：+0 magic，+4 dynamic_offsets 偏移，+8 .bss 起点偏移，+12 .bss 终点偏移（均相对 MOD0）
    bss = mod0 + struct.unpack_from('<I', image, mod0 + 8)[0]
    if not (0 < bss <= len(image) and bss % 4 == 0):
        raise loc.Invalid('MOD0 .bss start outside image')
    return image_base, bss   # 文件偏移 0 即 image_base；bss 起点（文件偏移）就是 text 长度


def judge(metadata, image, image_base=0, text_start=None, text_size=None, codegen_module=None,
          absent_is_unlimited=False):
    start, size = text_bounds(image, image_base, text_start, text_size)
    located = loc.locate(metadata, image, image_base, codegen_module, start, size)
    text = image[start - image_base:start - image_base + size]
    sites = []
    for method in located['methods']:
        name = '%s.%s' % (method['type'], method['method'])
        for pc in method['direct_bl_candidates']:
            value, how = x0_at(text, start, pc)
            sites.append({'method': name, 'pc': pc, 'rel': pc - image_base,
                          'argument': None if value is None else encode_const(value), 'how': how})
    kinds = {}
    for site in sites:
        kinds.setdefault(VERDICT_EVIDENCE[site['method']], []).append(site)
    unknown = [s for s in sites if s['argument'] is None]
    if unknown:
        return result('判不出', '有调用点实参不是常量，不猜', sites, located)
    vsync = kinds.get('vSyncCount', [])
    frame = kinds.get('targetFrameRate', [])
    if any(s['argument'] != 0 for s in vsync):
        return result('够', 'vSyncCount 非 0：帧率由垂直同步决定，宿主每个显示节拍出一帧（交换间隔压 1）即放开', sites, located)
    if not frame:
        if absent_is_unlimited:
            return result('够', '游戏代码里没有直接调用 setter（假设未被内联 / 间接调用）：'
                          'targetFrameRate 保持 Unity 缺省 -1，不按帧率等待 → 够', sites, located)
        return result('判不出', '没找到 targetFrameRate 调用点（间接 / 内联 / 反射调用不在覆盖内），'
                      '不猜；确认确实没调可加 --absent-is-unlimited', sites, located)
    caps = [s for s in frame if 0 < s['argument'] < 60]
    if caps:
        return result('不够', 'targetFrameRate 被设成 %d：Unity 按该帧率等待，放开交换间隔到不了 60' % caps[0]['argument'], sites, located)
    return result('够', 'targetFrameRate 取值 <=0 或 >=60：不按更低帧率等待，出图跟交换间隔', sites, located)


def result(verdict, reason, sites, located):
    return {'verdict': verdict, 'reason': reason, 'sites': sites,
            'module': located['module'], 'codegen_module': located['codegen_module'],
            'module_match': located['module_match'], 'image_base': located['image_base'],
            'modules': located.get('modules', [])}


def print_report(report, metadata_path, image_path):
    print('# Unity 交换间隔判定：%s' % report['verdict'])
    print('# 输入：%s  %s' % (metadata_path, image_path))
    print('# 理由：%s' % report['reason'])
    print('# 模块名：%s' % report['module'])
    for module in report.get('modules', []):
        print('#   %s  CodeGenModule %#x（%s）' % (module['name'], module['codegen_module'],
                                                module['module_match']))
    for site in report['sites']:
        arg = '非常量' if site['argument'] is None else str(site['argument'])
        print('调用点 %s+%#x  %s(%s)  [%s]' % ('main', site['rel'], site['method'], arg, site['how']))


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('metadata')
    parser.add_argument('image')
    parser.add_argument('--image-base', type=lambda s: int(s, 0), default=0)
    parser.add_argument('--text-start', type=lambda s: int(s, 0))
    parser.add_argument('--text-size', type=lambda s: int(s, 0))
    parser.add_argument('--codegen-module', type=lambda s: int(s, 0),
                        help='手动给定 Il2CppCodeGenModule 地址（结构定位不唯一时）')
    parser.add_argument('--absent-is-unlimited', action='store_true',
                        help='零调用点时按 Unity 缺省不限帧判「够」（输出写明是假设）')
    parser.add_argument('--json', action='store_true', help='输出 JSON（机器读）')
    args = parser.parse_args()
    if (args.text_start is None) != (args.text_size is None):
        parser.error('--text-start and --text-size must be given together')
    try:
        report = judge(loc.read_input(args.metadata), loc.read_input(args.image),
                       args.image_base, args.text_start, args.text_size, args.codegen_module,
                       args.absent_is_unlimited)
    except (loc.Invalid, OSError) as exc:
        print(json.dumps({'verdict': '判不出', 'error': str(exc)}, ensure_ascii=False))
        return 2
    if args.json:
        print(json.dumps(report, ensure_ascii=False, indent=2))
    else:
        print_report(report, args.metadata, args.image)
    return {'够': 0, '不够': 1, '判不出': 2}[report['verdict']]


if __name__ == '__main__':
    sys.exit(main())
