#!/usr/bin/env python3
"""把解析器的容量守卫去掉、并把循环条件恢复成改前写法（静默截断），产出反例变异体。

只给 tools/nvn_vk_program_binding_cap.sh 用：验证「去掉守卫就会静默丢绑定」的危险成立。
用法：nvn_vk_program_binding_cap_mutant.py <源码> <输出>
"""
import re
import sys

src, dst = sys.argv[1], sys.argv[2]
text = open(src, encoding="utf-8").read()
block = re.search(r"\n            if \(out->binding_count >= FD_MAX_BINDINGS\) \{.*?\n            \}\n",
                  text, re.S)
if not block:
    raise SystemExit("找不到容量守卫块（源码结构变了？）")
text = text.replace(block.group(0), "\n", 1)
old_loop = "for (int i = 0; i < n; i++) {"
if old_loop not in text:
    raise SystemExit("找不到绑定解析循环（源码结构变了？）")
text = text.replace(old_loop, "for (int i = 0; i < n && out->binding_count < FD_MAX_BINDINGS; i++) {", 1)
open(dst, "w", encoding="utf-8").write(text)
