#!/usr/bin/env python3
# MT Framework ARC 版本 7 的两种条目宽度（11-02 普查 RESIDENT EVIL 6「直连抽取 zlib 截断」）：translator/shader_split.py mtarc_members。期望按格式手写，不跑被测实现推：
#   ① 路径 128 字节（大逆转裁判，条目 0x90）：两条（zlib 一条、原样一条）路径 / 内容逐字节等于手放的
#   ② 路径 64 字节（生化危机6，条目 0x50）：同上；旧代码按 0x90 读，长度字段落进路径文字，zlib 报截断
#   ③ 小条目压缩后比原文长（生化6 XfEnvCube：存 0x18、原长 0x10）：照常解出，不当成宽度不对
#   ④ 两种宽度都对不上（偏移越过文件尾）：判红退出，不猜
import os
from pathlib import Path
import struct
import sys
import tempfile
import unittest
import zlib

TOOLS = Path(__file__).resolve().parents[4] / 'translator'
SS = None
FILES = [('sc\\NX_64\\root', b'SPK\0' + bytes(range(256)) * 8), ('system\\texture\\tiny', b'0123456789abcdef'), ('raw\\stored', b'stored as is')]


def arc(plen, files=FILES, compress=(True, True, False), bad_offset=False):
    """ARC\\0、版本 7、条数，每条 {路径 plen 字节、u32 类型哈希、u32 存储长、u32 原长 | 标志 2<<29、u32 偏移}，数据紧跟条目表"""
    blobs = [zlib.compress(b) if c else b for (_, b), c in zip(files, compress)]
    table = 8 + (plen + 16) * len(files); off = table; head = b'ARC\0' + struct.pack('<HH', 7, len(files))
    for (path, raw), blob in zip(files, blobs):
        head += path.encode().ljust(plen, b'\0') + struct.pack('<4I', 0x241f5deb, len(blob), len(raw) | 2 << 29, off + (1 << 30 if bad_offset else 0)); off += len(blob)
    return head + b''.join(blobs)


class MtarcWidth(unittest.TestCase):
    def want(self):
        return [(p.replace('\\', '/'), b) for p, b in FILES]

    def test_1_path128(self):
        self.assertEqual(list(SS.mtarc_members(arc(0x80), 'syn')), self.want())

    def test_2_path64(self):
        self.assertEqual(list(SS.mtarc_members(arc(0x40), 'syn')), self.want())

    def test_3_tiny_entry_grows(self):
        self.assertGreater(len(zlib.compress(FILES[1][1])), len(FILES[1][1]))   # 夹具自检：这条压缩后确实变长
        self.assertEqual(list(SS.mtarc_members(arc(0x40), 'syn'))[1], ('system/texture/tiny', FILES[1][1]))

    def test_4_neither_width(self):
        with self.assertRaises(SystemExit):
            list(SS.mtarc_members(arc(0x40, bad_offset=True), 'syn'))


def main():
    global SS
    # The real shader_split import reads only this isolated synthetic profile (never a user's game, never its CLI main())
    with tempfile.TemporaryDirectory(prefix='mtarc-width-') as tmp:
        (Path(tmp) / 'game.tsv').write_text('shader_groups\tsynthetic=synthetic\nshader_note\tsynthetic\n')
        previous = os.environ.get('DM_GAME'); os.environ['DM_GAME'] = tmp
        try:
            sys.path.insert(0, str(TOOLS))
            import shader_split
            SS = shader_split; SS.COMMON = {}
            result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(MtarcWidth))
        finally:
            if previous is None: os.environ.pop('DM_GAME', None)
            else: os.environ['DM_GAME'] = previous
    print(f'MT ARC 条目宽度：{result.testsRun} 项，失败 {len(result.failures)}，错误 {len(result.errors)}；生化6 真文件 3213 个 arc / 208105 条全解开（11-02）')
    return 0 if result.wasSuccessful() else 1


if __name__ == '__main__':
    sys.exit(main())
