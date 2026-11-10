# Independent recipe matching the shared services/vpx build options: VP8 and VP9 decoders, with S2Arm's NVDEC hook patch
# (services/vpx/patches, design docs/设计_原生VP9/design_phase2_B.md). The patch bytes are part of the recipe key.
build_vpx() (
    set -euo pipefail
    local target work key
    key=$(codec_recipe_key vpx "$vpx_sha" "$repo_dir/android/codecs/vpx-build.sh" "$repo_dir/services/vpx/patches/0001-s2a-vp9-nvdec-hook.patch")
    target=$cache_root/codecs/vpx-$vpx_ver-$key
    if ! codec_cached "$target"; then
        work=$(mktemp -d "$cache_root/codecs/vpx-build.XXXXXX")
        trap 'rm -rf "$work"' EXIT
        codec_unpack "$vpx_sha" "$work" wrapped
        patch -p1 -s -d "$work/src" < "$repo_dir/services/vpx/patches/0001-s2a-vp9-nvdec-hook.patch" \
            || { echo "libvpx patch does not apply: services/vpx/patches/0001-s2a-vp9-nvdec-hook.patch" >&2; exit 1; }
        mkdir "$work/obj" "$work/result" "$work/result/include"
        (cd "$work/obj" && CC=$cc CXX="$cc++" AR=llvm-ar LD=$cc NM=llvm-nm STRIP=llvm-strip "$work/src/configure" \
            --target=arm64-android-gcc \
            --disable-vp8-encoder --enable-vp8-decoder --disable-vp9-encoder --enable-vp9-decoder --disable-examples --disable-tools --disable-docs \
            --disable-unit-tests --disable-webm-io --disable-libyuv --enable-pic --enable-static --disable-shared --size-limit=8192x8192 \
            > "$work/configure.log" 2>&1 && make -j"$codec_jobs" > "$work/make.log" 2>&1) || { tail -20 "$work"/*.log >&2; exit 1; }
        cp "$work/obj/libvpx.a" "$work/result/"
        cp -R "$work/src/vpx" "$work/result/include/"
        cp "$work/src/LICENSE" "$work/src/PATENTS" "$work/result/"
        codec_publish "$work/result" "$target"
    fi
    codec_shim s2a_vpx "$target/libvpx.a" "$target/include" "$target" "$repo_dir/services/vpx/s2a_vp8.c" "$repo_dir/services/vpx/s2a_vp9.c"
    cp "$target/LICENSE" "$licenses/libvpx-LICENSE.txt"
    cp "$target/PATENTS" "$licenses/libvpx-PATENTS.txt"
)
