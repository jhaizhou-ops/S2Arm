#!/usr/bin/env python3
"""IML（提高内存上限）签名核实、窗口估算与渠道推荐（纯函数，无副作用）。

调用方：
  pack/ipa.sh          — 签名后 check_app 核实
  pack/jobs/ipa.py     — 出包前设备窗口提示
  tests/iml_check_test.py — 单测
"""
from __future__ import annotations
import argparse
import datetime as dt
import plistlib
import sys
from pathlib import Path

# Script execution and importlib users (pack/jobs/ipa.py) share the same reader.
if str(Path(__file__).resolve().parent) not in sys.path:
    sys.path.insert(0, str(Path(__file__).resolve().parent))
from iml_formats import FormatError, read_macho_entitlements, read_plist, read_profile

IML_KEY = "com.apple.developer.kernel.increased-memory-limit"

# R09 §3 + TrollStore README：私有 JIT 键（A12+ iOS15+ banned 或尚未对第三方公开）
BANNED_KEYS: tuple[str, ...] = (
    "com.apple.private.cs.debugger",
    "dynamic-codesigning",
    "com.apple.private.skip-library-validation",
    "com.apple.developer.kernel.allow-jit",
)

# R09 渠道表（侧载工具现状.tsv）：True = 能保住 IML（免费队），False = 已知丢失
_CHANNEL_IML: dict[str, bool] = {
    "xcode_personal_team": True,
    "altstore_classic": True,
    "altstore_pal": True,      # 走公证能力集，IML 状态待真机 E_A1 验证
    "getmoreram": True,
    "impactor": True,          # 文档声称，待真机 E_A1 验证
    "livecontainer": True,     # host 含 IML；客体以 dylib 跑在宿主进程里，按宿主签名定档（10-30 实测）
    "sidestore_0.7.0": False,
    "sidestore_0.7.0-alpha": False,
    "sidestore_0.6.4": False,
    "trollstore": False,       # 上界 iOS 17.0，不适用 iOS 26/27
}

_CHANNEL_NOTE: dict[str, str] = {
    "xcode_personal_team":
        "Xcode Personal Team（开发首选，v1 PATCH 保留 IML，7 日刷新）",
    "altstore_classic":
        "AltStore Classic v2.3（AltSign pin 0d3c1a3，v1 PATCH 保留 IML）",
    "altstore_pal":
        "AltStore PAL（EU/JP/BR 合规区；走公证安装，IML 取决于公证能力集；仅限合规区，CN 不承诺）",
    "getmoreram":
        "GetMoreRam/iRAM+（给 App ID 补 IML 后需重装，1 个槽位）",
    "impactor":
        "Impactor（文档声称安装时自动加 IML，待真机 E_A1 核证）",
    "livecontainer":
        "LiveContainer host entitlements.xml 含 IML；客体以 dylib 形式在宿主进程里运行，内核按进程签名定档：宿主带 IML，客体就是 6144 MB / 64 GB 窗口（10-30 测试机1 实测，付费团队 IML 描述文件签名）；客体自己签名里的权限不起作用",
    "sidestore_0.7.0":
        "SideStore 0.7.0 freeFeatures 不含 IML（SideStore#1616），免费账号重签后丢失",
    "sidestore_0.7.0-alpha":
        "SideStore 0.7.0-alpha 同 0.7.0，免费账号重签后丢失",
    "sidestore_0.6.4":
        "SideStore 0.6.4 已废弃（DO NOT USE），禁止使用",
    "trollstore":
        "TrollStore 上界 iOS 17.0，不适用于 iOS 26/27 大众分发",
}

_CHANNEL_RECOMMEND = (
    "推荐渠道（能保住 IML）：Xcode Personal Team / AltStore Classic v2.3 / "
    "GetMoreRam（补救）；不推荐：SideStore 0.7.0 免费账号（会丢 IML）"
)


