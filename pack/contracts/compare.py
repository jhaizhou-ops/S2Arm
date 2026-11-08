#!/usr/bin/env python3
"""Read-only IPA/resource comparison. Reports are private local evidence."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import stat
import subprocess
import sys
import tempfile
import zipfile


class ComparisonError(ValueError):
    pass


def digest_stream(source):
    digest = hashlib.sha256()
    for block in iter(lambda: source.read(4 << 20), b""):
        digest.update(block)
    return digest.hexdigest()


def digest_file(path):
    with Path(path).open("rb") as source:
        return digest_stream(source)


def relative_name(name):
    path = PurePosixPath(name)
    if not name or path.is_absolute() or "\\" in name or any(p in (".", "..") for p in name.split("/")):
        raise ComparisonError("交付包含非规范相对路径。")
    return name


def resource_index(root):
    root = Path(root)
    if root.is_symlink() or not root.is_dir():
        raise ComparisonError("资源包目录缺失或为符号链接。")
    result = {}
    for path in sorted(root.rglob("*")):
        if path.is_symlink():
            raise ComparisonError("资源包包含符号链接。")
        if path.is_file():
            name = relative_name(path.relative_to(root).as_posix())
            result[name] = dict(size=path.stat().st_size, sha256=digest_file(path), mode=stat.S_IMODE(path.stat().st_mode))
        elif not path.is_dir():
            raise ComparisonError("资源包包含非普通文件。")
    if not result or "manifest.json" not in result:
        raise ComparisonError("资源包为空或缺少 manifest.json。")
    return result


def differences(old, new):
    return dict(onlyOld=sorted(old.keys() - new.keys()), onlyNew=sorted(new.keys() - old.keys()),
                changed=[name for name in sorted(old.keys() & new.keys()) if old[name] != new[name]])


def compare_resources(old, new):
    old, new = resource_index(old), resource_index(new)
    delta = differences(old, new)
    return dict(equal=not any(delta.values()), oldFiles=len(old), newFiles=len(new),
                oldBytes=sum(v["size"] for v in old.values()), newBytes=sum(v["size"] for v in new.values()),
                differences=delta)


def zip_index(archive):
    result = {}
    for entry in archive.infolist():
        name = relative_name(entry.filename.rstrip("/"))
        if name in result:
            raise ComparisonError("IPA 包含重复成员。")
        if stat.S_ISLNK(entry.external_attr >> 16):
            raise ComparisonError("IPA 包含符号链接，需另行核对。")
        result[name] = entry
    if not any(name.startswith("Payload/") and ".app/" in name for name in result):
        raise ComparisonError("IPA 不含 Payload App。")
    return result


def signature_envelope(name):
    parts = PurePosixPath(name).parts
    if not (len(parts) >= 3 and parts[0] == "Payload" and parts[1].endswith(".app")):
        return False
    return (parts[-2:] == ("_CodeSignature", "CodeResources")
            or (len(parts) == 3 and parts[-1] == "embedded.mobileprovision"))


MACHO_MAGIC = {b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xce",
               b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca", b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca"}


def unsigned_digest(data):
    """Strip signatures only on throwaway copies using Apple's own format tool."""
    if data[:4] not in MACHO_MAGIC:
        return None
    codesign = shutil.which("codesign")
    if codesign is None:
        raise ComparisonError("比较 Mach-O 签名差异需要 macOS codesign。")
    with tempfile.TemporaryDirectory(prefix="s2arm-ipa-compare-") as folder:
        path = Path(folder) / "image"
        path.write_bytes(data)
        result = subprocess.run([codesign, "--remove-signature", str(path)],
                                capture_output=True, timeout=60, check=False)
        if result.returncode:
            return None
        return digest_file(path)


