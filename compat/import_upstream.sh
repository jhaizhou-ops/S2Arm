#!/bin/bash
# 把 Ryujinx 上游某个提交的原样源码（子集）导入 compat/tree/，并写 compat/UPSTREAM。
# 只在锁版本 / 升版本时用；日常改动一律走 patches/（见 compat/README.md）。
# 用法：import_upstream.sh <上游 git 仓库目录> <提交>
#       import_upstream.sh --add <上游 git 仓库目录> <路径…>   在已锁定的提交上补导路径（如 src/Ryujinx.Graphics.Vulkan），
#                                                            不动已有的树与补丁，只往 tree/ 加原样文件、往 UPSTREAM 加 path 行
#   上游仓库要能取到该提交的全部对象（官方 git.ryujinx.app；镜像见 UPSTREAM 的 source 行）。
# 导入后自检：tree/ 下每个导入路径的 git 对象号必须与上游提交里同一路径的对象号相同（逐字节原样的机械证明）。
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); TREE=$HERE/tree

if [ "${1:-}" = "--add" ]; then
    UP=$2; shift 2
    FULL=$(awk -F'\t' '$1=="commit"{print $2}' "$HERE/UPSTREAM")
    for p in "$@"; do
        awk -F'\t' -v p="$p" '$1=="path" && $2==p {f=1} END {exit !f}' "$HERE/UPSTREAM" && { echo "已在子集：$p" >&2; exit 1; }
        [ -e "$TREE/$p" ] && { echo "树里已有 ${p}（不是原样导入的？）" >&2; exit 1; }
        git -C "$UP" archive --format=tar "$FULL" -- "$p" | tar -x -C "$TREE"
        bad=0; n=0
        while IFS=$'\t' read -r meta path; do
            id=${meta##* }; n=$((n+1))
            [ "$(git hash-object --no-filters "$TREE/$path")" = "$id" ] || { echo "不一致：$path" >&2; bad=$((bad+1)); }
        done < <(git -C "$UP" ls-tree -r "$FULL" -- "$p" | awk -F'\t' '$1 ~ / blob /')
        [ $bad -eq 0 ] || { echo "补导自检失败：$p $bad / $n" >&2; exit 1; }
        git -C "$UP" ls-tree "$FULL" -- "$p" | awk -F'\t' -v p="$p" '{split($1,a," "); print "path\t" p "\t" a[3] "\t" a[1]}' >> "$HERE/UPSTREAM"
        old=$(awk -F'\t' '$1=="files"{print $2}' "$HERE/UPSTREAM")
        sed -i '' "s/^files	$old$/files	$((old + n))/" "$HERE/UPSTREAM"
        echo "已补导 ${p}：$n 个文件，逐字节与上游 ${FULL:0:12} 一致（先单独提交这一笔「上游原样补导」，verify.sh 要从历史里取它的对象）"
    done
    exit 0
fi

UP=$1; REV=$2
# 子集：服务（HLE / Horizon）、声音、显卡、视频解码、CPU 接口与内存、输入、单测；不收界面、OpenGL / Vulkan、SDL / OpenAL / SoundIo 后端
PROJ=(ARMeilleure Ryujinx.Audio Ryujinx.Audio.Backends.Apple Ryujinx.Common Ryujinx.Cpu
      Ryujinx.Graphics.Device Ryujinx.Graphics.GAL Ryujinx.Graphics.Gpu Ryujinx.Graphics.Host1x
      Ryujinx.Graphics.Nvdec Ryujinx.Graphics.Nvdec.FFmpeg Ryujinx.Graphics.Nvdec.Vp9 Ryujinx.Graphics.Shader
      Ryujinx.Graphics.Texture Ryujinx.Graphics.Vic Ryujinx.Graphics.Video
      Ryujinx.HLE Ryujinx.HLE.Generators Ryujinx.Horizon Ryujinx.Horizon.Common Ryujinx.Horizon.Generators
      Ryujinx.Horizon.Kernel.Generators Ryujinx.Input Ryujinx.Memory
      Ryujinx.Tests.Memory Spv.Generator)   # Ryujinx.Tests / Ryujinx.Tests.Unicorn 10-30 删（ARMeilleure CPU 对拍，S2Arm 不编不跑；Unicorn 依赖随之去掉）
ROOTF=(.editorconfig .gitignore Directory.Build.props Directory.Packages.props LICENSE.txt global.json nuget.config)

PATHS=("${ROOTF[@]}"); for p in "${PROJ[@]}"; do PATHS+=("src/$p"); done
FULL=$(git -C "$UP" rev-parse "$REV^{commit}")
rm -rf "$TREE"; mkdir -p "$TREE"
# 直接从上游对象导出（不经 checkout 的换行转换），保证逐字节原样
git -C "$UP" archive --format=tar "$FULL" -- "${PATHS[@]}" | tar -x -C "$TREE"

# 自检：本地文件的对象号 = 上游对象号
bad=0; n=0
while IFS=$'\t' read -r meta path; do
    id=${meta##* }
    h=$(git hash-object --no-filters "$TREE/$path"); n=$((n+1))
    [ "$h" = "$id" ] || { echo "不一致：$path" >&2; bad=$((bad+1)); }
done < <(git -C "$UP" ls-tree -r "$FULL" -- "${PATHS[@]}" | awk -F'\t' '$1 ~ / blob /')
[ $bad -eq 0 ] || { echo "导入自检失败：$bad / $n 个文件与上游对象不一致" >&2; exit 1; }

{
    echo "# Ryujinx 上游锁定版本（import_upstream.sh 生成，勿手改）"
    echo "upstream	Ryubing/Ryujinx（git.ryujinx.app/ryubing/ryujinx）"
    echo "commit	$FULL"
    echo "commit_date	$(git -C "$UP" log -1 --format=%cI "$FULL")"
    echo "commit_subject	$(git -C "$UP" log -1 --format=%s "$FULL")"
    echo "files	$n"
    # path 行：路径、上游对象号、模式（verify.sh 据此用 git mktree 复原上游子集的根树）
    for p in "${PATHS[@]}"; do git -C "$UP" ls-tree "$FULL" -- "$p" | awk -F'\t' -v p="$p" '{split($1,a," "); print "path\t" p "\t" a[3] "\t" a[1]}'; done
} > "$HERE/UPSTREAM"
echo "已导入 ${FULL}：${#PATHS[@]} 个路径、$n 个文件，逐字节与上游一致"
