#!/bin/bash
# 腾测试机空间：卸掉我方装了超过 N 小时的 App（11-06 jhz：「清理一下超过 24 小时以上的 S2Arm 的安装包吧，以免三台设备硬盘不够。
#   后续也是，如果安装遇到了空间问题，就删掉超过 24 小时的咱们的包。」）
#   tools/dev_prune.sh <机号> [--older-h 24] [--first <包名,…>] [--need-mb <MB>] [--dry]
#   我方 App = io.s2arm.* / io.s2arm-exp.*；永不卸：S2A_PRUNE_KEEP 里点名的「机号:包名」（缺省空；11-06 晚 jhz「旷野之息可以删」，原缺省 2:io.s2arm.botw 取消）。
#   最后动过的时间 = 我方装机记录与容器 Documents 里最新修改时间（devicectl info files 的 lastModDate；读不出的不卸）取较新的；装机记录——各作业目录 out_*/install.log（dev_run 装包写的）的修改时间，作业 job.env 的 DEV 对得上这台、
#     BUNDLE 对得上包名，取最新一次。（11-06 实测：Duo 上满屏线装的实验包没有 job.env 记录，但容器今天 09:34 还在写，单看装机记录会误卸正在用的包）记录根 S2A_PRUNE_ROOTS（缺省运行区、工作盘 S2A_WORK（运行区 env/layout.env）、内置盘溢出根；find -H 深 4 层、7 天内，实测约 1 秒）。
#   --first：先卸这几款（不看时长，如资源没推完的半截包）；--need-mb：机上可用空间够这么多就停（不给 = 把超龄的全卸）；--dry：只列不卸。
#   每款卸前先把存档（Documents/S2A/ryujinx/bis）拉回 <运行区>/saves_backup/<机号>_<包名>_<时刻>/（拉不回就不卸这款），再 devicectl 卸载。
#   全程拿该机设备锁（与调度、真机局互斥）。最后一行：「腾空间：测试机N 卸 X 款，可用 A → B MB」。退出码 0 / 1 设备或锁失败 / 2 用法
set -u
TOOLS=$(cd "$(dirname "$0")" && pwd); DEV=${1:-}; shift || true
OLD=24; FIRST=; NEED=; DRY=0
while [ $# -gt 0 ]; do case $1 in --older-h) OLD=$2; shift 2;; --first) FIRST=$2; shift 2;; --need-mb) NEED=$2; shift 2;; --dry) DRY=1; shift;; *) echo "用法：tools/dev_prune.sh <机号> [--older-h N] [--first 包名,…] [--need-mb MB] [--dry]" >&2; exit 2;; esac; done
[ -n "$DEV" ] || { echo "用法：tools/dev_prune.sh <机号> …" >&2; exit 2; }
source "$TOOLS/devices.sh"; s2a_device "$DEV" || exit 1; N=$DEVNUM
DC=${S2A_DEVICECTL:-xcrun devicectl}; T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
RUNR=${S2A_RUN_ROOT:-$HOME/.s2arm/run}/s2arm; BK=${S2A_SAVE_BACKUP_DIR:-$RUNR/saves_backup}
[ -n "${S2A_WORK:-}" ] || { [ -f "$RUNR/env/layout.env" ] && . "$RUNR/env/layout.env"; }   # 工作盘路径 S2A_WORK 只从运行区上限表取（本机私有路径不进仓库）
dcp() { local t=$1; shift; timeout $((t + 30)) $DC "$@" --timeout "$t"; }
freemb() { if [ -n "${S2A_PRUNE_FREE_CMD:-}" ]; then bash -c "$S2A_PRUNE_FREE_CMD"; else ideviceinfo -u "$SW_IOS_UDID" -q com.apple.disk_usage -k AmountDataAvailable 2> /dev/null | awk '{printf "%d", $1 / 1048576}'; fi; }
if [ $DRY = 0 ] && [ -z "${SW_DEVLOCK_HELD:-}" ]; then source "$TOOLS/devlock.sh"; devlock_acquire "腾空间 ${DEVNAME}" 1800 || { echo "【红】拿不到 ${DEVNAME} 的设备锁" >&2; exit 1; }; trap 'devlock_release; rm -rf "$T"' EXIT; fi
dcp 60 device info apps --device "$SW_DEVICE" --json-output "$T/apps.json" > /dev/null 2>&1 || { echo "【红】列不出 ${DEVNAME} 已装 App" >&2; exit 1; }
# 选单：我方 App、排除永不卸、按（--first 优先，安装时间从旧到新）排；输出「包名<TAB>安装纪元秒（0 = 没记录）<TAB>原因」
python3 - "$T/apps.json" "$N" "$SW_IOS_UDID" "$SW_DEVICE" "$DEVNAME" "$OLD" "$FIRST" "${S2A_PRUNE_KEEP:-}" "${S2A_PRUNE_ROOTS:-$RUNR ${S2A_WORK:-} $HOME/.s2arm/run_int}" > "$T/plan.tsv" <<'PY' || { echo "【红】选单失败" >&2; exit 1; }
import glob, json, os, sys, time
apps, n, udid, cd, name, old, first, keep, roots = sys.argv[1:10]
mine = [a['bundleIdentifier'] for a in json.load(open(apps))['result']['apps'] if a.get('bundleIdentifier', '').startswith(('io.s2arm.', 'io.s2arm-exp.'))]
keep = {k.split(':', 1)[1] for k in keep.split() if ':' in k and k.split(':', 1)[0] == n}
first = [b for b in first.split(',') if b]
ids = {n, udid, cd, name}; last = {}
import subprocess
envs = subprocess.run(['find', '-H'] + [r for r in roots.split() if os.path.isdir(r)] + ['-maxdepth', '4', '-name', 'job.env', '-mtime', '-7'],
                      capture_output=True, text=True).stdout.split('\n') if any(os.path.isdir(r) for r in roots.split()) else []
for env in [e for e in envs if e]:
        try: kv = dict(l.rstrip('\n').split('=', 1) for l in open(env, encoding='utf-8', errors='replace') if '=' in l)
        except OSError: continue
        if kv.get('DEV', '').strip("'\"") not in ids: continue
        b = kv.get('BUNDLE', '').strip("'\"")
        for lg in glob.glob(os.path.join(os.path.dirname(env), 'out_*', 'install.log')):
            last[b] = max(last.get(b, 0), os.path.getmtime(lg))
import datetime, tempfile
def newest(b):   # 容器 Documents 里最新的修改时间（纪元秒）；读不出 = None（不据此卸）。单测给 S2A_PRUNE_NEWEST=<包名>=<纪元秒>,…
    fake = os.environ.get('S2A_PRUNE_NEWEST')
    if fake is not None:
        d = dict(x.split('=', 1) for x in fake.split(',') if '=' in x); return float(d[b]) if b in d else None
    j = tempfile.mktemp(suffix='.json')
    r = subprocess.run(os.environ.get('S2A_DEVICECTL', 'xcrun devicectl').split() + ['device', 'info', 'files', '--device', cd, '--domain-type', 'appDataContainer',
                       '--domain-identifier', b, '--subdirectory', 'Documents', '--json-output', j, '--timeout', '120'], capture_output=True)
    try: fs = json.load(open(j))['result']['files']
    except Exception: return None
    finally:
        try: os.remove(j)
        except OSError: pass
    ds = [f.get('metadata', {}).get('lastModDate') for f in fs]
    ds = [datetime.datetime.fromisoformat(d.replace('Z', '+00:00')).timestamp() for d in ds if d]
    return max(ds) if ds else 0.0
now = time.time(); rows = []
for b in mine:
    if b in keep: continue
    if b in first: rows.append((0, -1, b, 0, '点名先卸')); continue
    t = last.get(b, 0)
    if now - t < float(old) * 3600: continue   # 我方 N 小时内装过
    u = newest(b)
    if u is None: print(f'#\t{b}\t读不出容器修改时间，不卸', file=sys.stderr); continue
    t = max(t, u)
    if now - t >= float(old) * 3600: rows.append((1, t, b, t, f'最后装 / 用于 {int((now - t) / 3600)} 小时前' if t else '没有装机记录、容器无文件'))
for _, _, b, t, why in sorted(rows): print(f'{b}\t{int(t)}\t{why}')
PY
A=$(freemb); n=0; echo "腾空间 ${DEVNAME}：可用 ${A} MB，候选 $(grep -c . "$T/plan.tsv") 款（超过 ${OLD} 小时 / 点名先卸）"
while IFS=$'\t' read -r b t why; do [ -n "$b" ] || continue
  [ -n "$NEED" ] && [ "$(freemb)" -ge "$NEED" ] && { echo "可用已够 ${NEED} MB，停"; break; }
  if [ $DRY = 1 ]; then echo "会卸 ${b}（${why}）"; continue; fi
  d=$BK/${N}_${b}_$(date +%m%d%H%M%S); mkdir -p "$d"
  dcp 300 device copy from --device "$SW_DEVICE" --domain-type appDataContainer --domain-identifier "$b" --source Documents/S2A/ryujinx/bis --destination "$d/bis" > "$d/copy.log" 2>&1
  if [ ! -d "$d/bis" ] && ! grep -qiE "not found|No such|does not exist|file node|error 7000" "$d/copy.log"; then echo "【黄】${b} 存档拉不回（$(tail -1 "$d/copy.log" | cut -c1-80)），不卸"; continue; fi
  dcp 120 device uninstall app --device "$SW_DEVICE" "$b" > "$d/uninstall.log" 2>&1 && { n=$((n + 1)); echo "卸 ${b}（${why}；存档备份 ${d}）"; } || echo "【黄】卸 ${b} 失败（$(tail -1 "$d/uninstall.log" | cut -c1-80)）"
done < "$T/plan.tsv"
echo "腾空间：${DEVNAME}（测试机${N}）卸 ${n} 款，可用 ${A} → $(freemb) MB"
