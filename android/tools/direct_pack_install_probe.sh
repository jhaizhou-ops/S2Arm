#!/usr/bin/env bash
# C7（装包阶段）：direct 产物 v1 在真机上走一遍装包事务 —— 装成功 / 篡改被拒 / 缺文件被拒 / 同一游戏回退 generic。
# 用 make_pack.py --synthetic 造合成包（无游戏数据），只验证"设备端 BootContract 真的消费
# requiredFeatures + graphics.v1.json"，不涉及 direct 运行时、首装后启动或完整游戏。
#
# 前提：make_pack 的 rewrite 需要 capstone + lz4 的 python，用 S2A_PY 指定（默认 python3）：
#   python3 -m venv /tmp/s2a-venv && /tmp/s2a-venv/bin/pip install lz4 capstone
#   S2A_PY=/tmp/s2a-venv/bin/python3 bash android/tools/direct_pack_install_probe.sh
# 设备上要装好 org.s2arm.android（主链包即可，引擎开关无关）。
set -euo pipefail
repo=$(cd "$(dirname "$0")/../.." && pwd)
py=${S2A_PY:-python3}
serial=${S2A_ADB:-$(adb devices | awk 'NR>1 && $2=="device" {print $1; exit}')}
[ -n "$serial" ] || { echo "no adb device; direct pack install probe NOT RUN" >&2; exit 2; }
"$py" -c 'import lz4, capstone' 2>/dev/null || { echo "S2A_PY 缺 lz4/capstone（make_pack rewrite 需要）" >&2; exit 2; }
adb_shell() { adb -s "$serial" shell "$@"; }
work=$(mktemp -d "${TMPDIR:-/tmp}/s2a-direct-pack.XXXXXX")
trap 'rm -rf "$work"' EXIT
import_dir=/sdcard/Android/data/org.s2arm.android/files/import
title=0100000000ABCDEF

"$py" - "$work/graphics.v1.json" <<'PY'
import json, sys
doc = {'schema': 's2a-graphics-v1', 'titleId': '0100000000ABCDEF',
       'gameContentRoot': 'sha256-' + 'a' * 64, 'moduleSetDigest': 'sha256-' + 'b' * 64,
       'frontend': 'nvn', 'backend': 'vulkan-direct', 'directABI': 1,
       'translatorClosure': 'd2r-1.0+synthetic', 'sourceParserVersion': 2,
       'runtimeCompilerABI': 's2a-direct-compile-v1',
       'profiles': [{'profileHash': 'sha256-' + 'c' * 64}],
       # 空清单：这个探针只验 requiredFeatures/描述文件的装包事务，不携带离线库文件。
       # 非空清单现在会被 make_pack 按“必须在 index 中且字节/摘要相符”校验。
       'files': []}
open(sys.argv[1], 'w').write(json.dumps(doc))
PY
PY="$py" "$py" "$repo/android/tools/make_pack.py" "$work/direct" --synthetic --direct-graphics "$work/graphics.v1.json" >/dev/null
PY="$py" "$py" "$repo/android/tools/make_pack.py" "$work/generic" --synthetic >/dev/null
# B：extension 的 sha256 篡改（文件还在，走 artifact 刷新路径 → validateRevision 抓 sha 不符）。
# D：descriptor 文件与 index 行一起删掉、requiredFeatures 保留（新的 contentRoot → 真走一次装包 →
#    BootContract 找不到图形描述。注意：contentRoot 相同的包会走 alreadyActive 短路、不逐文件复验，
#    所以"只删文件不改 index"的包本来就不会被查出来）。
"$py" - "$work/direct" "$work/tampered" "$work/missing" <<'PY'
import hashlib, json, os, shutil, sys

GRAPHICS = 'shaders/vulkan/direct/graphics.v1.json'

