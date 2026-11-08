# CRI CPK 目录（nxsh_extract 解不开数据块报告用，10-22 第 4 项）：读 CPK 头表与 TOC 表（@UTF 表格式），列出每个条目的 (名字, 起点, 长度)。
#   格式按公开资料（CriPakTools / VGMToolbox 的 @UTF 读法）手写，不引第三方代码；只读数据，不解条目内容。
#   @UTF 表（大端）：'@UTF' 表长 u32 | 版本 u16 行区偏移 u16 字符串区偏移 u32 数据区偏移 u32（三者相对 +8）| 表名 u32 列数 u16 行长 u16 行数 u32 | 列描述…
#     列描述 = 标志 u8（高 4 位存法：1 零值 / 3 常量（值紧跟在列描述后）/ 5 每行；低 4 位类型：0–7 依次 u8 s8 u16 s16 u32 s32 u64 s64，8 float，0xA 字符串（u32 偏移），0xB 数据（u32 偏移 + u32 长））+ 列名 u32
#   表头不是 '@UTF' 的是加密表：逐字节异或，钥匙从 0x5F 起每字节乘 0x15（CriPakTools 同法）
#   CPK：0 处 'CPK ' 块头 16 字节、其后头表（ContentOffset / TocOffset …）；TocOffset 处 'TOC ' 块头 16 字节、其后 TOC 表（DirName / FileName / FileSize / FileOffset）。
#   条目起点 = FileOffset + min(TocOffset, ContentOffset)（CriPakTools 同法）。解析不了一律返回 []，不猜
import struct

def _dec(b):
    if b[:4] == b'@UTF': return b
    out = bytearray(len(b)); k = 0x5F
    for i, x in enumerate(b): out[i] = x ^ k; k = (k * 0x15) & 0xFF
    return bytes(out)

def utf_table(b):
    """一张 @UTF 表 → 行列表（每行 {列名: 值}）；不是 @UTF 返回 None"""
    b = _dec(bytes(b))   # 传进来的就是一张表（CPK 块头给了长度），整段解密
    if b[:4] != b'@UTF': return None
    b = b[:8 + struct.unpack_from('>I', b, 4)[0]]
    _, rows_off, str_off, data_off, _, ncol, row_len, nrow = struct.unpack_from('>HHIIIHHI', b, 8)
    base = 8; S = base + str_off; Dt = base + data_off
    def cstr(o): e = b.index(b'\0', S + o); return b[S + o:e].decode('utf-8', 'replace')
    FMT = {0: ('>B', 1), 1: ('>b', 1), 2: ('>H', 2), 3: ('>h', 2), 4: ('>I', 4), 5: ('>i', 4), 6: ('>Q', 8), 7: ('>q', 8), 8: ('>f', 4), 0xA: ('>I', 4), 0xB: ('>II', 8)}
    def val(t, o):
        f, n = FMT[t]; v = struct.unpack_from(f, b, o)
        if t == 0xA: return cstr(v[0]), n
        if t == 0xB: return (Dt + v[0], v[1]), n
        return v[0], n
    cols = []; p = base + 24
    for _ in range(ncol):
        fl, name = struct.unpack_from('>BI', b, p); p += 5; st, t = fl >> 4, fl & 0xF
        if t not in FMT: return None
        if st == 3: v, n = val(t, p); p += n; cols.append((cstr(name), st, t, v))
        else: cols.append((cstr(name), st, t, None))
    out = []
    for r in range(nrow):
        q = base + rows_off + r * row_len; row = {}
        for name, st, t, v in cols:
            if st == 5: v, n = val(t, q); q += n
            elif st == 1: v = 0
            row[name] = v
        out.append(row)
    return out

def entries(data):
    """CPK 文件 → [(目录/名字, 起点, 长度)]；不是 CPK 或解析不了 → []"""
    try:
        if bytes(data[:4]) != b'CPK ': return []
        n = struct.unpack_from('<Q', data, 8)[0]; hd = utf_table(bytes(data[16:16 + n]))
        if not hd: return []
        toc = int(hd[0].get('TocOffset') or 0); con = int(hd[0].get('ContentOffset') or 0)
        if not toc or bytes(data[toc:toc + 4]) != b'TOC ': return []
        n = struct.unpack_from('<Q', data, toc + 8)[0]; rows = utf_table(bytes(data[toc + 16:toc + 16 + n])) or []
        add = min(toc, con) if con else toc
        return [((f"{r.get('DirName') or ''}/" if r.get('DirName') else '') + str(r.get('FileName') or ''), add + int(r['FileOffset']), int(r['FileSize']))
                for r in rows if 'FileOffset' in r and 'FileSize' in r]
    except (struct.error, ValueError, IndexError, KeyError, TypeError):
        return []
