#!/usr/bin/env bash
# Resolve a JDK 17 `javac` for the device-free checks and the host build.
# Prints its absolute path and exits 0; prints nothing and exits 1 when none is found.
# Candidates, in order: S2A_JAVAC, JAVA_HOME, macOS `java_home -v 17`, Homebrew, the distro
# JDK 17 layout (/usr/lib/jvm/java-17-openjdk*; Arch, Debian, Fedora), PATH, and the mini's copy.
# A candidate is only accepted when it actually reports 17, so a JAVA_HOME pointing at 21
# falls through instead of failing later with a confusing version error.
set -euo pipefail

candidates=()
[ -n "${S2A_JAVAC:-}" ] && candidates+=("$S2A_JAVAC")
[ -n "${JAVA_HOME:-}" ] && candidates+=("$JAVA_HOME/bin/javac")
if [ -x /usr/libexec/java_home ]; then
    jh=$(/usr/libexec/java_home -v 17 2> /dev/null || true)
    [ -n "$jh" ] && candidates+=("$jh/bin/javac")
fi
candidates+=(
    /opt/homebrew/opt/openjdk@17/bin/javac
    /usr/local/opt/openjdk@17/bin/javac
    /usr/lib/jvm/*17*/bin/javac
    "$(command -v javac 2>/dev/null || true)"
    "$HOME/.s2arm/toolchain/jdk-17/bin/javac"
)
for javac in "${candidates[@]}"; do
    [ -x "$javac" ] || continue
    if "$javac" -version 2>&1 | grep -q ' 17\.'; then
        printf '%s\n' "$javac"
        exit 0
    fi
done
exit 1
