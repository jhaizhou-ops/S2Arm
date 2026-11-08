"""D2：把已解析的 plan 拒收原因映射成说明；不读日志、不决定补丁状态。

生产依据：pack/cpatch.py 的 plan() 六条 why 分支。供调用方使用
`describe_reason(row["reason"])`，其中 row 可来自 C4 的既有 TSV。
不属于这六条完整模板的字符串原样返回 unknown，包括 prune 的缺口原因。
"""

import re

# 模块是生产者的文件名，不造 main/sdk 白名单，也不剥掉空格或 Unicode。
# TAB/CR/LF/NUL 会破坏原日志边界；本模块不尝试修复或重新解析这些字段。
_MODULE = r"[^\t\r\n\x00]+"
_HEX = r"-?0x(?:0|[1-9a-f][0-9a-f]*)"
# scan() 的 sha256 字段只是截前 16 字符，未校验 hex；不能假定另一补丁
# 编号一定是合法摘要。缺 sha256 时才是路径摘要，二者都不在这里查证。
_PATCH = r"(?:widescreen|fps|gfx):[^\t\r\n\x00]{1,16}"
_RULES = (
    (
        re.compile(rf"写入 {_HEX}\+(?:0|[1-9][0-9]*) 超出模块映像"),
        "outside_image",
        "这次筛选未收录：补丁要修改的位置超出了游戏程序模块的范围。",
    ),
    (
        re.compile(rf"与 {_PATCH} 改同一处 {_MODULE}\+{_HEX}"),
        "patch_conflict",
        "这次筛选未收录：这份补丁与另一份补丁修改了同一位置。",
    ),
    (
        re.compile(rf"数据写入 {_MODULE}\+{_HEX} 落在代码段末页上（只读可执行，运行时写不了）"),
        "readonly_code_page",
        "这次筛选未收录：补丁要修改的数据位于运行时不可写的代码页。",
    ),
    (
        re.compile(
            rf"改到我方改写点 {_MODULE}\+{_HEX}（宽屏点 / x18 等，两套改动叠在同一条指令上）"
        ),
        "rewrite_conflict",
        "这次筛选未收录：补丁与 S2Arm 的代码改写位置重叠。",
    ),
    (
        re.compile(re.escape("本款已有我方帧率表（fps.tsv），社区帧率类不收")),
        "builtin_fps",
        "这次筛选未收录：游戏已有 S2Arm 帧率方案，不再收录社区帧率补丁。",
    ),
    (
        re.compile(rf"{_MODULE} 已有 64 份补丁（槽 2046 位数用尽）"),
        "module_limit",
        "这次筛选未收录：这个程序模块已达到 64 份补丁的上限。",
    ),
)


def describe_reason(reason: str) -> dict[str, str]:
    """返回新的 {code, message_zh, raw}；只解释一条事件，不改原文或输入。

    未知原因（包括空字符串）不是成功：code 为 unknown，raw 逐字保留。
    调用者负责先按日志/TSV 合同解析，并按其 UI 的普通文本规则显示 raw。
    """
    if not isinstance(reason, str):
        raise TypeError("reason 必须是字符串")
    if reason.startswith("改写器缺口："):
        return dict(code="unknown", message_zh="此条拒收原因尚无对应说明，请查看原文。", raw=reason)
    for pattern, code, message in _RULES:
        if pattern.fullmatch(reason):
            return dict(code=code, message_zh=message, raw=reason)
    return dict(code="unknown", message_zh="此条拒收原因尚无对应说明，请查看原文。", raw=reason)
