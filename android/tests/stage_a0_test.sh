#!/usr/bin/env bash
# End-to-end A0 check: synthetic package -> rewriter -> stage_a0 -> current.json ->
# schema validation -> BootContract. Needs Python with capstone + lz4 (make_pack.py).
set -euo pipefail
H=$(cd "$(dirname "$0")" && pwd)
A=$(cd "$H/.." && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

"${PY:-python3}" "$A/tools/make_pack.py" "$T/pkg" --synthetic > /dev/null
G="$T/games/0100000000ABCDEF"
mkdir -p "$G"
cp -a "$T/pkg/." "$G/"
"${PY:-python3}" "$A/tools/stage_a0.py" "$G"
REV_README=$(find "$G/revisions" -name readme.txt | head -1)
BEFORE=$(sha256sum "$REV_README" | cut -d' ' -f1)
printf 'source changed after activation\n' >> "$G/romfs/readme.txt"
AFTER=$(sha256sum "$REV_README" | cut -d' ' -f1)
[ "$BEFORE" = "$AFTER" ] || { echo "revision changed when the source was edited"; exit 1; }
# Formal layout: the game root only has current.json + revisions/. GameLibrary and
# GameMetadata must not need root manifest.json / index.tsv / ctl/ / exefs/.
rm -f "$G/manifest.json" "$G/index.tsv" "$G/game-build-artifact.json"
rm -rf "$G/ctl" "$G/exefs" "$G/romfs" "$G/modules"
"${PY:-python3}" "$A/contracts/validate.py" --game "$G"

mkdir -p "$T/classes"
javac -d "$T/classes" \
    "$A/app/src/main/java/org/s2arm/android/Json.java" \
    "$A/app/src/main/java/org/s2arm/android/BootContract.java" \
    "$A/app/src/main/java/org/s2arm/android/GamePack.java" \
    "$A/app/src/main/java/org/s2arm/android/GameMetadata.java" \
    "$A/tests/BootContractTest.java" \
    "$A/tests/GameMetadataTest.java"
java -cp "$T/classes" org.s2arm.android.BootContractTest "$G"
java -cp "$T/classes" org.s2arm.android.GameMetadataTest "$G"
"${PY:-python3}" "$H/input_identity_test.py" "$G"
echo "stage_a0: ok"
