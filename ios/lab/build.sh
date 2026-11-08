#!/bin/bash
# Build the standalone workbench; device/team are always chosen by the caller.
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
device= team= bundle=local.s2arm.inputlab install=0 launch=0 provisioning=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        --device) device=${2:?missing device}; shift 2 ;;
        --team-id) team=${2:?missing team}; shift 2 ;;
        --bundle-id) bundle=${2:?missing bundle id}; shift 2 ;;
        --developer-dir) export DEVELOPER_DIR=${2:?missing Xcode path}; shift 2 ;;
        --allow-provisioning-updates) provisioning=1; shift ;;
        --install) install=1; shift ;;
        --launch) launch=1; install=1; shift ;;
        *) echo "Usage: $0 --device <UDID> --team-id <team> [--bundle-id <id>] [--developer-dir <path>] [--allow-provisioning-updates] [--install] [--launch]" >&2; exit 2 ;;
    esac
done
[ -n "$device" ] && [ -n "$team" ] || { echo "Specify --device and --team-id" >&2; exit 2; }
export DEVELOPER_DIR=${DEVELOPER_DIR:-${S2A_DEVELOPER_DIR:-$(xcode-select -p)}}
cd "$root"
command -v xcodegen >/dev/null || { echo "XcodeGen is required; no software was installed" >&2; exit 2; }
lab_weak=$(python3 tools/weak_link_decl.py flags lab)   # project.yml OTHER_LDFLAGS 读 $(S2A_LAB_WEAK)
[ -n "$lab_weak" ] || { echo "弱链接登记读不出 lab 场合（tools/weak_link_decl.py flags lab）" >&2; exit 2; }
xcodegen generate --spec ios/lab/project.yml --project-root . --project build/f01-lab
args=()
[ "$provisioning" = 0 ] || args+=(-allowProvisioningUpdates)
xcodebuild -project build/f01-lab/S2ArmInputLab.xcodeproj -scheme S2ArmInputLab \
    -configuration Debug -destination "id=$device" -derivedDataPath build/f01-lab/DerivedData \
    "DEVELOPMENT_TEAM=$team" "PRODUCT_BUNDLE_IDENTIFIER=$bundle" "S2A_LAB_WEAK=$lab_weak" "${args[@]}" build
app="$root/build/f01-lab/DerivedData/Build/Products/Debug-iphoneos/S2ArmInputLab.app"
codesign --verify --deep --strict "$app"
if [ "$install" = 1 ]; then xcrun devicectl device install app --device "$device" "$app"; fi
if [ "$launch" = 1 ]; then xcrun devicectl device process launch --device "$device" "$bundle"; fi
echo "Input workbench built: $app (no guest/game startup)"
