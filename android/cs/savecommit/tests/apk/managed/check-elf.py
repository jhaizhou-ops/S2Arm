#!/usr/bin/env python3
# 门禁手动：辅助脚本，由 apk/managed/build-library.sh 调用核对两份探针库；其 check() 已被门禁里的 apk/unit/managed_elf_test.py 导入覆盖，本身不是单测
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""Check the two probe libraries before packaging; never execute target code."""
import argparse
from pathlib import Path
import re
import subprocess


def check(readelf, directory):
    provider = "libs2a_savecommit_managed.so"
    consumer = "libmanaged_bridge.so"
    reports = {}
    for name in (provider, consumer):
        report = subprocess.check_output(
            [str(readelf), "--dynamic", "--version-info", str(directory / name)],
            text=True, encoding="utf-8", errors="strict")
        reports[name] = report
        sonames = re.findall(r"\(SONAME\).*?\[([^\]]+)\]", report)
        if sonames != [name]:
            raise ValueError(f"{name}: expected exactly one matching DT_SONAME, got {sonames!r}")
    definitions = reports[provider].split("Version definition section", 1)
    if len(definitions) != 2:
        raise ValueError(f"{provider}: missing version definitions")
    definitions = definitions[1].split("Version needs section", 1)[0]
    base = re.findall(r"Flags:\s+BASE\s+.*?Name:\s+(\S+)", definitions)
    if base != [provider]:
        raise ValueError(f"{provider}: version BASE does not match SONAME: {base!r}")
    exported_versions = set(re.findall(r"Name:\s+(\S+)", definitions)) - {provider}
    needed = re.findall(r"\(NEEDED\).*?\[([^\]]+)\]", reports[consumer])
    if needed.count(provider) != 1:
        raise ValueError(f"{consumer}: DT_NEEDED must contain {provider} exactly once")
    needs = reports[consumer].split("Version needs section", 1)
    if len(needs) != 2:
        raise ValueError(f"{consumer}: missing version requirements")
    current = None
    required = []
    for line in needs[1].splitlines():
        file = re.search(r"File:\s+(\S+)\s+Cnt:", line)
        if file:
            current = file.group(1)
            if current.endswith(provider) and current != provider:
                raise ValueError(f"{consumer}: absolute or mismatched verneed File {current!r}")
        name = re.search(r"Name:\s+(\S+)\s+Flags:", line)
        if current == provider and name:
            required.append(name.group(1))
    if not required or not set(required) <= exported_versions:
        raise ValueError(f"{consumer}: unresolved provider versions {required!r}, exported {sorted(exported_versions)!r}")
    return reports


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("readelf", type=Path)
    parser.add_argument("directory", type=Path)
    parser.add_argument("--report", type=Path)
    args = parser.parse_args()
    try:
        reports = check(args.readelf, args.directory)
    except (OSError, subprocess.CalledProcessError, ValueError) as error:
        parser.exit(1, f"Managed ELF contract failed: {error}\n")
    if args.report:
        args.report.write_text("\n".join(f"=== {name} ===\n{text}" for name, text in reports.items()))
    print("Managed ELF contract: SONAME, version BASE and bridge verneed match (2 libraries); not device execution.")
