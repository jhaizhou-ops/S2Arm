#!/usr/bin/env bash
# 主机测试输出目录：每次运行一个独有目录，进程退出即删。
#
# #919（10-29 安卓门禁偶发红）根因：输出目录原先固定为 <仓库>/build/android-host-tests。
#   · 同一棵树上两份门禁同时跑（列车本机步与各线自检、人工重跑叠在一起）时，两份都在写
#     $out/java：javac 不是原子写 .class（先 truncate 再写），另一个进程的
#     `java -cp $out/java` 正好读到半截，红行是
#     java.lang.ClassFormatError: Truncated class file（加载主类 GameTouchTest / GameSessionTest）。
#   · 目录还跨次复用：上一次被中断（超时被杀 / Ctrl-C）留下的半写文件，下一次首跑当输入读。
# 两种都是共享状态，改成按运行隔离即可确定性消除：不重试、不放宽超时。
s2a_host_out() {
    local base=${S2A_HOST_OUT_ROOT:-${TMPDIR:-/tmp}}
    base=${base%/}
    [ -n "$base" ] || base=/
    [ -d "$base" ] || mkdir -p "$base" || return 1
    mktemp -d "$base/s2a-android-host-tests.XXXXXXXX"
}