def window_gb(ios_ver: int, has_iml: bool) -> float:
    """最大连续可用地址窗口（GiB），按 R02 布局_系统版本x权限.tsv 与地址布局_各系统版本.md。

    ios_ver <= 0 表示 Mac 或未知（返回 0.0 = 无数据）。
    """
    if ios_ver <= 0:
        return 0.0   # macOS 洞大小待实测（#58 S2），不估算
    if has_iml:
        if ios_ver >= 27:
            return 64.0   # iOS 27 实测 [0x700000000, 0x800000000) 64 GiB（地址布局_各系统版本.md）
        if ios_ver >= 17:
            return 51.0   # xnu-10063+：0xfc0000000 − 0x300000000 = 51 GiB（R02 + #61 实测）
        if ios_ver >= 16:
            return 53.0   # xnu-8796：0xfc0000000 − 0x280000000 = 53 GiB
        return 51.0       # 更老版本保守按 51 GiB
    else:
        if ios_ver >= 27:
            return 6.0    # iOS 27 无 IML 实测约 6 GiB @0x70（地址布局_各系统版本.md）
        return 5.375       # DEVICE_LARGE 洞（iOS 16–26 一致：hole_upper_bound_GiB）


def check_entitlements_plist(xml_bytes: bytes) -> tuple[bool, list[str], list[str]]:
    """解析权限 plist；只判内容，不验证代码签名或 CMS 信任链。

    返回 (ok, missing, banned)：
      missing — 必须键缺失列表（目前只有 IML_KEY，非空 = 红）
      banned  — 检测到的私有/JIT 键列表（非空 = 红）
      ok      — missing 为空且 banned 为空
    解析失败视为 IML 缺失（保守处理）。
    """
    try:
        ents = read_plist(xml_bytes)
    except ValueError:
        return False, [IML_KEY], []
    missing = [] if ents.get(IML_KEY) is True else [IML_KEY]
    banned = [k for k in BANNED_KEYS if ents.get(k)]
    return not missing and not banned, missing, banned


def channel_ok(tool: str) -> tuple[bool, str]:
    """侧载渠道是否能保住 IML（免费队），以 R09 侧载工具现状.tsv 为准。

    tool 传工具名，空格或下划线均可，不区分大小写。
    返回 (ok, 说明文字)。
    未知渠道默认 ok=True，说明文字提示需自行核实。
    """
    key = tool.replace(" ", "_").lower()
    note = _CHANNEL_NOTE.get(key, f"{tool}：未在已知渠道列表中，请自行核实签名后 IML 是否保留（docs/研究/免费账号.md）")
    ok = _CHANNEL_IML.get(key, True)
    return ok, note


def window_hint(ios_ver: int, has_iml: bool, need_gb: float | None = None) -> str:
    """出包 / 首启时的窗口提示文案（一行中文）。

    need_gb — 本款地址需求（GiB），None = 未知（只报窗口大小，不对比）。
    """
    avail = window_gb(ios_ver, has_iml)
    iml_tag = "带 IML" if has_iml else "不带 IML"
    os_tag = f"iOS {ios_ver}" if ios_ver > 0 else "macOS"
    if avail == 0.0:
        return f"目标 {os_tag}、{iml_tag}：窗口大小待实测，无法估算"
    base = f"目标 {os_tag}、{iml_tag}：可用约 {avail:.0f} GB"
    if need_gb is None or need_gb <= 0:
        return base
    if avail >= need_gb:
        margin = avail - need_gb
        return f"{base}，本款需约 {need_gb:.0f} GB，余量 {margin:.1f} GB，充足"
    overshoot = need_gb - avail
    if has_iml:
        rec = "超出部分走远端翻译，可能更卡"
    else:
        rec = "超出部分走远端翻译，可能更卡；建议用带 IML 的签名渠道（SideStore 0.7.0 免费账号会丢 IML）"
    return f"{base}，本款需约 {need_gb:.0f} GB，超 {overshoot:.1f} GB；{rec}"


