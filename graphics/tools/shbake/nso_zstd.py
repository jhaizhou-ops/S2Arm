# 主程序模块里内嵌的 zstd 字典与着色器帧（11-02 着色器容器族 A 组，Trine 5 / Frozenbyte 引擎）：着色器逐支压成带字典号的 zstd 帧编进 exefs/main 的只读数据，
#   字典也在同一个镜像里，前面带 8 字节 {u32 1, u32 字典长}（本作 3 本，各 0x18000 字节）。资源目录里没有字典文件，find_zsdicts 收不到、帧一支都解不开（原先 0 支）。
# 字典：只认「魔数 37 A4 30 EC 前 4 字节是一个说得通的长度、且 libzstd 按这段认得出字典号」的；用不用得上由帧自己验证（帧头字典号对上 + 解出长度恰为帧头原长）。
# 帧内容 = [控制段 (+0x20 自报长 n)][m 条 12 字节小记录][机器码 (控制段 +0x704 自报长 k)]，机器码在帧尾：按这个结构取，不交给 scan_adj 猜
#   （11-02 实测：scan_adj 的通用配对在这种排法上把小记录 + 半截机器码当无头计算着色器，4794 支只对 3541、漏 1253、配出 49 支幽灵）。
import struct

MAGIC = b'\x37\xa4\x30\xec'
CTL = bytes.fromhex('3412769801000000')
HDR = bytes.fromhex('78563412')
STAGE = {1: 'vs', 2: 'hs', 3: 'ds', 4: 'gs', 5: 'ps'}


def dicts(img, dict_id):
    """镜像里的字典 → {字典号: 字典字节}；dict_id = libzstd 的 ZSTD_getDictID_fromDict 包装（字节 → 号，认不出是 0）"""
    out = {}; p = img.find(MAGIC)
    while p >= 0:
        n = struct.unpack_from('<I', img, p - 4)[0] if p >= 4 else 0
        if 8 < n <= len(img) - p:
            d = bytes(img[p:p + n]); did = dict_id(d)
            if did and did not in out: out[did] = d
        p = img.find(MAGIC, p + 4)
    return out


def frame_shader(r, code_ok):
    """一帧解出的内容 → (阶段, 控制段, 机器码)；不是上述排法返回 None、排法对但机器码不像指令 / 计算着色器没有线程组返回 'bad'"""
    if r[:8] != CTL or len(r) < 0x708: return None
    n, k = struct.unpack_from('<I', r, 0x20)[0], struct.unpack_from('<I', r, 0x704)[0]
    gap = len(r) - n - k
    if not (0x708 <= n <= len(r)) or k <= 0 or gap < 0 or gap % 12: return None
    ctl, code = r[:n], r[len(r) - k:]
    if code[:4] == HDR: st = STAGE.get(struct.unpack_from('<I', code, 0x30)[0] >> 10 & 0xf)
    else: st = 'cs' if 0 not in struct.unpack_from('<3I', ctl, 0x748) else None
    return (st, ctl, code) if st and code_ok(code, ctl) else 'bad'
