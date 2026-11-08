#!/bin/bash
# Tool-key contracts use synthetic files and controlled version probes only.
set -euo pipefail
R=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/repo/graphics/tools/shbake" "$T/repo/graphics/metal/tools" "$T/repo/tools" "$T/bin" "$T/data/romfs" "$T/data/exefs" "$T/prebuilt/gal" "$T/prebuilt/shbake"
cp "$R/graphics/tools/shader_pack.sh" "$T/repo/graphics/tools/"
# romfs_list.py：input_fp 的 RomFS 文件清单经它（仓库里唯一的 RomFS 遍历）
mkdir -p "$T/repo/graphics/nvn/tools"; cp "$R/graphics/nvn/tools/romfs_list.py" "$T/repo/graphics/nvn/tools/"
# key_of 的「烘焙脚本」项由 key_norm.py 算（只算代码行），是 shader_pack.sh --key 的真依赖
cp "$R/graphics/tools/shbake/key_norm.py" "$T/repo/graphics/tools/shbake/"
# 出包目标对也进键（10-29，key_of 调 pack/jobs/archs.py pairs，推导不出报红）：推导要的脚本、目标表、跑局机清单原样带上
mkdir -p "$T/repo/pack/jobs"; cp "$R/pack/jobs/archs.py" "$T/repo/pack/jobs/"; cp "$R/pack/pso_targets.tsv" "$R/pack/our_devices.tsv" "$T/repo/pack/"
printf 'export IPHONEOS_DEPLOYMENT_TARGET=18.0 MACOSX_DEPLOYMENT_TARGET=15.0\n' > "$T/repo/tools/toolchain.sh"
# 闭包清单桩：打印一个落在翻译器键过滤范围里的文件（shader_pack.sh tool_keys 只取决定翻译输出的源码，过滤后为空即报红）
printf 'print("graphics/tools/shbake/Fake.cs")\n' > "$T/repo/tools/csproj_closure.py"; printf 'class Fake {}\n' > "$T/repo/graphics/tools/shbake/Fake.cs"
printf 'echo source-gal-closure\n' > "$T/repo/graphics/tools/shbake/xc_key.sh"
printf 'probe' > "$T/repo/graphics/metal/tools/gal_offline.py"
printf 'code' > "$T/data/exefs/main"; printf data > "$T/data/romfs/file"
printf '{}' > "$T/prebuilt/prepare.json"
for f in gal/gal_xc shbake/S2A.ShBake shbake/gpu_arch; do printf '#!/bin/sh\nexit 0\n' > "$T/prebuilt/$f"; chmod +x "$T/prebuilt/$f"; done
printf original > "$T/prebuilt/shbake/support.dll"
cat > "$T/bin/xcrun" <<'X'
#!/bin/bash
printf '%s\n' "$*" >> "$PROBE_LOG"
case "$*" in *--show-sdk-version*) echo "${SDK_REV:-27.1}";; *metal*--version*) echo "Apple metal ${METAL_REV:-32023}";; *) exit 1;; esac
X
chmod +x "$T/bin/xcrun"
( cd "$T/repo"; git init -q; git add .; git -c user.name=test -c user.email=test@localhost commit -qm fixture )
export PATH="$T/bin:$PATH" PROBE_LOG="$T/probes"
key() { bash "$T/repo/graphics/tools/shader_pack.sh" --key "$T/data"; }
unset S2A_PREBUILT_TOOLS S2A_PACK_PLAT SDK_REV METAL_REV
base=$(key)
grep -q -- '--sdk iphoneos --show-sdk-version' "$PROBE_LOG"
grep -q -- '--sdk macosx --show-sdk-version' "$PROBE_LOG"
grep -q -- '-sdk iphoneos metal --version' "$PROBE_LOG"
printf changed > "$T/prebuilt/shbake/support.dll"
[ "$(key)" = "$base" ]
export S2A_PREBUILT_TOOLS="$T/prebuilt" S2A_PACK_PLAT=macos
mac=$(key)
printf replaced > "$T/prebuilt/shbake/support.dll"
[ "$(key)" != "$mac" ]
mac=$(key); printf '#!/bin/sh\nexit 1\n' > "$T/prebuilt/gal/gal_xc"
[ "$(key)" != "$mac" ]
mac=$(key)
[ "$(SDK_REV=28.0 key)" != "$mac" ]
[ "$(METAL_REV=99999 key)" != "$mac" ]
[ "$(S2A_PACK_PLAT=ios key)" != "$mac" ]
# Relocating the identical tool directory must preserve its content key.
cp -cR "$T/prebuilt" "$T/relocated tools"
[ "$(S2A_PREBUILT_TOOLS="$T/relocated tools" key)" = "$mac" ]
rm "$T/prebuilt/gal/gal_xc"
! key > /dev/null 2>&1
echo 'Default version probes, binary/assembly changes, SDK/Metal changes, relocation and missing-tool rejection passed'
