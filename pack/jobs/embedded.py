"""Install the app's immutable engine snapshot into a writable private cache.

The snapshot contains a fresh, local-only Git object database for the existing
pipeline's HEAD-based stage keys. It contains no developer history or remotes.
"""
from pathlib import Path
import os
import shutil
import uuid
from core import Failure, atomic, contained, read


def check_git(engine):
    """内置引擎的 Git 快照必须自成一库：Git 认出的仓库目录就是引擎自己的 .git，不许往上认到外层仓库"""
    import subprocess
    env = dict(os.environ, GIT_CEILING_DIRECTORIES=str(Path(engine).resolve().parent))
    p = subprocess.run(["git", "-C", str(engine), "rev-parse", "--absolute-git-dir"], capture_output=True, text=True, env=env)
    if p.returncode or Path(p.stdout.strip()).resolve() != (Path(engine) / ".git").resolve():
        raise Failure("应用内置引擎的版本快照无效，请重新安装完整应用。")


def install(c):
    bundle = c.r.get("engineBundle")
    if not bundle:
        return  # Source-checkout CLI/development tests.
    from build import clone_tree, validate_files
    source = Path(bundle).resolve()
    manifest = read(source / "engine.json", {})
    identity = manifest.get("id", "")
    if manifest.get("schema") != 1 or len(identity) != 64 or any(x not in "0123456789abcdef" for x in identity):
        raise Failure("应用内置引擎不完整，请重新安装完整应用。")
    destination = contained(c.private, c.private / "engines" / identity)
    # 安装标记第 2 版：第 1 版的复制丢了空目录、Git 快照无效（10-23），旧安装一律重装
    if read(destination / ".installed.json", {}).get("schema") != 2:
        if destination.exists():
            shutil.rmtree(contained(c.private / "engines", destination))
        c.begin("初始化内置 S2Arm 引擎")
        validate_files(c, source, manifest.get("files"))
        destination.parent.mkdir(parents=True, exist_ok=True)
        temporary = destination.with_name(identity + "." + uuid.uuid4().hex + ".partial")
        temporary.mkdir()
        try:
            clone_tree(c, source, temporary)
            validate_files(c, temporary, manifest["files"])
            check_git(temporary)
            atomic(temporary / ".installed.json", dict(schema=2, id=identity))
            c.check()
            # Concurrent read-only catalogue/check workers may initialize once.
            try:
                os.rename(temporary, destination)
            except OSError:
                if read(destination / ".installed.json", {}).get("id") != identity:
                    raise
        finally:
            if temporary.exists():
                shutil.rmtree(temporary)
    c.engine = destination
    c.require_source()


def artifact(c, name):
    manifest = read(c.engine / "engine.json", {})
    if not manifest:
        return None
    from build import validate_files
    prefix = "Binaries/" + name
    files = {p: v for p, v in manifest.get("files", {}).items() if p.startswith(prefix + "/")}
    if not files:
        raise Failure("应用内置引擎产物缺失，请重新安装完整应用。")
    validate_files(c, c.engine, files)
    return c.engine / prefix
