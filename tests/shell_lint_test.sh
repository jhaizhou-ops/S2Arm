#!/bin/bash
# 门禁覆盖：*.sh
# 仓库里的 *.sh（compat/tree 上游原样除外）不许出现「$变量紧跟非 ASCII 字符」（例：美元符 + X + 全角逗号）——bash 5.3（mini）在 UTF-8 区域下把全角字符读进变量名，set -u 下直接「未绑定的变量」
# （10-20 测试机2 局：dev_run.sh 行 45 DEVNAME… 未绑定）；本机 bash 5.2 不报，只能靠静态检查拦。一律写 ${X}。
# 10-23 起扫全仓库：macOS 自带 /bin/bash 3.2 在 en_US / zh_CN.UTF-8（终端缺省）下同样报（不开 set -u 时静默展开成乱码），原先只扫 tools / pack / tests 顶层，
#   漏了 services/nxaot.sh 行 29（「键」后美元符 K 紧跟全角括号）——一键出包在缺省区域的终端里停在 make ios（Blade II 实测）。注释吞代码一项 10-28 起也扫全仓库（原先只查 tools / pack（含一层子目录）/ tests / services。
H=$(cd "$(dirname "$0")/.." && pwd)
python3 "$H/tests/shell_timeout_env_test.py" || exit $?
python3 "$H/tests/shell_fail_shapes_test.py" || exit $?
out=$(python3 - "$H" <<'PY'
import re, glob, sys, os
sys.path.insert(0, os.path.join(sys.argv[1], 'tests'))
from shell_timeout_env import violations
from shell_stdin_lint import lint as stdin_violations
from shell_fail_shapes import tail_rc, skip_exit0, auto_tests   # 11-01 审计「失败当成功」：tail 吃掉前段退出码 / 自动收的单测跳过分支 exit 0
pat = re.compile(r'\$([A-Za-z_][A-Za-z0-9_]*)(?=[^\x00-\x7f])')
tailrc = re.compile(r'=\$\(([^()]|\([^()]*\))*\|\s*(tr|head|tail|cut|sort|sed|awk|tee|wc|uniq)\b([^()]|\([^()]*\))*\)\s*&&')   # 10-23：x=$(… | tr …) && … 判的是 tr 的退出码（恒 0），秒级合入的交集判定因此全判重叠
eat = re.compile(r'\s#\s.*?(;\s*(done|then|fi|do|esac|exit|return|break|continue|\[\[?\s)|\|\|\s*(exit|return|break|continue|\{)|&&\s*(exit|return|break|continue)\b|\bfor \w+ in \$\(|\bwhile \[)')   # 行尾注释里出现代码 = 后面的命令被注释吞了（10-19 一天 5 次、10-20 oneshot 等结论循环被吞）。
#   10-28 质量线放宽：「; [ … ] || break」「; exit 1」「|| { …」也算——gate.sh 负载排队的跳出、app_only.sh / shcollect.sh 的出错处理都这样被吞，旧式只认 done/then/fi/do 没抓到；扫全仓库 0 误报
import subprocess
r = sys.argv[1]
top = set(glob.glob(f'{r}/tools/*.sh') + glob.glob(f'{r}/pack/*.sh') + glob.glob(f'{r}/pack/*/*.sh') + glob.glob(f'{r}/tests/*.sh') + glob.glob(f'{r}/services/*.sh') + glob.glob(f'{r}/services/*/*.sh'))
auto = set(auto_tests(r))
ls = subprocess.run(['git', '-C', r, 'ls-files', '-z', '*.sh'], capture_output=True).stdout.decode('utf-8').split('\0')
for f in sorted({os.path.join(r, x) for x in ls if x and not x.startswith('compat/tree/')} | top):
    source = open(f, encoding='utf-8').read()
    for i, message in stdin_violations(source, os.path.relpath(f, r)):
        print(f'{os.path.relpath(f, r)}:{i}: {message}')
    for i, message in tail_rc(source) + (skip_exit0(source) if os.path.relpath(f, r) in auto else []):
        print(f'{os.path.relpath(f, r)}:{i}: {message}')
    for i, name in violations(source):
        print(f'{os.path.relpath(f, r)}:{i}: timeout 把 {name}=… 当命令；改为 timeout N env {name}=… cmd')
    for i, l in enumerate(source.split('\n'), 1):
        for m in pat.finditer(l): print(f'{os.path.relpath(f, r)}:{i}: ${m.group(1)} 后紧跟非 ASCII')
        if not l.lstrip().startswith('#') and 're.compile(' not in l and tailrc.search(l): print(f'{os.path.relpath(f, r)}:{i}: $(… | 过滤命令) && 判的是管道尾巴的退出码（先取值，再按值判）')
        if not l.lstrip().startswith('#') and eat.search(l): print(f'{os.path.relpath(f, r)}:{i}: 行尾注释里有代码（被注释吞了？）')
PY
) || exit $?
n=$(printf '%s' "$out" | grep -c . ); echo "$out" | head -10
echo "期望 0 处「\$变量紧跟非 ASCII」/ 注释吞代码 / 管道尾巴退出码 / tail 吃掉前段退出码 / 单测跳过分支 exit 0 / timeout 后直接赋值 / while read 远端 stdin → 真结果 $n 处（扫仓库全部 .sh，compat/tree 除外）"; [ "$n" = 0 ]
