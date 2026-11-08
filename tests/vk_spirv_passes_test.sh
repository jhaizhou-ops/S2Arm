#!/usr/bin/env bash
# 门禁覆盖：translator/vk/*
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
bash "$ROOT/translator/vk/test.sh"