def _need_gb_from_tsv(path: Path) -> float | None:
    """从产物根 addr_need.tsv 读本款地址需求（GiB）。

    地址需求 = 别名区GB（大别名区游戏）或 普通堆MB/1024（无大别名区）。
    读取失败返回 None。
    """
    try:
        rows = dict(line.split("\t", 1) for line in path.read_text(encoding="utf-8").splitlines() if "\t" in line)
        alias_gb = int(rows.get("别名区GB", "0"))
        heap_mb = int(rows.get("普通堆MB", "0"))
        if alias_gb > 0:
            return float(alias_gb)
        if heap_mb > 0:
            return heap_mb / 1024
    except Exception:
        pass
    return None


def _profile_errors(profile: dict, entitlements: dict, bundle_id: str,
                    device_udid: str | None) -> list[str]:
    """Match declared permissions/identity/expiry, without authenticating a profile."""
    errors = []
    allowed = profile.get("Entitlements")
    if not isinstance(allowed, dict):
        return ["描述文件缺少权限字典"]
    _, missing, banned = check_entitlements_plist(plistlib.dumps(allowed))
    if missing:
        errors.append("描述文件未许可提高内存上限权限")
    if banned:
        errors.append("描述文件含私有 JIT 禁用权限")
    prefixes, teams = profile.get("ApplicationIdentifierPrefix"), profile.get("TeamIdentifier")
    signed_id = entitlements.get("application-identifier")
    signed_team = entitlements.get("com.apple.developer.team-identifier")
    pattern = allowed.get("application-identifier")
    team = allowed.get("com.apple.developer.team-identifier")
    if (not isinstance(prefixes, list) or not prefixes
            or not all(isinstance(x, str) and x for x in prefixes)
            or not isinstance(signed_id, str)
            or signed_id not in [f"{prefix}.{bundle_id}" for prefix in prefixes]):
        errors.append("主程序签名包名与 App / 描述文件前缀不符")
    if (not isinstance(pattern, str) or not isinstance(signed_id, str)
            or ("*" in pattern and (pattern.count("*") != 1 or not pattern.endswith("*")))
            or not isinstance(prefixes, list)
            or not any(isinstance(prefix, str) and pattern.startswith(prefix+".") for prefix in prefixes)
            or not (signed_id.startswith(pattern[:-1]) if pattern.endswith("*") else signed_id == pattern)):
        errors.append("描述文件 application-identifier 不匹配")
    if (not isinstance(teams, list) or not teams or not all(isinstance(x, str) and x for x in teams)
            or not isinstance(team, str) or not team or team not in teams or signed_team != team):
        errors.append("主程序 / 描述文件 team 不匹配")
    expiry = profile.get("ExpirationDate")
    if not isinstance(expiry, dt.datetime):
        errors.append("描述文件缺少有效到期时间")
    else:
        expiry = expiry.replace(tzinfo=dt.timezone.utc) if expiry.tzinfo is None else expiry.astimezone(dt.timezone.utc)
        if expiry <= dt.datetime.now(dt.timezone.utc):
            errors.append("描述文件已到期")
    devices = profile.get("ProvisionedDevices")
    if devices is not None and (not isinstance(devices, list) or not all(isinstance(x, str) and x for x in devices)):
        errors.append("描述文件设备清单无效")
    if device_udid is not None and (not device_udid or
            (profile.get("ProvisionsAllDevices") is not True
             and (not isinstance(devices, list) or device_udid not in devices))):
        errors.append("描述文件未许可指定设备")
    return errors


