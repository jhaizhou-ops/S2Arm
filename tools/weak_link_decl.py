#!/usr/bin/env python3
# 弱链接登记：宿主弱符号放行清单的唯一来源是源码里的「// 弱链接[<场合,…>]：<符号>」注释（runtime/build.mk S2A_WEAK_U 按同一口径收）。
#   python3 tools/weak_link_decl.py check          runtime/src 里每个 __attribute__((weak_import)) 都要有「弱链接[…host…]」登记；全仓（除本工具与 .md）不许手写链接放行参数；缺了 / 有了逐个报出、退出 1
#   python3 tools/weak_link_decl.py flags <场合>    打印该场合的 -Wl,-U,_<符号> 参数（给不走 make 的测试用，如 Mac 图形 Python 测试）
# 11-01 合入线：原先 5 个单测 mk、gfxmode 单测替身、Mac 图形 Python 测试各抄一份放行清单，加一个弱符号要改 7 处、漏一处门禁就红（织梦岛 s2a_vi_entry 连退两次）。
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DECL_GLOBS = ("runtime/src/*.c", "ios/*.m", "graphics/nvn/gfx/*/*.m", "graphics/nvn/gfx/*/*.c", "tests/autoplay/*.c")   # 同 runtime/build.mk S2A_DECL_SRCS
# 苹果 / 共用侧的场合只扫上面这些源码（11-05 架构方案 2-1 / H6：原先通配含 android/native/nvn/*.c，iOS 出壳 make ios 求 $(call S2A_WEAK_U,ios)
#   时把安卓源码也读进来，壳输入表 shell.tsv 就得登记 48 个安卓文件，安卓每加一个 .c 出壳就红，如 92517a319）。
#   安卓在 Mac 上跑的宿主单测（androiddraw、poolahb_test …）登记在安卓源码里：场合不是苹果侧的那几个时，再加扫安卓目录
APPLE_PLACES = ("host", "ios", "nvntest", "autoplay", "lab", "touchtest")   # 苹果 / 共用构建取放行参数的场合（runtime/build.mk、tests/build.mk、Mac 图形测试）
ANDROID_DECL_GLOBS = ("android/native/nvn/*.c", "android/native/direct/*.c")   # direct/：W2 导出门 / 诊断的弱引用（11-06）
REG = re.compile(r"弱链接\[([^\]]*)\]：([A-Za-z0-9_]+)")
WEAK = re.compile(r"\b([A-Za-z_][A-Za-z0-9_]*)\s*\([^;{}]*\)\s*__attribute__\(\(weak_import\)\)")


def decl_files(root=ROOT, place=None):
    globs = DECL_GLOBS + (() if place is None or place in APPLE_PLACES else ANDROID_DECL_GLOBS)
    return sorted(p for g in globs for p in Path(root).glob(g))


def registered(place, root=ROOT):
    out = set()
    for p in decl_files(root, place):
        for m in REG.finditer(p.read_text(errors="replace")):
            if place in [s.strip() for s in m.group(1).split(",")]:
                out.add(m.group(2))
    return out


def u_flags(symbols):
    """放行参数的唯一生成处：按符号名给 ld64 的 -U（登记表与 android/tests/host_link.py 按目标文件实算的弱引用集都走这里）"""
    return ["-Wl,-U,_" + s for s in sorted(symbols)]


def flags(place, root=ROOT):
    return u_flags(registered(place, root))


def missing(root=ROOT):
    host = registered("host", root)
    bad = []
    for p in sorted(Path(root).glob("runtime/src/*.c")):
        for n, line in enumerate(p.read_text(errors="replace").splitlines(), 1):
            for m in WEAK.finditer(line):
                if m.group(1) not in host:
                    bad.append((p.relative_to(root), n, m.group(1)))
    return bad


HANDWRITTEN = re.compile(r"-Wl,-U")   # 全仓（除本工具与 .md 历史记录）不许出现：放行参数只从源码登记生成


def handwritten(root=ROOT):
    """手写的链接放行参数（11-01：织梦岛两次、t_nvn_m3 一次都是某处手抄漏了符号）：make 读 $(call S2A_WEAK_U,<场合>)，脚本 / 工程读 weak_link_decl.py flags <场合>"""
    import subprocess
    files = subprocess.run(["git", "-C", str(root), "ls-files", "-z"], capture_output=True).stdout.decode().split("\0")
    bad = []
    for rel in files:
        if not rel or rel == "tools/weak_link_decl.py" or rel.endswith(".md") or rel.startswith("compat/tree/"):
            continue
        p = Path(root) / rel
        if not p.is_file() or p.is_symlink():
            continue
        data = p.read_bytes()
        if b"-Wl,-U" not in data or b"\0" in data:
            continue
        for n, line in enumerate(data.decode(errors="replace").splitlines(), 1):
            if HANDWRITTEN.search(line):
                bad.append((rel, n, line.strip()[:120]))
    return bad


def main(argv):
    if argv[1:2] == ["check"]:
        bad, hand = missing(), handwritten()
        for path, n, flag in hand:
            print(f"【红】{path}:{n} 手写了链接放行参数（{flag}）：make 改读 $(call S2A_WEAK_U,<场合>) / $(NVN_TEST_WEAK)，脚本改读 python3 tools/weak_link_decl.py flags <场合>，"
                  "符号在引用它的源文件里登记「// 弱链接[<场合>]：<符号>」一处")
        for path, n, sym in bad:
            print(f"【红】弱符号 {sym}（{path}:{n} 声明 weak_import）没有登记：在引用它的源文件里加一行「// 弱链接[host]：{sym}（谁提供）」，"
                  "Mac 宿主、原生单测与探针、Mac 图形测试的放行参数都从这行生成，不要再手改链接行")
        print(f"弱链接登记：runtime/src 的 weak_import 已登记 {'全部' if not bad else '缺 ' + str(len(bad)) + ' 个'}（已登记 host 场合 {len(registered('host'))} 个）")
        print(f"弱链接登记：全仓手写链接放行参数 {len(hand)} 处")
        return 1 if bad or hand else 0
    if argv[1:2] == ["flags"] and len(argv) == 3:
        print(" ".join(flags(argv[2])))
        return 0
    print(__doc__ or "用法：weak_link_decl.py check | flags <场合>", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
