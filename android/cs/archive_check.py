#!/usr/bin/env python3
"""linux-bionic-arm64 静态归档产出物即时校验（#1131）。

`dotnet publish -p:NativeLib=Static` 的 CppLibCreator 归档必须：ar 归档、成员 ≥1、
每个成员都是 ELF64 且 e_machine=EM_AARCH64(183)。macOS 上默认 `CppLibCreator=ar`
（BSD ar）：ELF 成员被 ranlib 警告后静默丢掉，产出 8 字节空归档（t140 探测实测），
下游到 CMake 链接才炸。构建当场报红，判据在 doctor/archive_valid.py——
与 doctor 对运行时/codec 缓存用的是同一份，规则只在一处演进。

用法：archive_check.py <file.a> [<file.a> ...]；全部合法退出 0，否则 1。
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'doctor'))
from archive_valid import archive_valid   # noqa: E402  —— 小模块无 import 副作用

EM_AARCH64 = 183


def main():
    if len(sys.argv) < 2:
        sys.exit(f'用法：{sys.argv[0]} <file.a> [...]')
    rc = 0
    for arg in sys.argv[1:]:
        path = Path(arg)
        ok = False
        try:
            ok = path.is_file() and archive_valid(path, EM_AARCH64)
        except OSError:
            pass
        if ok:
            print(f'✅ {path}: ar 归档成员全部是 ELF64/AArch64（archive_valid）')
        else:
            print(f'🔴 {path}: 不是合法的 AArch64 ELF 归档'
                  '（缺文件 / 非 ar / 0 成员 / 含非 ELF64-AArch64 成员；'
                  'macOS 上常见根因是误用了 BSD ar，CppLibCreator 必须指向 NDK llvm-ar）',
                  file=sys.stderr)
            rc = 1
    return rc


if __name__ == '__main__':
    sys.exit(main())
