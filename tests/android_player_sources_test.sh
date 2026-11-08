#!/usr/bin/env bash
# 门禁覆盖：android/app/src/main/java/org/s2arm/android/PlayerSources.java android/tests/PlayerSourcesTest.java
# Real host tests; selector fixtures below are not Mac, JDK 8 or Android execution evidence.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
script="$root/tests/android_player_sources_test.sh"

fail() { printf 'PlayerSources JDK: %s\n' "$*" >&2; exit 1; }

select_jdk() {
    JAVAC=""
    if [ "${S2A_JAVAC+x}" = x ]; then
        # An explicit bad override must not silently select another installed JDK.
        [ -n "$S2A_JAVAC" ] && [ -x "$S2A_JAVAC" ] || fail 'S2A_JAVAC must name an executable JDK 17 javac'
        JAVAC=$S2A_JAVAC
    else
        # Same candidate order as android/gate.sh; never fall back to PATH javac.
        for candidate in /opt/homebrew/opt/openjdk@17/bin/javac /usr/local/opt/openjdk@17/bin/javac; do
            if [ -x "$candidate" ]; then JAVAC=$candidate; break; fi
        done
        if [ -z "$JAVAC" ] && [ -x /usr/libexec/java_home ]; then
            registered=$(/usr/libexec/java_home -v 17 2>/dev/null || true)
            if [ -n "$registered" ] && [ -x "$registered/bin/javac" ]; then JAVAC="$registered/bin/javac"; fi
        fi
        if [ -z "$JAVAC" ] && [ -n "${HOME:-}" ] && [ -x "$HOME/.s2arm/toolchain/jdk-17/bin/javac" ]; then
            JAVAC="$HOME/.s2arm/toolchain/jdk-17/bin/javac"
        fi
    fi
    [ -n "$JAVAC" ] || fail 'JDK 17 not found; set S2A_JAVAC to its javac (no downloads or PATH fallback)'
    compiler_version=$("$JAVAC" -version 2>&1) || fail 'selected javac -version failed'
    printf '%s\n' "$compiler_version" | grep -Eq '^javac 17([.-]|$)' || fail 'selected javac is not JDK 17'
    # Homebrew bin/javac may be a symlink outside Contents/Home. Ask its actual VM instead
    # of deriving JAVA_HOME from dirname(javac), and retain spaces in the reported path.
    settings=$("$JAVAC" -J-XshowSettings:properties -version 2>&1) || fail 'selected javac VM query failed'
    vm_home=$(printf '%s\n' "$settings" | sed -n 's/^[[:space:]]*java\.home[[:space:]]*=[[:space:]]*//p')
    case "$vm_home" in
        ''|*"
"*) fail 'javac must report exactly one java.home' ;;
        /*) ;;
        *) fail 'javac reported a non-absolute java.home' ;;
    esac
    [ -d "$vm_home" ] || fail 'javac java.home is not a directory'
    JAVA_HOME=$(cd "$vm_home" && pwd -P) || fail 'cannot resolve javac java.home'
    JAVA="$JAVA_HOME/bin/java"
    [ -x "$JAVA" ] || fail 'javac VM has no executable paired java'
    runtime_version=$("$JAVA" -version 2>&1) || fail 'paired java -version failed'
    printf '%s\n' "$runtime_version" | grep -Eq '^(openjdk|java) version "17([.+-]|")' \
        || fail 'paired java is not JDK 17'
    export JAVA_HOME
    export PATH="$JAVA_HOME/bin:$PATH"
    printf 'PlayerSources JDK 17: javac=%s; java=%s\n' "$JAVAC" "$JAVA"
}

# Persisted selection regressions use tiny command fixtures, not JVM substitutes for Java tests.
# The fake compiler reports a VM home unrelated to its symlink's parent, including spaces.
self_test_jdk() (
    fixture=$(mktemp -d "${TMPDIR:-/tmp}/s2arm-jdk-selector.XXXXXXXX")
    trap 'rm -rf "$fixture"' EXIT
    # Match the selector's canonical VM home even when TMPDIR itself is a system alias.
    fixture=$(cd "$fixture" && pwd -P)
    mkdir -p "$fixture/actual compiler" "$fixture/keg bin" "$fixture/VM home/bin" \
        "$fixture/home/.s2arm/toolchain/jdk-17/bin"
    cat > "$fixture/actual compiler/javac" <<'STUB'
#!/usr/bin/env bash
set -eu
case "$1" in
    -version)
        [ "${FIXTURE_JAVAC_FAIL:-0}" = 0 ] || exit 9
        printf 'javac %s.0.99\n' "${FIXTURE_JAVAC_MAJOR:-17}" ;;
    -J-XshowSettings:properties)
        printf '    java.home = %s\njavac 17.0.99\n' "$FIXTURE_VM_HOME" >&2 ;;
    *) exit 8 ;;
esac
STUB
    cat > "$fixture/VM home/bin/java" <<'STUB'
#!/usr/bin/env bash
set -eu
[ "$1" = -version ] || exit 8
printf 'openjdk version "%s.0.99"\n' "${FIXTURE_JAVA_MAJOR:-17}" >&2
STUB
    chmod +x "$fixture/actual compiler/javac" "$fixture/VM home/bin/java"
    ln -s "$fixture/actual compiler/javac" "$fixture/keg bin/javac"
    ln -s "$fixture/actual compiler/javac" "$fixture/home/.s2arm/toolchain/jdk-17/bin/javac"
    export FIXTURE_VM_HOME="$fixture/VM home"
    check_selector() {
        expected=$1; label=$2; shift 2
        if "$@" > "$fixture/check.log" 2>&1; then result=0; else result=$?; fi
        if { [ "$expected" = pass ] && [ "$result" -ne 0 ]; } \
                || { [ "$expected" = fail ] && [ "$result" -eq 0 ]; }; then
            cat "$fixture/check.log" >&2
            fail "selector command fixture failed: $label"
        fi
        printf 'PASS selector command fixture: %s\n' "$label"
    }
    check_selector pass 'symlink compiler uses its reported VM home with spaces' \
        env S2A_JAVAC="$fixture/keg bin/javac" bash "$script" --check-jdk
    grep -Fq "java=$fixture/VM home/bin/java" "$fixture/check.log" \
        || fail 'selector did not use the reported VM home'
    check_selector fail 'empty explicit override does not fall through to installed candidates' \
        env HOME="$fixture/home" S2A_JAVAC= bash "$script" --check-jdk
    check_selector fail 'nonexistent explicit override does not fall through' \
        env HOME="$fixture/home" S2A_JAVAC="$fixture/missing" bash "$script" --check-jdk
    check_selector fail 'compiler major 8 fixture is rejected' \
        env S2A_JAVAC="$fixture/keg bin/javac" FIXTURE_JAVAC_MAJOR=8 bash "$script" --check-jdk
    check_selector fail 'compiler version command failure is not ignored' \
        env S2A_JAVAC="$fixture/keg bin/javac" FIXTURE_JAVAC_FAIL=1 bash "$script" --check-jdk
    check_selector fail 'mismatched paired runtime major fixture is rejected' \
        env S2A_JAVAC="$fixture/keg bin/javac" FIXTURE_JAVA_MAJOR=8 bash "$script" --check-jdk
    printf 'JDK selection: 6 command fixtures passed (not real alternate-JDK/platform evidence)\n'
)

case "${1:-}" in
    --check-jdk) [ "$#" -eq 1 ] || fail 'unexpected arguments'; select_jdk; exit 0 ;;
    --self-test-jdk) [ "$#" -eq 1 ] || fail 'unexpected arguments'; self_test_jdk; exit 0 ;;
    '') [ "$#" -eq 0 ] || fail 'unexpected empty argument' ;;
    *) fail 'usage: android_player_sources_test.sh [--check-jdk|--self-test-jdk]' ;;
esac

select_jdk
self_test_jdk
out=$(mktemp -d "${TMPDIR:-/tmp}/s2arm-player-sources.XXXXXXXX")
trap 'rm -rf "$out"' EXIT
"$JAVAC" -encoding UTF-8 -d "$out" \
    "$root/android/app/src/main/java/org/s2arm/android/PlayerSources.java" \
    "$root/android/tests/PlayerSourcesTest.java"
"$JAVA" -Xmx32m -cp "$out" org.s2arm.android.PlayerSourcesTest
# Separate host JVM: selective permission checks exercise the actual available-space API.
"$JAVA" -Xmx32m -cp "$out" org.s2arm.android.PlayerSourcesTest --space-api
# A real symlink, not a fabricated platform path, exercises canonical temporary-root assertions.
mkdir "$out/temp-real"
ln -s "$out/temp-real" "$out/temp-alias"
"$JAVA" -Xmx32m -Djava.io.tmpdir="$out/temp-alias" -cp "$out" org.s2arm.android.PlayerSourcesTest --temp-root
