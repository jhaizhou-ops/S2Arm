#!/bin/bash
set -euo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
PROJECT=$R/tests/frame_pacing/FramePacingTest.csproj
ARTIFACTS=$R/build/frame-pacing-dotnet
dotnet build "$PROJECT" -c Release --artifacts-path "$ARTIFACTS"
dotnet run --project "$PROJECT" -c Release --artifacts-path "$ARTIFACTS" --no-build
