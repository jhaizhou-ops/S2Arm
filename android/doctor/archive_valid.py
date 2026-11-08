"""ar 归档成员与 ELF 头判据（#1131）。

单独放一个小模块，让 cs/archive_check.py（构建当场校验）与 doctor.py（运行时 /
codec 缓存巡检）共用同一份判据，而不必把整份 doctor 放进两路共享的准备标记清单：
改 doctor 的其它检查不会让各门禁机重新备料。
"""
import struct


def elf_header(h, machine, types=(1, 2, 3)):
    return (len(h) >= 64 and h[:6] == b'\x7fELF\x02\x01'
            and struct.unpack('<H', h[16:18])[0] in types
            and struct.unpack('<H', h[18:20])[0] == machine)


def archive_valid(p, machine):
    # Check every ar member boundary and object architecture without unpacking it.
    # GNU symbol/name tables are metadata, never sufficient evidence by themselves.
    total = p.stat().st_size
    objects = 0
    with p.open('rb') as f:
        if f.read(8) != b'!<arch>\n':
            return False
        while f.tell() < total:
            h = f.read(60)
            if len(h) != 60 or h[58:] != b'`\n':
                return False
            try:
                size = int(h[48:58].decode('ascii').strip())
            except (ValueError, UnicodeError):
                return False
            start = f.tell()
            end = start + size
            if size < 0 or end > total:
                return False
            name = h[:16].rstrip(b' ')
            metadata = name in (b'/', b'//', b'/SYM64/')
            if name.startswith(b'#1/'):
                try:
                    name_size = int(name[3:])
                except ValueError:
                    return False
                if name_size < 0 or name_size > size:
                    return False
                name = f.read(name_size).rstrip(b'\0')
                metadata = name.startswith(b'__.SYMDEF')
            if not metadata:
                remaining = end - f.tell()
                obj = f.read(min(64, remaining))
                # Unknown/bitcode members need separate validation; do not guess their ISA.
                if not elf_header(obj, machine, (1,)):
                    return False
                objects += 1
            f.seek(end)
            if size % 2:
                if f.read(1) != b'\n':
                    return False
        return f.tell() == total and objects > 0
