#!/usr/bin/env bash
# 仅在临时 Git 仓库中创建空夹具，不读取本机配置或签名材料。
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR
check_git() { git -c core.excludesFile=/dev/null -c core.hooksPath=/dev/null -C "$TMP" "$@"; }
check_git init -q --template=
cp "$ROOT/.gitignore" "$TMP/.gitignore"
mkdir -p "$TMP/tools" "$TMP/nested"
count=0
expect() {
    local expected=$1 path=$2 actual=0
    : > "$TMP/$path"
    check_git check-ignore -q --no-index -- "$path" || actual=$?
    if [ "$actual" -ne "$expected" ]; then
        printf 'FAIL %s: expected rc=%s, actual rc=%s\n' "$path" "$expected" "$actual" >&2
        exit 1
    fi
    count=$((count + 1))
}
for path in tools/machine.local tools/machine.local.bak_1 tools/machine.local.orig \
    tools/machine.local.backup tools/machine.local.example.bak tools/another.local \
    fixture.mobileprovision nested/fixture.mobileprovision fixture.p12 nested/fixture.p12 \
    fixture.cer nested/fixture.cer; do
    expect 0 "$path"
done
# 独立负例：模板与普通源码不能被新的敏感文件规则误伤。
for path in tools/machine.local.example tools/another.local.example tools/ordinary.sh; do
    expect 1 "$path"
done
printf 'PASS gitignore_sensitive: %s assertions (empty synthetic fixtures)\n' "$count"
