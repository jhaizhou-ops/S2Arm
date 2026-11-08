#!/usr/bin/env python3
"""Host fake-driver tests using the real direct Vulkan implementation."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[3]
test_dir = Path(__file__).resolve().parent
with tempfile.TemporaryDirectory(prefix="s2a-vk-contract-") as tmp:
    binary = Path(tmp) / "contract"
    link = "-Wl,-dead_strip" if sys.platform == "darwin" else "-Wl,--gc-sections"
    subprocess.run([os.environ.get("CC", "cc"), "-std=c11", "-D_GNU_SOURCE", "-DS2A_ANDROID_GAME_RUNTIME=1",
                    "-O2", "-Wall", "-Wextra", "-Werror", "-ffunction-sections", "-fdata-sections",
                    "-I" + str(test_dir / "include"),
                    "-I" + str(root / "graphics/nvn/third_party/vulkan-headers/include"),
                    "-I" + str(root / "android/native"), "-I" + str(root / "runtime/include"),
                    str(test_dir / "shutdown_contract_test.c"), "-pthread", link, "-o", str(binary)], check=True)
    for mode in ("acquire", "present"):
        subprocess.run([str(binary), mode], check=True, timeout=10)
