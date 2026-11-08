#!/usr/bin/env python3
# 来源列路径一律 /（11-05 天眼勇者斗恶龙 XI S：Windows 上 shader_split 来源列 38892 行全是 \ 且带 ..\..\..\ 前缀，按来源分组的规则认不出，ps_game / ps_engine 全落 ps_other）。
#   Mac 上 os.sep 本来就是 /，这里用 ntpath（Windows 的路径函数）模拟。期望手写：
#   ① nxsh_extract._rel：ntpath 下 relpath('C:\r\a\b.bin', 'C:\r') → 'a/b.bin'
#   ② shader_split 旧版 pak 来源：挂载点 ../../../JackGame/Content/ + 条目名 → 'JackGame/Content/Env/x.uexp'（posixpath 归一、去 ../ 前缀；ntpath.normpath 会出 ..\..\..\JackGame\…）
#   ③ shader_split 不再用 os.path.normpath 归一 pak 内路径（两处），资源文件相对路径换成 /
import ntpath, os, posixpath, re, sys
from pathlib import Path
from unittest import mock

H = Path(__file__).resolve().parents[4]
bad = 0
def chk(name, want, got):
    global bad
    ok = want == got; bad += not ok
    print(f'{"通" if ok else "不通"} {name}：期望 {want!r} → 真结果 {got!r}')

sys.path.insert(0, str(H / 'graphics/tools/shbake'))
import nxsh_extract
with mock.patch.object(nxsh_extract.os, 'sep', '\\'), mock.patch.object(nxsh_extract.os.path, 'relpath', ntpath.relpath):
    chk('① nxsh_extract._rel 在 Windows 路径函数下出 /', 'a/b.bin', nxsh_extract._rel('C:\\r\\a\\b.bin', 'C:\\r'))
mount, name = '../../../JackGame/Content/', 'Env/x.uexp'
chk('② 旧版 pak 来源：posixpath 归一后去掉 ../ 前缀', 'JackGame/Content/Env/x.uexp', re.sub(r'^(\.\./)+', '', posixpath.normpath(mount + name)))
chk('② 对照：Windows 的 normpath 出反斜杠、../ 前缀去不掉（原缺陷）', '..\\..\\..\\JackGame\\Content\\Env\\x.uexp', re.sub(r'^(\.\./)+', '', ntpath.normpath(mount + name)))
src = (H / 'translator/shader_split.py').read_text(encoding='utf-8')
chk('③ shader_split 不再用 os.path.normpath 归一 pak 内路径', 0, len(re.findall(r'os\.path\.normpath\(pk\.mount', src)))
chk('③ 资源文件相对路径换成 /', True, "os.path.relpath(os.path.join(dp, f), romfs).replace(os.sep, '/')" in src)
print(f'来源列路径：失败 {bad}')
sys.exit(1 if bad else 0)
