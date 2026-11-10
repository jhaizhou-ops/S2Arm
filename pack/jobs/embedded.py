"""Install the app's immutable engine snapshot into a writable cache (the default location's hosts/engine, see engines_root).

The snapshot contains a fresh, local-only Git object database for the existing
pipeline's HEAD-based stage keys. It contains no developer history or remotes.
"""
import contextlib
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
    source = Path(bundle).resolve()
    manifest = read(source / "engine.json", {})
    identity = manifest.get("id", "")
    if manifest.get("schema") != 1 or len(identity) != 64 or any(x not in "0123456789abcdef" for x in identity):
        raise Failure("应用内置引擎不完整，请重新安装完整应用。")
    root = engines_root(c)
    destination = contained(root, root / identity)
    _adopt_private_copy(c, root, identity)
    # 已装的副本每次用前按大小快速复核（#304：玩家机上已装副本里宿主的 Info.plist 被外部改过，0.1.7 只看安装标记、之后每次出包都报 runtime_invalid、
    #   重新打包也好不了）；对不上就挪开、从 App 包重解。逐文件 lstat，约 8500 个文件几十毫秒；摘要级核对仍在用到具体产物时（artifact）。
    #   不核 .git/（_stable_files：快照自带的 Git 仓库元数据，正常使用就可能变）。
    #   完好的副本直接用、不拿锁；要挪开 / 重解时拿跨进程锁（_install_lock），拿到后重读标记、再核一次（别的作业可能刚装好）才动手——
    #   v0.2.0 前回归：启动时 preflight 与 setup 同时初始化同一份副本，一个读到另一个装到一半 / 正被收走的副本，误判「被改过」、挪走对方的
    if not _ready(c, destination, manifest):
        with _install_lock(root):
            if not _ready(c, destination, manifest):
                _reinstall(c, source, manifest, root, destination, identity)
    c.engine = destination
    _retain(c, root, identity)
    c.require_source()


def _ready(c, destination, manifest):
    """有安装标记且清单里稳定的文件都在、大小对"""
    return read(destination / ".installed.json", {}).get("schema") == 2 and _intact(c, destination, manifest, _stable_files(manifest), full=False)


@contextlib.contextmanager
def _install_lock(root, timeout=1800):
    """同一引擎目录的挪开 / 重解只许一个作业做（跨进程：flock / msvcrt，同 filelock）。等别的作业解完最多 timeout 秒（解一份几秒到一两分钟）"""
    import time
    import filelock
    root.mkdir(parents=True, exist_ok=True)
    with (root / ".install.lock").open("a") as f:
        t0 = time.time()
        while True:
            try:
                filelock.try_lock(f)
                break
            except BlockingIOError:
                if time.time() - t0 > timeout:
                    raise Failure("另一个任务正在初始化内置 S2Arm 引擎，等了太久，请稍后重试。") from None
                time.sleep(0.5)
        try:
            yield
        finally:
            filelock.unlock(f)


def _reinstall(c, source, manifest, root, destination, identity):
    """持 _install_lock 调：坏副本（或没装完的）挪开，从 App 包解一份新的。App 包本身的文件不对 → engine_incomplete（只能重装 App）"""
    from build import clone_tree, validate_files
    if destination.exists():
        _set_aside(c, root, destination, "已装的内置引擎文件被改过" if read(destination / ".installed.json", {}).get("schema") == 2 else "上次没装完的内置引擎")
    c.begin("初始化内置 S2Arm 引擎")
    try:
        validate_files(c, source, manifest.get("files"))
    except Failure as e:
        raise Failure("S2Arm 应用里的内置引擎文件不完整（" + str(e).rsplit("：", 1)[-1] + "），请重新安装完整的 S2Arm。", code="engine_incomplete") from e
    temporary = destination.with_name(identity + "." + uuid.uuid4().hex + ".partial")
    temporary.mkdir(parents=True)
    try:
        clone_tree(c, source, temporary)
        validate_files(c, temporary, manifest["files"])
        check_git(temporary)
        atomic(temporary / ".installed.json", dict(schema=2, id=identity))
        c.check()
        os.rename(temporary, destination)
    finally:
        if temporary.exists():
            shutil.rmtree(temporary)


# ---- 引擎副本放哪、留几份（游戏库结构 P3）----
# 原来每版一份放 <私有目录>/engines/<引擎号>/、从不清（约 4 GB / 版）。现在放默认位置的 hosts/engine/<引擎号>/，只留在用的一份和上一份
# （上一份给升级当口还在跑的旧版作业、以及回退旧版 App 时直接用，不用重解）。库还没建好（setup 之前）退回私有目录；建库后下次装引擎时
# 同一卷的直接改名搬过去，跨卷的从 App 里重新解出，私有目录里的旧副本一律删掉。

def engines_root(c):
    from core import default_home
    home = default_home(c.private, c.library)
    return home / "engines" if home == c.private else home / "hosts" / "engine"


PRIVATE_STALE_SECONDS = 24 * 3600   # 私有目录里的旧副本多久没用才删：长出包也在这之内结束（出包 ≤30 分钟硬线）


