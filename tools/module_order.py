# Horizon 模块装载序（与 runtime/src/loader.c s2a_module_order_ok、BootContract.java 同一份规则）：
#   main 第一，subsdk0..N 按数字升序，sdk 最后；名单外的名（如 rtld——宿主自己扮演 rtld、从不装载 guest rtld）
#   排在 subsdk* 与 sdk 之间、按名定序。装载顺序决定全局符号绑定：默认可见性的已定义符号先装的模块胜出
#   （runtime/src/loader.c resolve_global；DT_INIT 逆序 = sdk → subsdk* → main）。
#   安卓包原先按字母排（main → sdk → subsdk*），subsdk 与 sdk 重名的导出会错绑到 sdk（11-06 Bloodstained 调查）；
#   subsdk10+ 也会排错位置（字母序 subsdk10 < subsdk2）。
import re

_SUBSDK = re.compile(r"subsdk[0-9]+\Z")


def _key(name):
    if name == "main":
        return (0, 0, "")
    if _SUBSDK.match(name):
        return (1, int(name[6:]), "")
    if name == "sdk":
        return (3, 0, "")
    return (2, 0, name)


def load_order(names):
    """把模块名排成 Horizon 装载序（输入可乱序）。"""
    return sorted(names, key=_key)


def is_load_order(names):
    """名单是否已是 Horizon 装载序（非空时第一个必须是 main）。"""
    names = list(names)
    return names == load_order(names) and (not names or names[0] == "main")
