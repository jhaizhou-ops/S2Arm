#!/bin/bash
set -euo pipefail
R=$(cd "$(dirname "$0")/.." && pwd -P)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
DN=${DOTNET:-$HOME/.dotnet/dotnet}; [ -x "$DN" ] || DN=$(command -v dotnet)
clang -dynamiclib "$R/tests/ios_layer/fixture.c" -o "$T/libios_attach_fixture.dylib"
printf '%s\n' '<configuration><packageSources><clear /></packageSources></configuration>' > "$T/nuget.config"
"$DN" build "$R/tests/ios_layer/AttachTest.csproj" -c Release -v quiet \
  --configfile "$T/nuget.config" -p:BaseIntermediateOutputPath="$T/obj/" -p:OutputPath="$T/bin/"
"$DN" "$T/bin/AttachTest.dll" "$T/libios_attach_fixture.dylib"