def rewrite_pack(root):
    """按当前目录内容重写 index.tsv / manifest.json / artifact 的哈希与计数。"""
    paths = []
    for directory, _, names in os.walk(root):
        for name in names:
            full = os.path.join(directory, name)
            rel = os.path.relpath(full, root).replace(os.sep, '/')
            if rel in ('index.tsv', 'manifest.json', 'game-build-artifact.json', 'manifest.json.tmp'):
                continue
            paths.append(rel)
    paths.sort()
    lines, total = [], 0
    for rel in paths:
        data = open(os.path.join(root, rel), 'rb').read()
        total += len(data)
        lines.append(f'{rel}\t{len(data)}\t{hashlib.sha256(data).hexdigest()}\n')
    index = ''.join(lines).encode()
    open(os.path.join(root, 'index.tsv'), 'wb').write(index)
    index_sha = hashlib.sha256(index).hexdigest()
    manifest = json.load(open(os.path.join(root, 'manifest.json')))
    manifest.update({'files': len(paths), 'total': total, 'index_sha256': index_sha})
    open(os.path.join(root, 'manifest.json'), 'w').write(json.dumps(manifest, indent=1) + '\n')
    path = os.path.join(root, 'game-build-artifact.json')
    artifact = json.load(open(path))
    artifact['contentRoot'] = 'sha256-' + index_sha
    artifact['package'].update({'files': len(paths), 'bytes': total, 'indexSha256': index_sha})
    return path, artifact

shutil.copytree(sys.argv[1], sys.argv[2])
path, artifact = rewrite_pack(sys.argv[2])
artifact['extensions']['org.s2arm.graphics.v1']['sha256'] = 'ff' * 32
open(path, 'w').write(json.dumps(artifact, indent=1) + '\n')

shutil.copytree(sys.argv[1], sys.argv[3])
os.remove(os.path.join(sys.argv[3], GRAPHICS))
path, artifact = rewrite_pack(sys.argv[3])
open(path, 'w').write(json.dumps(artifact, indent=1) + '\n')
PY

push_pack() {
    adb_shell rm -rf "$import_dir"
    adb_shell mkdir -p "$import_dir"
    adb -s "$serial" push "$1" "$import_dir/" >/dev/null
}
# 清日志、重启 App，然后轮询到匹配行为止（扫描是异步的；每条判据都必须只看本次启动的日志）。
wait_for() {
    local pattern=$1 tries=${2:-20}
    adb -s "$serial" logcat -c
    adb_shell am force-stop org.s2arm.android
    adb_shell am start -W -n org.s2arm.android/.MainActivity >/dev/null
    for _ in $(seq "$tries"); do
        sleep 1
        line=$(adb -s "$serial" logcat -d | grep -E "$pattern" | tail -1 || true)
        [ -n "$line" ] && { printf '%s\n' "$line"; return 0; }
    done
    echo "--- 本次启动没有匹配 /$pattern/ 的日志；最近的相关行：" >&2
    adb -s "$serial" logcat -d | grep -E 'Game (installed|already installed|build artifact updated|import)' | tail -5 >&2 || true
    return 1
}
# 三种成功结果都算装上了：新装 / 同一份已激活 / 同内容新 artifact（例如 direct<->generic 换包）。
installed() { wait_for "Game (installed|already installed|build artifact updated).*\[$title\]"; }
refused() { wait_for 'Game import of .* refused: '; }
content_root_of() { "$py" -c 'import hashlib,sys;print("sha256-"+hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$1/index.tsv"; }

# A：带 requiredFeatures + descriptor 的 direct 包
push_pack "$work/direct" direct
a_log=$(installed)
[ -n "$a_log" ] || { echo "direct pack was not installed" >&2; echo "$(refused)" >&2; exit 1; }
echo "A $a_log"
direct_root=$(content_root_of "$work/direct")
echo "A direct revision $direct_root"

# B：extension 的 sha256 被篡改 → 必须被拒，提示是 graphics 扩展
push_pack "$work/tampered" tampered
b_log=$(refused)
echo "$b_log" | grep -q 'org.s2arm.graphics.v1' || { echo "tampered descriptor was not refused by the graphics extension" >&2; exit 1; }
echo "B $b_log"

# D：descriptor 文件缺失 → 必须被拒（证明设备端真去读这个文件）
push_pack "$work/missing" missing
d_log=$(refused)
echo "$d_log" | grep -qi 'graphics' || { echo "missing descriptor was not refused by the graphics manifest check" >&2; exit 1; }
echo "D $d_log"

# C：同一游戏不带图形能力的包 → 装成另一个 revision，previous 指向 direct 那份
push_pack "$work/generic" generic
c_log=$(installed)
[ -n "$c_log" ] || { echo "generic pack was not installed" >&2; echo "$(refused)" >&2; exit 1; }
# 日志里的 contentRoot 是前 19 字符（sha256- + 12 hex），按前缀比对。
echo "$c_log" | grep -q "previous ${direct_root:0:19}" || { echo "generic revision did not record the direct revision as previous" >&2; exit 1; }
echo "C $c_log"
echo "C7 direct pack install transaction: ok ($(adb_shell getprop ro.product.model | tr -d '\r'))"
