#!/usr/bin/env python3
"""交付 IPA 的画面模式：读 IPA 里 Payload/<App>.app/Info.plist 的 S2AGraphicsMode / S2AGraphicsModeReason（pack/ipa.sh 写，iOS「关于本包」与 Mac 启动器读的同一份），
输出「模式<TAB>理由」一行。一键出包收尾用它填 result 的 graphics_mode / graphics_reason，作业记录与启动器看的就是这个。
11-01 #1104 验收：原先从产物根的中间目录 build/ios/S2Arm.app/Info.plist 取，那份不在就落成 unknown，两单（通用 / 直连）都报 unknown；交付物本身才是唯一来源。
读不开 IPA、没有 App 的 Info.plist、或没有 S2AGraphicsMode → 退 1 并说明（不猜 unknown）。用法：ipa_mode.py <IPA>"""
import plistlib, sys, zipfile


def mode(path):
    with zipfile.ZipFile(path) as z:
        names = [n for n in z.namelist() if n.startswith('Payload/') and n.count('/') == 2 and n.endswith('.app/Info.plist')]
        if len(names) != 1: raise ValueError(f'IPA 里 Payload/<App>.app/Info.plist 应恰好 1 份，实有 {len(names)} 份')
        info = plistlib.loads(z.read(names[0]))
    m = info.get('S2AGraphicsMode')
    if not isinstance(m, str) or not m: raise ValueError(f'{names[0]} 里没有 S2AGraphicsMode')
    return m, str(info.get('S2AGraphicsModeReason') or '')


if __name__ == '__main__':
    try: m, r = mode(sys.argv[1])
    except (OSError, ValueError, zipfile.BadZipFile, plistlib.InvalidFileException) as e:
        print(f'读不到交付 IPA 的画面模式：{e}', file=sys.stderr); sys.exit(1)
    print(f'{m}\t{" ".join(r.split())}')
