#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
# Keep child-test failures distinct from Docker's reserved launch exit codes.
s2a_vulkan_result() {
  case "$1" in
    0) ;;
    125|126|127) echo "Vulkan test failed with reserved process rc=$1" >&2; return 1 ;;
    *) return "$1" ;;
  esac
  if grep -qE 'Validation Error|VUID-' "$2"; then
    echo "Vulkan validation reported an error" >&2
    return 1
  fi
}
