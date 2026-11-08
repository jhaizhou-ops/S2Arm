#!/usr/bin/env python3
"""Synthetic NSO for the on-device rewrite self-test (native/selftest.c).
Usage: selftest_nso.py <output.nso>

Code starts at module offset 0x100; each function is `<instruction>; ret`:
  0x100 mrs x0, tpidr_el0     0x108 msr tpidr_el0, x0     0x110 mrs x0, tpidrro_el0
  0x118 mov x18, x0           0x120 add x0, x18, #8       0x128 svc #1
Module skeleton as in tests/rewrite_target_test.sh: text[4] = MOD0 offset, MOD0 + 16 =
eh_frame_hdr with one FDE covering the code. Contains no game code or data."""
import argparse
import struct
import sys

RET = 0xd65f03c0
CODE = [0xd53bd040, RET, 0xd51bd040, RET, 0xd53bd060, RET,
        0xaa0003f2, RET, 0x91002240, RET, 0xd4000021, RET]

text = bytearray(0x1000)
struct.pack_into('<II', text, 0, 0x14000040, 0x1000)
struct.pack_into('<%dI' % len(CODE), text, 0x100, *CODE)
ro = bytearray(0x1000)
EH, EF = 0x100, 0x200
struct.pack_into('<4sIIIii', ro, 0, b'MOD0', 0, 0, 0, EH, EH + 0x20)
struct.pack_into('<BBBBiIii', ro, EH, 1, 0x1B, 0x03, 0x3B, (0x1000 + EF) - (0x1000 + EH + 4), 1,
                 0x100 - (0x1000 + EH), (0x1000 + EF + 0x18) - (0x1000 + EH))
cie = struct.pack('<II', 0x14, 0) + bytes([1]) + b'zR\0' + bytes([4, 0x78, 30, 1, 0x1B]) + bytes(7)
ro[EF:EF + 0x18] = cie
f = 0x1000 + EF + 0x18
struct.pack_into('<IIii', ro, EF + 0x18, 0x10, (f + 4) - (0x1000 + EF), 0x100 - (f + 8), 4 * len(CODE))
data = bytes(0x1000)
h = bytearray(0x100)
h[:4] = b'NSO0'
for k, (mo, seg) in enumerate(((0, text), (0x1000, ro), (0x2000, data))):
    struct.pack_into('<III', h, 0x10 + 0x10 * k, 0x100 + 0x1000 * k, mo, len(seg))
    struct.pack_into('<I', h, 0x60 + 4 * k, len(seg))
h[0x40:0x50] = b'S2A-selftest\0\0\0\0'
def with_sdk_entries(module):
    """同一份合成模块，额外导出运行时要求的 7 个 SDK 入口（各一条 ret；nnMain 返回 0）。

    loader 的口径（runtime/src/loader.c parse_dynamic）：
      MOD0+4 = dynamic 表相对 MOD0 的偏移；DT_SYMTAB/DT_STRTAB 的 d_ptr 相对模块基址；
      符号数 = (strtab - symtab) / 24，所以 .dynstr 必须紧跟在 .dynsym 后面、不能有填充。
    """
    # 文件偏移（段在文件里从 0x100 起，每段 0x1000）：text 0x100、ro 0x1100、data 0x2100；
    # 段内偏移与 vaddr 一致（ro 的 vaddr 是 0x1000），所以 MOD0/符号表用段内偏移即可。
    text_loc, ro_loc, data_loc = 0x100, 0x1100, 0x2100
    base = bytearray(module)
    text = bytearray(base[text_loc:text_loc + 0x1000])
    ro = bytearray(base[ro_loc:ro_loc + 0x1000])
    # 入口桩放在 text 的 0x400 起：ret 一格；nnMain 用 mov w0,#0; ret
    stubs = [(0x400, [RET]), (0x408, [0x52800000, RET])]
    for offset, code in stubs:
        struct.pack_into('<%dI' % len(code), text, offset, *code)
    names = ['_init_libc0', 'nnosInitialize', '_init_libc1', 'nninitInitializeSdkModule',
             'nninitStartup', '_init_libc2', 'nnMain']
    # eh_frame_hdr 在 ro+0x100、FDE 在 ro+0x200（基类模块已经写好、且是相对编码，不能搬），
    # 所以动态表和字符串表放到 0x300 之后。
    dyn_off, sym_off, str_off = 0x300, 0x340, 0x400
    ro_va = 0x1000                                  # ro 段的模块内地址：DT_* 的 d_ptr 用它做基
    dyn = struct.pack('<QQQQQQ', 6, ro_va + sym_off, 5, ro_va + str_off, 0, 0)   # DT_SYMTAB, DT_STRTAB, DT_NULL
    strings = bytearray(b'\0')                                       # 索引 0 保留空名，真名从 1 起
    symbols = [struct.pack('<IBBHQQ', 0, 0, 0, 0, 0, 0)]           # 索引 0：空符号（24 字节）
    for index, name in enumerate(names):
        encoded = name.encode() + b'\0'
        st_name = len(strings)
        strings += encoded
        stub = 0x400 if index != len(names) - 1 else 0x408
        symbols.append(struct.pack('<IBBHQQ', st_name, 0x12, 0, 1, stub, 0))   # STB_GLOBAL|STT_FUNC
    symtab = b''.join(symbols)
    if len(symtab) != (str_off - sym_off):
        raise SystemExit(f'dynsym size {len(symtab)} does not fit 0x{str_off - sym_off:x}')
    struct.pack_into('<4sIIIii', ro, 0, b'MOD0', dyn_off, 0, 0, 0x100, 0x120)
    ro[dyn_off:dyn_off + len(dyn)] = dyn
    ro[sym_off:str_off] = symtab
    ro[str_off:str_off + len(strings)] = strings
    out = bytearray(base)
    out[text_loc:text_loc + 0x1000] = text
    out[ro_loc:ro_loc + 0x1000] = ro
    return bytes(out)


parser = argparse.ArgumentParser(description='synthetic NSO for the rewrite self-test / synthetic packages')
parser.add_argument('output')
parser.add_argument('--sdk-entries', action='store_true',
                    help='also export the SDK entries the game runtime requires (synthetic package chain)')
args = parser.parse_args()
module = bytes(h) + bytes(text) + bytes(ro) + data
if args.sdk_entries:
    module = with_sdk_entries(module)
with open(args.output, 'wb') as out:
    out.write(module)
