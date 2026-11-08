# 固定版本源码包的共用下载 + 本机共享缓存（安卓 APK 准备、services/opus|vpx 共用；只定义函数，source 后用）。
# 11-01：准备标记一失效就从 GitHub 重下 openssl / libvpx 等源码包；列车 launchd 环境没代理时直连十几 KB/s、常 0 字节，
#   curl / gh api 没有进展判据，一次准备挂半小时以上。根修：按 SHA 内容寻址缓存（命中不联网）+ 下载按进展判挂死。
#
# 接口：
#   s2a_source_fetch <文件名> <URL> <sha256>
#       缓存 <缓存根>/sources/<sha256>/<文件名> 在且 SHA 对 → 直接打印该路径，不发起任何下载；
#       没有或 SHA 不对 → 下载到同目录临时文件，校验通过才 mv 落位（原子），打印路径；任何失败 → 【红】、返回非零。
#       缓存根 = ${S2A_BUILD_CACHE:-$HOME/.cache/s2arm-build}（docker 准备把宿主的 sources/ 挂到容器 /cache/sources，同一份）。
#   s2a_source_cache_dir
#       打印共享源码缓存目录 <缓存根>/sources（docker 准备挂载用）。
#   s2a_download <URL> <输出文件>
#       只下载、不缓存不校验（libavc 的 Gitiles 包字节不固定，由调用方按内容校验）。
#       github.com 的地址先走 gh api（有登录 / 代理配置时快），失败再走 curl；其余地址只走 curl。
#       每次尝试：S2A_FETCH_STALL_SECS（缺省 120）秒内收到的字节没涨 → 判「下载无进展」杀掉；
#       S2A_FETCH_MAX_SECS（缺省 900）秒整体上限 → 判「整体超时」杀掉。全部尝试失败 → 【红】写明 URL 与每次的原因。
#   代理只认环境（https_proxy 等，curl / gh 自己读），本文件不写任何代理地址。
#
# 并发：同一 sha 多方同时下载各写各的临时文件（mktemp），校验过才 mv -f 覆盖到同名终点，读方任何时刻只看到完整文件；
#   不删别人的文件，SHA 不对的旧文件也只靠 mv 覆盖替换。

s2a_source_cache_dir() {
    printf '%s/sources\n' "${S2A_BUILD_CACHE:-${HOME:?【红】源码缓存需要 HOME 或 S2A_BUILD_CACHE}/.cache/s2arm-build}"
}

_s2a_fetch_sha256() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
    else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

# 跑一个把内容写到 stdout 的下载命令，按进展 / 整体时限看守。成功返回 0；失败返回 1，原因写进 _s2a_fetch_reason。
_s2a_fetch_watch() {
    local out=$1 err=$2 stall=$3 max=$4 pid size last=-1 last_t start rc=0
    shift 4
    : > "$out"
    "$@" > "$out" 2> "$err" &
    pid=$!
    start=$SECONDS; last_t=$SECONDS
    while kill -0 "$pid" 2>/dev/null; do
        sleep 1
        size=$(wc -c < "$out" | tr -d ' ')
        if [ "$size" != "$last" ]; then last=$size; last_t=$SECONDS; fi
        if [ $((SECONDS - last_t)) -ge "$stall" ] || [ $((SECONDS - start)) -ge "$max" ]; then
            kill "$pid" 2>/dev/null || true
            wait "$pid" 2>/dev/null || true
            if [ $((SECONDS - start)) -ge "$max" ]; then
                _s2a_fetch_reason="整体超时：${max} 秒没下完（已收 ${size} 字节）"
            else
                _s2a_fetch_reason="下载无进展：${stall} 秒没收到新字节（已收 ${size} 字节）"
            fi
            return 1
        fi
    done
    wait "$pid" || rc=$?
    if [ "$rc" != 0 ]; then
        _s2a_fetch_reason="$1 退出码 ${rc}：$(tail -c 300 "$err" | tr '\n' ' ')"
        return 1
    fi
    return 0
}

s2a_download() (
    set -u
    url=$1 out=$2
    stall=${S2A_FETCH_STALL_SECS:-120} max=${S2A_FETCH_MAX_SECS:-900}
    err=$(mktemp "${out}.err.XXXXXX") || { echo "【红】下载失败 ${url}：建不了临时文件（$out 所在目录）" >&2; exit 1; }
    trap 'rm -f "$err"' EXIT
    reasons=
    case $url in
    https://github.com/*)
        if command -v gh >/dev/null 2>&1; then
            if _s2a_fetch_watch "$out" "$err" "$stall" "$max" gh api "$url"; then exit 0; fi
            reasons="gh api：${_s2a_fetch_reason}；"
        fi ;;
    esac
    command -v curl >/dev/null 2>&1 || { echo "【红】下载失败 ${url}：${reasons}没有 curl" >&2; exit 1; }
    if _s2a_fetch_watch "$out" "$err" "$stall" "$max" curl --fail --location --silent --show-error --no-buffer --connect-timeout 30 "$url"; then exit 0; fi
    reasons="${reasons}curl：${_s2a_fetch_reason}"
    case $reasons in
    *下载无进展*) echo "【红】下载无进展 ${url}：$reasons" >&2 ;;
    *) echo "【红】下载失败 ${url}：$reasons" >&2 ;;
    esac
    exit 1
)

s2a_source_fetch() (
    set -u
    name=$1 url=$2 sha=$3
    case $sha in *[!0-9a-f]*|'') echo "【红】源码包 $name 的 sha256 不合法：$sha" >&2; exit 1 ;; esac
    [ ${#sha} = 64 ] || { echo "【红】源码包 $name 的 sha256 不合法：$sha" >&2; exit 1; }
    case $name in */*|''|.*) echo "【红】源码包文件名不合法：$name" >&2; exit 1 ;; esac
    dir=$(s2a_source_cache_dir)/$sha || exit 1
    path=$dir/$name
    if [ -f "$path" ] && [ "$(_s2a_fetch_sha256 "$path")" = "$sha" ]; then
        printf '%s\n' "$path"; exit 0
    fi
    [ -f "$path" ] && echo "源码缓存 $path 校验不过，重新下载" >&2
    mkdir -p "$dir" || { echo "【红】建不了源码缓存目录 $dir" >&2; exit 1; }
    work=$(mktemp "$dir/.$name.XXXXXX") || { echo "【红】建不了源码缓存临时文件（${dir}）" >&2; exit 1; }
    trap 'rm -f "$work"' EXIT
    echo "下载源码 ${name}：$url" >&2
    s2a_download "$url" "$work" || exit 1
    actual=$(_s2a_fetch_sha256 "$work")
    [ "$actual" = "$sha" ] || { echo "【红】源码 $name sha256 不符：期望 ${sha}，实得 ${actual}（${url}）" >&2; exit 1; }
    mv -f "$work" "$path" || { echo "【红】源码 $name 落入缓存失败：$path" >&2; exit 1; }
    printf '%s\n' "$path"
)
