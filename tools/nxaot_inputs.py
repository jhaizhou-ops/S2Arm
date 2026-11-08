#!/usr/bin/env python3
"""列出 NativeAOT 镜像（services/aot/S2A.Aot.csproj）整个工程闭包的编译输入：每个工程的 Compile / EmbeddedResource / AdditionalFiles
加工程文件本身，沿 ProjectReference 递归。只读求值（dotnet msbuild -getItem），不编。输出仓库内的相对路径，一行一个；仓库外的（NuGet 包、SDK）不列。
用法：python3 tools/nxaot_inputs.py <仓库根>（DOTNET 可指 dotnet）。tests/nxaot_key_test.sh 用它核 services/nxaot.sh 的缓存键覆盖全部输入。"""
import json, os, subprocess, sys

root = os.path.realpath(sys.argv[1])
dn = os.environ.get('DOTNET') or os.path.expanduser('~/.dotnet/dotnet')
seen, todo, out = set(), [os.path.join(root, 'services/aot/S2A.Aot.csproj')], set()
while todo:
    p = os.path.realpath(todo.pop())
    if p in seen:
        continue
    seen.add(p)
    r = subprocess.run([dn, 'msbuild', p, '-getItem:Compile', '-getItem:EmbeddedResource', '-getItem:AdditionalFiles', '-getItem:ProjectReference',
                        '-p:Configuration=Release', '-p:RuntimeIdentifier=ios-arm64'], capture_output=True, text=True)
    if r.returncode:
        sys.exit(f'nxaot_inputs：求值失败 {p}：{r.stdout[-300:]}{r.stderr[-300:]}')
    items, d = json.loads(r.stdout).get('Items', {}), os.path.dirname(p)
    out.add(p)
    for k in ('Compile', 'EmbeddedResource', 'AdditionalFiles'):
        for it in items.get(k, []):
            out.add(os.path.realpath(it.get('FullPath') or os.path.join(d, it['Identity'])))
    todo += [it.get('FullPath') or os.path.join(d, it['Identity']) for it in items.get('ProjectReference', [])]
print(f'nxaot_inputs：{len(seen)} 个工程', file=sys.stderr)
for f in sorted(out):
    if f.startswith(root + os.sep) and '/obj/' not in f and '/bin/' not in f:   # obj/ 下是构建时生成的（如 AbiHash 生成的 .g.cs），其来源已在键里
        print(os.path.relpath(f, root))
