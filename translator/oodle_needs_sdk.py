#!/usr/bin/env python3
# 抽取阶段编 Mac 宿主前判：这款的 Oodle 工具模式要不要 C# 服务层（pack/stage_extract.sh）。
#   游戏自带的是 LZ5_decompress_safe（勇者斗恶龙 XI S）→ 要：LZ5 在 SDK 初始化之后做，SDK 初始化连系统服务（svc 0x1f）要 C#（runtime/src/host_main.c、oodle_tool.c s2a_oodle_tool_needs_sdk）；
#   OodleLZ 系 → 不要（SDK 之前做完，省编 C# 约 60 秒）。判法与宿主同：main 的符号表里有没有 LZ5_decompress_safe（宿主 module_sym 按名找它）。
# 11-01：只按「有 .pak」编不带 C# 的宿主，勇者斗恶龙 XI S 在普查（Air）里 LZ5 起不来，直连抽取报 4748 → 16732 字节解压失败。
# 用法：oodle_needs_sdk.py <exefs 目录或 main> → 打印 yes / no；main 不是 NSO 答 no 并在 stderr 说明（同 gfx_api.py 不认的 main 照常往下走）；文件读不了退 2
import struct, sys, os


def main_image(path):
    d = open(path, 'rb').read()
    if d[:4] != b'NSO0': raise ValueError(f'{path} 不是 NSO')
    flags = struct.unpack_from('<I', d, 0xc)[0]; csz = struct.unpack_from('<III', d, 0x60)
    out = bytearray()
    for i in range(3):
        fo, mo, sz = struct.unpack_from('<III', d, 0x10 + i * 0x10); raw = d[fo:fo + csz[i]]
        if flags >> i & 1:
            import lz4.block
            raw = lz4.block.decompress(raw, uncompressed_size=sz)
        out += raw
    return bytes(out)


def needs_sdk(path):
    if os.path.isdir(path): path = os.path.join(path, 'main')
    return b'\0LZ5_decompress_safe\0' in main_image(path)


if __name__ == '__main__':
    try: print('yes' if needs_sdk(sys.argv[1]) else 'no')
    except OSError as e: print(f'读不了 main：{e}', file=sys.stderr); sys.exit(2)
    except (ValueError, IndexError, struct.error) as e: print(f'main 不是能解的 NSO（{e}），按不要 C# 算', file=sys.stderr); print('no')
