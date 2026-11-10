# Independent Opus recipe. Source SHA and exact toolchain enter its key.
build_opus() (
    set -euo pipefail
    local target work key
    key=$(codec_recipe_key opus "$opus_sha" "$repo_dir/android/codecs/opus-build.sh")
    target=$cache_root/codecs/opus-$opus_ver-$key
    if ! codec_cached "$target"; then
        work=$(mktemp -d "$cache_root/codecs/opus-build.XXXXXX")
        trap 'rm -rf "$work"' EXIT
        codec_unpack "$opus_sha" "$work" wrapped
        mkdir "$work/obj" "$work/result" "$work/result/include"
        # __FILE__（assert/日志）必须与随机 mktemp 目录无关，否则同一路重跑、两路之间都不可复现。
        (cd "$work/obj" && CC=$cc AR=llvm-ar RANLIB=llvm-ranlib \
            CFLAGS="-O2 -fPIC -ffile-prefix-map=$work=opus -fmacro-prefix-map=$work=opus" "$work/src/configure" \
            --host=aarch64-linux-android --enable-static --disable-shared --disable-doc --disable-extra-programs \
            --disable-rtcd --disable-dependency-tracking > "$work/configure.log" 2>&1 \
            && make -j"$codec_jobs" > "$work/make.log" 2>&1) || { tail -20 "$work"/*.log >&2; exit 1; }
        cp "$work/obj/.libs/libopus.a" "$work/result/"
        cp "$work/src/include/"*.h "$work/result/include/"
        cp "$work/src/COPYING" "$work/result/"
        codec_publish "$work/result" "$target"
    fi
    codec_shim s2a_opus "$target/libopus.a" "$target/include" "$target" "$repo_dir/services/opus/s2a_opus.c"
    cp "$target/COPYING" "$licenses/opus-COPYING.txt"
)
