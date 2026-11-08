#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
# Shared, source-addressed local image identity; no registry publication implied.
s2a_vulkan_image() {
  local here=$1
  S2A_VULKAN_SOURCE=$(python3 - "$here" <<'PY_IMAGE'
import hashlib, sys
from pathlib import Path
root = Path(sys.argv[1])
h = hashlib.sha256()
for name in ("Dockerfile", "entrypoint.sh", "result.sh"):
    h.update(name.encode() + b"\0" + (root / name).read_bytes() + b"\0")
print(h.hexdigest())
PY_IMAGE
  ) || return
  S2A_VULKAN_IMAGE="s2arm-vulkan-tests:${S2A_VULKAN_SOURCE:0:20}"
}
s2a_vulkan_engine() {
  S2A_VULKAN_ENGINE=(docker)
  if [ "$(uname -s)" = Darwin ]; then S2A_VULKAN_ENGINE+=(--context colima); fi
}