def _adopt_private_copy(c, root, identity):
    """库建好后，私有目录 engines/ 里的旧副本（库建好前解的）在没人用之后清掉；hosts/engine 没有这一版就由 install 从 App 包重解（APFS 克隆几秒）。
    不改名搬、不当场删：同一时刻别的作业可能正用着那份副本，或者正把一份解到 <号>.<随机>.partial（v0.2.0 前回归：启动时 preflight 在库建好前开始解，
    紧接着建库后的 keys / catalog 作业把私有 engines/ 整个删了，preflight 核自己解到一半的副本报「缺失或大小不符：.git/COMMIT_EDITMSG」）。
    只删最后一次用过（.installed.json / .last-used 的修改时刻）超过 PRIVATE_STALE_SECONDS 的完整副本；.partial / .broken 由解它的作业自己收拾，
    崩溃留下的超过同样时长也删"""
    import time
    old = c.private / "engines"
    if root == old or not old.is_dir():
        return
    now = time.time()
    for d in old.iterdir():
        if d.is_symlink() or not d.is_dir():
            continue
        try:
            used = max((p.stat().st_mtime for p in (d / ".installed.json", d / ".last-used", d) if p.exists()), default=0)
        except OSError:
            continue
        if now - used > PRIVATE_STALE_SECONDS:
            shutil.rmtree(d, ignore_errors=True)
    try:
        old.rmdir()   # 空了才删
    except OSError:
        pass


def _retain(c, root, identity):
    """hosts/engine 下只留在用的这份 + 上一份（按 .last-used 时刻取最近用过的另一份）；在用的这份每次装引擎时记一次时刻"""
    stamp = root / identity / ".last-used"
    try:
        stamp.touch()   # 私有目录里的副本也记：_adopt_private_copy 按它判断有没有人还在用
    except OSError:
        return
    if root.name != "engine":
        return
    others = []
    for d in root.iterdir():
        if d.name == identity or d.is_symlink() or not d.is_dir():
            continue
        if d.name.endswith(".partial"):
            continue   # 别的作业正在解的
        try:
            used = (d / ".last-used").stat().st_mtime
        except OSError:
            used = 0
        others.append((used, d.name, d))
    for _, _, d in sorted(others, reverse=True)[1:]:
        shutil.rmtree(d, ignore_errors=True)


def _stable_files(manifest):
    """清单里不会被正常使用改动的文件：去掉 Git 仓库元数据 .git/"""
    return {p: v for p, v in (manifest.get("files") or {}).items() if not (p == ".git" or p.startswith(".git/"))}


def _intact(c, root, manifest, files=None, full=True):
    """副本里这些文件（缺省清单全部）在、是普通文件、大小对（full 再核摘要）"""
    from build import validate_files
    try:
        validate_files(c, root, files if files is not None else manifest.get("files"), full)
        return True
    except Failure as e:
        if e.code != "runtime_invalid":
            raise
        c.emit("message", "内置引擎副本校验没过：" + str(e).rsplit("：", 1)[-1])
        return False


def _set_aside(c, root, destination, why):
    """坏副本改名挪开（同卷改名；正在用它的别的作业照常读完），随后删掉；install 接着从 App 包重解"""
    c.emit("message", why + "，从 S2Arm 应用里重新解出一份")
    broken = destination.with_name(destination.name + "." + uuid.uuid4().hex + ".broken")
    try:
        os.rename(destination, broken)
    except OSError:
        return   # 别的作业刚挪走 / 正在重解
    shutil.rmtree(broken, ignore_errors=True)


def artifact(c, name):
    if c.r.get("engineBundle") and not (c.engine / "engine.json").is_file():
        # 发版应用里本作业在用的引擎副本不在了（被别的作业收走 / 重解中）：重新定位一次（install 持锁装好或找到现成的），不当成「没有内置产物」
        c.emit("message", "内置引擎副本不在原处，重新定位")
        install(c)
    manifest = read(c.engine / "engine.json", {})
    if not manifest:
        return None
    prefix = "Binaries/" + name
    files = {p: v for p, v in manifest.get("files", {}).items() if p.startswith(prefix + "/")}
    if not files:
        raise Failure("应用内置引擎产物缺失，请重新安装完整应用。")
    if not _intact(c, c.engine, manifest, files):
        if not c.r.get("engineBundle"):   # 源码树开发：没有 App 包可重解，照原样报
            from build import validate_files
            validate_files(c, c.engine, files)
        # 已装副本里这件产物被改过（#304）：持锁再核一次（别的作业可能正在重解、刚换上新的），还不对就从 App 包重解整份引擎再核；
        #   App 包本身坏了由 _reinstall 报「重新安装 S2Arm」
        source = Path(c.r["engineBundle"]).resolve()
        bundle = read(source / "engine.json", {})
        with _install_lock(c.engine.parent):
            if not _intact(c, c.engine, manifest, files):
                c.emit("message", "内置引擎里的 " + name + " 被改过")
                _reinstall(c, source, bundle, c.engine.parent, c.engine, bundle.get("id", c.engine.name))
        from build import validate_files
        validate_files(c, c.engine, files)
    return c.engine / prefix
