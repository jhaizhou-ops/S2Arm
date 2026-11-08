#!/usr/bin/env python3
# 着色器缓存键里「烘焙脚本与工具」一项（graphics/tools/shader_pack.sh key_of ④）：按提交 HEAD 里的文件内容算，但去掉只改注释 / 空行的差别。
#   10-23 换键批：原先整份文件 blob 哈希进键，脚本里补一行注释也让九款整份重烘；这里只比「代码行」，改代码（含 #include / #pragma / #define 等预处理行）照样变键。
# 用法：key_norm.py <仓库根> <相对路径>…    输出一行 sha256（按给的顺序逐个文件：路径 + 规范化内容）
# 规范化：
#   .py / .sh：整行注释去掉——去掉行首空白后以 # 开头、且 # 后面不是 ASCII 字母或 !（#include、#pragma、#define、#! 等照样算代码）；行尾空白去掉；空行去掉
#   .c / .m / .h / .cs：整行 // 注释去掉（.cs 10-24 起：翻译器 C# 源码进着色器键，补注释不再让九款重烘）、行尾空白去掉、空行去掉（/* */ 块注释不动：少见，误判为代码只会多变键、不会漏变）
#   其它：原样
#   行内尾注释不动（# 可能在字符串里，去掉有漏变键的风险）
import hashlib, re, subprocess, sys

_PY_COMMENT = re.compile(r'^\s*#(?![A-Za-z!])')
_C_COMMENT = re.compile(r'^\s*//')

def norm(path, data):
    if path.endswith(('.py', '.sh')): pat = _PY_COMMENT
    elif path.endswith(('.c', '.m', '.h', '.cs')): pat = _C_COMMENT
    else: return data
    out = []
    for l in data.decode('utf-8', 'surrogateescape').split('\n'):
        l = l.rstrip()
        if not l or pat.match(l): continue
        out.append(l)
    return '\n'.join(out).encode('utf-8', 'surrogateescape')

def main():
    root, files = sys.argv[1], sys.argv[2:]
    h = hashlib.sha256()
    for f in files:
        p = subprocess.run(['git', '-C', root, 'show', f'HEAD:{f}'], capture_output=True)
        if p.returncode: sys.exit(f'key_norm：HEAD 里没有 {f}')
        h.update(f.encode() + b'\0' + norm(f, p.stdout) + b'\0')
    print(h.hexdigest())

if __name__ == '__main__': main()