def compare_ipa(old, new, *, allow_signatures=False, allow_zip_metadata=False):
    raw_old, raw_new = digest_file(old), digest_file(new)
    changed, excluded, metadata = [], [], []
    with zipfile.ZipFile(old) as a, zipfile.ZipFile(new) as b:
        old_index, new_index = zip_index(a), zip_index(b)
        all_names = sorted(old_index.keys() | new_index.keys())
        old_files = new_files = 0
        for name in all_names:
            before, after = old_index.get(name), new_index.get(name)
            old_files += bool(before and not before.is_dir())
            new_files += bool(after and not after.is_dir())
            if before is not None and after is not None:
                if before.is_dir() != after.is_dir():
                    changed.append(dict(path=name, reason="member_type"))
                    continue
                if stat.S_IMODE(before.external_attr >> 16) != stat.S_IMODE(after.external_attr >> 16):
                    changed.append(dict(path=name, reason="permissions"))
                    continue
                if (before.date_time, before.compress_type, before.comment, before.extra,
                        before.external_attr, before.flag_bits) != (after.date_time, after.compress_type,
                        after.comment, after.extra, after.external_attr, after.flag_bits):
                    metadata.append(name)
                with a.open(before) as left, b.open(after) as right:
                    left_hash, right_hash = digest_stream(left), digest_stream(right)
                if left_hash == right_hash:
                    continue
            else:
                left_hash = right_hash = None
            if allow_signatures and signature_envelope(name):
                excluded.append(dict(path=name, reason="signature_envelope", oldSha256=left_hash, newSha256=right_hash))
                continue
            if allow_signatures and before is not None and after is not None:
                # Preserve all executable code, constants, UUIDs and resources;
                # never exclude a whole executable merely because it is signed.
                left_unsigned = unsigned_digest(a.read(before))
                right_unsigned = unsigned_digest(b.read(after))
                if left_unsigned is not None and left_unsigned == right_unsigned:
                    excluded.append(dict(path=name, reason="macho_signature_only", unsignedSha256=left_unsigned,
                                         oldSha256=left_hash, newSha256=right_hash))
                    continue
            changed.append(dict(path=name, reason="content" if before and after else "missing_member",
                                oldSha256=left_hash, newSha256=right_hash))
        # A raw ZIP difference with equal members can also be in the central
        # directory or compression layout. It is only accepted by explicit flag.
        container_diff = raw_old != raw_new
        equal = not changed and (not container_diff or allow_zip_metadata)
    return dict(equal=equal, rawEqual=raw_old == raw_new, oldSha256=raw_old, newSha256=raw_new,
                oldFiles=old_files, newFiles=new_files, differences=changed, excluded=excluded,
                zipMetadataChanged=metadata, zipContainerChanged=container_diff,
                allowed=dict(signatures=allow_signatures, zipMetadata=allow_zip_metadata))


def compare(old_ipa, new_ipa, old_resources, new_resources, **options):
    resources = compare_resources(old_resources, new_resources)
    ipa = compare_ipa(old_ipa, new_ipa, **options)
    return dict(schema="s2a.package-comparison.v1", equal=ipa["equal"] and resources["equal"], ipa=ipa, resources=resources)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("old-ipa", "new-ipa", "old-resources", "new-resources", "report"):
        parser.add_argument("--" + name, required=True, type=Path)
    parser.add_argument("--allow-signatures", action="store_true")
    parser.add_argument("--allow-zip-metadata", action="store_true")
    args = parser.parse_args()
    report_path = args.report.resolve()
    inputs = [p.resolve() for p in (args.old_ipa, args.new_ipa, args.old_resources, args.new_resources)]
    if any(report_path == path or path in report_path.parents for path in inputs):
        parser.error("报告必须写到产物目录外，不能覆盖输入。")
    try:
        result = compare(args.old_ipa, args.new_ipa, args.old_resources, args.new_resources,
                         allow_signatures=args.allow_signatures, allow_zip_metadata=args.allow_zip_metadata)
    except (ComparisonError, OSError, ValueError, zipfile.BadZipFile, subprocess.TimeoutExpired):
        print("对照失败：交付不可读取、结构异常或校验工具不可用；未改动输入。", file=sys.stderr)
        return 2
    report_path.parent.mkdir(parents=True, exist_ok=True)
    with os.fdopen(os.open(report_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "w") as out:
        json.dump(result, out, ensure_ascii=False, indent=2)
        out.write("\n")
    print(json.dumps(dict(equal=result["equal"], ipaFiles=result["ipa"]["oldFiles"],
                          resourceFiles=result["resources"]["oldFiles"],
                          excluded=len(result["ipa"]["excluded"])), ensure_ascii=False))
    return 0 if result["equal"] else 1


if __name__ == "__main__":
    sys.exit(main())
