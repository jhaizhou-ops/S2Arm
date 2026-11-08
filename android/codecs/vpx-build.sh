# Independent VP8-only recipe, matching the shared services/vpx build options.
build_vpx() (
    set -euo pipefail
    local target work key
    key=$(codec_recipe_key vpx "$vpx_sha" "$repo_dir/android/codecs/vpx-build.sh")
    target=$cache_root/codecs/vpx-$vpx_ver-$key
    if ! codec_cached "$target"; then
        work=$(mktemp -d "$cache_root/codecs/vpx-build.XXXXXX")
        trap 'rm -rf "$work"' EXIT
        codec_unpack "$vpx_sha" "$work" wrapped
        mkdir "$work/obj" "$work/result" "$work/result/include"
        (cd "$work/obj" && CC=$cc CXX="$cc++" AR=llvm-ar LD=$cc NM=llvm-nm STRIP=llvm-strip "$work/src/configure" \
            --target=arm64-android-gcc \
            --disable-vp9 --disable-vp8-encoder --enable-vp8-decoder --disable-examples --disable-tools --disable-docs \
            --disable-unit-tests --disable-webm-io --disable-libyuv --enable-pic --enable-static --disable-shared --size-limit=8192x8192 \
            > "$work/configure.log" 2>&1 && make -j"$codec_jobs" > "$work/make.log" 2>&1) || { tail -20 "$work"/*.log >&2; exit 1; }
        cp "$work/obj/libvpx.a" "$work/result/"
        cp -R "$work/src/vpx" "$work/result/include/"
        cp "$work/src/LICENSE" "$work/src/PATENTS" "$work/result/"
        codec_publish "$work/result" "$target"
    fi
    codec_shim s2a_vpx "$target/libvpx.a" "$repo_dir/services/vpx/s2a_vp8.c" "$target/include" "$target"
    cp "$target/LICENSE" "$licenses/libvpx-LICENSE.txt"
    cp "$target/PATENTS" "$licenses/libvpx-PATENTS.txt"
)