def _check_app(app_path: str, profile_path: str | None = None,
               device_udid: str | None = None) -> int:
    """Read all slices and automatically validate an embedded profile, if present."""
    try:
        app = Path(app_path).resolve(strict=True)
        info_path = app / "Info.plist"
        mac_layout = not info_path.exists()
        if mac_layout:
            info_path = app / "Contents/Info.plist"
        info = read_plist(info_path.read_bytes())
        executable, bundle_id = info.get("CFBundleExecutable"), info.get("CFBundleIdentifier")
        if (not isinstance(executable, str) or not executable or executable in (".", "..")
                or any(c in executable for c in "/\\:\0") or not isinstance(bundle_id, str) or not bundle_id):
            raise FormatError("Info.plist 主程序名或包名无效")
        binary = (app / "Contents/MacOS" / executable) if mac_layout else (app / executable)
        binary = binary.resolve(strict=True)
        if not binary.is_relative_to(app):
            raise FormatError("主程序路径超出 App")
        slices = read_macho_entitlements(binary.read_bytes())
        embedded = app / ("Contents/embedded.provisionprofile" if mac_layout else "embedded.mobileprovision")
        profiles = [embedded] if embedded.exists() or embedded.is_symlink() else []
        if profile_path is not None:
            explicit = Path(profile_path)
            if explicit not in profiles:
                profiles.append(explicit)
        if device_udid is not None and not profiles:
            raise FormatError("指定设备校验缺少安装描述文件")
        decoded_profiles = [read_profile(p.read_bytes()) for p in profiles]
        failed = False
        for index, ents in enumerate(slices, 1):
            ok, missing, banned = check_entitlements_plist(plistlib.dumps(ents))
            if missing:
                print(f"【红】签名里没有「提高内存上限」权限（{IML_KEY}）；{_CHANNEL_RECOMMEND}（切片 {index}）", flush=True)
            if banned:
                print(f"【红】签名含私有 JIT 键 {banned}，出包拒绝（切片 {index}）", flush=True)
            failed |= not ok
            for prof in decoded_profiles:
                errors = _profile_errors(prof, ents, bundle_id, device_udid)
                for error in errors:
                    print(f"【红】{error}（切片 {index}）", flush=True)
                failed |= bool(errors)
        if not profiles:
            print("未验安装描述文件：仅检查主程序权限内容", flush=True)
        elif device_udid is None:
            print("未指定设备：未核指定设备许可", flush=True)
        print("内容检查不验证代码签名密码学完整性或 CMS 信任链", flush=True)
        if not failed:
            print(f"🟢 签名权限内容核实：提高内存上限权限已确认（{len(slices)} 个切片）", flush=True)
        return 1 if failed else 0
    except (OSError, ValueError, TypeError, OverflowError) as exc:
        # File/decoder exceptions may contain device identifiers and personal paths.
        message = str(exc) if isinstance(exc, FormatError) else "无法读取 App / 签名 / 描述文件，或其内容无效"
        print(f"【红】{message}", flush=True)
        return 1


def _hint_device(ios_ver_str: str, addr_need_tsv: str | None) -> int:
    """CLI 入口：hint_device <ios_ver> [addr_need.tsv]。

    打印带 IML / 不带 IML 两种情况的窗口提示（E，只提示不中止）。
    """
    try:
        ios_ver = int(ios_ver_str)
    except (ValueError, TypeError):
        ios_ver = 0
    need_gb = _need_gb_from_tsv(Path(addr_need_tsv)) if addr_need_tsv else None
    for has_iml in (True, False):
        print(window_hint(ios_ver, has_iml, need_gb), flush=True)
    return 0


if __name__ == "__main__":
    # Chinese diagnostics must also work in Windows pipes with a legacy code page.
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, "reconfigure"):
            stream.reconfigure(encoding="utf-8")
    args = sys.argv[1:]
    if not args:
        print("用法：pack/iml_check.py check_app <S2Arm.app>\n"
              "      pack/iml_check.py hint_device <ios_ver> [addr_need.tsv]", file=sys.stderr)
        sys.exit(2)
    cmd, rest = args[0], args[1:]
    if cmd == "check_app":
        parser = argparse.ArgumentParser(description="只核权限/描述文件内容，不验证密码学签名或 CMS 信任链")
        parser.add_argument("app")
        parser.add_argument("--profile")
        parser.add_argument("--device-udid")
        options = parser.parse_args(rest)
        sys.exit(_check_app(options.app, options.profile, options.device_udid))
    elif cmd == "hint_device":
        sys.exit(_hint_device(rest[0] if rest else "0", rest[1] if len(rest) > 1 else None))
    else:
        print(f"不认得的子命令：{cmd}", file=sys.stderr)
        sys.exit(2)
