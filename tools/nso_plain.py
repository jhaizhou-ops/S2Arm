"""NSO 规整：仓库里 Python 读 NSO 段的地方遇到 ZBIC（NSO 标志 bit 7，22.0.0 起）都调这里，不各写一份解码。

ZBIC 是任天堂改过的 zstd（帧魔数 ZBIC、FSE 表头用二进制插值编码），解码只有一份实现：pack/nx_unpack/ZbicDecoder.cs（自写，C#，Mac / Windows / Linux
同一份 dotnet 构建）。本模块把整份 NSO 交给 `nx_unpack --nso-normalize <入> <出>`（NsoZbic.Normalize：三段解成不压缩段、紧排在原段前内容之后，
标志去掉 0–2 位与 0x80，哈希位与 0x40 保留，每段核 SHA-256），读回规整后的 NSO；调用方原有的「不压缩段」路径照常读，一处不用改。
不带 0x80 的 NSO 原样返回同一个对象（LZ4 / 不压缩的老路一字不变，也不需要 dotnet）。

nx_unpack 的定位与 pack/srcs.sh 的 nxu_path 同口径：S2A_NX_UNPACK 给了就用（可执行文件或 .dll）；没给按 pack/nx_unpack 源码哈希取
<run 根>/s2arm/bin/nx_unpack_<哈希>/，没有就现编（dotnet build，编到 .tmp 再改名）。要 .NET 10 SDK；编不出 / 解不开一律抛 NsoPlainError（ValueError），不猜。

用法：from nso_plain import plain;  raw = plain(raw, '<名字>')
"""
import hashlib
import os
import shutil
import struct
import subprocess
import tempfile

ZBIC = 0x80
ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
SRC = os.path.join(ROOT, 'pack', 'nx_unpack')


class NsoPlainError(ValueError):
    pass


def is_zbic(raw):
    return len(raw) >= 0x10 and bytes(raw[:4]) == b'NSO0' and bool(struct.unpack_from('<I', raw, 12)[0] & ZBIC)


def _built():
    names = sorted(n for n in os.listdir(SRC) if n.endswith('.cs')) + sorted(n for n in os.listdir(SRC) if n.endswith('.csproj'))
    h = hashlib.sha256()
    for n in names:
        with open(os.path.join(SRC, n), 'rb') as f:
            h.update(f.read())
    out = os.path.join(os.environ.get('S2A_RUN_ROOT', os.path.expanduser('~/.s2arm/run')), 's2arm', 'bin', 'nx_unpack_' + h.hexdigest()[:12])
    dll = os.path.join(out, 'nx_unpack.dll')
    if os.path.isfile(dll):
        return dll
    if not shutil.which('dotnet'):
        raise NsoPlainError('ZBIC 的 NSO 要 nx_unpack 解，本机没有 dotnet（.NET 10 SDK），也没给 S2A_NX_UNPACK')
    os.makedirs(os.path.dirname(out), exist_ok=True)
    tmp = f'{out}.tmp.{os.getpid()}'
    shutil.rmtree(tmp, ignore_errors=True)
    r = subprocess.run(['dotnet', 'build', '-c', 'Release', SRC, '-o', tmp, '--nologo', '-v', 'quiet'], capture_output=True, text=True)
    if r.returncode != 0 or not os.path.isfile(os.path.join(tmp, 'nx_unpack.dll')):
        shutil.rmtree(tmp, ignore_errors=True)
        raise NsoPlainError('编 nx_unpack 失败（解 ZBIC 要它）：' + (r.stdout + r.stderr).strip()[-600:])
    try:
        os.rename(tmp, out)
    except OSError:   # 别的进程先编好了：用它的
        shutil.rmtree(tmp, ignore_errors=True)
    return dll


def _command():
    p = os.environ.get('S2A_NX_UNPACK')
    if p:
        return ['dotnet', p] if p.endswith('.dll') else [p]
    return ['dotnet', _built()]


def plain(raw, name='NSO'):
    """带 ZBIC 的 NSO → 段不压缩的 NSO（bytes）；别的原样返回同一个对象。解不开抛 NsoPlainError，信息带原因。"""
    if not is_zbic(raw):
        return raw
    with tempfile.TemporaryDirectory(prefix='nso_plain.') as d:
        src, dst = os.path.join(d, os.path.basename(name) or 'nso'), os.path.join(d, 'out')
        with open(src, 'wb') as f:
            f.write(raw)
        r = subprocess.run(_command() + ['--nso-normalize', src, dst], capture_output=True, text=True)
        if r.returncode != 0:
            raise NsoPlainError(f'{name}：ZBIC 解不开（nx_unpack --nso-normalize 退出 {r.returncode}）：{(r.stderr or r.stdout).strip()}')
        with open(dst, 'rb') as f:
            return f.read()
