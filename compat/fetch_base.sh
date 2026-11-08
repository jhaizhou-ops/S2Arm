#!/bin/bash
# 取兼容层的上游基线：按 compat/UPSTREAM 记录的提交号，从上游浅取那一个提交的对象到本仓库（refs/compat/upstream）。
# 全新克隆后跑一次；之后 compat/verify.sh 核「上游 + 补丁 = 树内源码」不再需要网络。
# 用法：compat/fetch_base.sh            已有对象就直接退出 0
#       S2A_UPSTREAM_URL=<地址> compat/fetch_base.sh   指定上游或镜像（缺省依次试官方与 GitHub 镜像）
# 退出码：0 已就绪；2 取不到（打印试过的地址）。
set -euo pipefail
ROOT=$(git -C "$(dirname "$0")" rev-parse --show-toplevel); cd "$ROOT"
COMMIT=$(awk -F'\t' '$1=="commit"{print $2}' compat/UPSTREAM)
[ -n "$COMMIT" ] || { echo "compat/UPSTREAM 缺 commit 行" >&2; exit 2; }
have() { git cat-file -e "$COMMIT^{commit}" 2>/dev/null; }
if have; then git update-ref refs/compat/upstream "$COMMIT"; echo "上游基线已就绪：${COMMIT:0:12}"; exit 0; fi
URLS=${S2A_UPSTREAM_URL:-"https://git.ryujinx.app/ryubing/ryujinx.git https://github.com/Stella-sea/ryujinx-admin.git"}
for u in $URLS; do
    echo "取上游基线 ${COMMIT:0:12} ← $u"
    if git fetch -q --depth 1 --no-tags "$u" "$COMMIT:refs/compat/upstream" && have; then
        echo "上游基线已就绪：${COMMIT:0:12}"; exit 0
    fi
done
echo "取不到上游提交 $COMMIT（试过：$URLS）。可设 S2A_UPSTREAM_URL 指向含该提交的镜像。" >&2
exit 2
