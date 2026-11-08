#!/usr/bin/env python3
"""gal_abi.h 的 ABI 指纹（C 端 Makefile、C# 端 NxGal.csproj 构建时都调它，两边编进同一个值，初始化时比对）。
指纹 = 去掉注释、合并空白之后全文的 SHA-256 前 8 字节：改注释不变；改任何导出函数签名 / 结构体 / 常量都会变，不靠人记得升版本号
（10-18/19 两次改 nxgal_perf_read 签名没升号，旧库配新核心库越界卡死）。
用法：abi_hash.py <gal_abi.h> [--c <输出 .h> | --cs <输出 .cs>]；不给输出就打印十六进制。"""
import hashlib, re, sys

def fingerprint(path):
    s = open(path, encoding='utf-8').read()
    s = re.sub(r'/\*.*?\*/', ' ', s, flags=re.S)        # 块注释
    s = re.sub(r'//[^\n]*', ' ', s)                      # 行注释
    s = ' '.join(s.split())                              # 空白全部合成一个空格
    return hashlib.sha256(s.encode()).hexdigest()[:16]

def write_if_changed(path, text):   # 内容不变不改写：免得每次构建都让依赖它的目标重编
    try:
        if open(path, encoding='utf-8').read() == text: return
    except OSError: pass
    open(path, 'w', encoding='utf-8').write(text)

h = fingerprint(sys.argv[1])
if len(sys.argv) == 4 and sys.argv[2] == '--c':
    write_if_changed(sys.argv[3], f'// 生成文件（graphics/metal/tools/abi_hash.py），勿改\n#define NXGAL_ABI_HASH 0x{h}ull\n')
elif len(sys.argv) == 4 and sys.argv[2] == '--cs':
    write_if_changed(sys.argv[3], f'// 生成文件（graphics/metal/tools/abi_hash.py），勿改\nnamespace NxGal {{ public static class Abi {{ public const ulong Hash = 0x{h}UL; }} }}\n')
else:
    print(h)
