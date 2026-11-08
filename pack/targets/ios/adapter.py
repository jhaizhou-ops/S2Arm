"""Phase 0 iOS adapter: delegate to the existing ipa -> oneclick -> ipa.sh path."""
from __future__ import annotations

import hashlib
from pathlib import Path
import platform

from pack.contracts.validate import ContractError, validate


def check_request(request):
    validate("request", request)
    if request.get("targetId") != "ios" or request["operation"] != "ipa":
        raise ContractError("iOS 宿主目标只接受 targetId=ios / operation=ipa。")
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        raise ContractError("iOS 宿主目标需要 Apple Silicon Mac；其他宿主变体尚未实现。")


def artifact_manifest(result, check=None):
    root = Path(result["outputPath"]).resolve()
    ipa = Path(result["ipa"])
    resources = root / (ipa.stem + "资源包")
    if ipa.is_symlink() or ipa.resolve().parent != root or not ipa.is_file():
        raise ContractError("iOS 交付的安装包不在声明的输出目录。")
    ipa = ipa.resolve()
    if resources.is_symlink() or not resources.is_dir() or not (resources / "manifest.json").is_file():
        raise ContractError("iOS 交付缺少对应的资源包。")
    files = []
    for path in [ipa, *sorted(resources.rglob("*"))]:
        if check:
            check()
        if path.is_symlink() or not path.resolve().is_relative_to(root):
            raise ContractError("iOS 交付含符号链接或越界路径。")
        if path.is_file():
            digest = hashlib.sha256()
            with path.open("rb") as source:
                while data := source.read(4 << 20):
                    if check:
                        check()
                    digest.update(data)
            files.append(dict(path=path.relative_to(root).as_posix(), size=path.stat().st_size, sha256=digest.hexdigest()))
    manifest = dict(schema="s2a.artifact.v2", target="ios", files=files,
                    details=dict(schema="s2a.artifact.ios.v1", ipa=ipa.name,
                                 resourcePack=resources.name, buildId=result.get("buildId", ""),
                                 device=result["target"]))
    return validate("artifact", manifest)


def build(context):
    # These imports use the same jobs directory as the legacy main entry point.
    import ipa
    from core import Failure

    result = ipa.build(context)
    try:
        manifest = artifact_manifest(result, context.check)
    except (ContractError, OSError, KeyError) as error:
        raise Failure("iOS 产物账本校验失败；保留原产物，请检查本任务日志。", code="artifact_invalid") from error
    return result | {"artifactManifest": manifest}
