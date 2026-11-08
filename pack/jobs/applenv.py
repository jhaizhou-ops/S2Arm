"""Apple / iOS 环境的准备入口（命令行；总指挥 10-23 归口 #106）。和 Mac 前端的环境检查用同一份判据：直接调 toolchain.preflight，
Xcode 按前端同一规则自动选装着的最新版（toolchain.detect_xcode），iPhone 目标的「系统比 SDK 新」用 target.check 判。

  python3 pack/jobs/applenv.py [--json] [--target <机型号> <系统大版本>]   只读：列出每一项通过 / 缺什么、怎么补
  python3 pack/jobs/applenv.py --install dotnet                           显式授权后安装 .NET 10 SDK 到 ~/.dotnet（同前端「一键安装」）
  python3 pack/jobs/applenv.py --install metal                            下载 Xcode 的 Metal 编译组件（同前端「一键下载」）
Xcode 本身要从 App Store 装（脚本不代装）。退出码：只读模式下 prepare / ipa 必需项有缺 → 1，齐 → 0。
"""
from __future__ import annotations
import contextlib
import io
import json
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from core import Context, Failure, default_developer_dir  # noqa: E402
import target as tg  # noqa: E402
import toolchain  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]


def machine_py():
    """开发机在 tools/machine.local 声明的 S2A_PY（tools/machine.sh get；同 oneclick.sh）。源码树外（App 的 Resources/Jobs）没有 tools/，返回 None"""
    m = ROOT / "tools/machine.sh"
    if not m.is_file():
        return None
    try:
        return subprocess.run(["bash", str(m), "get", "S2A_PY"], capture_output=True, text=True, timeout=30).stdout.strip() or None
    except (OSError, subprocess.SubprocessError):
        return None
# 「装了 3.11+ 但 pip 被拒」（uv / Homebrew 的 PEP 668）时的出路；一键出包的报错用同一句
VENV = "装不进包（externally-managed / uv 托管）就建个虚拟环境：python3 -m venv ~/s2a-venv && ~/s2a-venv/bin/python3 -m pip install -r launchers/macos/requirements-runtime.txt -r pack/fonts/requirements.txt，再 export S2A_PYTHON=~/s2a-venv/bin/python3"


def context(operation, private):
    dev = toolchain.detect_xcode() or default_developer_dir()   # 同前端：装着的最新一个；都找不到 → None，预检里报没装（不写死 Xcode.app）
    req = dict(schema=1, taskId="applenv", operation=operation, privateRoot=str(private), library=str(Path(private) / "library"),
               engineDir=str(ROOT), developerDir=dev)
    return Context(req), dev


def main(argv):
    as_json = "--json" in argv
    private = Path(tempfile.mkdtemp(prefix="s2arm-applenv-"))
    if "--install" in argv:
        what = argv[argv.index("--install") + 1]
        fn = {"dotnet": toolchain.install_dotnet, "metal": toolchain.download_metal, "ios": toolchain.download_ios_platform}.get(what)
        if not fn:
            sys.exit("--install 只认 dotnet / metal / ios（Xcode 请从 App Store 安装）")
        c, _ = context({"dotnet": "installDotnet", "metal": "downloadMetal", "ios": "downloadIosPlatform"}[what], private)
        try:
            fn(c)
        except Failure as e:
            print(f"🔴 {e}"); return 1
        print(f"🟢 {what} 已装好；再跑一次 applenv.py 核对"); return 0
    c, dev = context("preflight", private)
    with contextlib.redirect_stdout(io.StringIO()):   # 前端事件流（NDJSON）不打到终端
        checks = toolchain.preflight(c)["checks"]
    # 命令行（源码树）口径：读取器由一键出包首次自己编（pack/srcs.sh），App 私有目录里那份不适用；
    #   Python 依赖的提示从「重装应用」换成按 App 内置 Python 同一份钉版清单装
    checks = [x for x in checks if x["name"] != "S2Arm 内容读取工具"]
    # 与 pack/oneclick/oneclick.sh 开头的自检同一口径（10-23 总指挥：缺什么 doctor 先抓到）：
    #   timeout 系统没有时用仓库自带 perl 版；.NET 10 SDK 认 PATH 或 ~/.dotnet；spirv-as / spirv-val 只给 graphics/metal 单测夹具用，出包不需要
    import shutil
    from ipa import dotnet_sdk
    dn = shutil.which("dotnet") or (str(dotnet_sdk()[1]) if dotnet_sdk()[1] else None)
    for x in checks:
        if x["name"] == "timeout" and (ROOT / "tools/bin/timeout").is_file():
            x.update(ok=True, message=f"用 {shutil.which('timeout') or '仓库自带的 tools/bin/timeout（perl 实现）'}")
        elif x["name"] in ("spirv-as", "spirv-val"):
            x["requiredFor"] = ["test"]
            if not x["ok"]:
                x["message"] = "只有 graphics/metal 的单测夹具要它（brew install spirv-tools）；一键出包不需要"
        elif x["name"] == ".NET 10" and not x["ok"] and dn:
            ok, ver = toolchain.probe(c, [dn, "--list-sdks"])
            if ok and any(line.startswith("10.") for line in ver.splitlines()):
                x.update(ok=True, message=f"用 {dn}（不在 PATH 上，一键出包会自己找到）")
        elif x["name"] == ".NET 10" and not x["ok"]:
            x["message"] = "没有 .NET 10 SDK：python3 pack/jobs/applenv.py --install dotnet（装到 ~/.dotnet，不要管理员密码）"
    import os
    gen_ok = subprocess.run([shutil.which("python3") or sys.executable, "-c", "import fontTools, pathops"], capture_output=True).returncode == 0
    FONTDEPS = "" if gen_ok else "（生成器要的 fonttools / skia-pathops 还没装：python3 -m pip install -r pack/fonts/requirements.txt；%s）" % VENV
    #   共享字体（jhz 10-30：缺省开源替代字体，原版只在显式给 S2A_FONTS 时用）：同 pack/stages/sysdata.sh 的来源顺序；都没有时出包现做，生成器依赖齐就算通过
    fonts = os.environ.get("S2A_FONTS") or next((str(f) for f in (Path("/Applications/S2Arm.app/Contents/Resources/Fonts"),
                                                  Path.home() / "Applications/S2Arm.app/Contents/Resources/Fonts",
                                                  Path(os.environ.get("S2A_OPENFONTS_DIR") or Path(os.environ.get("S2A_RUN_ROOT") or Path.home() / ".s2arm/run") / "s2arm/openfonts"))
                                                 if f.is_dir() and any(f.glob("*.bfttf"))), None)
    checks.append(dict(name="共享字体", ok=bool(fonts) or gen_ok, requiredFor=["prepare"], group="system",
                       message=f"用 {fonts}" if fonts else "出包时现做开源替代字体（pack/fonts/make_open_fonts.py）" if gen_ok else
                       f"没有共享字体：一键出包给 --fonts <目录>（S2Arm.app 的 Contents/Resources/Fonts），或装好生成器依赖由出包现做开源替代字体{FONTDEPS}"))
    #   Python 包按一键出包会用的那个解释器查（S2A_PYTHON → S2A_PY（环境 → tools/machine.local）→ S2Arm.app 内置 Python → PATH 上的 python3，同 oneclick.sh）
    app_py = "Contents/Resources/Runtime/python/bin/python3"
    cands = [Path("/Applications/S2Arm.app") / app_py, Path.home() / "Applications/S2Arm.app" / app_py]
    py = os.environ.get("S2A_PYTHON") or os.environ.get("S2A_PY") or machine_py() or next((str(p) for p in cands if os.access(p, os.X_OK)), None) \
        or shutil.which("python3") or sys.executable
    for x in checks:
        if x["name"] == "Python":
            x["ok"] = toolchain.probe(c, [py, "-c", "import sys; assert sys.version_info >= (3, 11)"])[0]
            x["message"] = f"用 {py}" if x["ok"] else f"{py} 低于 3.11：装 Python 3.11+ 或装 S2Arm.app（自带钉版 Python），或用 S2A_PYTHON=<解释器> 指定。{VENV}"
        elif x["name"] == "zstd":
            # 一键出包只看你自己的 PATH（前端那套会补 Homebrew，这里不补），另认 S2Arm.app 自带的那份，同 oneclick.sh
            apps = [Path(a) / "Contents/Resources/Runtime/bin/zstd" for a in ("/Applications/S2Arm.app", Path.home() / "Applications/S2Arm.app")]
            found = shutil.which("zstd") or next((str(p) for p in apps if os.access(p, os.X_OK)), None)
            x["ok"] = bool(found)
            x["message"] = f"用 {found}" if found else "没有 zstd（解社区着色器参考库要用）：brew install zstd，或装 S2Arm.app（自带一份）"
        elif x["name"] == ".NET SDK（打 iPhone 包）" and not x["ok"]:
            x["message"] = "打 iPhone 包需要 .NET 10 SDK：python3 pack/jobs/applenv.py --install dotnet（从微软官方下载装到 ~/.dotnet，约 300 MB，不要管理员密码）"
        elif x["name"].startswith("Python / "):
            x["ok"] = toolchain.probe(c, [py, "-c", "import " + x["name"][9:]])[0]
            x["message"] = f"用 {py}" if x["ok"] else f"{py} 缺 {x['name'][9:]}：{py} -m pip install -r launchers/macos/requirements-runtime.txt（与 App 内置 Python 同一份钉版清单；换解释器用 S2A_PYTHON=<路径>）。{VENV}"
    env = c.env()
    sdk = None
    try:
        sdk = tg.os_choices(env)[0] if checks else None
    except tg.TargetError as e:
        checks.append(dict(name="iOS SDK", ok=False, requiredFor=["ipa"], group="system",
                           code=e.code, message=str(e)))
    out = dict(developerDir=dev, iosSdkMajor=sdk, checks=checks)
    if "--target" in argv:
        i = argv.index("--target"); pt, osv = argv[i + 1], int(argv[i + 2])
        try:
            out["target"] = tg.check(dict(model=pt, gpuArch=tg.gpu_arch(pt, dev) if dev else None, os=osv), sdk)
        except tg.TargetError as e:
            out["target"] = dict(error=str(e))
    # 出包支持 Intel（jhz 10-24：用 Intel Mac 给自己的 iPhone 出包是正常用法）：Apple 芯片只是「在 Mac 上打包 / 玩」要的，不算 iPhone 出包的缺项
    for x in checks:
        if x["name"] in ("Apple Silicon", "macOS") and not x["ok"]:
            # macOS 15 是 S2Arm.app 的下限；命令行给 iPhone 出包不要求（10-24 #152 Intel macOS 15.8 实走）
            x["requiredFor"] = ["launch"]
            if x["name"] == "macOS":
                x["message"] = "S2Arm.app 要 macOS 15 或更新；命令行给 iPhone 出包（pack/oneclick/oneclick.sh）不受影响"
                continue
            x["message"] = "这台是 Intel Mac：在 Mac 上玩（原生执行要 arm64）需要 Apple 芯片；给 iPhone 出包不受影响，用 pack/oneclick/oneclick.sh"
    missing = [x for x in checks if not x["ok"] and any(s in x["requiredFor"] for s in ("prepare", "ipa"))]
    if as_json:
        print(json.dumps(out, ensure_ascii=False, indent=1))
    else:
        print(f"Xcode：{dev}（iOS SDK {sdk}）" if dev else "Xcode：没找到（/Applications 下没有 Xcode*.app，xcode-select 也没指向可用的）")
        for x in checks:
            need = "、".join({"prepare": "打包", "launch": "启动", "ipa": "打 iPhone 包", "test": "只单测要"}.get(s, s) for s in x["requiredFor"])
            tag = "" if need in x["name"] else f"（{need}）"
            print(f"{'🟢' if x['ok'] else '🔴'} {x['name']}{tag}" + ("" if x["ok"] else f"：{x['message']}"))
        if "target" in out:
            t = out["target"]; print(f"{'🔴 目标设备：' + t['error'] if 'error' in t else '🟢 目标设备：' + t['model'] + ' ' + t['gpuArch'] + ' iOS ' + str(t['os'])}")
        if missing:
            print("缺的项里，.NET SDK 用 `--install dotnet`、Metal 组件用 `--install metal` 补；Xcode 请从 App Store 装好后打开一次。")
    return 1 if missing or ("error" in out.get("target", {})) else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
