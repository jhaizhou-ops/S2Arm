"""装到 iPhone（10-26 维护者 定：Xcode 做主路、AltStore 备选）：打 iPhone 包出的是自签 IPA，iPhone 不认；
用玩家在 Xcode 里登录的 Apple ID（免费的个人团队就行）重签后，用数据线直接装上，再把资源包拷进去、逐文件核对。

  ① 团队：优先读 Xcode 团队缓存；账号存在但缓存缺失时核本机开发描述文件与可用签名身份。请求给了 teamId 就用它，否则优先付费团队；找不到不当作未登录
  ② 设备：连着线、已信任的那台 iPhone / iPad（恰好一台；请求可给 device 指定）
  ③ 包名：io.s2arm.games.<团队号小写>（所有游戏进同一个容器 App，主页亮点「一个 App 装下整个游戏库」，维护者 11-08）——包名在 Apple 那边按团队注册，别的团队用过的同名包名注册不了
  ④ pack/ensure_profile.sh（xcodebuild -allowProvisioningUpdates，带设备号时顺带登记这台设备）拿开发描述文件 → pack/dev_sign.py 重签（核「提高内存上限」）
  ⑤ devicectl 装 App → tools/push_pack.py 按内容增量推资源包（同 dev_run、Windows 一键装机）→ 起 App 只解包，机上 .applied 对上本包索引才算装好
10-26 本机实测（免费个人团队、测试设备2）：描述文件 27 秒、签名 7 秒、安装 3 秒。免费账号签的 App 7 天过期，到期连上再装一次就行（资源包已在机上的不重拷）。"""
from __future__ import annotations

import argparse
import contextlib
import json
import datetime
import hashlib
import os
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

from core import Failure, atomic, contained, read
from errors import recovery
import devcert
import layout


def profile_teams(env=None):
    """从未过期开发描述文件及可用私钥身份发现团队；最终账号权限仍由 Xcode 签名验证。"""
    deadline = time.monotonic() + 8
    try:
        p = subprocess.run(["security", "find-identity", "-v", "-p", "codesigning"], capture_output=True, text=True, env=env, timeout=5)
        identities = set(re.findall(r"\b[0-9A-Fa-f]{40}\b", p.stdout.upper())) if p.returncode == 0 else set()
    except (OSError, subprocess.TimeoutExpired):
        return []
    if not identities:
        return []
    home = Path((env or os.environ).get("HOME", str(Path.home())))
    folders = (home / "Library/Developer/Xcode/UserData/Provisioning Profiles", home / "Library/MobileDevice/Provisioning Profiles")
    out, seen = [], set()
    now = datetime.datetime.now(datetime.timezone.utc)
    for folder in folders:
        for path in sorted(folder.glob("*.mobileprovision")):
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                return out
            try:
                p = subprocess.run(["security", "cms", "-D", "-i", str(path)], capture_output=True, env=env, timeout=min(2, remaining))
                if p.returncode:
                    continue
                profile = plistlib.loads(p.stdout)
                expiry = profile.get("ExpirationDate")
                if not isinstance(expiry, datetime.datetime) or expiry.replace(tzinfo=datetime.timezone.utc) <= now:
                    continue
                ent = profile.get("Entitlements", {})
                teams = profile.get("TeamIdentifier", [])
                if len(teams) != 1 or not isinstance(teams[0], str) or not re.fullmatch(r"[A-Z0-9]{10}", teams[0]):
                    continue
                tid = teams[0]
                if ent.get("get-task-allow") is not True or not profile.get("ProvisionedDevices") or ent.get("com.apple.developer.team-identifier") != tid:
                    continue
                if not any(hashlib.sha1(cert).hexdigest().upper() in identities for cert in profile.get("DeveloperCertificates", [])):
                    continue
                if tid not in seen:
                    seen.add(tid)
                    # 缺少个人团队标记时保守按免费处理，不据缺字段断言付费资格。
                    out.append(dict(id=tid, name=profile.get("TeamName") or "", free=profile.get("LocalProvision") is not False))
            except (OSError, subprocess.TimeoutExpired, ValueError, TypeError, AttributeError):
                continue
    return out


# 玩家话术（环境检查、装机清单、失败提示同一份）。Xcode 里加完 Apple ID，团队要等账户页把团队列表显示出来才写进缓存（11-08 MacBook Air 实走）：
#   判据是团队号真的出现，不是账号存在
ACCOUNT_NONE = ("还没有登录 Apple ID：打开 Xcode，点菜单 Xcode › Settings › Apple Accounts，点 + 添加你的 Apple ID（免费的就行），"
                "选中账号，等团队列表显示出来，再回来重新检查。装了多个 Xcode 也只要登一个，账号是共用的。")
TEAM_PENDING = ("Apple ID 已经登录，但这台 Mac 还没有签名团队：点「解决办法」打开现成的引导项目，在 Xcode 里选 Personal Team，"
                "连上手机点运行一次，回来会自动打勾。也可以先到 Xcode › Settings › Apple Accounts 看团队列表有没有显示。")


def _security_text(args, env):
    try:
        p = subprocess.run(["security", *args], capture_output=True, text=True, env=env, timeout=10)
    except (OSError, subprocess.TimeoutExpired):
        return ""
    return p.stdout if p.returncode == 0 else ""


def development_identities(env=None):
    """钥匙串里带私钥、能用的开发证书的 SHA-1。"""
    text = _security_text(["find-identity", "-v", "-p", "codesigning"], env)
    return {h.upper() for h in re.findall(r'\b([0-9A-Fa-f]{40})\s+"(?:Apple Development|iPhone Developer):', text)}


def keychain_teams(env=None):
    """钥匙串开发证书的 OU 就是团队号，不依赖 Xcode 偏好缓存。证书看不出是否付费，按免费处理（只影响到期提示）；最终权限由 Xcode 签名验证。"""
    identities = development_identities(env)
    if not identities:
        return []
    text = _security_text(["find-certificate", "-a", "-Z", "-p"], env)
    out, seen = [], set()
    for sha, pem in re.findall(r"SHA-1 hash: ([0-9A-Fa-f]{40})\s+(-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----)", text, re.S):
        if sha.upper() not in identities:
            continue
        try:
            subject = subprocess.run(["/usr/bin/openssl", "x509", "-noout", "-subject"], input=pem, capture_output=True, text=True, env=env, timeout=5).stdout
        except (OSError, subprocess.TimeoutExpired):
            continue
        match = re.search(r"\bOU\s*=\s*([A-Z0-9]{10})\b", subject)
        if match and match[1] not in seen:
            seen.add(match[1])
            out.append(dict(id=match[1], name="", free=True))
    return out


PREFS_UNREADABLE = "S2ArmPrefsUnreadable"


def _xcode_prefs(env):
    p = subprocess.run(["defaults", "export", "com.apple.dt.Xcode", "-"], capture_output=True, env=env, timeout=20)
    if p.returncode:
        return {}
    # 第三方 Xcode 扩展的快捷键键名可能带控制字符（如 ESC），defaults 原样导出，XML 不允许，解析会失败：先去掉（#144）
    text = re.sub(rb"[\x00-\x08\x0b\x0c\x0e-\x1f]", b"", p.stdout)
    try:
        return plistlib.loads(text)
    except Exception:
        return {PREFS_UNREADABLE: True}


def signing_summary(env=None):
    """给诊断用的签名现状：只有版本和数量，不含账号和团队名。"""
    if os.name == "nt":
        return ""
    try:
        prefs = _xcode_prefs(env)
        version = subprocess.run(["xcodebuild", "-version"], capture_output=True, text=True, env=env, timeout=20).stdout.splitlines()[:1]
    except (OSError, subprocess.TimeoutExpired):
        prefs, version = {}, []
    accounts = prefs.get("DVTDeveloperAccountManagerAppleIDLists") or {}
    count = sum(len(xs) for xs in accounts.values() if isinstance(xs, list)) if isinstance(accounts, dict) else 0
    return (f"{version[0] if version else 'Xcode 未知'}；账号 {count} 个；团队缓存键{'读不了偏好' if PREFS_UNREADABLE in prefs else '有' if 'IDEProvisioningTeamByIdentifier' in prefs else '无'}；"  # 非玩家句
            f"可用团队 {len(xcode_account(env)[1])} 个；开发证书 {len(development_identities(env))} 张")


def xcode_account(env=None):
    """(有没有登录 Apple ID, 团队列表)：依次看 Xcode 团队缓存、本机描述文件、钥匙串开发证书，定位不到才算没有。"""
    if os.name == "nt":   # Windows 没有 Xcode 账号（也没有 defaults 命令）：签名走 Impactor
        return False, []
    prefs = _xcode_prefs(env)
    out, seen = [], set()
    for teams in (prefs.get("IDEProvisioningTeamByIdentifier") or {}).values():
        for t in teams or []:
            tid = t.get("teamID")
            if tid and tid not in seen:
                seen.add(tid)
                out.append(dict(id=tid, name=t.get("teamName") or "", free=bool(t.get("isFreeProvisioningTeam"))))
    accounts = prefs.get("DVTDeveloperAccountManagerAppleIDLists") or {}
    logged_in = isinstance(accounts, dict) and any(isinstance(xs, list) and any(isinstance(a, dict) and a.get("identifier") for a in xs) for xs in accounts.values())
    return logged_in, out or (profile_teams(env) if logged_in else []) or keychain_teams(env)


SIGNING_PBXPROJ = """// !$*UTF8*$!
{ archiveVersion = 1; classes = {}; objectVersion = 56; objects = {
A1000000000000000000000A = {isa = PBXBuildFile; fileRef = A1000000000000000000000B; };
A1000000000000000000000B = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = App.swift; sourceTree = "<group>"; };
A1000000000000000000000C = {isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = S2ArmSigning.app; sourceTree = BUILT_PRODUCTS_DIR; };
A1000000000000000000000D = {isa = PBXGroup; children = (A1000000000000000000000B, A1000000000000000000000E); sourceTree = "<group>"; };
A1000000000000000000000E = {isa = PBXGroup; children = (A1000000000000000000000C); name = Products; sourceTree = "<group>"; };
A1000000000000000000000F = {isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (A1000000000000000000000A); runOnlyForDeploymentPostprocessing = 0; };
A10000000000000000000010 = {isa = PBXNativeTarget; buildConfigurationList = A10000000000000000000013; buildPhases = (A1000000000000000000000F); buildRules = (); dependencies = (); name = S2ArmSigning; productName = S2ArmSigning; productReference = A1000000000000000000000C; productType = "com.apple.product-type.application"; };
A10000000000000000000011 = {isa = PBXProject; buildConfigurationList = A10000000000000000000012; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en, Base); mainGroup = A1000000000000000000000D; productRefGroup = A1000000000000000000000E; projectDirPath = ""; projectRoot = ""; targets = (A10000000000000000000010); };
A10000000000000000000012 = {isa = XCConfigurationList; buildConfigurations = (A10000000000000000000014); defaultConfigurationIsVisible = 0; defaultConfigurationName = Debug; };
A10000000000000000000013 = {isa = XCConfigurationList; buildConfigurations = (A10000000000000000000015); defaultConfigurationIsVisible = 0; defaultConfigurationName = Debug; };
A10000000000000000000014 = {isa = XCBuildConfiguration; buildSettings = {IPHONEOS_DEPLOYMENT_TARGET = 16.0; SDKROOT = iphoneos; SWIFT_VERSION = 5.0; ONLY_ACTIVE_ARCH = YES; }; name = Debug; };
A10000000000000000000015 = {isa = XCBuildConfiguration; buildSettings = {CODE_SIGN_STYLE = Automatic; GENERATE_INFOPLIST_FILE = YES; INFOPLIST_KEY_UILaunchScreen_Generation = YES; PRODUCT_BUNDLE_IDENTIFIER = "@BUNDLE@"; PRODUCT_NAME = "$(TARGET_NAME)"; TARGETED_DEVICE_FAMILY = "1,2"; }; name = Debug; };
}; rootObject = A10000000000000000000011; }
"""
SIGNING_APP = """import SwiftUI  # 非玩家句

@main struct S2ArmSigningApp: App {
    var body: some Scene { WindowGroup { Text("S2Arm 签名已就绪，可以回到电脑继续") } }
}
"""


def signing_project(c):
    """没有团队的玩家用的引导项目：放在私有目录，玩家在 Xcode 选 Personal Team、连手机运行一次，Xcode 就会生成证书和描述文件。"""
    root = c.private / "signing-helper"
    project = root / "S2ArmSigning.xcodeproj"
    project.mkdir(parents=True, exist_ok=True)
    bundle = "io.s2arm.signing.h" + hashlib.sha256(str(c.private).encode()).hexdigest()[:10]   # 免费账号的包名要全局唯一：按这台机的数据目录算，重开不变
    (project / "project.pbxproj").write_text(SIGNING_PBXPROJ.replace("@BUNDLE@", bundle), encoding="utf-8")
    (root / "App.swift").write_text(SIGNING_APP, encoding="utf-8")
    return dict(path=str(project))


def xcode_teams(env=None):
    return xcode_account(env)[1]


def no_team_failure(env=None):
    """没有可用团队时的失败：还没登录，和登录了但团队没同步，是两件事。"""
    return Failure(TEAM_PENDING, code="xcode_team_pending") if xcode_account(env)[0] else Failure(ACCOUNT_NONE, code="xcode_account_missing")


def pick_team(teams, want=None):
    if want:
        t = next((t for t in teams if t["id"] == want), None)
        if t:
            return t
        if not re.fullmatch(r"[A-Z0-9]{10}", want):
            raise Failure("Team ID 要是 10 位大写字母或数字，可以在 Xcode 的账户页或 Apple 开发者网站查到。", code="xcode_account_missing")
        return dict(id=want, name="", free=True)   # 玩家手填的：本机查不到也试，能不能用由 Xcode 签名给真实结果
    if not teams:
        raise no_team_failure()
    paid = [t for t in teams if not t["free"]]
    return (paid or teams)[0]


# 多款容器（启动器线 11-07，一个 App 装多款游戏；组装见 pack/ship_ext.py container、pack/jobs/ipa.py container）：
#   包名固定 io.s2arm.games.<团队号小写>：本来就按团队分（不会被别的团队占），不用 NX2Apple 那样「缺省包名被占 → 团队变体 → 落盘沿用」；
#     加款 / 换款都是同一个包名覆盖安装（不卸载，Documents 保留），一个团队只占一个 App ID（免费账号 7 天 10 个的额度）。换团队 = 换包名 = 新沙盒，旧存档要迁
#   设备侧每款文档根 Documents/games/<游戏号>（存档 / 直连见过的键 / unpack.log 在它下面），资源包根 Library/Application Support/S2Arm/games/<游戏号>/资源包
#     （11-11 挪出 Documents：几万个文件让「文件」App 与文件选择器「最近项目」一直「正在加载」；旧位置 Documents/games/<游戏号>/资源包 过渡期还认，见 pack_listing），
#   起这一款的启动上下文 @bundle/Games/<游戏号>/launch.ctx——与 ship_ext 容器布局同口径


def container_bundle_id(team, c=None):
    """S2A_CONTAINER_SUFFIX（开发用：同一台手机上同时装几份测试包）：包名加后缀 io.s2arm.games.<团队>.<后缀>，几份并存互不覆盖；
    只收小写字母 / 数字 / 连字符，不设时与玩家完全一样。付费团队没有免费账号每周 10 个包名的限制。
    给了 c 且这个团队的包名曾被别处占用、自动换过（bundle_switched）→ 用换过的那个，之后每次装机、推资源包都对同一个 App"""
    suffix = re.sub(r"[^a-z0-9-]", "", os.environ.get("S2A_CONTAINER_SUFFIX", "").lower())[:40]
    base = f"io.s2arm.games.{team.lower()}" + (f".{suffix}" if suffix else "")
    return (read(_bundle_switch_file(c), {}).get(team.lower()) or base) if c is not None else base


# 包名被别处占用（Apple 9401：玩家先用自己的签名工具签 S2Arm 时沿用了 io.s2arm.games.<团队> 这个包名，它就注册到了别的 Apple ID 下；
#   之后 Mac 一键装按同一个包名向 Xcode 账号注册被拒——玩家改了签名里的包名才装上，11-11 反馈）：自动换成 <包名>.s2 再签一次，记在私有目录
ALT_BUNDLE_SUFFIX = ".s2"


def _bundle_switch_file(c):
    return c.private / "bundle-switch.json"


def bundle_switched(c, team, bid):
    m = read(_bundle_switch_file(c), {})
    atomic(_bundle_switch_file(c), dict(m if isinstance(m, dict) else {}, **{team.lower(): bid}))


def container_display_name(app):
    """S2A_CONTAINER_NAME（开发用，与 S2A_CONTAINER_SUFFIX 配套）：主屏显示名，连各语言 InfoPlist.strings 里的一起换；不设时不动"""
    name = os.environ.get("S2A_CONTAINER_NAME", "").strip()
    if not name:
        return None
    for strings in Path(app).glob("*.lproj/InfoPlist.strings"):
        text = strings.read_text(encoding="utf-8", errors="replace")
        strings.write_text(re.sub(r'"CFBundleDisplayName"\s*=\s*".*?";', '"CFBundleDisplayName" = "%s";' % name.replace('"', ''), text), encoding="utf-8")
    return name




def sgrade_pending(c, games):
    """这几款里有没有要补 S 级优化 / 按新版改写器重做的（rewrite_refresh.pending_ios）；取不到改写器指纹 = 没法判，按「没有」（不因此重组容器）"""
    import rewrite_refresh
    try:
        rid = rewrite_refresh.rewriter_id(c)
    except (Failure, OSError, subprocess.SubprocessError):
        return False
    if any(rewrite_refresh.kept_todo(c, g, layout.ios_kit(c, g)) for g in games if g):   # 运行时留下、还没进 iPhone 件的 NRO（#8be819）：要重组容器补上
        return True
    pend = rewrite_refresh.pending_ios(c, [g for g in games if g], rid)
    # 这一版记号下已经试过、缺原件补不上的不算（不然每次「更新 iPhone」都白重装一遍）
    if any((layout.game_info(c, g).get("ios") or {}).get("sgradeMissing") != (rewrite_refresh.ios_key(c, g, rid) or "") for g in pend):
        return True
    import sgrade_bf   # 老包直连库缺可读瓦片版着色器（_bf）：取不到原料、这一代已试过的不算
    return any(sgrade_bf.due(c, g) for g in games if g)

def patches_results(c):
    import patches
    return patches.results(c)

def game_docs(gid):
    return f"Documents/games/{gid.upper()}"


DOCS_GAMES = "Documents/games"
PACK_GAMES = "Library/Application Support/S2Arm/games"   # 每款资源包放 <PACK_GAMES>/<游戏号>/资源包（设备侧宿主同口径）
# 备用位置（v0.3.3）：iOS 27 玩家机上 Library/Application Support/S2Arm 整条归 root、App 写不进，当时的壳把资源包搬到 Library/S2Arm/games
#   （那段迁移 11-15 已撤，存量手机上可能还留着这个目录）；手机上有它就一律推它（宿主同一判据：s2a_docs.h s2a_pack_base_rel 看 Library/S2Arm/games 在不在）
PACK_GAMES_ALT = "Library/S2Arm/games"


def game_pack(gid, games=PACK_GAMES):
    """本款设备侧资源包根（新位置，不在 Documents 里；games = PACK_GAMES_ALT 时是备用位置）"""
    return f"{games}/{gid.upper()}/资源包"  # 非玩家句


def game_pack_old(gid):
    """本款资源包旧位置（11-11 之前的宿主放在文档根下）：过渡期只读、只在新位置不在时推它（App 下次启动整个挪到新位置）"""
    return f"{game_docs(gid)}/资源包"  # 非玩家句


def game_ctx(gid):
    return f"@bundle/Games/{gid.upper()}/launch.ctx"


S_NO_USB = "这台 Mac 的 USB 上没看到 iPhone / iPad：换一根能传数据的线（充电线不行）、换个接口直连 Mac，并解锁手机。"
S_NOT_LISTED = "这台 Mac 看到手机插着，但设备服务还没列出它：解锁手机，在弹出的框里点「信任」；还不行就拔掉重插一次。"
S_MANY_WIRED = "连着不止一台 iPhone / iPad：只留要装的那一台。"
S_NETWORK = "能装，但网络传资源包慢、容易断：插上数据线再装更稳。"
S_MANY_NETWORK = "同一网络上有多台配对过的 iPhone / iPad：用数据线连上要装的那一台。"
# 装到哪台由玩家选、作业照办，不替玩家换一台（维护者 11-11：续签时玩家选的 iPhone 拔了线，旁边同网的 iPad 被装上了）
S_DEVICE_REQUIRED = "没说要装到哪台设备：在装机页选好 iPhone / iPad 再装。"
S_OFFLINE = "{0}「{1}」现在不在线：插上数据线，或让它和这台电脑连同一个 Wi-Fi 并解锁，再试一次。"
S_PICK_LISTED = "要装的那台（{0}）这次没列出来；这台电脑现在看得到：{1}——在装机页选其中一台再装。"
S_TRUST = "在 iPhone 上点「信任」，再输入手机的锁屏密码。"
S_DEV_MODE = "在 iPhone 上打开「设置 → 隐私与安全性 → 开发者模式」，按提示重启手机；重启后解锁，这里会自动打勾。"
S_TUNNEL = "和手机建立开发连接失败：解锁手机后再试；走无线的话换成数据线。"
S_DDI = "手机的开发者服务没准备好：解锁手机后再试；还不行就重启手机。"
PREPARE_COOLDOWN = 30   # 清单几秒问一次：配对框、更新映像这类有动静的步骤隔一会儿才重试


def _link(d):
    return d.get("connectionProperties", {})


def _mask(value):
    return f"{value[:4]}…{value[-2:]}" if len(value or "") > 8 else "…"


def _clean(text):
    """诊断里的 devicectl 原文：设备序列号、UUID 不进诊断包"""
    return re.sub(r"\b[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4,16}(?:-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12})?\b", "…", str(text or ""))


def _with_raw(sentence, raw):
    """定句走翻译，原文另起一行照原样显示"""
    tail = _clean(raw).strip().splitlines()
    return sentence + ("\n" + tail[-1] if tail else "")


def device_hint(want):
    """上屏时怎么称呼玩家指定的那台：设备名照写；设备号只写末尾 6 位——整串会被诊断脱敏换成 [DEVICE_ID] 占位、玩家看不懂（11-11 真机验收测出）"""
    return f"编号末尾 {want[-6:]}" if re.fullmatch(r"[0-9A-Fa-f-]{20,}", want) else f"「{want}」"


def device_kind(d):
    """devicectl 设备 → 「iPad」或「iPhone」（文案里写实际的设备类型，不写死 iPhone）；Apple Vision Pro 按 iPad 兼容装，写 iPad"""
    from diag import is_vision
    h = d.get("hardwareProperties", {})
    return "iPad" if h.get("platform") == "iPadOS" or (h.get("productType") or "").startswith("iPad") or is_vision(d) else "iPhone"


def _pick_device(devices, want, install=False):
    """要装的那台：返回 (设备, 问题)。候选 = devicectl 列出的每台带硬件 UDID 的设备（diag.is_candidate）：
    不按 reality / 配对 / 开发者服务 / 连接方式这些元数据筛（11-13 维护者：「明明插着一台手机就是硬说识别不了」）——
    装得上装不上让 devicectl 装的那一步说了算，真失败报它的原文和下一步。
    给了 want（玩家选的那台）：列着就用它；没列着但只有一台候选就用那一台（完成页写的是实际装到的那台）；
    多台候选都对不上 → 列出看得到的让玩家选；一台都没有 → (None, "")，调用方按 USB 现状说。
    没给 want：只给装机前清单看（polling），有线优先挑出连着的那台供界面显示"""
    from diag import is_candidate
    phones = [d for d in devices if is_candidate(d)]
    if want:
        def named(d):
            return want in (d.get("identifier"), d.get("hardwareProperties", {}).get("udid"), (d.get("deviceProperties", {}).get("name") or "").strip())
        chosen = [d for d in phones if named(d)]
        if chosen:
            return chosen[0], ""
        if len(phones) == 1:
            return phones[0], ""
        if phones:
            seen = "、".join(f"{device_kind(d)}「{(d.get('deviceProperties', {}).get('name') or '').strip()}」" for d in phones)
            return None, S_PICK_LISTED.replace("{0}", device_hint(want)).replace("{1}", seen)
        return None, ""
    if install:   # 真装机没指定哪台：只有一台候选就用它；多台要玩家选；零台交调用方按 USB 现状说
        return (phones[0], "") if len(phones) == 1 else (None, S_DEVICE_REQUIRED if phones else "")
    live = [d for d in phones if _link(d).get("transportType") in ("wired", "localNetwork") or _link(d).get("tunnelState") == "connected"]
    wired = [d for d in live if _link(d).get("transportType") == "wired"]
    if len(wired) > 1:
        return None, S_MANY_WIRED
    if not wired and len(live) > 1:
        return None, S_MANY_NETWORK
    if wired or live:
        return (wired or live)[0], ""
    return None, ""


def _cooled(c, device, step, polling):
    """清单轮询时同一步隔 PREPARE_COOLDOWN 秒才再做一次；真正装机时总是做"""
    if not polling:
        return True
    path = c.private / "device-prepare.json"
    try:
        marks = json.loads(path.read_text())
    except (OSError, ValueError):
        marks = {}
    key = f"{device.get('identifier')}:{step}"
    if time.time() - marks.get(key, 0) < PREPARE_COOLDOWN:
        return False
    marks[key] = time.time()
    atomic(path, marks)
    return True


LINK_READS, LINK_RETRY_WAIT = 3, 3   # 真装机找设备：最多读 3 次、间隔 3 秒（单测置 0）


def device_link(c, want="", polling=False, install=False):
    """读设备并把它准备到能装（玩家不用打开 Xcode）：配对 → 开发者模式 → 拉起隧道和开发者服务 → 必要时更新开发者磁盘映像。
    返回 {device, stage, problem, trace}：stage 是没过的环节（connected / trusted / developerMode / prepare，全过为空）；polling = 装机前清单轮询。"""
    import target
    from diag import devicectl
    trace, limits = [], (30, 20, 120) if polling else (120, 60, 240)
    def note(step, rc, raw): trace.append(dict(step=step, rc=rc, raw=_clean(raw)[-1500:]))
    def say(text):
        if not polling: c.emit("progress", text)
    def read():
        devices, why, rc, raw = target.device_list(c, timeout=30 if polling else 60)
        note("list devices", rc, raw)
        return devices, why
    def step(name, *args, timeout):
        data = {}
        try:
            rc, data, raw = devicectl(c, *args, timeout=timeout)
        except subprocess.TimeoutExpired:
            rc, raw = "timeout", f"超过 {timeout} 秒"
        except OSError as e:
            rc, raw = "oserror", str(e)
        note(name, rc, raw)
        return rc, data, raw
    def out(device, stage, problem, devices=()):
        return dict(device=device, stage=stage, problem=problem, trace=trace, devices=list(devices))
    def again(dev):
        devices, why = read()
        fresh = next((d for d in devices if d.get("identifier") == dev.get("identifier")), None)
        return devices, why, fresh
    devices, why = read()
    dev, problem = (None, "") if why else _pick_device(devices, want, install)
    # 真装机时一次没读到 / 没看到要装的那台就再读：devicectl 列表会瞬时空、超时，或手机正从同网切到数据线（诊断#091bcf 同期玩家反馈
    #   「刚装上一款、下一次就说认不出」）。装机前清单轮询本来就每几秒再读，不在这里等
    for _ in range(LINK_READS - 1):
        if polling or not (why or problem or dev is None):
            break
        time.sleep(LINK_RETRY_WAIT)
        devices, why = read()
        dev, problem = (None, "") if why else _pick_device(devices, want, install)
    if why:
        return out(None, "connected", why)
    if problem:
        return out(None, "connected", problem, devices)
    if dev is None:
        usb = target.usb_idevices()
        note("usb", 0, "、".join(usb) or "没有 iPhone / iPad")  # 非玩家句
        return out(None, "connected", S_NOT_LISTED if usb else S_NO_USB, devices)
    # 下面每一环（配对 / 现查详情 / 开发者模式 / 开发者服务）真装机时只「去做」、不「拦」：做不成记进诊断轨迹，照样往下装，
    #   装的那一步失败时按 devicectl 原文归码给下一步（install.classify：未配对、开发者模式、锁屏…）。只有装机前清单轮询把它们当提示返回
    def hold(stage, problem):
        if polling:
            return out(dev, stage, problem, devices)
        note("继续装（不预先拦）", stage, problem)  # 非玩家句
        return None
    if _link(dev).get("pairingState") != "paired":
        raw = ""
        if _cooled(c, dev, "pair", polling):
            say("正在请手机信任这台 Mac")
            _, _, raw = step("manage pair", "manage", "pair", "--device", dev["identifier"], timeout=limits[0])
            devices, why, fresh = again(dev)
            dev = fresh or dev
        if _link(dev).get("pairingState") != "paired" and (r := hold("trusted", _with_raw(S_TRUST, raw))):
            return r
    def services_ready(d):
        return d.get("deviceProperties", {}).get("ddiServicesAvailable") is not False
    def refresh_details():
        nonlocal dev, devices
        rc, data, raw = step("device info details", "device", "info", "details", "--device", dev["identifier"], timeout=limits[1])
        fresh = data.get("result") if isinstance(data, dict) else None
        props = fresh.get("deviceProperties") if isinstance(fresh, dict) else None
        if rc != 0 or not isinstance(props, dict) or fresh.get("identifier") != dev["identifier"] or props.get("developerModeStatus") not in ("enabled", "disabled"):
            if _link(dev).get("transportType") != "wired":   # 走 Wi-Fi 的那台现查不通 = 它现在不在线（人走开 / 锁屏睡眠），如实说是哪台，原文进诊断
                return S_OFFLINE.replace("{0}", device_kind(dev)).replace("{1}", (dev.get("deviceProperties", {}).get("name") or "").strip())
            return _with_raw(S_TUNNEL, raw)
        # list devices 可能仍留着旧值；以指定设备的详情为准，同时更新诊断快照。
        dev = fresh
        devices = [fresh if d.get("identifier") == dev["identifier"] else d for d in devices]
        return ""
    # 真装机（非清单轮询）对选中的那台一律现查一次详情：设备列表里「同网」只说明配对过，不说明此刻连得上（11-11 玩家实报：
    #   没插线点续签，列表里那台标着同网，走到「读已装游戏」才报「找不到设备」）；现查不通就在开工前拦下
    if not polling or dev.get("deviceProperties", {}).get("developerModeStatus") not in ("enabled", None) or _link(dev).get("tunnelState") != "connected" or not services_ready(dev):
        say("正在和设备建立开发连接")
        problem = refresh_details()
        if problem and (r := hold("prepare", problem)):
            return r
    if dev.get("deviceProperties", {}).get("developerModeStatus") == "disabled" and (r := hold("developerMode", S_DEV_MODE)):
        return r
    if not services_ready(dev):
        raw = ""
        if _cooled(c, dev, "ddi", polling):
            say("正在准备手机的开发者服务")
            _, _, raw = step("manage ddis update", "manage", "ddis", "update", timeout=limits[2])
            problem = refresh_details()
            if problem and (r := hold("prepare", problem)):
                return r
            if dev.get("deviceProperties", {}).get("developerModeStatus") == "disabled" and (r := hold("developerMode", S_DEV_MODE)):
                return r
        if not services_ready(dev) and (r := hold("prepare", _with_raw(S_DDI, raw))):
            return r
    return out(dev, "", "", devices)


def _write_link_report(c, link):
    """失败时写进诊断包（日志目录 core.logs_root）：每步退出码和原文、每台设备的连接状态；序列号打码，不写设备名"""
    lines = ["# 设备连接诊断"]  # 非玩家句
    lines += [f"{t['step']}: rc={t['rc']} {t['raw']}" for t in link["trace"]]
    for d in link["devices"]:
        h, p, cp = d.get("hardwareProperties", {}), d.get("deviceProperties", {}), _link(d)
        lines.append(f"device {_mask(h.get('udid') or d.get('identifier') or '')} {h.get('productType')} reality={h.get('reality')} transport={cp.get('transportType')} pairing={cp.get('pairingState')} "
                     f"tunnel={cp.get('tunnelState')} boot={p.get('bootState')} developerMode={p.get('developerModeStatus')} ddi={p.get('ddiServicesAvailable')}")
    problem = link["problem"]
    for d in link["devices"]:   # 结论里列着「看得到的设备」时带了名字：报告不写设备名（同上）
        name = (d.get("deviceProperties", {}).get("name") or "").strip()
        if name:
            problem = problem.replace(f"「{name}」", "「<设备名>」")  # 非玩家句
    lines.append(f"结论: stage={link['stage']} {problem}")  # 非玩家句
    target = c.logs / f"{c.task}-device.log"
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text("\n".join(lines) + "\n", encoding="utf-8")


def phone(c):
    import target
    want = (c.r.get("device") or "").strip()   # 没给：只连着一台就用它（device_link → _pick_device install=True），多台才要玩家选
    link = device_link(c, want, install=True)
    if link["problem"]:
        _write_link_report(c, link)
        code = "device_required" if link["problem"] == S_DEVICE_REQUIRED else "device_not_connected" if link["stage"] == "connected" else "device_not_ready"
        raise Failure(link["problem"], code=code)
    return target._row(link["device"], c.env()["DEVELOPER_DIR"], with_link=True)


def udid_of(c, ident):
    from diag import devicectl
    rc, data, _ = devicectl(c, "list", "devices", timeout=60)
    for d in data.get("result", {}).get("devices", []) if rc == 0 else []:
        if d.get("identifier") == ident:
            return d.get("hardwareProperties", {}).get("udid") or ""
    return ""


def usb_mbps(udid, env=None):
    """这台 iPhone 现在的 USB 连接速率（Mb/s）：system_profiler 里设备序列号 = 去掉横杠的硬件 UDID；没插线 / 走无线 / 读不到 = 0"""
    if not udid:
        return 0
    try:
        p = subprocess.run(["system_profiler", "SPUSBHostDataType", "-json"], capture_output=True, text=True, env=env, timeout=60)
        data = json.loads(p.stdout or "{}")
    except Exception:
        return 0
    want = udid.replace("-", "").upper()
    def walk(o):
        if isinstance(o, dict):
            if str(o.get("USBDeviceKeySerialNumber", "")).replace("-", "").upper() == want:
                m = re.match(r"([\d.]+)\s*([MG])b/s", str(o.get("USBDeviceKeyLinkSpeed", "")))
                return int(float(m.group(1)) * (1000 if m.group(2) == "G" else 1)) if m else 0
            o = list(o.values())
        for v in o if isinstance(o, list) else ():
            r = walk(v)
            if r:
                return r
        return 0
    return walk(data)


# 申请描述文件 / 签名失败时 xcodebuild 的报错 → 玩家能照做的错误码
SIGN_ERRORS = (
    (r"等钥匙串授权超时", "keychain_prompt"),   # pack/ensure_profile.sh：第一次签名的钥匙串框没人点（11-08 Spare-host 实测）  # 非玩家句
    (r"Xcode 看不到这台 iPhone，账号上也还没登记它|has no devices from which to generate", "device_not_visible"),   # pack/ensure_profile.sh 兜底后核出描述文件不含这台 / 账号一台设备都没有（11-16）  # 非玩家句
    (r"needs to be unlocked|device is locked|Unlock the device", "device_locked"),   # 10-26 测试设备2 锁屏：xcodebuild 等不到目的设备超时
    # 免费 Apple ID 有两个不同的上限，原文措辞能分开，办法也不同：
    #   ① 包名（App ID）额度：签名前向 Apple 注册包名时被拒，Apple 错误 9120，Xcode 原文
    #      「Your maximum App ID limit has been reached. You may create up to 10 App IDs every 7 days.」——
    #      说的是「App ID」，按 7 天窗口计，删 App 不退额度 → free_appid_limit；
    #   ② 设备同时装 3 个自签 App：签名已过、装机（devicectl / 系统安装服务）时设备拒收，原文
    #      「This device has reached the maximum number of installed apps using a free developer profile」（iOS 27）、
    #      「The maximum number of apps for free development profiles has been reached」（较早 iOS / Xcode）——
    #      说的是「apps」装在这台设备上，删一个就能装 → free_app_limit。
    # 两条正则互不相交：①只认「App ID(s)」字样或带 error / code 前缀的 9120，②的「apps」后面不跟「ID」；
    # ①仍排在前面，万一一行里两种字样都有，按删 App 无效的那件事报，免得玩家白删。
    (r"App ID limit|\b10 App IDs\b|maximum number of App IDs|(?:error|code)\D{0,20}\b9120\b", "free_appid_limit"),
    (r"maximum number of (?:installed )?apps\b|(?:maximum|limit)[^\n]{0,100}free development profiles", "free_app_limit"),
    (r"Personal development teams[^\n]{0,160}do not support", "free_team_capability"),   # #897 免费个人团队申请了只有付费团队才有的权限（如扩展虚拟寻址）
    (r"(?:error|code)\D{0,20}\b9401\b|App ID with Identifier[^\n]{0,120}is not available", "app_id_taken"),   # 包名已被占用（Apple 9401）
    # 手机上已有同包名、别的签名装的 App（玩家自签装过 S2Arm）：系统安装服务拒绝覆盖（installation_proxy MismatchedApplicationIdentifierEntitlement）
    (r"MismatchedApplicationIdentifierEntitlement|application-identifier entitlement string[^\n]{0,240}does not match", "app_other_signer"),
    (r"Developer\s*Mode\s*(?:is\s*)?(?:disabled|not enabled|required)|DeveloperModeDisabled", "developer_mode_required"),
    (r"pairing (?:record|relationship)[^\n]{0,80}(?:invalid|missing|expired)|not paired|pair (?:the )?device again|InvalidHostID", "device_pairing_required"),
    (r"provisioning profile[^\n]{0,100}(?:has expired|is expired|expired on)|expired provisioning profile", "provisioning_expired"),
    (r"No Account for Team|No accounts|not logged in|Your session has expired", "xcode_account_missing"),
    (r"No signing certificate|No certificate for team|Signing certificate is invalid|doesn't include signing certificate", "signing_certificate_missing"),
)


def classify(text, default="signing_failed"):
    for pat, code in SIGN_ERRORS:
        if re.search(pat, text, re.I):
            return code
    return default


def ios_pack(c, gid):
    """这款的资源包（image/ios/.pack）；还没出 iPhone 版 / 没有资源包就不装、不报成功（审计 18:00 P1-58：原先照装、启动器写死「资源包也拷好了」，打开游戏才进缺资源页）"""
    if not layout.has_ios_kit(c, gid):
        raise Failure("这款游戏还没出 iPhone 包：先点「打 iPhone 包」。", code="job_failed")
    pack = layout.ios_pack(c, gid)
    if not (pack / "manifest.json").is_file():
        raise Failure(f"没找到这款的资源包（{pack}），没有装。请重新「打 iPhone 包」后再装。", code="pack_missing")
    return pack


def pack_id(pack):
    """资源包号：清单的 index_sha256；清单没写就按推送实际用的 index.tsv 现算（原先缺这个字段就整单不装，预检清单 #16：推送本来不读它）"""
    pid = read(Path(pack) / "manifest.json", {}).get("index_sha256") or ""
    if not pid:
        try:
            pid = hashlib.sha256((Path(pack) / "index.tsv").read_bytes()).hexdigest()
        except OSError:
            pid = ""
    return pid


PUSHING = "正在传输资源"   # 推送阶段的进度消息（定文案，两端前端按它本地化；数字走 done / total / unit）


def push_progress(c, done, total, step, steps):
    """推资源包的作业计数（Mac 解析 push_pack 的机器读行、Windows 直接回调，同一出口）：done / total 字节，unit = B；前端据此画百分比、速度、剩余时间。
    没有要推的（total = 0）不发计数，免得画出 0/0；传完（done = total）也只是「传完」，之后的机上解包另有「机上解包 k/n」计数，最终成功仍以解包确认为准"""
    if total > 0:
        c.emit(message=PUSHING, done=done, total=total, unit="B")


def push_stage(c, name, done=None, total=None):
    """推资源包之前的准备子阶段（Mac 解析 push_pack 的 S2A_PUSH_STAGE 行、Windows 直接回调，同一出口）：名字原样上屏，有字节就带计数"""
    if total:
        c.emit(message=name, done=done or 0, total=total, unit="B")
    else:
        c.emit("message", name)


def img_pack(pack):
    """单一 IMG 形态的资源包（manifest v3 format=img，pack/img.py convert）：传完并核过 game.img 长度即装好，不再起 App 等机上解包——
    机上要从 game.img 解出的几个小件由玩家打开 S2Arm 时自己完成（11-11 维护者：启动器到「完整传到手机并校验通过」就结束）"""
    try:
        return json.loads((Path(pack) / "manifest.json").read_text(encoding="utf-8")).get("format") == "img"
    except (OSError, ValueError, AttributeError):
        return False


def push_pack(c, ident, bid, pack, udid=None, docs=None, ctx=None, pack_root=None):
    """资源包推进 App：调 Mac / Windows 共用的 tools/push_pack.py run（同 dev_run、Windows 一键装机、s2armctl push-pack，
    #206 / PR #470、11-06 两端合一）——按 sha256 只推机上没有 / 变了的文件（免费账号 7 天到期重装、改一点重出一版时只推几个文件），
    残留推送包按完整性处理、推前抽查机上实况，一批 ≤1 GB 流式写进 <资源包根>/.incoming/；传完并核过即装好，不起 App——机上解开由 App 第一次打开时自己做。
    多款容器：docs = 本款设备侧文档根 Documents/games/<游戏号>、pack_root = 本款设备侧资源包根（pick_pack_root 选的那处）、
    ctx = 本款启动上下文（有它即按多款容器拉起到游戏库）。
    返回（推的文件数, 字节数）"""
    import diag
    got = {}
    def line(text):
        m = re.match(r"S2A_PUSH_PROGRESS (\d+) (\d+) (\d+) (\d+)$", text.strip())   # tools/push_pack.py --progress-lines：每推完一批的已传 / 本次待传总字节（#266）
        if m:
            push_progress(c, *map(int, m.groups()))
            return
        m = re.match(r"S2A_PUSH_STAGE (.+?)\t(\d*)\t(\d*)$", text.strip("\r\n"))   # 推之前的准备子阶段（核对手机上的文件 / 检查手机空间 / 准备资源（拼镜像）按字节）
        if m:
            push_stage(c, m.group(1), int(m.group(2)) if m.group(2) else None, int(m.group(3)) if m.group(3) else None)
            return
        m = re.search(r"推 (\d+) 个文件 (\d+) MB", text)  # 非玩家句
        if m: got.update(files=int(m.group(1)), mb=int(m.group(2)))
        m = re.search(r"机上解包 (\d+)/(\d+)", text)   # tools/push_pack.py apply 每解完一包打一行：启动器显示「机上解包 13/17」  # 非玩家句
        if m: c.emit(message=f"机上解包 {m.group(1)}/{m.group(2)}", done=int(m.group(1)), total=int(m.group(2)), unit="包")  # 非玩家句
    env = dict(c.env(), S2A_DEVICECTL=str(diag.COREDEVICE / "Resources/bin/devicectl"))
    if c.r.get("acceptLowSpace") is True: env["S2A_PUSH_ACCEPT_LOW_SPACE"] = "1"   # 玩家在「手机空间看起来不够」那页点了「仍然继续」（device_space_low）
    if udid: env["S2A_PUSH_UDID"] = udid   # 有 UDID + App 内置 s2a-devpush（S2A_PREBUILT_TOOLS/devpush）→ 每批流式写手机，否则退回 devicectl（11-06）
    log = c.logs / (c.task + "-push" + (f"-{docs.rsplit('/', 1)[-1]}" if docs else "") + ".log")
    extra = (["--docs", docs] if docs else []) + (["--pack-root", pack_root] if pack_root else []) + (["--launch-ctx", ctx] if ctx else [])
    try:
        # 传完并核过就算装好，一律不由电脑起 App 解开（11-13 维护者：「把 App 装上以后直接把包传过去放在位置上不就行了吗，玩家自己在手机上再去点信任」）：
        #   解开由 App 第一次打开时自己做（多款容器的游戏库、单一 IMG、下游单款 App 的壳同样）。原先不带上下文的单款 App（下游壳）推完要拉起 App 解包，
        #   免费账号第一次装还没信任开发者时拉不起，作业打了红却报完成（假绿）；完成页本来就写「第一次打开前信任你的 Apple ID」（install.done.trust）
        c.run([sys.executable, "-B", c.engine / "tools/push_pack.py", "run", ident, bid, pack, "--via", "devicectl", "--progress-lines", *extra], log, env=env, on_line=line)
    except Failure as e:
        if e.code != "tool_exit":
            raise
        text = log.read_text(encoding="utf-8", errors="replace") if log.is_file() else ""
        m = APPLY_FAILED.search(text)   # tools/push_pack.py apply：App 自己写的解开失败原因（如 #569 目录写不进），原样上屏，不说「推不进」「没有开始」
        if m:
            raise Failure(f"资源包已传到 iPhone，但手机上解开失败：{m.group(1)}", code="job_failed") from e
        m = re.search(r"资源包推进去了，但(机上解包 \d+ 秒没有新进展[^：\n]*|起 App 后 \d+ 秒机上解包没有开始)", text)   # tools/push_pack.py apply：按进度判停住（11-07）  # 非玩家句
        if m:   # 旧口径的「停住」（推包工具现在报成下面的「还差最后一步」）：同样按传输成功 + 提醒（装机原则 11-11）
            c.diagnostic(f"资源包已传完，但{m.group(1)}：请打开这款游戏，保持在前台等它导入完，会自动进入游戏。", code="manual_unpack_required", severity="warning")
            return got.get("files", 0), got.get("mb", 0) << 20
        m = re.search(r"资源包已传完，还差最后一步：[^\n]*", text)   # tools/push_pack.py NeedsPlayer：电脑拉不起 App，传输本身成功（#192）  # 非玩家句
        if m:
            c.diagnostic(m.group(0), code="manual_unpack_required", severity="warning")
            return got.get("files", 0), got.get("mb", 0) << 20
        m = re.search(r"^S2A_PUSH_CODE (device_space_low|ios_install_no_space|ios_install_dir_unwritable)\t([^\n]+)", text, re.M)   # tools/push_pack.py：估算空间不够（玩家可确认继续）/ 真写满了 / 机上目录 App 写不进（删除重装）
        if m:
            raise Failure(m.group(2), code=m.group(1)) from e
        m = re.search(r"iPhone 写不进资源包：[^\n]*", text)   # tools/push_pack.py probe：推之前写探针失败、手机确实锁着（#333）  # 非玩家句
        if m:
            raise Failure(m.group(0), code="device_locked") from e
        m = re.search(r"iPhone 写不进资源包（[^\n]*", text)   # probe：写不进但手机没锁 / 判不了 = 连接问题（带原文），不冒充锁屏（11-13）  # 非玩家句
        if m:
            raise Failure(m.group(0), code="resource_transfer_failed") from e
        from errors import tool_reason
        raise Failure("资源包推不进 iPhone：" + tool_reason(log), code="resource_transfer_failed") from e  # 非玩家句
    return got.get("files", 0), got.get("mb", 0) << 20


def push_cheats(c, device, bid, gid, docs):
    """金手指（11-12）：这款文件夹 cheats/ 里的 txt（出包时从公开库取的 + 玩家导入的）拷到机上本款文档根 cheats/，
    游戏内金手指菜单（ios/vpad_cheats.m）与服务层 Cheats.cs 读那里；改代码的条目出包时已编进包。开关 enabled.txt / 状态 status.txt 不推（不盖玩家在手机上的选择）。
    拷不进只记黄、不挡装机"""
    import cheats
    d = cheats.cheats_dir(c, gid.upper(), create=False)
    files = [f for f in layout.entries(d, "*.txt") if f.name not in cheats.SKIP]   # ._<名>.txt（exFAT 附属文件）不推进手机金手指目录
    bad = 0
    for f in files:
        r = subprocess.run(["xcrun", "devicectl", "device", "copy", "to", "--device", device, "--domain-type", "appDataContainer",
                            "--domain-identifier", bid, "--source", str(f), "--destination", f"{docs}/cheats/{f.name}"],
                           capture_output=True, text=True, timeout=120)
        bad += r.returncode != 0
    if files:
        print(f"[装机] 金手指文件 {len(files) - bad}/{len(files)} 份拷进手机{'（有拷不进的，游戏内菜单里会缺几份）' if bad else ''}", file=sys.stderr, flush=True)  # 非玩家句


def push_mods(c, ph, gid, had):
    """资源替换类 mod（11-15）：这款游戏文件夹 mods/<名字>/romfs 推进机上本款文档根 mods/（服务层 RomFsMods.cs 起局叠上）。
    had = 上次推过的 {名字: 内容记号}（设备记录 games.<款>.mods）：记号变了的整份重推、电脑上删了的机上也删；玩家在手机上自己放的别的 mod 不碰。
    推不进只记黄、不挡装机。→ 这次推完后机上的 {名字: 记号}（推失败的那份按没推算，下次再推）"""
    import mods
    home = mods.mods_dir(c, gid, create=False)
    local = {d.name: mods.fingerprint(d) for d in layout.entries(home) if d.is_dir() and not d.name.startswith(".")}
    if not local and not had:
        return {}
    now, base = dict(had), f"{game_docs(gid)}/{mods.DIR}"
    try:
        with tempfile.TemporaryDirectory(dir=c.private) as w:
            cl = ph.client(w)
            for n in [n for n in had if local.get(n) != had[n]]:
                ok, out = cl.rm(f"{base}/{n}")
                if not ok:
                    raise RuntimeError(f"删手机上的旧 mod「{n}」：{out.splitlines()[-1] if out else '失败'}")  # 非玩家句
                now.pop(n)
            for n, fp in local.items():
                if had.get(n) == fp:
                    continue
                files = [f for f in layout.entries(home / n, recursive=True) if f.is_file() and not f.is_symlink()]   # ._<名> 不推进 romfs 叠加层
                c.emit("message", f"正在把 mod「{n}」推进 iPhone（{len(files)} 个文件）")
                for f in files:
                    cl.put(str(f), f"{base}/{n}/{f.relative_to(home / n).as_posix()}")
                now[n] = fp
    except Exception as e:   # 推不进：已推好的记下，其余下次装机再推
        c.diagnostic(f"mod 没全推进 iPhone，这次游戏里会缺几份，下次「装到 iPhone」会补推：{str(e)[:200]}", code="resource_transfer_failed", severity="warning")  # 非玩家句
    return now


APPLY_FAILED = re.compile(r"资源包推进去了，但手机上解开失败：([^\n]+)")   # tools/push_pack.py apply 读到解包日志「解包失败：…」时报的那句  # 非玩家句


def pull_seen(c, ident, bid, gid, tag, docs="Documents"):
    """装之前把这台设备记下的见过的键（直连线 Documents/wire/<程序号大写>/pso_user.tsv）拉回游戏库 games/<程序号>/seen/<设备>.tsv，
    下次打包按它重算两段式热键（hotset.py）；第一次装 / 没开过直连 / 拉不到都不算错。设备上是追加写：拉回的是已有那份的续写就覆盖，
    否则（换包后机上重新记了）另存一份，多份由 hotset.rank 合并去重"""
    from diag import devicectl
    dest = layout.path(c, gid, "seen", re.sub(r"[^0-9A-Za-z-]", "", tag) + ".tsv")
    with tempfile.TemporaryDirectory(dir=c.private) as d:
        rc, _, _ = devicectl(c, "device", "copy", "from", "--device", ident, "--domain-type", "appDataContainer", "--domain-identifier", bid,
                             "--source", f"{docs}/wire/{gid.upper()}/pso_user.tsv", "--destination", f"{d}/s", timeout=120)
        got = Path(d, "s")
        if rc or not got.is_file():
            return False
        new = got.read_bytes()
        if dest.is_file():
            old = dest.read_bytes()
            if old.startswith(new):
                return False
            if not new.startswith(old):
                dest = dest.with_name(f"{dest.stem}-{time.strftime('%Y%m%d%H%M%S')}.tsv")
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(got, dest)
        return True


def app_running(c, ident, bid):
    """手机上这个包名的 App（S2Arm 容器）现在是不是在跑：进程可执行文件落在它的安装目录下 = 在跑。→ True / False（没装也算不在跑）/ None（查不清）。
    自动推送前查（#8be819，phone_kept_pull）：在玩就不推，推送装 App 会把这局杀掉"""
    from diag import devicectl
    rc, apps, _ = devicectl(c, "device", "info", "apps", "--device", ident, "--bundle-id", bid, timeout=60)
    if rc:
        return None
    urls = [a["url"].rstrip("/") + "/" for a in (apps.get("result") or {}).get("apps") or [] if isinstance(a, dict) and a.get("bundleIdentifier") == bid and a.get("url")]
    if not urls:
        return False
    rc, procs, _ = devicectl(c, "device", "info", "processes", "--device", ident, timeout=60)
    if rc:
        return None
    exe = [p.get("executable") or "" for p in (procs.get("result") or {}).get("runningProcesses") or [] if isinstance(p, dict)]
    # 只认主程序本身：<安装目录>/<CFBundleExecutable>。安装目录下还有系统常驻拉起的扩展进程（主屏小组件 PlugIns/S2ArmWidget.appex，11-16 进壳），
    #   和玩家在不在玩无关——原先「落在安装目录下」就算在跑，phone_kept_pull 一直回 running=true，自动补件 / 提示更新从不发起
    #   （11-16 真机实测：App 已退出，只剩小组件进程）。按主程序全路径比，以后再加扩展（Live Activity 等）也不会算进来
    main = main_executable(c)
    return any(e == u + main for e in exe for u in urls)


def main_executable(c):
    """装到手机上的容器 App 的主程序文件名：游戏库根 S2Arm.ipa（layout.phone_ipa，装机时组装的那份）里 Info.plist 的 CFBundleExecutable；
    读不到（还没装过 / 文件坏）→ 壳的缺省名 S2Arm"""
    import zipfile
    try:
        with zipfile.ZipFile(layout.phone_ipa(c)) as z:
            name = next(n for n in z.namelist() if re.fullmatch(r"Payload/[^/]+\.app/Info\.plist", n))
            exe = plistlib.loads(z.read(name)).get("CFBundleExecutable")
            if isinstance(exe, str) and exe and "/" not in exe:
                return exe
    except (OSError, StopIteration, ValueError, KeyError, zipfile.BadZipFile, plistlib.InvalidFileException):
        pass
    return "S2Arm"


def pull_kept_nros(c, ident, bid, gid, docs="Documents"):
    """装之前把这台设备上宿主留下的 NRO（runtime/src/loader.c s2a_nro_keep：包里没有改写映像、游戏解开的整份，Documents/wire/<号>/nro/<SHA-256>.nro）
    拉回游戏库 games/<号>/nro_kept/，下次准备这款时改写进包（#8be819）。机上没有 / 列不出 / 拉不到都不算错；只收文件名 = 内容 SHA-256 的。→ 新收的个数
    Mac：devicectl 列 / 拉，收文件这段在 keep_nros；Windows 不收（WinPhone.pull_kept 回 0）"""
    from diag import devicectl
    rc, data, err = devicectl(c, "device", "info", "files", "--device", ident, "--domain-type", "appDataContainer", "--domain-identifier", bid,
                            "--subdirectory", f"{docs}/wire/{gid.upper()}/nro", timeout=120)
    if rc:
        if not dir_missing(err):   # 目录不在 = 这款没留下 NRO（常态）；别的列不出要看得见，不然真问题被吞成「收 0 个」
            note(c, f"收回 {gid} 留下的 NRO：列不出手机上的目录（{(err or '').strip().splitlines()[-1:] or rc}），这次没收")  # 非玩家句
        return 0
    names = {p.rsplit("/", 1)[-1] for p in (f.get("relativePath") or f.get("path") for f in ((data.get("result") or {}).get("files") or [])
                                            if isinstance(f, dict) and not (f.get("resources") or {}).get("isDirectory")) if p}
    def fetch(name, dst):
        rc, _, _ = devicectl(c, "device", "copy", "from", "--device", ident, "--domain-type", "appDataContainer", "--domain-identifier", bid,
                             "--source", f"{docs}/wire/{gid.upper()}/nro/{name}", "--destination", dst, timeout=300)
        return rc == 0
    return keep_nros(c, gid, names, fetch)


def keep_nros(c, gid, names, fetch):
    """机上列出的名字里，文件名 = 内容 SHA-256 的 NRO 逐个拉到临时文件（fetch(名字, 本地路径) → 成功?）、核过摘要收进 games/<号>/nro_kept/；
    已收过的不再拉。→ 新收的个数"""
    import hashlib
    new = 0
    for name in sorted(set(names)):
        if not re.fullmatch(r"[0-9a-f]{64}\.nro", name):
            continue
        dest = layout.nro_kept(c, gid, create=True) / name
        if dest.is_file():
            continue
        with tempfile.TemporaryDirectory(dir=c.private) as d:
            got = Path(d, "n")
            if not fetch(name, str(got)) or not got.is_file():
                note(c, f"收回 {gid} 留下的 NRO {name}：拉不回来，这次没收")  # 非玩家句
                continue
            if hashlib.sha256(got.read_bytes()).hexdigest() != name[:64]:
                note(c, f"收回 {gid} 留下的 NRO {name}：内容摘要与文件名不符，丢掉")  # 非玩家句
                continue
            dest.parent.mkdir(parents=True, exist_ok=True)
            part = dest.with_name(f"{dest.name}.{os.getpid()}.partial")   # 临时文件 + 改名：补件（rewrite_refresh.add_kept_nros）同时在读也读不到半个
            shutil.copyfile(got, part); os.replace(part, dest); new += 1
    if new:
        c.emit("message", f"这款游戏有 {new} 个代码模块要在运行中才能取到，已经从 iPhone 收回，这次装机一并补上")
    return new


SAVE_REL = "S2A/ryujinx/bis/user/save"   # 文档根下的存档目录（Ryujinx 数据根 = <文档根>/S2A/ryujinx）
SAVE_DIR = "Documents/" + SAVE_REL


def save_dir_absent(c, ident, bid, save_dir):
    """存档目录列不出时，判它是不是根本不在：从它的父目录往上逐级列到 Documents，第一个列得出的父目录里没有它（也没有它下面的东西）→ True；
    父目录里看得到它、或一个父目录都列不出（锁屏 / 隧道断）→ False（调用方停装，宁可不装也不冒丢档的险）"""
    from diag import devicectl
    parts = save_dir.split("/")
    for i in range(len(parts) - 1, 0, -1):
        parent, rest = "/".join(parts[:i]), "/".join(parts[i:])
        rc, data, _ = devicectl(c, "device", "info", "files", "--device", ident, "--domain-type", "appDataContainer", "--domain-identifier", bid,
                                "--subdirectory", parent, timeout=120)
        if rc:
            continue
        seen = [f.get("relativePath", "") for f in ((data.get("result") or {}).get("files") or [])]
        return not any(r == rest or r.startswith(rest + "/") or rest.startswith(r + "/") and r == rest.split("/")[0] for r in seen)
    return False

def note(c, text):
    """装机原则（11-11：玩家主动点了装机就别替他拒——认得出的风险让他确认，认不出的直接装）：拿不准、照样继续的判断只记进本任务的日志 <任务号>-decisions.log，界面不拦"""
    line = time.strftime("%H:%M:%S ") + text
    try:
        c.logs.mkdir(parents=True, exist_ok=True)
        with open(c.logs / f"{c.task}-decisions.log", "a", encoding="utf-8") as f:
            f.write(line + "\n")
    except (OSError, AttributeError, TypeError):
        pass
    print("[装机] " + text, file=sys.stderr, flush=True)  # 非玩家句


def backup_failed(c, why):
    """覆盖装前存档备份不了（装机原则「认得出的风险让用户确认」）：没带 acceptNoBackup → 停下报 save_backup_failed，界面问「仍然继续 / 先不」；
    玩家确认后带 acceptNoBackup 重发 → 记一笔「未备份」照装（返回 None = 没有备份目录）"""
    if c.r.get("acceptNoBackup") is True:
        note(c, "覆盖装前没能备份手机上的存档，玩家已确认继续：" + why)  # 非玩家句
        return None
    raise Failure("这次装机前没能备份手机上的存档（" + why + "）。存档没备份，万一覆盖出问题可能丢档；确认仍然继续再点一次。",  # 非玩家句
                  code="save_backup_failed", internal=why)


def backup_saves(c, ident, bid, gid, docs="Documents"):
    """覆盖装前把机上这款的整个存档目录（bis/user/save）逐文件拉回游戏库 games/<程序号>/save_backup/<时刻>/（10-27 运维线：
    斯普拉遁3 体感包覆盖装后进了选形象页，原档没有备份、无从比对）。第一次装 / 机上没有存档 = 不备份；拉失败报红停装，宁可不装也不冒丢档的险"""
    from diag import devicectl
    save_dir = f"{docs}/{SAVE_REL}"
    rc, data, err = devicectl(c, "device", "info", "files", "--device", ident, "--domain-type", "appDataContainer", "--domain-identifier", bid,
                              "--subdirectory", save_dir, timeout=120)
    # 文件清单的路径字段（#908：玩家 Xcode 16.0 的 devicectl 有条目不带 relativePath，原先 f["relativePath"] 抛 KeyError、整个装机作业崩成
    #   「本地任务失败」，每次都装不上）：relativePath / path 都认；都没有的条目读不懂 → 走「备份不了存档、确认后照装」，条目字段名记进日志，不再崩
    entries = [f for f in ((data.get("result") or {}).get("files") or []) if isinstance(f, dict)]
    unknown = [sorted(f) for f in entries if not (f.get("relativePath") or f.get("path")) and not (f.get("resources") or {}).get("isDirectory")]   # 目录条目读不出路径不碍事
    files = [p for p in (f.get("relativePath") or f.get("path") for f in entries if not (f.get("resources") or {}).get("isDirectory"))
             if p and not p.rsplit("/", 1)[-1].startswith(".")]
    if not rc and unknown:
        print(f"[s2a] 存档文件清单有 {len(unknown)} 条读不出路径，字段：{unknown[0]}", file=sys.stderr)
        return backup_failed(c, f"读不懂 iPhone 返回的存档文件清单（{len(unknown)} 条没有路径字段，多半是 Xcode 版本不同）")
    if rc:
        # 列不出：App 不在机上（第一次装）才算没有存档；App 在却列不出要分清两种——devicectl 对「目录不存在」和「锁屏 / 隧道断」报同一个错
        #   （11-07 满屏线 Duo 实测：容器第一次装半途失败 / 从没进过游戏，机上 Documents/games 是空目录，原先每次都拒装、玩家永久卡死）。
        #   往上逐级列父目录，第一个列得出的父目录定：里面看不到存档目录 = 没有存档，照装；看得到却列不出 / 父目录一个都列不出 = 停装
        arc, apps, aerr = devicectl(c, "device", "info", "apps", "--device", ident, "--bundle-id", bid, timeout=60)
        if arc:   # 连「装没装过」都问不出（锁屏 / 超时 / 断开）：不能当成第一次装，否则跳过备份直接覆盖（#333）
            return backup_failed(c, "确认不了 iPhone 上有没有装过这款：" + (aerr.splitlines()[-1] if aerr else f"devicectl 退出 {arc}"))  # 非玩家句
        if any(a.get("bundleIdentifier") == bid for a in (apps.get("result") or {}).get("apps") or []):
            if not save_dir_absent(c, ident, bid, save_dir):
                return backup_failed(c, "读不到 iPhone 上这款的存档目录：" + (err.splitlines()[-1] if err else f"devicectl 退出 {rc}"))  # 非玩家句
        return None
    if not files:
        return None
    dest = layout.path(c, gid, "save_backup", time.strftime("%Y%m%d-%H%M%S"))
    for rel in files:
        (dest / rel).parent.mkdir(parents=True, exist_ok=True)
        rc, _, err = devicectl(c, "device", "copy", "from", "--device", ident, "--domain-type", "appDataContainer", "--domain-identifier", bid,
                               "--source", f"{save_dir}/{rel}", "--destination", str(dest / rel), timeout=120)
        if rc or not (dest / rel).is_file():
            return backup_failed(c, f"拉存档失败（{rel}）：" + (err.splitlines()[-1] if err else f"devicectl 退出 {rc}"))  # 非玩家句
    return dest


def phone_ipa_path(c):
    """「显示 IPA」用：装机时组装的那份 IPA（整个游戏库共用一份，在默认位置根 S2Arm.ipa）；还没装过、没有这个文件 → 空串（界面不给按钮）。
    原先给的是这款的 image/ios 目录，「显示 IPA」打开的是游戏目录"""
    ipa = layout.phone_ipa(c)
    return str(ipa) if ipa.is_file() else ""


def phone_img_path(c, gid):
    """给玩家拷到手机用的这款 .img：只给「S2Arm 自签导出」文件夹里那份完整的（game.img + 着色器库 / 覆盖层，pack/img.py export）；
    资源包里的 image/ios/.pack/game.img 按设计不带着色器库（一键装机另推），交给自签玩家就是 D-QW2Q 那样整局黑屏，所以不再给它。
    没导出过这款 → 空串（界面不给按钮；要玩家先「导出，自己签名安装」，连着手机会直接推进去）"""
    folder = export_dir(c)
    if not gid or not folder.is_dir():
        return ""
    return next((str(p) for p in _full_imgs(folder) if _img_head(p)[0] == gid.upper()), "")


def phone_shader_cache(c, gid):
    """导出可选附带的着色器缓存（加速首次进局，不带也能玩）：资源包里的 shaders/ 目录；没有 → 空串"""
    d = layout.ios_pack(c, gid) / "shaders" if gid else None
    return str(d) if d and d.is_dir() else ""


def devcert_items(c, item, udid):
    """开发者证书模式的清单项（v0.2.4）：替掉 Apple ID / Impactor 两项。问题只提示、不挡（blocking 只给「没出包」）；
    到期 / 权限这类提醒随结果 devcert.warnings 给启动器画黄字。返回体检结果（读不出 → None）"""
    try:
        got = devcert.summary(c, udid=udid)
    except Failure as e:
        item("devcert", False, "开发者证书可用", str(e))
        return None
    item("devcert", not got["blocking"], "开发者证书可用", got["blocking"][0]["text"] if got["blocking"] else "")
    if udid and not got["allDevices"]:
        item("devcertDevice", got["deviceListed"], "这台 iPhone 在描述文件的设备列表里",
             "不在列表里：签出来装不上这台。请在开发者网站登记这台设备并重新生成描述文件，再在出包页重新导入。")
    return got


# 导出自签包不再是一种「装法」（11-15 维护者：让玩家先去设置里切模式本身就是多出来的一道）：游戏库「装到 iPhone」与「导出自签包」两个按钮并排，
#   导不导出只看这次请求带的 mode = export（wants_export）。原先存在私有目录 install.json 的装法设置作废：installMode 作业（两端启动时读签名身份）顺手删掉它，迁移一次
def export_available(c):
    """导出作业（export_phone，IMG + 未签名壳）在不在"""
    return callable(globals().get("export_phone"))


def install_mode_job(c):
    """作业 installMode：只读签名身份 → {signMode, exportAvailable}；旧版留下的装法设置 install.json 删掉（迁移一次）"""
    try:   # 删不掉（Windows 上被杀软 / 别的进程占着）不碍事：wants_export 已经不看它，下次启动再删；这个作业是启动时读签名身份的，不能因此失败
        (c.private / "install.json").unlink(missing_ok=True)
    except OSError:
        pass
    return dict(exportAvailable=export_available(c), signMode="devcert" if devcert.active(c) else "appleId")


# 导出给自签玩家（v0.3.1，维护者 11-12「导出，自己签名安装」）：游戏库根下这个文件夹放未签名 S2Arm.ipa + 各款 <游戏名>.img + 一份说明。
#   每次导出整个换新（先在同盘临时目录写好再对调），里面只有这次导出的东西
#   文件夹名与说明跟启动器界面语言（请求 uiLanguage，两端每个作业都带；11-13 维护者「i18n 要做好」）：中文 / 英文各一个定名（iOS 端文案同步用这两个名字）。
#   换了语言再导出：新名字的写好后把另一种语言名字的旧导出删掉，游戏库根只留一份
EXPORT_DIRS = {"zh": "S2Arm 自签导出", "en": "S2Arm Self-Sign Export"}  # 非玩家句
EXPORT_READMES = {"zh": "怎么装到 iPhone.txt", "en": "How to install on iPhone.txt"}  # 非玩家句
_BAD_NAME = re.compile(r'[\\/:*?"<>|\x00-\x1f]')


def ui_lang(c):
    """玩家看得到的文件名 / 说明用哪种语言：中文界面（zh-Hans / zh-Hant、没带）用中文，其余用英文"""
    lang = c.r.get("uiLanguage") or "zh-Hans"   # 没带（旧客户端）照旧中文
    return "zh" if lang.startswith("zh") else "en"   # 中文界面（简 / 繁）用中文定名，其余语言用英文（11-14 加新语言：日 / 西 / 法界面不给中文文件夹）


def export_dir(c):
    return c.library / EXPORT_DIRS[ui_lang(c)]


def wants_export(c):
    """这次按导出走：请求带 mode = export（游戏库「导出自签包」、完成页「这次改为导出自签」、S 级优化升级页「自签导出」）；没带 = 一键装"""
    return c.r.get("mode") == "export"


def _img_name(name, gid, used):
    """game.img 在导出文件夹里的名字：<游戏名>.img（玩家在「文件」App 里认得出）；名字不能做文件名 / 重名时带上游戏号。
    手机上按文件头认游戏（pack_apply.c s2a_img_scan 认 S2AIMG01 魔数与头里的游戏号），文件叫什么都行"""
    base = _BAD_NAME.sub(" ", name or "").strip().strip(".") or gid
    out = base + ".img"
    if out.lower() in used:
        out = f"{base} {gid}.img"
    used.add(out.lower())
    return out


def _export_img(c, pack, dst):
    """一款一个文件（pack/img.py export）：game.img + 着色器库 / 覆盖层 / romfs.s2aidx / game.imgmap 写成一个 .img，手机认领后照常从里面解出来。
    只放 game.img 不够——这几样不在 game.img 里、一键装机时随包另推；少了它们手机上起局报 direct_lib_missing（11-12 真机验收）。
    走 c.run：Windows 实拷几十 GB 时出包页有进度"""
    log = c.logs / (c.task + "-export.log")
    try:
        c.run([os.sys.executable, "-X", "utf8", "pack/img.py", "export", str(pack), str(dst)], log, c.env(), cwd=c.engine)
    except Failure as e:
        from errors import tool_reason
        raise Failure("写导出用的游戏文件失败：" + (tool_reason(log) or str(e)), code="package_failed") from e  # 非玩家句


EXPORT_STAMPS = "export-stamps.json"   # 私有目录：上次导出文件夹里每个 .img 的来源戳（不往玩家的导出文件夹里放杂文件）


def _pack_stamp(c, pack):
    """这款导出 .img 的来源戳：资源包里每个文件的相对路径 / 大小 / 修改时间 + 写 .img 的程序（pack/img.py）摘要。
    戳一样 = 这次写出来的 .img 和上次逐字节相同（#1132：加一款新游戏也把 8 款 53 GB 全重写一遍、约 18 分钟）"""
    h = hashlib.sha256()
    h.update(hashlib.sha256((c.engine / "pack/img.py").read_bytes()).digest())
    root = Path(pack)
    for p in sorted(root.rglob("*")):
        if p.is_file():
            st = p.stat()
            h.update(f"{p.relative_to(root).as_posix()}\0{st.st_size}\0{st.st_mtime_ns}\n".encode())
    return h.hexdigest()


def _reuse_export(old, new, old_stamp, stamp):
    """上次导出的这个文件来源没变、文件还在：硬链接过来沿用，不重写（几 GB 的 .img 秒过）。硬链接不动旧文件，
    这次导出中途失败旧导出文件夹照样完整；建不了硬链接（exFAT 等）或戳不同 → False，照常重写"""
    if old_stamp is None or old_stamp != stamp or not old.is_file():
        return False
    try:
        os.link(old, new)
    except OSError:
        return False
    return True


UPDATE_SUFFIX = {"zh": " 着色器更新包.img", "en": " shader update.img"}  # 非玩家句


def _update_name(img_file, lang):
    """<游戏名>.img → <游戏名> 着色器更新包.img（英文界面「… shader update.img」）：文件名一眼看得出是更新包，和完整包分开"""
    return img_file[:-4] + UPDATE_SUFFIX.get(lang, UPDATE_SUFFIX["en"])


def _export_update(c, pack, dst):
    log = c.logs / (c.task + "-export.log")
    try:
        c.run([os.sys.executable, "-X", "utf8", "pack/img.py", "update", str(pack), str(dst)], log, c.env(), cwd=c.engine)
    except Failure as e:
        from errors import tool_reason
        raise Failure("写着色器更新包失败：" + (tool_reason(log) or str(e)), code="package_failed") from e  # 非玩家句


IMPORT_DIRS = ("放这里导入", "Import Here")   # 手机上 S2Arm 扫的导入文件夹（runtime/src/pack_apply.c s2a_img_import_dirs，同序）  # 非玩家句


def _img_head(path):
    """.img 开头：(游戏号, 头一页字节)；不是 S2AIMG01 → ("", b"")。一页 = pack/img.py PAGE（tools/push_pack.py IMG_PAGE）"""
    with open(path, "rb") as f:
        page = f.read(16384)
    return (page[16:32].decode("ascii", "replace").upper(), page) if page[:8] == b"S2AIMG01" else ("", b"")


def _full_imgs(folder):
    """导出文件夹里的完整 .img（格式号 1）：同游戏号的「<游戏名> 着色器更新包.img」（格式号 2，pack/img.py UPDATE_FORMAT）只给手机上已有本体时套用，
    不当这款的完整文件给出去、也不随「推到手机」推（推过去手机上还没本体就认领不了）"""
    if not folder.is_dir():
        return []
    return [p for p in layout.entries(folder, "*.img") if p.is_file() and int.from_bytes(_img_head(p)[1][8:12], "little") != 2]   # 导出文件夹在 exFAT 上：._<名>.img 不是游戏文件


def _devpush_exe(c):
    sys.path.insert(0, str(c.engine / "tools"))
    import push_pack as P
    prebuilt = c.engine / "Binaries/Prepare/devpush" / P.EXE
    exe = P.devpush_path(str(prebuilt) if prebuilt.is_file() else None, c.env())
    if not exe:
        raise Failure("找不到 s2a-devpush：请重新安装完整的 S2Arm。", code="tool_missing")
    return exe


def _devpush_lines(c, exe, *args):
    p = subprocess.run([exe, *args], capture_output=True, text=True, encoding="utf-8", errors="replace", env=c.env(), timeout=120)
    return p.returncode, [l for l in p.stdout.splitlines() if l.strip()], (p.stderr or p.stdout).strip()


def push_export_job(c):
    """「推到手机」作业（exportPush）：只推、不重新导出"""
    with packer_phone_lock(c):   # 装机类作业一次一个（ipa.phone_lock）
        return _push_export_job(c)


def _push_export_job(c):
    return push_export(c, c.r.get("gameId") or None)   # pushed = 推进去的文件名（界面按它显示）


def push_export(c, gid=None, folder=None):
    """「推到手机」（11-13 维护者：自签成功页玩家可以选一键推送到手机，推上去直接能玩；也照旧可以自己从文件夹选文件传）：
    把「S2Arm 自签导出」文件夹里的完整 .img（含着色器库，同 pack/img.py export）经数据线推进手机上自签装好的 S2Arm 的「放这里导入」。
    玩家手里只有这一个 .img；不自动推（几 GB，玩家点了才推）。
    只要手机信任了这台电脑：不要 Xcode 账号、不要开发者模式（s2a-devpush devices / find-s2arm；不是开发签名的 App 退到只进 Documents）。
    gid：只推这一款；None = 导出文件夹里的全部。推不了抛 Failure：缺什么、玩家该怎么做"""
    sys.path.insert(0, str(c.engine / "tools"))
    import push_pack as P
    folder = Path(folder) if folder else export_dir(c)
    imgs = _full_imgs(folder)
    heads = {p: _img_head(p) for p in imgs}
    if gid:
        imgs = [p for p in imgs if heads[p][0] == gid.upper()]
    if not imgs:
        raise Failure("导出文件夹里还没有" + ("这款游戏的" if gid else "") + " .img：先点「导出，自己签名安装」，导出完再推到手机。", code="pack_missing")  # 非玩家句
    exe = _devpush_exe(c)
    c.begin("找连着的 iPhone", 1, 3)
    rc, devs, err = _devpush_lines(c, exe, "-", "-", "devices")
    want = (c.r.get("device") or "").strip()
    if rc or not devs:
        raise Failure("没找到连着的 iPhone：用数据线把手机连到这台电脑，解锁手机，弹出「要信任此电脑吗」时点「信任」，再点「推到手机」。"
                      + ("（Windows 要先装 Apple 设备支持：装一次 iTunes 或「Apple 设备」App。）" if os.name == "nt" else ""),  # 非玩家句
                      code="device_not_connected", internal=err[-300:])
    # 推给哪台：指定了且连着就是它；没指定（或指定的不在线）就逐台问谁装着 S2Arm——只有一台装着就是它，几台都装着才要玩家选（不默认挑第一台：
    #   连着几台时第一台未必是玩家要的那台，11-13 实测把测试文件推进了另一台）
    pool = [want] if want in devs else devs
    found = {}
    for u in pool:
        rc, apps, err = _devpush_lines(c, exe, u, "-", "find-s2arm")
        if rc and len(pool) == 1:
            raise Failure("读不出这台 iPhone 上装了哪些 App：解锁手机、确认点过「信任」后再点一次「推到手机」。", code="device_not_ready", internal=err[-300:])
        if not rc and apps:
            found[u] = apps
    if not found:
        tail = f"（编号末尾 {pool[0][-6:]}）" if len(pool) == 1 else ""  # 非玩家句
        raise Failure(f"这台 iPhone{tail}上还没装 S2Arm：先用你的签名工具装导出文件夹里的 S2Arm.ipa，在手机上打开一次，再点「推到手机」。", code="device_not_ready")
    if len(found) > 1:
        raise Failure("连着的 " + "、".join(f"编号末尾 {u[-6:]}" for u in found) + " 都装着 S2Arm：在装机页选好要推到哪台，再点「推到手机」。", code="device_required")  # 非玩家句
    udid, apps = next(iter(found.items()))
    rows = [a.split("\t") for a in apps]
    pick = next((r for r in rows if r[0] == c.r.get("bundleId")), rows[0])
    bid = pick[0]
    work = Path(tempfile.mkdtemp(prefix=".push-", dir=c.library))
    env = dict(c.env(), S2A_DEVPUSH_DOCUMENTS="1")
    dp = P.Devpush(exe, udid, bid, work, env)
    try:
        names = dp.ls("Documents") or []
        sub = next((d for d in IMPORT_DIRS if any(l.rstrip("/").split("/")[-1] == d for l in names)), IMPORT_DIRS[0 if ui_lang(c) == "zh" else 1])
        total = sum(p.stat().st_size for p in imgs)
        done, pushed = 0, []
        c.begin("把游戏文件推进 iPhone", 2, 3)
        for p in imgs:
            size, rel = p.stat().st_size, f"Documents/{sub}/{p.name}"
            got = dp.head(rel, P.IMG_PAGE)
            off = 0
            if got and got[0] >= 2 * P.IMG_PAGE and got[0] <= size and got[1] == heads[p][1] and heads[p][1][P.IMG_PACK_ID].strip(b"\0"):
                off = got[0] // P.IMG_PAGE * P.IMG_PAGE   # 上次推到一半（同一份：头一页逐字节相同、资源包号不空）：接着推
            base = done
            dp.progress = lambda n, base=base: c.progress(base + n, total)
            if off and off == size:
                pass   # 已经整份在手机上、还没被导入：不重推
            elif off:
                dp.put_at(str(p), rel, off)
            else:
                dp.put(str(p), rel)
            done += size
            c.progress(done, total)
            pushed.append(p.name)
        c.begin("推完：在手机上打开 S2Arm", 3, 3)
        return dict(pushed=pushed, pushDevice=udid, pushBundleId=bid, pushApp=pick[2] if len(pick) > 2 else "", importDir=sub,
                    pushNote="打开手机上的 S2Arm，等游戏库导入完就能玩（大游戏要等一会儿）。")
    except P.Fail as e:
        raise Failure(str(e), code="resource_transfer_failed") from e
    finally:
        shutil.rmtree(work, ignore_errors=True)


def _readme_zh(games):
    names = "\n".join(f"  · {g['file']}（{g['name']}）" for g in games)
    return f"""S2Arm 自签安装说明  # 非玩家句

这个文件夹里有：
  · S2Arm.ipa：未签名的 S2Arm（里面带着下面这几款游戏的程序）
  · 每款游戏一个 .img 文件：
{names}

一、装 S2Arm
  用你常用的自签工具（如 Sideloadly、AltStore、爱思助手的「IPA 签名」等）签名并安装 S2Arm.ipa。
  已经装过 S2Arm 的，直接覆盖安装：手机上的游戏、.img 和存档都会保留。
  第一次装好后，在 iPhone「设置 → 通用 → VPN 与设备管理」里信任你的开发者账号，然后打开一次 S2Arm。

二、放游戏
  在 iPhone 的「文件」App 里打开「我的 iPhone → S2Arm → 放这里导入」（英文系统叫 Import Here），把 .img 文件拷进去。
  可以用隔空投送、数据线（Mac 访达 / Windows 爱思助手等的文件共享）或网盘拷到手机，再在「文件」App 里挪进这个文件夹。
  文件名随便改，S2Arm 按文件内容认游戏。手机上已经有、也没重新打过 iPhone 包的游戏，不用再放。

  只更新着色器：每款旁边还有一个「<游戏名> 着色器更新包.img」，只有几百 MB。手机上已经放过这款的完整 .img（游戏本身没换版本）、
  后来只是着色器变了（升级 S2Arm 后重新导出），只放这个更新包就行，不用重拷几 GB 的完整 .img。
  手机上还没有这款的，先放完整的 .img（不带「着色器更新包」字样的那个）。

三、开始玩
  回到 S2Arm，游戏会出现在游戏库里，点开就能玩。.img 还在拷的时候 S2Arm 会等它拷完再导入。

这个文件夹每次导出都会整个换新。
"""


def _readme_en(games):
    names = "\n".join(f"  · {g['file']} ({g['name']})" for g in games)
    return f"""S2Arm self-sign install guide

This folder contains:
  · S2Arm.ipa: S2Arm, unsigned (it carries the programs of the games below)
  · One .img file per game:
{names}

1. Install S2Arm
  Sign and install S2Arm.ipa with the sideloading tool you use (for example Sideloadly or AltStore).
  If S2Arm is already installed, install over it: the games, .img files and saves on the iPhone are kept.
  After the first install, trust your developer account in Settings → General → VPN & Device Management, then open S2Arm once.

2. Add the games
  In the Files app on the iPhone, open On My iPhone → S2Arm → Import Here and copy the .img files into it.
  You can get them onto the phone with AirDrop, a cable (file sharing in the Mac Finder or a Windows tool) or a cloud drive, then move them into this folder in the Files app.
  The file names do not matter: S2Arm recognises each game by its contents. Games already on the phone that you have not rebuilt for iPhone do not need to be added again.

  Shader-only updates: next to each game there is also a "<game name> shader update.img" of only a few hundred MB. If the phone already has this
  game's full .img (same game version) and only the shaders changed (you updated S2Arm and exported again), add just this update file instead of
  copying the multi-GB .img again. If the game is not on the phone yet, add the full .img first (the one without "shader update" in its name).

3. Play
  Go back to S2Arm: the games appear in the library, tap one to play. If an .img is still being copied, S2Arm waits for it to finish before importing.

This folder is replaced as a whole on every export.
"""


def export_readme(games, lang="zh"):
    return _readme_en(games) if lang == "en" else _readme_zh(games)


EXPORT_SWAP_TRIES, EXPORT_SWAP_WAIT = 5, 2.0   # 换导出文件夹被占用时的退避：最多 5 次、每次等 2 秒（资源管理器刷新、杀毒扫完常在几秒内放手）


def swap_export_dir(out, dest, old, tries=None, wait=None):
    """刚写好的导出 out 换到 dest（原来的挪到 old 随临时目录删）。→ 实际放到的路径。
    D-4MAH：Windows 上旧导出文件夹被占着（资源管理器开着、自签工具还拿着上次的 S2Arm.ipa、杀毒软件在扫刚写的 .img），
    整目录改名抛 PermissionError，原先整次导出失败（.img 都写完了）。现在：退避重试几次；还不行就不动旧的，换个带时刻的新名字放"""
    tries = EXPORT_SWAP_TRIES if tries is None else tries
    wait = EXPORT_SWAP_WAIT if wait is None else wait
    for attempt in range(tries):
        moved = False
        try:
            if dest.exists():
                os.replace(dest, old); moved = True
            os.replace(out, dest)
            return dest
        except PermissionError:
            if moved and not dest.exists():   # 旧的挪走了、新的没换进去：挪回去，再等
                try:
                    os.replace(old, dest)
                except OSError:
                    pass
            if attempt + 1 < tries:
                time.sleep(wait)
    alt = dest.with_name(f"{dest.name} {time.strftime('%m%d-%H%M%S')}")
    n = 2
    while alt.exists():
        alt = dest.with_name(f"{dest.name} {time.strftime('%m%d-%H%M%S')}-{n}"); n += 1
    os.replace(out, alt)
    return alt


def export_phone(c, gid=None):
    """导出，自己签名安装：本版壳 + 游戏库里能放进本壳、已出成单一 IMG 的各款组一个容器（ipa.assemble，同一键装），
    出未签名 S2Arm.ipa + 每款一个 <游戏名>.img + 说明到游戏库根「S2Arm 自签导出」（英文界面「S2Arm Self-Sign Export」）。不连手机、不签名。
    gid：这次点的那款（必须带上，放不进就报真实原因）；None = 「导出新版 S2Arm」（只换壳，带上能带的各款）。
    带 gid 时 .img 只新写这一款，别的款能沿用上次导出的就沿用、不能就不写（结果 unwritten 点名）；None 时照旧每款都写。
    放不进本壳（要按新版重新出包）/ 还不是单一 IMG 形态的别的款不带，结果 skipped 点名"""
    import ipa as packer
    gid = gid.upper() if gid else None
    c.begin("核对要导出的游戏", 1, 4)
    sid = packer.current_shell_id(c)
    if gid:
        if not img_pack(ios_pack(c, gid)):
            raise Failure("这款的 iPhone 包是旧格式，导出不了这款的 .img 文件：请重新「打 iPhone 包」后再导出。", code="pack_missing")
    games_all = c.catalog()["games"]
    names = {g["id"].upper(): g.get("name") or g["id"] for g in games_all}
    hidden = {g["id"].upper() for g in games_all if g.get("hidden")}   # 从游戏库删掉的（library.remove 只置 hidden）：不再导出（#1132：删了照样被带上）
    others, skipped = [], []
    for g in sorted(names):
        if g == gid or g in hidden:
            continue
        pack = layout.ios_pack(c, g)
        if not layout.has_ios_kit(c, g) or not (pack / "manifest.json").is_file():
            continue   # 没出过 iPhone 版：本来就不在手机上，不算跳过
        if packer.usable_kit(c, g, sid) is None or not img_pack(pack):
            skipped.append(names[g])
            continue
        others.append(g)
    # 地址空间类型（#1132）：一个 App 里各款要同一类型（pack/ship_ext.py container 组装期拒、宿主 vawin.c 同判据）。导出把游戏库里能带的都带上，
    #   原先只要库里有一款类型不同，点哪款导出都报「放不进同一个 App」、删光手机上的游戏也没用。现在按这次点的那款（没点 = 款数最多的那类）分组，
    #   类型不同的这次不带、点名说明
    kinds = {g: packer.kit_astype(c, g) for g in ([gid] if gid else []) + others}
    if gid:
        want = kinds[gid]
    else:
        counts = {}
        for g in others:
            counts[kinds[g]] = counts.get(kinds[g], 0) + 1
        want = max(counts, key=lambda k: (counts[k], -min(i for i, g in enumerate(others) if kinds[g] == k))) if counts else None
    apart = [g for g in others if kinds[g] != want] if want is not None else []   # 读不到这款类型：不分组，交组装期按真实原因报
    others = [g for g in others if g not in apart]
    if not gid and not others:
        raise Failure("游戏库里还没有能导出的 iPhone 版：先给游戏「打 iPhone 包」。", code="job_failed")
    from rewrite_refresh import refresh_ios
    import contextlib
    held = contextlib.ExitStack()   # 导出读各款程序件与资源包（写 .img）：整段持有这几款的程序锁，出包交付换件时等它写完
    held.enter_context(packer.program_locks(c, ([gid] if gid else []) + others))
    refresh_ios(c, ([gid] if gid else []) + others)
    c.begin("组装 S2Arm.ipa（未签名）", 2, 4)
    work = Path(tempfile.mkdtemp(prefix=".export-", dir=c.library))
    try:
        ipa, games, _ = packer.assemble(c, gid, others, dest=work / "assemble")
        out = work / "out"
        out.mkdir()
        # 玩家在设置里关了主屏小组件（widget: false）：导出的 ipa 去掉扩展再交（侧载工具按壳里有什么签什么）；没关照原样
        if c.r.get("widget") is False and ipa_strip_widget(ipa, out / "S2Arm.ipa"):
            Path(ipa).unlink()
        else:
            os.replace(ipa, out / "S2Arm.ipa")
        shutil.rmtree(work / "assemble", ignore_errors=True)
        c.begin("写各款游戏的 .img（含着色器库）与着色器更新包", 3, 4)
        used, listed, fresh, unwritten = set(), [], [], []
        prev, stamps = export_dir(c), {}
        old_stamps = read(c.private / EXPORT_STAMPS, {}) or {}
        for g in games:
            f = _img_name(names.get(g, g), g, used)
            stamp = _pack_stamp(c, layout.ios_pack(c, g))
            if not _reuse_export(prev / f, out / f, old_stamps.get(f), stamp):
                # 点了哪款只新写那一款（库大时第一次导出 / 换版本不再把每款几 GB 全写一遍）：别的款上次导出的 .img 来源没变就沿用，
                #   变了或没有就这次不写，完成页点名（unwritten）。程序都在 S2Arm.ipa 里；手机上已有的旧 .img 照常能玩（game.img 不随壳变）
                if gid and g != gid:
                    unwritten.append(names.get(g, g))
                    continue
                _export_img(c, layout.ios_pack(c, g), out / f)
                fresh.append(f)   # 这次新写的（#1132 完成页点名「.img 只要拷这几个」；沿用的和上次导出逐字节相同，手机上已有就不用再拷）
            # 着色器更新包（维护者 11-13）：只含派生件，几百 MB；手机上已有这款同一版本体时只放它就能换着色器，不用重拷几 GB 的 .img
            u = _update_name(f, ui_lang(c))
            if not _reuse_export(prev / u, out / u, old_stamps.get(u), stamp):
                _export_update(c, layout.ios_pack(c, g), out / u)
            stamps[f] = stamps[u] = stamp
            listed.append(dict(gameId=g, name=names.get(g, g), file=f, update=u))
        c.begin("写安装说明", 4, 4)
        lang = ui_lang(c); readme = EXPORT_READMES[lang]
        (out / readme).write_text(export_readme(listed, lang), encoding="utf-8-sig" if os.name == "nt" else "utf-8")
        want = export_dir(c)
        dest = swap_export_dir(out, want, work / "old")
        if dest != want:   # 旧导出文件夹被占着换不掉：这次写到新名字，照常算成功（几 GB 的 .img 都写完了，不因旧文件夹被占整次失败）
            c.diagnostic(f"原来的导出文件夹正被别的程序占用，这次导出到新文件夹：{dest.name}", code="export_dir_busy", severity="warning")   # 下一步见 errors.RECOVERY
        for other, name in EXPORT_DIRS.items():   # 换过界面语言：另一种语言名字的旧导出挪进临时目录随它删，游戏库根只留这一份
            if other != lang and (c.library / name).exists():
                try:
                    os.replace(c.library / name, work / ("old-" + other))
                except PermissionError:   # 被占着：留着，不挡这次导出
                    pass
    finally:
        held.close()
        shutil.rmtree(work, ignore_errors=True)
    if dest == want:   # 来源戳只记正式导出文件夹里的（换到带时刻的新名字时下次不沿用）
        atomic(c.private / EXPORT_STAMPS, stamps)
    size = sum(p.stat().st_size for p in dest.iterdir() if p.is_file())
    if skipped:
        c.diagnostic("这几款没放进这次导出（要按新版重新「打 iPhone 包」）：" + "、".join(skipped), code="container_stale", severity="warning")  # 非玩家句
    if apart:  # 非玩家句
        c.diagnostic("这几款和这次导出的游戏地址空间类型不同，放不进同一个 App，这次没带：" + "、".join(names[g] for g in apart)  # 非玩家句
                     + "（要玩它们就单独点它们导出，导出的 S2Arm 会换成只含同一类的游戏）", code="container_incompatible", severity="warning")  # 非玩家句
    return dict(exported=True, outputPath=str(dest), ipa=str(dest / "S2Arm.ipa"), readme=str(dest / readme), sgrade=patches_results(c),
                games=list(games), files=listed, skipped=skipped + [names[g] for g in apart], exportBytes=size,
                fresh=fresh, reused=len(listed) - len(fresh), unwritten=unwritten)


def readiness(c):
    """装机前清单（用户体验线 11-02）：启动器装机页每几秒问一次、AI 代劳也读它，逐项说「好了没有、没好要谁做什么」，只有 iPhone 版没做好才挡（blocking），其余只提示，真失败由 install 给原因。
    只读不改：不申请描述文件、不签名、不碰设备上的 App。每项 {id, ok, title, detail, who}；who = human（只能玩家本人做）/ app（启动器自己能做）。
    文案都是定句（启动器按原句查英文），账号名、设备名另放 account / device。
    设备一项一项判（连上 → 信任 → 开发者模式），前一项没好，后面的标 waiting、不给误导的「没打开」"""
    gid = c.r.get("gameId") or ""
    if os.name == "nt":
        return readiness_windows(c, gid)
    items = []
    ipa_path = ""
    def item(key, ok, title, detail, who="human", waiting=False, note=""):
        wait = waiting and not ok
        # 等前一步的不给说明，免得 AI 拿去催玩家；好了的项也不带说明，只有 note（好了但值得知道的，如只靠网络连着）照带
        items.append(dict(id=key, ok=bool(ok), waiting=wait, blocking=key == "package" and not ok, title=title, detail=note if ok else "" if wait else detail, who=who))
    import downstream
    scheme = downstream.requested(c, next((g for g in c.catalog()["games"] if g["id"].upper() == gid.upper()), dict(id=gid)))
    if scheme:   # 下游深度方案出的是独立 App（install → downstream.install_ios）：iPhone 版看它自己的出包记录，不看容器件（原先一律报没做好，实际装得上）
        rec = downstream.last_record(c, gid.upper(), scheme)
        ipa_path = (rec or {}).get("ipa") or ""
        item("package", bool(rec), "这款游戏的 iPhone 版已经做好", "还没做好：先做 iPhone 版，做好后这里自动打勾。", who="app")
    else:
        try:
            ios_pack(c, gid)
            ipa_path = phone_ipa_path(c)
            item("package", True, "这款游戏的 iPhone 版已经做好", "")
        except Failure:
            item("package", False, "这款游戏的 iPhone 版已经做好", "还没做好：先做 iPhone 版，做好后这里自动打勾。", who="app")
    use_cert = devcert.active(c)
    team = None
    if not use_cert:
        teams = xcode_teams(c.env())
        team = (pick_team(teams) if teams else None)
        item("appleId", team, "已登录 Apple ID", "" if team else (TEAM_PENDING if xcode_account(c.env())[0] else ACCOUNT_NONE))
    # 清单只看玩家选的那台、每次现查（11-11 玩家实报：没插线却亮「iPhone 已用数据线连上」——原先没选设备时作业自己挑了同网的 iPad 来打勾）
    want = (c.r.get("device") or "").strip()
    link = device_link(c, want, polling=True) if want else dict(device=None, stage="connected", problem=S_DEVICE_REQUIRED, trace=[], devices=[])
    one, stage = link["device"], link["stage"]
    cert = devcert_items(c, item, (one or {}).get("hardwareProperties", {}).get("udid") or "") if use_cert else None
    name = (one.get("deviceProperties", {}).get("name") or "").strip() if one else ""
    kind = device_kind(one) if one else "iPhone / iPad"
    how = "数据线" if one and _link(one).get("transportType") == "wired" else "同一 Wi-Fi"
    item("connected", one, "{0}「{1}」已连上（{2}）".replace("{0}", kind).replace("{1}", name).replace("{2}", how) if one else "选的设备已连上（数据线或同一 Wi-Fi）",
         link["problem"] if stage == "connected" else "", note=S_NETWORK if one and how != "数据线" else "")   # 只靠网络连着：能装，但提醒插线更稳（玩家反馈 11-11）
    paired = bool(one) and stage != "trusted"
    item("trusted", paired, "{0} 已信任这台 Mac".replace("{0}", kind), link["problem"] if stage == "trusted" else S_TRUST, waiting=not one)
    mode_pending = paired and stage == "prepare" and one.get("deviceProperties", {}).get("developerModeStatus") not in ("enabled", None)
    dev_mode = paired and stage != "developerMode" and not mode_pending
    item("developerMode", dev_mode, "{0} 已打开开发者模式".replace("{0}", kind), S_DEV_MODE, waiting=not paired or mode_pending)
    item("deviceReady", dev_mode and stage == "", "{0} 已准备好安装".replace("{0}", kind), link["problem"] if stage == "prepare" else "", who="app", waiting=not paired or stage == "developerMode")
    account = (cert or {}).get("teamName") or "" if use_cert else (team["name"] or team["id"]) if team else ""
    return dict(gameId=gid, items=items, ready=not any(i["blocking"] for i in items), device=name, deviceKind=kind.lower() if one else "", account=account, ipaPath=ipa_path, imgPath=phone_img_path(c, gid), shaderCachePath=phone_shader_cache(c, gid),
                signing="" if use_cert else signing_summary(c.env()), signMode="devcert" if use_cert else "appleId", devcert=cert)


def linked_sdk(exe):
    """主程序链接时的 iOS SDK 版本（Mach-O LC_BUILD_VERSION 的 sdk 字段，xxxx.yy.zz 按半字节编码），读不到返回 None。
    11-07 Duo 实测：iOS 按主程序链接的 SDK 判 App 认不认识本机型——旧 SDK（26.5）出的壳在 iPhone Duo（iOS 27 新机型）上按旧 iPhone 尺寸
    （667×375 点）缩小居中、四周留黑；同一份代码用 27.1 SDK 链接就铺满 2034×1398。启动屏键（UILaunchStoryboardName / UILaunchScreen）有没有都一样"""
    import struct
    try:
        with open(exe, "rb") as f:
            head = f.read(4096 * 8)
    except OSError:
        return None
    if len(head) < 32 or struct.unpack_from("<I", head)[0] != 0xFEEDFACF:   # 只认 64 位单架构（iOS 壳只出 arm64）
        return None
    ncmds, off = struct.unpack_from("<I", head, 16)[0], 32
    for _ in range(ncmds):
        if off + 8 > len(head):
            return None
        cmd, size = struct.unpack_from("<II", head, off)
        if cmd == 0x32 and off + 16 <= len(head):   # LC_BUILD_VERSION：platform, minos, sdk
            v = struct.unpack_from("<I", head, off + 16)[0]
            return (v >> 16, (v >> 8) & 0xFF, v & 0xFF)
        if size < 8:
            return None
        off += size
    return None


def check_shell_sdk(c, app, dev):
    """iPhone 的系统大版本比壳链接的 SDK 新 → 黄字 shell_sdk_old（照常装）：这一代系统新出的机型（如 iPhone Duo）会把 App 按旧尺寸缩小显示"""
    try:
        exe = app / plistlib.loads((app / "Info.plist").read_bytes()).get("CFBundleExecutable", "S2Arm")
    except (OSError, plistlib.InvalidFileException):
        return
    sdk, os_major = linked_sdk(exe), str(dev.get("os") or "").split(".")[0]
    if sdk and os_major.isdigit() and int(os_major) > sdk[0]:
        c.diagnostic(f"这个包是用 iOS {sdk[0]}.{sdk[1]} 的 Xcode 出的，这台 iPhone 是 iOS {dev.get('os')}：iOS {os_major} 新出的机型（如 iPhone Duo）"
                     "上整个 App 会按旧 iPhone 尺寸缩小在屏幕中间", code="shell_sdk_old", severity="warning")


PROFILE_REJECTED = "0xe8008015"   # 「A valid provisioning profile for this executable was not found」（MIInstallerErrorDomain 13）


def set_aside_profiles(c, picked):
    """dev_sign 记下的那几份描述文件挪进 <产物根>/.stale_profiles/（同 ensure_profile.sh 挪缺设备的旧描述文件那个目录；不删，挪不动的跳过）→ 挪走的"""
    try:
        paths = {p.strip() for p in Path(picked).read_text(encoding="utf-8").splitlines() if p.strip()} if picked and Path(picked).is_file() else set()
    except OSError:
        paths = set()
    env = c.env()
    sd = Path(env.get("S2A_ROOTS") or Path(env.get("S2A_RUN_ROOT") or Path.home() / ".s2arm/run") / "s2arm/roots") / ".stale_profiles"
    moved = []
    for p in sorted(paths):
        try:
            sd.mkdir(parents=True, exist_ok=True)
            shutil.move(p, sd / Path(p).name)
            moved.append(p)
        except OSError as e:
            note(c, f"挪不开描述文件 {p}：{e}")  # 非玩家句
    return moved


def app_has_widget(app):
    return any((Path(app) / "PlugIns").glob("*.appex")) if (Path(app) / "PlugIns").is_dir() else False


def sign_and_install(c, ipa, team, dev, udid, bid, games, steps=True):
    """steps=False：不报主进度（出包重叠早装在后台线程里调，进度条归出包）。解 ipa → 改包名 → 申请开发描述文件 → 用玩家 Apple ID 签名 →
    按各款文档根 Documents/games/<游戏号> 拉跑局知识与存档备份 → devicectl 覆盖装（不卸载，Documents 保留）"""
    ents = c.engine / "pack/app.entitlements"
    stage = Path(tempfile.mkdtemp(prefix="s2a-install-", dir=c.private))
    log = c.logs / (c.task + "-install.log")
    try:
        # ditto 解：保留可执行位与符号链接（zipfile 会丢，codesign / 安装都要）
        r = subprocess.run(["/usr/bin/ditto", "-x", "-k", str(ipa), str(stage)], capture_output=True, text=True)
        app = next((stage / "Payload").glob("*.app"), None)
        if r.returncode or not app:
            raise Failure("解不开 iPhone 包：" + (r.stderr.strip()[-200:] or str(ipa)), code="job_failed")  # 非玩家句
        info = app / "Info.plist"
        pl = plistlib.loads(info.read_bytes()); pl["CFBundleIdentifier"] = bid
        shown = container_display_name(app)
        if shown:
            pl["CFBundleDisplayName"] = shown
        info.write_bytes(plistlib.dumps(pl))
        check_shell_sdk(c, app, dev)
        # 主屏小组件扩展（PlugIns/S2ArmWidget.appex，11-16）：扩展包名跟着主包名（<主包名>.widget）。玩家在设置里关了（widget: false）→ 去掉；
        #   玩家自己的证书只有主程序一份描述文件 → 去掉并提示；Apple ID 签名带上（sign_with_apple_id 申请两份描述文件，哪步不成就去掉重签，绝不因小组件装不上）
        widget = widget_prepare(c, app, bid, devcert=devcert.active(c))
        from diag import is_vision
        c.profile_picked = stage / "profile-picked.txt"   # dev_sign 记下这次用了哪份描述文件（手机拒了就挪开它重申）
        if devcert.active(c):   # 玩家自己的开发者证书（v0.2.4）：rcodesign 直接读 p12 签，不申请描述文件、不要 Xcode 账号
            if steps: c.begin("用你的开发者证书签名", 4, 6)
            devcert.sign_app(c, app, log)
            devcert.export_ipa(c, stage / "Payload")
        else:
            sign_with_apple_id(c, app, team, bid, ents, udid, log, steps, vision=is_vision(dev), widget=widget)
        if steps: c.begin("装到 iPhone", 5, 6)
        from diag import devicectl
        for g in games:
            pull_seen(c, dev["id"], bid, g, udid or dev["id"], docs=game_docs(g))
            backup_saves(c, dev["id"], bid, g, docs=game_docs(g))
        rc, _, err = devicectl(c, "device", "install", "app", "--device", dev["id"], str(app), timeout=1800)
        if rc and PROFILE_REJECTED in err and not devcert.active(c):
            # 11-17 #1447 / #1448：手机说这次签名用的描述文件不能用（0xe8008015）——本机核得出的几项都过了、手机仍不认（证书在别处被换掉 / 吊销、
            #   描述文件被别的工具改过等）：把这次用过的描述文件挪开（不删），按 0.5.1 的做法向 Xcode 申请一份新的、重签、再装一次；仍不认照常报
            moved = set_aside_profiles(c, c.profile_picked)
            note(c, f"iPhone 不认这次用的开发描述文件（0xe8008015）：挪开 {len(moved)} 份、重新申请后再签再装一次")  # 非玩家句
            c.profile_force_request = True
            try:
                sign_with_apple_id(c, app, team, bid, ents, udid, log, steps, vision=is_vision(dev), widget=widget and app_has_widget(app))
            finally:
                c.profile_force_request = False
            rc, _, err = devicectl(c, "device", "install", "app", "--device", dev["id"], str(app), timeout=1800)
        if rc:
            # 识别 devicectl 的实际原因，不把额度、配对和开发者模式失败统称签名。
            code = classify(err, default="device_install_failed")
            reason = err.strip()[-2000:] or f"devicectl 退出 {rc}（未提供错误详情）"
            raise Failure("装不上 iPhone：" + reason, code=code)  # 非玩家句
    finally:
        shutil.rmtree(stage, ignore_errors=True)


WIDGET_QUOTA = "这个免费 Apple ID 7 天内注册的包名已满 10 个，小组件要多注册一个（App 照常装上，额度恢复后再装一次就带上）"


def ipa_strip_widget(src, dst):
    """另存一份去掉小组件扩展（Payload/*.app/PlugIns/）的 ipa → 原包里有没有扩展。没有就不写 dst"""
    import zipfile
    with zipfile.ZipFile(src) as z:
        names = z.infolist()
        drop = [i for i in names if re.match(r"Payload/[^/]+\.app/PlugIns/", i.filename)]
        if not drop:
            return False
        with zipfile.ZipFile(dst, "w", zipfile.ZIP_DEFLATED) as o:
            for i in names:
                if i not in drop:
                    o.writestr(i, z.read(i), compress_type=i.compress_type)
    return True


def widget_mod(c):
    """pack/widget_ext.py（出壳 / 组装 / 装机同一份包名与去扩展规则）：按请求给的引擎树（c.engine，同本文件取 tools / pack/orch）导入。
    原先按本文件位置往上两级找：源码树里是仓库根，对；Mac App 里作业层在 Contents/Resources/Jobs、引擎在 Resources/Engine，
    往上两级是 Contents、没有 pack，装到 iPhone 一律 ModuleNotFoundError（0.5.0 正式候选 667ccdb92，11-16 维护者）。
    引擎树里没有这份时（单测给的空引擎）才退回本文件所在的源码树"""
    root = Path(c.engine)
    if not (root / "pack" / "widget_ext.py").is_file():
        root = Path(__file__).resolve().parents[2]
    if str(root) not in sys.path:
        sys.path.insert(0, str(root))
    from pack import widget_ext
    return widget_ext


def widget_group(team_id):
    """小组件与主程序共用的 App Group：全苹果唯一，按团队号区分（壳里写的 group.s2arm.widget 是给侧载工具改名用的占位；运行时按前缀认）"""
    return f"group.s2arm.widget.{team_id}"


def widget_prepare(c, app, bid, devcert=False):
    """装机前处理小组件扩展 → 还带不带（True = 交给签名带上）。没有扩展（单款包 / 旧壳）→ False"""
    if not (Path(app) / "PlugIns").is_dir():
        return False
    W = widget_mod(c)
    if not W.appexes(app):
        return False
    W.retarget(app, bid)
    if c.r.get("widget") is False:   # 玩家在设置里关了「装到 iPhone 时带主屏小组件」：不提示
        W.strip(app)
        return False
    if devcert:
        widget_skip(c, app, "用你自己的开发者证书签名只有主程序一份描述文件，签不了小组件")
        return False
    return True


def widget_skip(c, app, why):
    """去掉小组件扩展、照常装 App，黄字说明这次为什么没带（玩家决定要不要换签名方式 / 等额度）"""
    widget_mod(c).strip(app)
    c.diagnostic(f"这次没装小组件：{why}", code="widget_skipped", severity="warning")


def _sign_or_request(c, sign, bid, team, ents, udid, log, env, steps):
    """先用本机已有的开发描述文件签（sign = dev_sign.py 命令；退出码 3 = 没有合适的：没有、过期或一天内到期、不含这台手机、权限不够），
    3 才申请（ensure_profile.sh：xcodebuild 拿这台手机当目标、登记设备，要 Xcode 看得到它）再签一次。
    11-16 诊断 D-44DP：原先每次装机都先申请，Xcode 看不到这台手机（Unable to find a destination）时本机明明有能用的描述文件，主程序也签不成；
    ensure_profile.sh 文件头写的本意就是「签名报退出码 3 时才调」。dev_sign 带 S2A_PROFILE_NEED_UDIDS = 这台，描述文件不含它也算没有"""
    #   11-17 #1447 / #1448（0.5.2 装上被手机拒 0xe8008015）：不知道这台手机的 UDID 时本机描述文件含不含它核不了 → 不用本机的，先申请（0.5.1 的做法）；
    #   c.profile_force_request（sign_and_install 手机拒了那份之后重来）同样先申请；c.profile_picked：dev_sign 把用了哪份描述文件记进这个文件
    picked = getattr(c, "profile_picked", None)
    senv = dict(env or c.env(), **({"S2A_PROFILE_NEED_UDIDS": udid} if udid else {}), **({"S2A_DEV_SIGN_PICKED": str(picked)} if picked else {}))
    if udid and not getattr(c, "profile_force_request", False):
        if steps: c.begin("用你的 Apple ID 签名", 4, 6, keychain=True)   # codesign 用钥匙串里的签名身份：可能弹授权（开发者证书模式读 p12，不弹）
        c.last_rc = 0
        c.run(sign, log, senv, ok_codes=(0, 3))
        if c.last_rc != 3:
            return
    if steps: c.begin("申请开发描述文件（第一次要几十秒）", 3, 6, keychain=True)   # 用 Xcode 账号申请：可能弹钥匙串授权
    c.run(["bash", c.engine / "pack/ensure_profile.sh", bid, team["id"], ents] + ([udid] if udid else []), log, env)
    if steps: c.begin("用你的 Apple ID 签名", 4, 6, keychain=True)
    c.run(sign, log, senv)


def sign_with_apple_id(c, app, team, bid, ents, udid, log, steps, vision=False, widget=False):
    """Apple ID 模式：按玩家 Xcode 账号申请开发描述文件（ensure_profile.sh）再用钥匙串身份签（dev_sign.py）。
    vision：目标是 Apple Vision Pro（按 iPad 兼容装）——申请描述文件的目标写 id=<UDID>，让 Xcode 自己认平台与「Designed for iPad」变体、登记这台设备
    （原样写 platform=iOS 会找不到这台；理论支持、未真机验证）。
    widget：带主屏小组件扩展——主程序与扩展各申请一份描述文件（扩展包名 <主包名>.widget，两边都带共享组 group.s2arm.widget.<团队号>），
    先签扩展再签主程序；其中任何一步不成（免费账号包名额度 9120、个人团队不给共享组等）→ 去掉扩展、按原来的权限重签，黄字说原因"""
    if widget:
        try:
            return sign_with_widget(c, app, team, bid, ents, udid, log, steps, vision)
        except Failure as e:
            if e.code in ("keychain_prompt",):   # 钥匙串框没人点：去掉扩展也一样要签，照原样报
                raise
            widget_skip(c, app, WIDGET_QUOTA if e.code == "free_appid_limit" else str(e).removeprefix("签名没成：") or e.code)  # 非玩家句（去前缀用）
    try:
        env = dict(c.env(), S2A_PROFILE_DEST=f"id={udid}") if vision and udid else None
        _sign_or_request(c, [sys.executable, c.engine / "pack/dev_sign.py", app, bid, team["id"], ents], bid, team, ents, udid, log, env, steps)
    except Failure as e:
        if e.code != "tool_exit":
            raise
        from errors import recovery, tool_reason
        text = log.read_text(errors="replace")[-8000:] if log.is_file() else ""
        code = classify(text)
        raise Failure("签名没成：" + tool_reason(log) + "；" + recovery(code, packaged=bool(c.r.get("engineBundle"))), code=code) from e  # 非玩家句


def sign_with_widget(c, app, team, bid, ents, udid, log, steps, vision):
    """sign_with_apple_id 带小组件的那一支：权限文件临时写（主程序 = 原权限 + 共享组；扩展 = 只有共享组），扩展先签（dev_sign --extension 不核内存上限）"""
    W = widget_mod(c)
    group = widget_group(team["id"])
    wbid = W.bundle_id(bid)
    with tempfile.TemporaryDirectory(dir=c.private) as t:
        main_ents = Path(t) / "app.entitlements"
        pl = plistlib.loads(Path(ents).read_bytes()); pl["com.apple.security.application-groups"] = [group]
        main_ents.write_bytes(plistlib.dumps(pl))
        ext_ents = Path(t) / "widget.entitlements"
        ext_ents.write_bytes(plistlib.dumps({"com.apple.security.application-groups": [group]}))
        try:
            env = dict(c.env(), S2A_PROFILE_DEST=f"id={udid}") if vision and udid else None
            for x in W.appexes(app):   # 扩展先签（主程序的封印要包住签好的扩展）
                _sign_or_request(c, [sys.executable, c.engine / "pack/dev_sign.py", x, wbid, team["id"], ext_ents, "--extension"], wbid, team, ext_ents, udid, log, env, steps)
            _sign_or_request(c, [sys.executable, c.engine / "pack/dev_sign.py", app, bid, team["id"], main_ents], bid, team, main_ents, udid, log, env, steps)
        except Failure as e:
            if e.code != "tool_exit":
                raise
            from errors import tool_reason
            text = log.read_text(errors="replace")[-8000:] if log.is_file() else ""
            raise Failure("签名没成：" + tool_reason(log), code=classify(text)) from e  # 非玩家句


def win_install_mod(c):   # Windows 签名装机 + 推包（pack/orch/install_win.py：玩家自装的 Impactor 同版 plumesign + s2a-devpush）
    sys.path.insert(0, str(c.engine / "pack/orch"))
    import install_win
    return install_win


def win_udids(W):
    """设备服务里的手机：有 USB 连着的只算 USB 的，同网配对的不算（同 target.cable_first）"""
    devs = W.mux_devices()
    return sorted({u for u, how, _ in devs if u and how == "USB"} or {u for u, _, _ in devs if u})


def win_udid(c, W):
    """要装的那台：请求给的 device（UDID，玩家选的那台）在设备服务里（USB 或同网都算）就用它；没给、或给的那台这次没列出，
    设备服务里只有一台就用那一台（11-13 维护者：插着一台手机就别说识别不了）；多台对不上才让玩家选。
    设备服务列表会瞬时空（插拔 / 同网切数据线），最多读 3 次、间隔 3 秒再判"""
    want = (c.r.get("device") or "").strip()
    udids = []
    for k in range(LINK_READS):
        try:
            links = W.mux_devices()
        except OSError as e:
            raise Failure(f"连不上本机苹果设备服务（{e}）：从 Microsoft Store 装「Apple Devices」后重试。", code="device_pairing_required") from e
        udids = list(dict.fromkeys(u for u, _, _ in links if u))
        if (want and want in udids) or (not want and udids):
            break
        if k + 1 < LINK_READS:
            time.sleep(LINK_RETRY_WAIT)
    if want and want in udids:
        return want
    if len(udids) == 1:
        return udids[0]
    if not udids:
        raise Failure("这台电脑的设备服务里没看到 iPhone / iPad：插上数据线并解锁手机，在手机上点「信任」，再试一次。", code="device_not_connected")
    raise Failure(S_DEVICE_REQUIRED if not want else
                  f"要装的那台设备（编号末尾 {want[-6:]}）这次没列出来，这台电脑现在连着 {len(udids)} 台：在装机页选其中一台再装。",
                  code="device_required" if not want else "device_not_connected")


def readiness_windows(c, gid):
    """装机前清单的 Windows 版：做好 iPhone 版 → Impactor（实测版本 + plumesign）→ 手机连着（设备服务里有且只有一台）；同 Mac 版的项格式"""
    W = win_install_mod(c)
    items = []
    ipa_path = ""
    def item(key, ok, title, detail, who="human", waiting=False, url=None, action=None):
        wait = waiting and not ok
        # 只有没出包才真挡；其余只提示，直接去签名，真失败再给原因
        items.append(dict(id=key, ok=bool(ok), waiting=wait, blocking=key == "package" and not ok, title=title, detail="" if ok or wait else detail, who=who,
                          url=None if ok else url,   # 玩家自装件的官方下载页（同环境检查 winenv 的 url 字段）：启动器渲染成「打开官方下载页」，不从说明文字里抠链接
                          action=None if ok else action))   # 启动器本地动作（openImpactor：打开随包的 Impactor）；只认枚举，不传路径
    try:
        ios_pack(c, gid)
        ipa_path = phone_ipa_path(c)
        item("package", True, "这款游戏的 iPhone 版已经做好", "")
    except Failure:
        item("package", False, "这款游戏的 iPhone 版已经做好", "还没做好：先做 iPhone 版，做好后这里自动打勾。", who="app")
    resources = c.r.get("resources")
    use_cert = devcert.active(c)
    st = W.impactor.status(resources=resources)
    if use_cert:
        pass   # 证书模式不用 Impactor 账号（plumesign 只装不签，随包就有）；证书两项排在设备之后（要设备 UDID）
    elif st.get("bundled"):   # 发版启动器随包（11-07）：零跳转；第一次要在 Impactor 里登录 Apple ID（密码只在 Impactor 里输、只发给 Apple，我们不代输）
        item("impactor", st["verdict"] == "ok", "签名工具 Impactor 已就绪（随 S2Arm 附带的第三方开源工具）",
             recovery("impactor_missing", packaged=True))
        many = len(W.impactor.unselected_accounts()) > 1   # 存了多个 Apple ID 却没选中（D-ZM37）；只存一个的装机时替玩家选上，照常打勾
        item("impactor_login", st["verdict"] != "ok" or (W.impactor.logged_in() and not many), "已在 Impactor 里登录 Apple ID（只需一次）",
             "Impactor 里存着几个 Apple ID，但没有选中要用的那个：点「打开 Impactor」，在「设置」里选中它点「移除账号」，再「添加账号」重新登录（添加的就是选中的），回来这里自动打勾。"
             if many else "点「打开 Impactor」，在「设置 → 添加账号」登录你的 Apple ID（免费的就行），登录好回来这里自动打勾。",
             action="openImpactor")
    else:
        item("impactor", st["verdict"] == "ok" and bool(W.plumesign_path()), "Impactor 已装好并登录过 Apple ID",
             recovery(st["code"] or "impactor_missing", packaged=False), url=st["download"])
    # 清单只看要装的那台、每次现查：请求带了 device（续签 = 当初那台）就只认它（USB 或同网都算）；没带就是唯一连着的那台（前端拿它的号去装）
    want = (c.r.get("device") or "").strip()
    try:
        links = W.mux_devices()
        udids = ([want] if want in {u for u, _, _ in links if u} else []) if want else win_udids(W)
    except OSError:
        links, udids = [], []
    how = "数据线" if udids and any(u == udids[0] and t == "USB" for u, t, _ in links) else "同一 Wi-Fi"
    item("connected", len(udids) == 1, "{0}已连上（{1}）".replace("{0}", "设备").replace("{1}", how) if len(udids) == 1 else "选的设备已连上（数据线或同一 Wi-Fi）",
         (f"要装的那台设备（编号末尾 {want[-6:]}）现在不在线：插上数据线并解锁，或让它和这台电脑连同一个 Wi-Fi。" if want else
          "连着不止一台 iPhone / iPad：只留要装的那一台。" if len(udids) > 1 else "用数据线把 iPhone / iPad 连到这台电脑，或让它和这台电脑连同一个 Wi-Fi；解锁并点「信任」。"))
    cert = devcert_items(c, item, udids[0] if len(udids) == 1 else "") if use_cert else None
    kind = ""
    if len(udids) == 1 and hasattr(W, "device_kind"):   # #487：连着的是 iPad 时入口写「装到 iPad」
        try:
            kind = W.device_kind(udids[0])
        except (OSError, ValueError):
            kind = ""
    return dict(gameId=gid, items=items, ready=not any(i["blocking"] for i in items), device=udids[0] if len(udids) == 1 else "", deviceKind=kind,
                account=(cert or {}).get("teamName") or "", ipaPath=ipa_path, imgPath=phone_img_path(c, gid), shaderCachePath=phone_shader_cache(c, gid), signMode="devcert" if use_cert else "appleId", devcert=cert)


def devpush_client(c, udid, bid, work):
    """s2a-devpush（house_arrest + AFC）：两端都随发版带，devicectl 没有的「删容器里的目录」「整目录拉回」走它"""
    sys.path.insert(0, str(c.engine / "tools"))
    import push_pack as P
    prebuilt = c.engine / "Binaries/Prepare/devpush" / P.EXE
    exe = P.devpush_path(str(prebuilt) if prebuilt.is_file() else None, c.env())
    if not exe:
        raise Failure("找不到 s2a-devpush：请重新安装完整的 S2Arm。", code="tool_missing")
    return P.Devpush(exe, udid, bid, work, c.env())


class MacPhone:
    """Mac：Xcode 账号签名 + devicectl 装 + push_pack 推（出包重叠早装传入开工前认好的账号与设备）"""

    def __init__(self, c, team=None, dev=None, udid=None):
        self.c = c
        self.team = team or devcert.team(c) or pick_team(xcode_teams(c.env()), c.r.get("teamId"))
        self.dev = dev or phone(c)
        self.udid = udid if udid is not None else udid_of(c, self.dev["id"])
        self.bid = devcert.state(c)["bundleId"] if devcert.active(c) else container_bundle_id(self.team["id"], c)   # 证书模式：描述文件定的包名（和 Apple ID 模式是两个 App）
        self.key = self.udid or self.dev["id"]   # devices/<设备>.json 的键
        # deviceKind / deviceName：完成页、诊断写「已装到 iPad「名字」」，不写死 iPhone
        self.info = dict(device=self.dev["name"], deviceName=self.dev["name"],
                         deviceKind="iPad" if (self.dev.get("productType") or "").startswith(("iPad", "RealityDevice")) else "iPhone",   # Apple Vision Pro 按 iPad 兼容装
                         team=self.team["name"], free=self.team["free"])
        self.pending = None   # 资源传完但没拉起 App 解开时的那句（put_game 带进结果 unpackPending）

    def app_running(self):
        return app_running(self.c, self.dev["id"], self.bid) if self.bid else None

    def pull_kept(self, games):
        """这几款在手机上留下的 NRO 都收回游戏库（pull_kept_nros，#8be819）→ 新收的个数；收不到不挡装机"""
        n = 0
        for g in games:
            try:
                n += pull_kept_nros(self.c, self.dev["id"], self.bid, g, docs=game_docs(g))
            except (OSError, Failure) as e:
                print(f"[s2a] 收回 {g} 留下的 NRO 失败：{e}", file=sys.stderr)
        return n

    def backup(self, g):
        backup_saves(self.c, self.dev["id"], self.bid, g, docs=game_docs(g))

    def app_missing(self, bid, why):
        """s2a-devpush 进不了容器时，这台手机确实没装这个包名吗？Mac 上没装时 s2a-devpush 只回「device socket io failed」（真机实测），
        和真断线分不开，所以问 devicectl 的应用列表（同 backup_saves）；连它也问不出 → 停装"""
        from diag import devicectl
        rc, apps, err = devicectl(self.c, "device", "info", "apps", "--device", self.dev["id"], "--bundle-id", bid, timeout=60)
        if rc:
            note(self.c, "问不出 iPhone 上有没有装过 S2Arm（" + (err.splitlines()[-1] if err else f"devicectl 退出 {rc}") + "），按装着、读不到继续")  # 非玩家句
            return False
        return not any(a.get("bundleIdentifier") == bid for a in (apps.get("result") or {}).get("apps") or [])

    def install(self, ipa, games, steps=True):
        try:
            sign_and_install(self.c, ipa, self.team, self.dev, self.udid, self.bid, games, steps=steps)
        except Failure as e:
            # 包名被别处占用（玩家先自签装过 S2Arm）：自动换一个包名再签一次、记下，之后都用它；换过的也被占才照报 app_id_taken
            if e.code != "app_id_taken" or devcert.active(self.c) or self.bid.endswith(ALT_BUNDLE_SUFFIX):
                raise
            old, self.bid = self.bid, self.bid + ALT_BUNDLE_SUFFIX
            sign_and_install(self.c, ipa, self.team, self.dev, self.udid, self.bid, games, steps=steps)
            bundle_switched(self.c, self.team["id"], self.bid)
            self.c.diagnostic(f"包名 {old} 已被别的签名占用，这次自动改用 {self.bid} 装好了", code="bundle_id_switched", severity="warning")

    def before_push(self, packs):
        mbps = usb_mbps(self.udid, self.c.env())
        if 0 < mbps < 5000:   # 10-26 实测：两台测试设备经集线器只有 480 Mb/s，资源包约 31 MB/秒；USB 3 直插约 10 倍
            gb = sum(f.stat().st_size for p in packs.values() for f in p.rglob("*") if f.is_file()) / 2**30
            if not packs or gb <= 0:   # 这次一个资源包都不推（只换壳更新、续签）：不说「第一次全拷约 N 分钟」（11-11 维护者截图：0.0 GB 也照报，误导）
                return
            self.c.diagnostic(f"这台 iPhone 现在按 USB 2.0（{mbps} Mb/s）连着：资源包 {gb:.1f} GB 第一次全拷约 {max(1, round(gb * 1024 / 31 / 60))} 分钟，"
                              "换 USB 3 能快约 10 倍（以后重装只推变了的文件）", code="usb_slow", severity="warning")

    def push(self, g, pack):
        n0 = len(self.c.job["diagnostics"])
        r = push_pack(self.c, self.dev["id"], self.bid, pack, udid=self.udid, docs=game_docs(g), ctx=game_ctx(g), pack_root=pick_pack_root(self.c, self, g))
        push_cheats(self.c, self.dev["id"], self.bid, g, game_docs(g))
        hit = [d for d in self.c.job["diagnostics"][n0:] if d.get("code") == "manual_unpack_required"]   # push_pack 按「需要玩家操作」收尾时记的那条
        if hit: self.pending = hit[-1].get("summary") or ""
        return r

    def client(self, work):
        return devpush_client(self.c, self.udid, self.bid, work)

    def purge(self, g):
        with tempfile.TemporaryDirectory(dir=self.c.private) as w:
            return purge_game(devpush_client(self.c, self.udid, self.bid, w), g)


def win_install_failure(e):
    """Windows plumesign 签名装机失败（install_win.Fail）→ 作业失败。有对应处理建议的码（free_appid_limit = Apple 9120 等）：上屏说人话的原因与办法，
    plumesign 英文原文只进诊断（Windows 实机：原先整句英文「Developer API error 9120 …」直接上屏，玩家只看到签名失败）；没有专门建议的照旧上屏原文。
    容器装机（WinPhone.install）与下游独立 App 装机（downstream.install_ios_win）同用"""
    code = e.err or "device_install_failed"
    from errors import RECOVERY
    if code in RECOVERY and code not in ("device_install_failed", "job_failed"):
        # 连不上签名服务器：plumesign 那句是系统的本地化原话（如「不知道这样的主机。 (os error 11001)」），一并上屏，玩家 / 帮他的人能照着查网络
        said = f"（Impactor 原话：{str(e).split('：', 1)[-1].strip()}）" if code == "signing_server_unreachable" else ""
        return Failure("签名装机没成：" + RECOVERY[code] + said, code=code, internal=str(e))  # 非玩家句
    return Failure(str(e), code=code)


class WinPhone:
    """Windows：Impactor 同版 plumesign 签名装机（包名由它按账号定、装完才知道，记在这台的设备记录 devices/<设备>.json 的 bundleId，供下次覆盖前备份）+ s2a-devpush 备份 / 推 / 删"""

    def __init__(self, c):
        self.c, self.W = c, win_install_mod(c)
        self.udid = win_udid(c, self.W)
        self.key = self.udid
        self.bid = devcert.state(c)["bundleId"] if devcert.active(c) else layout.load_device(c, self.key).get("bundleId") or None
        self.devpush = c.engine / "Binaries/Prepare/devpush/s2a-devpush.exe"
        # Windows 设备服务给不出设备名，类型按 USB 产品号认（同装机前清单 deviceKind）；认不出写空，前端写「iPhone / iPad」
        kind = ""
        if hasattr(self.W, "device_kind"):
            try:
                kind = {"ipad": "iPad", "iphone": "iPhone"}.get(self.W.device_kind(self.udid), "")
            except Exception:
                kind = ""
        self.info = dict(device=self.udid, deviceName="", deviceKind=kind)
        self.pending = None   # 资源传完但没拉起 App 解开时的那句（put_game 带进结果 unpackPending）

    def pull_kept(self, games):   # 留下的 NRO（#8be819）：Windows 不收（0.5.0 维护者定：从手机收回只保留 Mac 已发版的那条，Windows 端这次不上）
        return 0

    def app_running(self):   # 查不了进程（Windows 没有 devicectl）：调用方改用 playing（游玩时间心跳）
        return None

    def playing(self, games):
        """按游玩时间心跳判手机上是不是正在玩（playing_by_heartbeat）：True 在玩 / False 没在玩 / None 查不清"""
        if not self.bid:
            return None
        import tempfile
        with tempfile.TemporaryDirectory(prefix="s2a-hb-") as work:
            try:
                client = self.client(work)
            except Failure:
                return None
            return playing_by_heartbeat(client, games, work)

    def client(self, work):
        return devpush_client(self.c, self.udid, self.bid, work)

    def app_missing(self, bid, why):
        """Windows 上没有 devicectl：手机明确答「没有这个 App」时 s2a-devpush 的原文含 ApplicationLookupFailed（Windows 实机核过）；
        进不了容器时 s2a-devpush 再用 installation_proxy 按包名查一次，确实没装就打结构化标记 S2A_APP_MISSING（11-11 实机实测：
        删了 S2Arm 再装，原文只有「device socket io failed」，原先被当成锁屏挡住）。两样都没有 = 判不了，交给调用方按装机原则继续"""
        return "ApplicationLookupFailed" in why or "S2A_APP_MISSING" in why

    def backup(self, g):
        """覆盖装前备份本款存档（同 Mac backup_saves 口径：拉失败就停装）。按这次要装的包名查（这台没记录也可能有 Mac 装的同包名 App 和存档）；
        只有手机明确答「没有这个 App」（ApplicationLookupFailed）才算没装过、不备份。别的取不到（锁屏 / 断开 / 配对问题）一律停装，
        不当成没装过——当成没装会跳过备份直接覆盖（#333）"""
        bid = self.bid or self.bundle_for_signing()
        if not bid:
            # 这台没记过包名、又读不到 Impactor 当前账号的团队号：定不了包名就查不了手机上有没有这款的存档。原先直接放行、交给 plumesign 自己定包名
            #   装上去，等于不备份就覆盖（审计 P2-253）。真实 accounts.json 每个账号都带十位 team_id（Windows 实机核过），读不到 = 存档坏了或没选账号，停装
            return backup_failed(self.c, "读不到 Impactor 当前账号的团队号，定不了要装的包名，查不了手机上这款的存档")
        dest = layout.path(self.c, g, "save_backup", time.strftime("%Y%m%d-%H%M%S"))
        with tempfile.TemporaryDirectory(dir=self.c.private) as w:
            ok, out = devpush_client(self.c, self.udid, bid, w).get_tree(f"{game_docs(g)}/{SAVE_REL}", dest)
        if not ok:
            if "ApplicationLookupFailed" in out or "S2A_APP_MISSING" in out:   # 机上确实没装这个包名（Windows 实机核过的原文 / s2a-devpush 查 installation_proxy 的标记）
                return None
            return backup_failed(self.c, "拉存档失败：" + out[-200:])  # 非玩家句
        return dest if dest.is_dir() else None

    def install(self, ipa, games, steps=True):
        b = self.W.impactor.bundled(self.c.r.get("resources")) or {}   # 发版启动器随包的 plumesign（11-07）；源码树没有 → install_win 照旧找
        if not devcert.active(self.c):
            # 只存了一个 Apple ID 却没选中（D-ZM37）：先选上，备份要的团队号 / 包名和 plumesign 签名都认选中的那个
            picked = self.W.impactor.select_only_account(self.W.plumesign_path(b.get("plumesign")))
            if picked: self.c.emit("message", "Impactor 里存着一个 Apple ID 但没选中，已替你选上")
        for g in games:
            self.backup(g)
        if devcert.active(self.c):
            return self.install_devcert(ipa, steps)
        if steps: self.c.begin("签名并装到 iPhone（Impactor 官方命令行 plumesign）", 3, 6)
        log = self.c.logs / (self.c.task + "-install.log")
        self.c.last_log = log
        # 主屏小组件扩展（11-16）：plumesign 自己给扩展注册包名与共享组。玩家关了 → 去掉再交；带着签不成（免费账号包名额度 9120 等）→ 去掉重来一次，黄字说原因
        with tempfile.TemporaryDirectory(dir=self.c.private) as t:
            plain = Path(t) / "S2Arm.ipa"
            had = ipa_strip_widget(ipa, plain)
            if had and self.c.r.get("widget") is False:
                ipa, had = plain, False
            ns = argparse.Namespace(ipa=str(ipa), udid=self.udid, name=None, plumesign=b.get("plumesign"), log=str(log), bundle=self.bundle_for_signing())
            try:
                self.bid = self.W.install_app(ns, say=lambda m: self.c.emit("message", m))
            except self.W.Fail as e:
                if not had:
                    raise win_install_failure(e) from e
                first = win_install_failure(e)
                print(f"[装机] 带小组件签名装机没成（{e.err or ''}：{e}），去掉小组件重来", file=sys.stderr, flush=True)  # 非玩家句
                ns.ipa = str(plain)
                try:
                    self.bid = self.W.install_app(ns, say=lambda m: self.c.emit("message", m))
                except self.W.Fail as e2:
                    raise win_install_failure(e2) from e2
                why = WIDGET_QUOTA if e.err == "free_appid_limit" else str(first)
                self.c.diagnostic(f"这次没装小组件：{why}", code="widget_skipped", severity="warning")
        rec = layout.load_device(self.c, self.key)
        layout.save_device(self.c, self.key, dict(rec, bundleId=self.bid))

    def install_devcert(self, ipa, steps):
        """玩家自己的开发者证书（v0.2.4）：解 ipa → rcodesign 签（同 Mac devcert.sign_app）→ 另存 S2Arm.signed.ipa → plumesign 只装不签（device --install）"""
        c = self.c
        log = c.logs / (c.task + "-install.log")
        c.last_log = log
        stage = Path(tempfile.mkdtemp(prefix="s2a-install-", dir=c.private))
        try:
            import zipfile
            with zipfile.ZipFile(ipa) as z:
                z.extractall(stage)
            app = next((stage / "Payload").glob("*.app"), None)
            if not app:
                raise Failure("解不开 iPhone 包：" + str(ipa), code="job_failed")  # 非玩家句
            widget_prepare(c, app, devcert.state(c)["bundleId"], devcert=True)   # 自己的证书只有主程序一份描述文件：去掉小组件扩展（玩家关了不提示）
            if steps: c.begin("用你的开发者证书签名", 3, 6)
            bid, _ = devcert.sign_app(c, app, log)
            devcert.export_ipa(c, stage / "Payload")
            if steps: c.begin("装到 iPhone", 4, 6)
            b = self.W.impactor.bundled(c.r.get("resources")) or {}
            try:
                self.W.install_signed(self.W.plumesign_path(b.get("plumesign")), app, self.udid, log)
            except self.W.Fail as e:
                raise Failure(str(e), code=e.err or "device_install_failed") from e
        finally:
            shutil.rmtree(stage, ignore_errors=True)
        self.bid = bid
        rec = layout.load_device(c, self.key)
        layout.save_device(c, self.key, dict(rec, bundleId=bid))

    def bundle_for_signing(self):
        """交给 plumesign 的包名：和 Mac 同一个（container_bundle_id(团队号)，团队号取 Impactor 当前账号）。这台记录过只差大小写的包名
        （早先 Windows 让 plumesign 自己定的 io.s2arm.games.<大写团队号>）就沿用它：换成小写会在手机上多出一个 S2Arm、存档留在旧的里。
        读不到团队号 → None（照旧由 plumesign 定）"""
        if devcert.active(self.c):
            return devcert.state(self.c)["bundleId"]
        team = self.W.impactor.selected_team() if hasattr(self.W.impactor, "selected_team") else None
        if not team:
            return None
        want = container_bundle_id(team)
        return self.bid if self.bid and self.bid.lower() == want.lower() else want

    def before_push(self, packs):
        pass

    def push(self, g, pack):
        try:
            return self.W.push_pack(self.udid, self.bid, str(pack), str(self.devpush) if self.devpush.is_file() else None, accept_low_space=self.c.r.get("acceptLowSpace") is True,
                                    say=lambda m: self.c.emit("message", m), docs=game_docs(g), ctx=game_ctx(g), apply_after=not img_pack(pack) and not game_ctx(g),   # 容器传完即装好（同 Mac push_pack）
                                    pack_root=pick_pack_root(self.c, self, g),
                                    progress=lambda d, t, k, n: push_progress(self.c, d, t, k, n),
                                    stage=lambda name, d=None, t=None: push_stage(self.c, name, d, t))
        except self.W.Fail as e:
            if e.err == "manual_unpack_required":
                self.c.diagnostic(str(e), code=e.err, severity="warning")
                self.pending = str(e)
                return e.transferred
            raise Failure(str(e), code=e.err or "resource_transfer_failed") from e

    def purge(self, g):
        with tempfile.TemporaryDirectory(dir=self.c.private) as w:
            return purge_game(self.client(w), g)


def phone_for(c):
    return WinPhone(c) if os.name == "nt" else MacPhone(c)


GID_RE = re.compile(r"[0-9A-F]{16}")
# 机上目录不存在：s2a-devpush ls 的结构化错误码 S2A_AFC_ERR 8（AFC ObjectNotFound）；旧工具 / devicectl 只有原文，兜底认
#   「No such file」与「Object not found / ObjectNotFound」（带不带空格、大小写都认）。玩家实机（Windows 0.2.7、iOS 27.0.1）原文是
#   「afc error: Object not found」，原先只认 ObjectNotFound，首次装机（App 在、还没有 Documents/games）被当成读不出设备挡住（v0.2.8 热修）
AFC_NOT_FOUND = 8


def dir_missing(out):
    m = re.search(r"S2A_AFC_ERR (\d+)", out or "")
    if m:
        return int(m.group(1)) == AFC_NOT_FOUND
    return bool(re.search(r"no such file|object\s*not\s*found", out or "", re.I))


PREEMPT_OPERATIONS = ("installUpdatePrepare", "sgradeMac")   # 前台装机让它们先停的后台自动作业：同 main.AUTO_HEAVY（单测锁住两处一致；main 是入口脚本，这里不 import 它）


@contextlib.contextmanager
def packer_phone_lock(c):
    """装机类作业（装到 iPhone / 更新 / 装回上一版 / 从手机删 / 推导出包）一次一个（ipa.phone_lock）。拿锁前先取消正在跑的后台自动作业
    （core.preempt_jobs，11-17 #1450：玩家点的优先，不在降到最低优先级的后台改写后面排队）"""
    import ipa as packer
    from core import preempt_jobs
    preempt_jobs(c, PREEMPT_OPERATIONS, say=lambda t: trace(c, t))
    trace(c, "拿手机锁…")
    with packer.phone_lock(c):
        trace(c, "拿到手机锁")
        yield


def trace(c, text):
    """装机过程记进本任务日志（core.trace，进诊断包）：进锁前后、各款改写、组容器的起止（11-17 #1450：原先只看得到停在第几步）"""
    from core import trace as _trace
    _trace(c, text)


def phone_bid(ph):
    """这次要装的包名：这台记录过的；Windows 第一次装还没记录 → 按 Impactor 当前账号算（同 WinPhone.bundle_for_signing）"""
    return ph.bid or (ph.bundle_for_signing() if hasattr(ph, "bundle_for_signing") else None)


def phone_games(c, ph):
    """这台手机上的 S2Arm 里有哪些游戏——真相在手机上，不在某一台电脑的设备记录里（同一台手机 Mac 装几款、Windows 再装一款时，
    各自的记录只有自己装的）。列这个包名的资源包新旧两处游戏目录（PACK_GAMES、Documents/games）：只认目录名是 16 位游戏号、
    pack_listing 选出的那处资源包已解开（.applied）的，别的跳过。
    进不了容器时问平台这个包名装没装（ph.app_missing）：确实没装 → None（和「装着、一款都没有」的空集分开：没装时本机记录的各款也不在手机上了，
    container_others 据此不再带）。装着却列不出、或连装没装都判不了（锁屏 / 断开 / 工具原文认不出）：照装机原则（11-11「认不出的直接装」）
    按「这处没有别的游戏」继续，只记进日志——最坏是这台电脑不知道的别的款这次没带进容器，它们的资源包和存档还在手机上，回原电脑再装就回来"""
    bid = phone_bid(ph)
    if not bid or not ph.udid:
        return set()
    with tempfile.TemporaryDirectory(dir=c.private) as w:
        try:
            cl = devpush_client(c, ph.udid, bid, w)
        except Failure as e:   # 工具不在（预检清单 #29）：同「列不出」——按没有别的游戏继续装，不拦整单
            note(c, f"列不出{_who(ph)}上装了哪些游戏，按没有别的游戏继续装（{e}）")
            return set()
        names = set()
        for root in (DOCS_GAMES, PACK_GAMES, PACK_GAMES_ALT):
            rc, out = cl.call("ls", root)
            if rc:
                if dir_missing(out):   # 这处还没建（App 在、还没装过任何一款 / 只有新或旧一处）：这处当 0 款，装机照常（推资源包时自会建目录）
                    continue
                if ph.app_missing(bid, out):
                    return None
                note(c, f"读不出{_who(ph)}上 {root} 里装了哪些游戏，按这处没有别的游戏继续装（s2a-devpush ls：{out[-300:].strip()}）")
                continue
            names |= {n.strip().rstrip("/").upper() for n in out.splitlines()}
        return {g for g in names if GID_RE.fullmatch(g) and ".applied" in (pack_listing(cl, g, ph)[1] or [])}


PHONE_LEDGER = "Documents/.s2a-games.json"   # 手机 App 写的游戏账本（11-16 维护者「手机端得有个记录在根目录下」）：{"version": 1, "games": {游戏号: {"state": "present" | "removed", "at", "program"}}}


def phone_removed(c, ph):
    """手机账本里玩家在手机上删掉的款（state = removed）→ 游戏号集合；读不到账本（旧 App 没写、进不了容器、格式不对）→ None，按现状组壳。
    只有手机写账本，电脑只读：电脑重新装上一款，手机见到它的资源包回来就自己改回 present"""
    bid = phone_bid(ph)
    if not bid or not ph.udid:
        return None
    with tempfile.TemporaryDirectory(dir=c.private) as w:
        try:
            cl = devpush_client(c, ph.udid, bid, w)
        except (Failure, ImportError):   # 推送工具不在：同「读不到账本」，按现状组壳，不挡装机
            return None
        dst = Path(w) / "ledger.json"
        if not cl.get(PHONE_LEDGER, dst):
            return None
        try:
            data = json.loads(dst.read_text(encoding="utf-8"))
            games = data.get("games") if isinstance(data, dict) and data.get("version") == 1 else None
        except (OSError, ValueError):
            return None
    if not isinstance(games, dict):
        return None
    return {g.upper() for g, v in games.items() if isinstance(v, dict) and v.get("state") == "removed" and GID_RE.fullmatch(g.upper())}


def _who(ph):
    info = getattr(ph, "info", None) or {}
    return f"{info.get('deviceKind') or 'iPhone / iPad'}「{info.get('deviceName')}」" if info.get("deviceName") else (info.get("deviceKind") or "设备")


def pack_listing(cl, gid, ph=None):
    """本款资源包在手机上的哪一处 → (资源包根, 根下列表或 None)：新位置在 → 新位置；新位置不在、旧位置在 → 旧位置（App 下次启动整个同盘挪到新位置，
    含推进 .incoming 的包；增量仍按旧位置的 index.applied.tsv 算，不因新位置是空的整份重推几 GB）；两处都不在（第一次装这款）→ (新位置, None)。
    列不出（锁屏 / 断开等，不是「目录不在」）：照装机原则按「两处都不在」推到新位置继续，只记进日志（最多整份重推一次）。
    老位置真有一份旧的也不会两份长期并存：App 下次打开游戏库时 s2a_pack_migrate_one 见新旧都在、新的已应用，就删掉老的（runtime/src/pack_apply.c）"""
    rc, out = cl.call("ls", PACK_GAMES_ALT)   # 手机上有备用位置（新壳搬过）：宿主只认它，这款在不在都推它
    if not rc:
        root = game_pack(gid, PACK_GAMES_ALT)
        rc, out = cl.call("ls", root)
        return root, (None if rc else out.splitlines())
    for root in (game_pack(gid), game_pack_old(gid)):
        rc, out = cl.call("ls", root)
        if not rc:
            return root, out.splitlines()
        if not dir_missing(out):
            if getattr(ph, "c", None) is not None:
                note(ph.c, f"读不出{_who(ph)}上 {gid} 的资源放在哪（{root}），按第一次装推到新位置（s2a-devpush ls：{out[-300:].strip()}）")
            return game_pack(gid), None
    return game_pack(gid), None


def pick_pack_root(c, ph, gid):
    """推这款资源包推到哪（推送、列机上文件、判已应用都用这一处，push_pack.py --pack-root）：规则见 pack_listing"""
    with tempfile.TemporaryDirectory(dir=c.private) as w:
        return pack_listing(devpush_client(c, ph.udid, phone_bid(ph), w), gid, ph)[0]


def purge_game(cl, gid):
    """删手机上这款的数据：文档根（存档 / 金手指 / 解包日志，连同旧位置的资源包）+ 新位置本款目录（资源包）。→ (都删掉?, 输出)"""
    ok1, out1 = cl.rm(game_docs(gid))
    ok2, out2 = cl.rm(f"{PACK_GAMES}/{gid.upper()}")
    ok3, out3 = cl.rm(f"{PACK_GAMES_ALT}/{gid.upper()}")   # 备用位置（不在算删掉）
    return ok1 and ok2 and ok3, "\n".join(o for o in (out1, out2, out3) if o)


def phone_game_name(c, ph, gid, names):
    """确认框里的名字：本机游戏库有就用库里的，否则读手机上这款资源包自带的 control.nacp，再不行用游戏号"""
    if names.get(gid):
        return names[gid]
    try:
        import library
        with tempfile.TemporaryDirectory(dir=c.private) as w:
            dst = Path(w) / "control.nacp"
            cl = devpush_client(c, ph.udid, phone_bid(ph), w)
            if any(cl.get(f"{root}/ctl/control.nacp", dst) for root in (game_pack(gid, PACK_GAMES_ALT), game_pack(gid), game_pack_old(gid))):
                dump = library.engine_tool(c, "ns2_dump")
                n = dst.read_bytes()
                return dump.nacp_title(n, 14) or dump.nacp_title(n, 0) or gid
    except Exception:   # noqa: BLE001 —— 名字读不到就用游戏号
        pass
    return gid


def container_others(c, ph, rec, leave=None):
    """现组容器要带的别的款：这台电脑记录的 + 手机上实际有的（phone_games）。手机上有、这台电脑没记录、游戏库里也没有的，带不进去
    （App 里的游戏程序读不回电脑）：没带 acceptDropped 就停下报 container_would_drop，列出这几款，玩家确认后再装；确认了就不带它们——
    它们的存档和资源包还在手机上，在原来那台电脑上再装一次就回来。这台电脑记录装在手机上、但玩家已从游戏库删掉的款同样带不进，同样先问。
    手机上这个 App 已经不在（玩家在手机上删了，phone_games → None）：这台电脑记录的各款也跟着没了，一款都不带——原先照带，
    其中换壳后重出不了的报 container_stale 挡住这次装机，能带的也只进程序、资源包按记录不重推"""
    known = set(rec.get("games", {}))
    on_phone = phone_games(c, ph)
    if on_phone is None:
        known = on_phone = set()
    # 手机账本里玩家删掉的款不再带（原先这台电脑记录里还有它，下次更新 S2Arm 又把程序带回去、手机上却没资源，11-16 维护者）；
    #   这次明确要装的那款（leave）不在候选里、照装。读到了就顺手把本机记录里这几款摘掉
    removed = phone_removed(c, ph) or set()
    if removed & known:
        rec["games"] = {g: v for g, v in rec.get("games", {}).items() if g not in removed}
        layout.save_device(c, ph.key, rec)
        known -= removed
    on_phone -= removed
    names = {g["id"].upper(): g.get("name") or "" for g in c.catalog()["games"]}
    candidates = sorted((known | on_phone) - {leave})
    # 带不进的两种：手机上有、这台电脑没记录也没有（别的电脑装的）；这台电脑记录装在手机上、游戏库里已删（玩家删了这款）——
    #   后者原先在 ipa.assemble 里按「已删」静默不带，手机上这款就悄悄打不开了；现在同样先问
    lost = [g for g in candidates if g not in names and (g in on_phone or g in known)]
    here = known | set(rec.get("deleted") or [])   # 这台电脑记录装在手机上的 + 在这台电脑上「删除游戏」时摘掉的（library.drop_from_container 记）
    if lost and c.r.get("acceptDropped") is not True:
        elsewhere = "".join("「" + phone_game_name(c, ph, g, names) + "」" for g in lost if g not in here)
        deleted = "".join("「" + phone_game_name(c, ph, g, names) + "」" for g in lost if g in here)
        # 每行一个固定句式（游戏名进 {0} 占位），两端界面按 Localizable.json 逐行翻
        lines = ["这次装完，手机上这几款游戏会打不开（存档和资源包都还在手机上）。"] \
            + ([f"它们是在别的电脑上装的，到那台电脑上再「装到 iPhone」一次就回来：{elsewhere}"] if elsewhere else []) \
            + ([f"它们已从这台电脑的游戏库删除，重新加回游戏库、「打 iPhone 包」再装一次就回来：{deleted}"] if deleted else []) \
            + ["确认继续再点一次。"]
        raise Failure("\n".join(lines), code="container_would_drop", internal=" ".join(lost))
    return [g for g in candidates if g not in lost]


def put_game(c, gid, ph, steps=True, others=None, skipped=()):
    """把这款放进容器并装到手机：现组容器（这款 + 这台手机上已有的各款，ipa.assemble）→ 覆盖装 → 推资源包：这款照推，
    别的款只推「游戏库里的资源包比手机上记的新」的（重新打过 iPhone 包、还没装到这台的），没变的不推（数据和存档不动）。
    装上后记进 devices/<设备>.json，装机产物放默认位置根 S2Arm.ipa（换了壳的话原来那份留作 S2Arm.previous.ipa）。
    gid 为 None + others：不加新款，只把这几款换进本版壳（update_phone）"""
    import ipa as packer
    gid = gid.upper() if gid else None
    if gid: ios_pack(c, gid)   # 这款没有资源包就不组装、不装
    rec = layout.load_device(c, ph.key)
    if others is None:
        others = container_others(c, ph, rec, leave=gid)   # 手机上实际有的款也带上（另一台电脑装的），带不了的先问玩家
    if steps: c.begin("把这款放进手机上的 S2Arm" if gid else "核对手机上的游戏要不要跟着更新", 2, 6)   # gid 为 None = 更新手机上的 S2Arm（update_phone），不说装机的话
    # 改写器修过的话：容器里各款按本引擎改写器核一遍，受影响的只换改写产物（不重出资源包、不推 game.img），再组进新壳（rewrite_refresh.py）
    from rewrite_refresh import refresh_ios
    ph.pull_kept([g for g in ([gid] if gid else []) + list(others) if g])   # 先收回机上留下的 NRO，refresh_ios 才补得进（#8be819）
    with packer.program_locks(c, ([gid] if gid else []) + list(others)):   # 各款程序件这段不让出包交付换（ipa.program_locks）
        refresh_ios(c, [g for g in ([gid] if gid else []) + list(others) if g])
        # 已同意过「这次不带」的款（#479）：按壳号记在设备记录 staleAgreed，同一版壳不再每次问；换了壳号重新问。重新打过 iPhone 包的款组装时带得进，自然不在名单里
        ipa, games, sid = packer.assemble(c, gid, others, failed=rec.get("failedShells", []), agreed=rec.get("staleAgreed") or {})
    left_out = sorted({g.upper() for g in list(others) + list(skipped) if g} - set(games))   # 这次没带进去的（玩家已同意；游戏库删掉的也在里面，不碍事：它们组装时本来就不带、不问）
    # 这次要装的那款必须有资源包（上面已核）；容器里带着的别的款本机资源包不在（清理过 / 换了电脑）不拦整单（预检清单 #31）：
    #   它的资源包多半已在手机上，不推、记录照旧；手机上也没有的，App 里那款会显示要重新导入
    packs = {}
    for g in games:
        try:
            packs[g] = ios_pack(c, g)
        except Failure as e:
            if gid and g.upper() == gid.upper():
                raise
            packs[g] = None
            note(c, f"{g} 本机没有资源包（{e}）：这次不推它，手机上已有的照旧")
    skipped = same_app(c, ph, rec, packer.ipa_digest(ipa))
    if skipped:   # #845：手机上的 S2Arm 就是这次组出的这一个、签名离到期还早 → 不重签不重装，直接推资源（数据和存档本来就不动）
        if steps: c.begin("手机上的 S2Arm 已是这一版，跳过签名和安装", 5, 6)
        note(c, "手机上的 S2Arm 和这次组出的内容一样（S2AContainerDigest 相同），签名离到期还早：跳过签名和安装，只推变了的资源")
    else:
        ph.install(ipa, games, steps=steps)
    # 装上的包名和记录里的不同（换了签名方式 / 包名被占自动换过）= 手机上是另一个 App，资源包都不在里面：每款都推
    moved = bool(rec.get("bundleId")) and bool(ph.bid) and rec["bundleId"] != ph.bid
    stale = [g for g in games if packs[g] is not None and (moved or g == gid or pack_id(packs[g]) != (rec["games"].get(g) or {}).get("pack"))]
    ph.before_push({g: packs[g] for g in stale})
    img = bool(stale)   # 容器装机传完并核过即装好、不等机上解开（单一 IMG 与旧形态同口径，App 打开时游戏库解开；见 push_pack）
    if steps: c.begin("核对手机上游戏的资源（有变化的才推，通常一个都不用推）" if not gid else
                      "把游戏推进 iPhone（只推变了的文件；第一次大游戏要几分钟）" if img else "把资源包推进 iPhone 并解开（只推变了的文件；第一次大游戏要几分钟）", 6, 6)
    files = size = 0
    pushed = dict((g, (rec["games"].get(g) or {}).get("pack", "")) for g in games)
    modset = dict((g, (rec["games"].get(g) or {}).get("mods") or {}) for g in games)
    try:
        for g in stale:
            f, n = ph.push(g, packs[g])
            files += f; size += n
            pushed[g] = pack_id(packs[g])
        for g in games:   # 资源替换类 mod：每款按记录只推变了的（多数情况一个都不用推、不连手机）
            modset[g] = push_mods(c, ph, g, {} if moved else modset[g])
    finally:   # 推到一半失败：已推好的记下，没推的下次照推
        rec = layout.load_device(c, ph.key)
        # signed：这次签名（游戏库页的「还有几天到期 / 续签」读 layout.install_record）：免费账号的描述文件 7 天到期，容器里每款同一次签名
        signed = dict(signed=dict(at=time.time(), free=bool(ph.info["free"]), device=ph.info["device"])) if "free" in ph.info and not skipped else {}   # 跳过安装 = 没重签：到期时间照旧
        layout.save_device(c, ph.key, dict(rec, games={g: dict(pack=pushed[g], **({"mods": modset[g]} if modset[g] else {})) for g in games},
                                           deleted=[g for g in rec.get("deleted") or [] if g not in games], shellId=sid, bundleId=ph.bid or rec.get("bundleId", ""), at=time.time(),
                                           staleAgreed={sid: left_out} if left_out else {}, **signed))
    packer.commit_phone_ipa(c, ipa, sid)
    # 资源传完但电脑没拉起 App 解开（manual_unpack_required，11-09 #336）：不算「已装好」，结果带上还差的一步，两端前端据此显示「还差最后一步」而不是「已装到 iPhone」
    extra = dict(unpackPending=ph.pending) if ph.pending else {}
    if img: extra["openToFinish"] = True   # 两端成功页写「已传到 iPhone，打开 S2Arm 会自动完成安装」（机上解开由 App 打开时游戏库完成）
    return dict(outputPath=str(layout.phone_ipa(c)), bundleId=ph.bid, games=games, packFiles=files, packBytes=size, **ph.info, **extra,
                sgrade=patches_results(c))   # 这次补进 S 级优化的各款：打上 / 没打上（升级结果页列，11-14）


def program_root(pack_root):
    """这款程序包在手机上的目录：资源包根的同级 program/（宿主同口径：runtime/src/launchctx.c s2a_program_catalogue_path）"""
    return pack_root.rstrip("/").rsplit("/", 1)[0] + "/program"


PROGRAM_WRITER = "pc"   # 写入方名（版本目录 v-<sha16>-<写入方>/、临时清单 catalogue.json.<写入方>.tmp）；手机上的导入是 import


def look_of(custom):
    """启动器里改的游戏名 / 封面（ipa.container_custom 的一项）→ 指纹（名字 + 封面内容摘要；没改 = 原名原图同样有指纹，变了才重推）"""
    custom = custom or {}
    cover = Path(custom["cover"]) if custom.get("cover") else None
    h = hashlib.sha256((custom.get("name") or "").encode("utf-8"))
    if cover is not None and cover.is_file():
        h.update(hashlib.sha256(cover.read_bytes()).digest())
    return h.hexdigest()[:16]


def push_program(cl, gid, pkg, pack_root, keep_old=False, custom=None):
    """签好的程序包（program_pack.sign 的目录）推进手机。写入规则（通用壳方案「写入规则」，11-17 与 iOS 加载侧定稿；来源 D-YGEC：
    电脑推送与手机导入同时写同一款，清单和本体成了两版）：同一款各写入方各写自己的版本目录，用一次原子改名换上，后换上的为准，不靠「看见谁在写就让路」：
      ① 整份写进 <program>/v-<image_sha256 前 16 位>-pc/（dylib、Games/<号>/）——同一份续推时机上已完整的文件（长度与开头一页都对）跳过，只补没写完的；
      ② 清单加 dir = 这个版本目录名，先写 catalogue.json.pc.tmp，再改名覆盖 catalogue.json：这一步是唯一的换上（AFC 单文件改名覆盖是原子的）；
      ③ 换上后删**换上前清单指着的那个**旧版本目录——这款没在运行才删；keep_old（调用方判出手机上 App 开着 / 判不清）就留给 App 在这款退出或下次启动时清
         （11-17 定：程序包、资源包同一条）。别的写入方正在写的目录没被指过、不删；没写完的半份由 App 启动时按「最新文件 1 小时没写入」清。
         删不掉不算失败（App 会清）。
    宿主只按清单的 dir 取文件、核 image_sha256（iOS 加载侧）。cl = s2a-devpush 客户端（AFC 自己建目录，#1391）。
    → 设备记录里这款的 program 记录 {sha, team, host_abi, rewriter_id, dir}"""
    gid, pkg = gid.upper(), Path(pkg)
    root = program_root(pack_root)
    cat = json.loads((pkg / "catalogue.json").read_text(encoding="utf-8"))
    vdir = f"v-{cat['image_sha256'][:16]}-{PROGRAM_WRITER}"
    files = [pkg / cat["image"]] + sorted(p for p in (pkg / "Games" / gid).rglob("*") if p.is_file())
    try:
        for f in files:
            rel = f"{root}/{vdir}/{f.relative_to(pkg).as_posix()}"
            size = f.stat().st_size
            got = cl.head(rel, 4096) if hasattr(cl, "head") else None
            if got and got[0] == size:
                with open(f, "rb") as h:
                    if got[1] == h.read(len(got[1])):
                        continue   # 续推：机上这份已完整（同一份程序包、长度与开头一页都对；整份 sha 宿主加载时核）
            cl.put(f, rel)
        with tempfile.TemporaryDirectory() as w:
            old = None   # 换上前清单指着的版本目录（换上后删它）
            prev = Path(w) / "prev.json"
            if cl.get(f"{root}/catalogue.json", prev):
                try:
                    old = json.loads(prev.read_text(encoding="utf-8")).get("dir")
                except ValueError:
                    old = None
            # 启动器里改的名字 / 封面（只有壳的 App 不再带各款条目，游戏库从这份清单拼）：名字写进清单，封面盖到版本目录的 Games/<号>/icon.jpg
            shown = dict(cat, dir=vdir)
            if custom and custom.get("name"):
                shown["name"] = custom["name"]
            if custom and custom.get("cover") and Path(custom["cover"]).is_file():
                cl.put(Path(custom["cover"]), f"{root}/{vdir}/Games/{gid}/icon.jpg")
                shown["icon"] = f"Games/{gid}/icon.jpg"
            tmp = Path(w) / "catalogue.json"
            tmp.write_text(json.dumps(shown, ensure_ascii=False, indent=1), encoding="utf-8")
            cl.put(tmp, f"{root}/catalogue.json.{PROGRAM_WRITER}.tmp")
    except Exception as e:   # push_pack.Fail：已是给玩家的话
        if isinstance(e, Failure):
            raise
        raise Failure(str(e), code=getattr(e, "err", None) or "resource_transfer_failed") from e
    ok, out = cl.mv(f"{root}/catalogue.json.{PROGRAM_WRITER}.tmp", f"{root}/catalogue.json")
    if not ok:
        raise Failure(f"{gid} 的程序清单在手机上就不了位（{(out.splitlines() or [''])[-1]}）：再试一次；还不行请更新电脑上的 S2Arm。", code="resource_transfer_failed")
    if not keep_old and isinstance(old, str) and old.startswith("v-") and "/" not in old and old != vdir:
        cl.rm(f"{root}/{old}")   # 删不掉不算失败：没被指着，App 启动时清
    return dict(sha=cat["image_sha256"], team=cat["team"], host_abi=cat["host_abi"], rewriter_id=cat.get("rewriter_id", ""), dir=vdir, look=look_of(custom))


def push_programs(c, cl, games, rec, team, bundle, signer, pack_roots, keep_old=False):
    """通用壳装机（program_pack.enabled）：每款按设备记录判要不要推（program_pack.need），要推的出包、按这台的团队签、推进 program/。
    rec = 设备记录；pack_roots = {游戏号: 手机上资源包根}；keep_old = 手机上 App 开着 / 判不清（旧版本目录留给 App 清，见 push_program ③）。→ {游戏号: program 记录}（没推的照旧记录原样带回）；推到一半失败照抛，已推好的由调用方记下"""
    import program_pack
    import ipa as packer
    looks = packer.container_custom(c)
    out = {}
    for g in games:
        old = (rec.get("games", {}).get(g) or {}).get("program")
        pkg = program_pack.sign(c, g, team, bundle, signer)
        custom = next((v for k, v in looks.items() if k.upper() == g.upper()), None)
        want = dict(json.loads((Path(pkg) / "catalogue.json").read_text(encoding="utf-8")), look=look_of(custom))
        why = program_pack.need(c, g, old, team, want=want)
        if not why:
            out[g] = old
            continue
        note(c, f"{g} 的程序推进手机（{'、'.join(sorted(why))}）")  # 非玩家句
        out[g] = push_program(cl, g, pkg, pack_roots[g], keep_old=keep_old, custom=custom)
    return out


SHELL_INSTALL_FIRST = "手机上还没装 S2Arm：先点「安装 S2Arm」，装好后再把这款推到 iPhone。"
SHELL_UPDATE_FIRST = "手机上的 S2Arm 不是这一版：先点「更新 S2Arm」，再把这款推到 iPhone。"


def phone_signing(c, ph):
    """通用壳：这台手机上程序包按什么签 → (团队号, 包名, 签名器)。同装机签 App 的那一处：开发者证书 → 证书的团队与描述文件的包名；
    Windows Apple ID → Impactor 当前账号的团队、plumesign 定的包名；Mac Apple ID → 钥匙串账号的团队、容器包名"""
    import program_pack
    if devcert.active(c):
        return devcert.team(c)["id"], devcert.state(c)["bundleId"], program_pack.devcert_signer(c)
    if os.name == "nt":
        team = ph.W.impactor.selected_team() if hasattr(ph.W.impactor, "selected_team") else None
        if not team:
            raise Failure("读不到 Impactor 里登录的 Apple ID：在 Impactor 里登录后再推到 iPhone。", code="xcode_account_missing")
        import ipa as packer
        exe = ph.W.plumesign_path((ph.W.impactor.bundled(c.r.get("resources")) or {}).get("plumesign"))
        shell = Path(packer.container_shell(c, packer.current_shell_id(c))) / "root"
        return team, ph.bundle_for_signing() or ph.bid, program_pack.win_signer(c, exe, shell)
    return ph.team["id"], ph.bid, program_pack.mac_signer(c)


def phone_busy(ph, games):
    """这几款此刻可能在手机上运行吗（换上程序包后删不删旧版本目录，push_program keep_old）：Mac 只能看 App 开没开（devicectl），
    Windows 按游玩时间心跳；判不清一律当在运行"""
    try:
        got = ph.playing(games) if hasattr(ph, "playing") else ph.app_running()
    except Exception:   # noqa: BLE001 —— 判不清当在运行，最坏只是旧目录多留到下次启动
        return True
    return got is not False


def push_game(c, gid, ph, steps=True):
    """通用壳「推到 iPhone」（program_pack.enabled）：只推这一款的程序包与资源包，绝不签名装壳（11-17 维护者定：装 App 与推游戏是两个独立作业）。
    手机上没装 S2Arm（这台没有装壳记录）或壳不是本版 → 报「先安装 / 更新 S2Arm」、不推。程序包按设备记录判要不要推（program_pack.need），
    资源包照 put_game 的判据（资源包号变了才推）。装上后这款的记录加 program"""
    import ipa as packer
    gid = gid.upper()
    pack = ios_pack(c, gid)
    rec = layout.load_device(c, ph.key)
    if not rec.get("shellId") or not ph.bid:
        raise Failure(SHELL_INSTALL_FIRST, code="shell_install_required")
    if rec["shellId"] != packer.current_shell_id(c):
        raise Failure(SHELL_UPDATE_FIRST, code="shell_update_required")
    team, bid, signer = phone_signing(c, ph)
    if steps: c.begin("把这款的程序推进 iPhone", 2, 3)
    from rewrite_refresh import refresh_ios
    ph.pull_kept([gid])   # 机上留下的 NRO 先收回（#8be819），refresh_ios 补进程序件
    pr = pick_pack_root(c, ph, gid)
    with packer.program_locks(c, [gid]):
        refresh_ios(c, [gid])
        with tempfile.TemporaryDirectory(dir=c.private) as w:
            progs = push_programs(c, ph.client(w), [gid], rec, team, bid, signer, {gid: pr}, keep_old=phone_busy(ph, [gid]))
    old = rec.get("games", {}).get(gid) or {}
    rec = layout.load_device(c, ph.key)
    layout.save_device(c, ph.key, dict(rec, games=dict(rec.get("games") or {}, **{gid: dict(old, program=progs[gid])}), at=time.time()))
    if steps: c.begin("把这款的资源推进 iPhone（只推变了的文件；第一次大游戏要几分钟）", 3, 3)
    files = size = 0
    pushed, mods = old.get("pack", ""), old.get("mods") or {}
    try:
        if pack_id(pack) != pushed:
            ph.before_push({gid: pack})
            files, size = ph.push(gid, pack)
            pushed = pack_id(pack)
        mods = push_mods(c, ph, gid, mods)
    finally:
        rec = layout.load_device(c, ph.key)
        layout.save_device(c, ph.key, dict(rec, games=dict(rec.get("games") or {}, **{gid: dict(program=progs[gid], pack=pushed, **({"mods": mods} if mods else {}))}),
                                           at=time.time()))
    extra = dict(unpackPending=ph.pending) if ph.pending else {}
    return dict(bundleId=ph.bid, games=[gid], packFiles=files, packBytes=size, **ph.info, **extra, openToFinish=True)


def install_shell(c, ph, steps=True):
    """通用壳「安装 / 续签 / 更新 S2Arm」（program_pack.enabled）：只组只有壳的容器、签名、装壳，绝不推任何一款的程序包与资源包（11-17 维护者定）。
    手机上已是这一版壳、签名离到期还早（same_app）→ 不装，updated = False。装上后记壳号、包名、签名时刻；各款记录原样留着（程序包在手机上不受装壳影响）"""
    import ipa as packer
    rec = layout.load_device(c, ph.key)
    if steps: c.begin("组 S2Arm（不带游戏）", 2, 3)
    ipa, _, sid = packer.assemble_shell(c)
    if same_app(c, ph, rec, packer.ipa_digest(ipa)):
        note(c, "手机上的 S2Arm 已是这一版、签名离到期还早：不重签不重装")  # 非玩家句
        return dict(updated=False, bundleId=ph.bid, games=[], **ph.info)
    if steps: c.begin("签名并装到 iPhone", 3, 3)
    ph.install(ipa, [], steps=False)
    rec = layout.load_device(c, ph.key)
    signed = dict(signed=dict(at=time.time(), free=bool(ph.info["free"]), device=ph.info["device"])) if "free" in ph.info else {}
    layout.save_device(c, ph.key, dict(rec, shellId=sid, bundleId=ph.bid or rec.get("bundleId", ""), at=time.time(), **signed))
    packer.commit_phone_ipa(c, ipa, sid)
    return dict(updated=True, outputPath=str(layout.phone_ipa(c)), bundleId=ph.bid, games=[], toShell=sid, **ph.info)


SAME_APP_FRESH = (3 * 86400, 30 * 86400)   # 跳过重签的签名新鲜度：免费账号描述文件 7 天到期，签了不到 3 天才跳过（照常装机就顺手续签）；付费 / 证书 30 天


def same_app(c, ph, rec, digest):
    """#845「每次装到 iPhone 都要重新签名打包」：手机上的 S2Arm 就是这次组出的这一个时，不再重签重装，只推资源。三条都满足才跳过：
    ① 手机上这个包名的 App 的 Info.plist S2AContainerDigest（s2a-devpush app-attr，installation_proxy 读，不进容器）= 这次组出的（ipa.stamp_container）——
       真相在手机上：别的电脑（含没有这个键的旧版 S2Arm）重装过就对不上，照常装；② 这台电脑记的上次签名离现在不到 SAME_APP_FRESH（免费账号 / 付费）；
    ③ 请求没要求强制重装（forceInstall）。读不到（工具缺、断开、锁屏）一律当不同：照原来的流程装，最坏只是多装一次"""
    if not digest or c.r.get("forceInstall") or not getattr(ph, "bid", None) or not getattr(ph, "udid", None):
        return False
    signed = rec.get("signed") or {}
    if not isinstance(signed.get("at"), (int, float)) or time.time() - signed["at"] >= SAME_APP_FRESH[0 if signed.get("free", True) else 1]:
        return False
    try:
        with tempfile.TemporaryDirectory(dir=c.private) as w:
            rc, out = devpush_client(c, ph.udid, ph.bid, w).call("app-attr", ipa_key())
    except (Failure, OSError) as e:
        note(c, f"读不出手机上 S2Arm 的内容摘要，照常签名安装（{e}）")
        return False
    return not rc and out.strip().splitlines()[-1:] == [digest] if out else False


def ipa_key():
    import ipa as packer
    return packer.CONTAINER_DIGEST_KEY


def shell_outdated(c, rec, sid, games=None):
    """这台手机（设备记录 rec）上的 S2Arm 壳比本版旧时 → {from, to, games, stale}；不旧 / 没装过 → None。
    stale = 新壳认不得、要按新版重新出包的款（ipa.usable_kit 为 None：HOST_ABI 或直连链号变了）；游戏库里已删的款不列（组装时本来就不带）。
    games 缺省取记录里的各款（游戏库页检测用，不连手机）；update_phone 传手机上实际有的"""
    import ipa as packer
    games = sorted(games if games is not None else (rec.get("games") or {}))
    if not games or not rec.get("shellId") or rec.get("shellId") == sid:
        return None
    names = {g["id"].upper(): g.get("name") or g["id"] for g in c.catalog()["games"]}
    games = [g for g in games if g in names]
    stale = [g for g in games if packer.usable_kit(c, g, sid, rec.get("failedShells", [])) is None]
    return dict(fromShell=rec["shellId"], toShell=sid, games=[dict(gameId=g, name=names[g]) for g in games],
                stale=[dict(gameId=g, name=names[g]) for g in stale]) if games else None


def phone_updates(c):
    """游戏库页右上角「更新 iPhone 上的 S2Arm」：各台手机的设备记录里，壳比本版旧的 → [{device, name, fromShell, toShell, games, stale}]。
    只读本机记录（不连手机、不跑出包），catalog 每次带上；没有装过 iPhone 的玩家不算壳号"""
    recs = [(k, r) for k, r in layout.devices(c) if isinstance(r, dict) and r.get("games") and r.get("shellId")]
    if not recs:
        return []
    import ipa as packer
    sid = packer.current_shell_id(c)
    out = []
    import rewrite_refresh
    for key, rec in recs:
        st = shell_outdated(c, rec, sid)
        # 运行时留下、已收回游戏库还没补进 iPhone 件的 NRO（#8be819）：壳是本版也要更新（只推程序），按钮亮、启动器自动发起（kept 列这几款）
        kept = [g for g in rec.get("games") or [] if isinstance(g, str) and rewrite_refresh.kept_todo(c, g, layout.ios_kit(c, g))]
        if st or kept:
            if not st:
                names = {g["id"].upper(): g.get("name") or g["id"] for g in c.catalog()["games"]}
                st = dict(fromShell=rec["shellId"], toShell=sid, games=[dict(gameId=g, name=names.get(g, g)) for g in sorted(rec.get("games") or {})], stale=[])
            out.append(dict(device=key, name=(rec.get("signed") or {}).get("device") or "", **st, kept=[dict(gameId=g, name=g) for g in kept]))
    return out


PLAYING_WINDOW_S = 45   # 游玩时间心跳：游戏在前台时每 10 秒写一次 playtime.json（runtime/src/playtime.c，平台壳 10 秒定时器）；最近 45 秒内写过 = 正在玩


def playing_by_heartbeat(client, games, work, now=None):
    """手机上各款的游玩时间心跳（<容器>/Documents/games/<程序号>/playtime.json 的 lastPlayed，手机写入时的时刻）：
    任一款在 PLAYING_WINDOW_S 秒内写过 → True（正在玩，装 App 会杀掉这局）；都没有 / 文件不在（没玩过）→ False；
    一个都读不了（锁屏、断开）→ None（查不清）。Windows 没有 devicectl 查进程，靠它判（11-16 定的判据）"""
    import time as _t
    now = _t.time() if now is None else now
    got_any, stale = False, True
    for g in games:
        dst = Path(work) / f"playtime-{g}.json"
        try:
            ok = client.get(f"{game_docs(g)}/playtime.json", str(dst), 20)
        except Exception as e:   # 进不了容器（锁屏 / 断开 / 没装）：这一款查不清
            print(f"[s2a] 读 {g} 的游玩心跳失败：{e}", file=sys.stderr)
            continue
        got_any = True
        if not ok:
            continue   # 文件不在：这款没玩过，不算在玩
        try:
            last = int(json.loads(dst.read_text(encoding="utf-8")).get("lastPlayed") or 0)
        except (OSError, ValueError, TypeError):
            continue
        if now - last < PLAYING_WINDOW_S:
            return True
    return False if got_any or not games else None


def phone_kept_pull(c):
    """「手机插着、启动器开着」时启动器隔一阵调一次（phoneKeptPull 作业）：连着的那台手机上，宿主留下的 NRO（#8be819）拉回游戏库。
    → {device, new: 新收的个数, kept: 还没补进 iPhone 件的款, shellUpdate: 壳比本版旧且不用问玩家, stale: 壳旧了但要重出包的款,
       running: 手机上 S2Arm 正在跑或查不清（有要更新的才查）}；(kept 或 shellUpdate) 且 running 为假时启动器自动发起「更新 iPhone」
    只推程序（正在玩就不推：装 App 会杀掉这局，等它退了下一轮再推）。没连手机 / 没装过 = new 0、不报错"""
    try:
        ph = phone_for(c)
    except Failure as e:
        if e.code == "device_required" and not (c.r.get("device") or "").strip():
            return _kept_pull_many(c)
        return _kept_pull_none()
    return _kept_pull_on(c, ph)


def _kept_pull_none():   # 没连手机 / 都问不到：每次一份新的（列表不共用）
    return dict(device="", new=0, kept=[], shellUpdate=False, stale=[], running=False)


def _kept_pull_many(c):
    """多台手机同时连着、请求没说哪台（phone_for 报 device_required）：按游戏库里有设备记录的逐台问
    （11-16 候选验收：Mac 插着两部 iPhone，启动器的 2 分钟循环每次都拿到 device=""，自动更新永远不触发）。
    带上设备号建手机对象，认到的不是这台就跳过（这台没连着时选机会退到唯一连着的那台，那不是这条记录）；
    有事要做（收回了 NRO / 有没补进的款 / 壳要更新）且没在玩的那台先返回，其次是有事但在玩的；都没事返回第一台问到的；一台都问不到 → 空结果。
    启动器每轮只装返回的那台，下一轮再问时它已经是新版，就轮到下一台。请求里的 device 问完还原"""
    had, old = "device" in c.r, c.r.get("device")
    busy = idle = None
    try:
        for key, _ in layout.devices(c):
            c.r["device"] = key
            try:
                ph = phone_for(c)
            except Failure:
                continue
            if ph.key != key:
                continue
            r = _kept_pull_on(c, ph)
            if r["new"] or r["kept"] or r["shellUpdate"]:
                if not r["running"]:
                    return r
                busy = busy or r
            idle = idle or r
    finally:
        if had:
            c.r["device"] = old
        else:
            c.r.pop("device", None)
    return busy or idle or _kept_pull_none()


def _kept_pull_on(c, ph):
    rec = layout.load_device(c, ph.key)
    games = [g for g in rec.get("games") or [] if isinstance(g, str)]
    # 只和真冲突互斥（维护者「只按真冲突互斥」）：同一台手机上的装机 / 推包 / 续签（ipa.phone_lock）。手机在用就这一轮不收、下一轮再来；
    #   别的作业（出包、升级首启的程序件迁移……）照跑——原先前端「有任何作业在跑就整轮跳过」，升级首启迁移几分钟，拉回拖到第 360 秒（11-16 候选验收）。
    #   同一款程序件的迁移 / 现建由 programs-migrate 锁串行（ios_kit 里），收件写 nro_kept 是临时文件 + 改名（keep_nros），读的一方不会读到半个
    with c.idle("phone") as free:
        if not free:
            return _kept_pull_none()
        new = ph.pull_kept(games)
    import rewrite_refresh
    kept = [g for g in games if rewrite_refresh.kept_todo(c, g, layout.ios_kit(c, g))]   # 没补进的款（手动按钮兜底同 phone_updates）
    # 这台手机上的 S2Arm 壳比本版旧（启动器升级了）：shellUpdate = 可以不问玩家直接更新（没有要按新版重新出包的款）；
    #   有要重出的款 → shellUpdate 为假、stale 列出来，留给游戏库顶栏「更新 iPhone」按钮问（11-16 启动器升级顺带更新 iPhone App）
    import ipa as packer
    st = shell_outdated(c, rec, packer.current_shell_id(c))
    stale = [s["gameId"] for s in (st or {}).get("stale", [])]
    shell_update = bool(st) and not stale
    running = False
    if kept or shell_update:
        running = ph.app_running()
        if running is None and hasattr(ph, "playing"):   # 查不了进程（Windows）：按游玩时间心跳判
            running = ph.playing(games)
        running = running is not False
    return dict(device=ph.key, new=new, kept=kept, shellUpdate=shell_update, stale=stale, running=running)


def online_devices(c):
    """现在连着的设备号（Windows 设备服务里 USB 或同网的都算）；Mac / 读不到 → 空集（不影响更新本身，只少一句说明）"""
    if os.name != "nt":
        return set()
    try:
        return {u for u, _, _ in win_install_mod(c).mux_devices() if u}
    except OSError:
        return set()


def other_device_current(c, want):
    """#900：「更新手机上的 S2Arm」要找的那台（壳旧了的设备记录）不在线，而现在连着的另一台已经是本版壳 → 说清是两台、连着的这台不用更新；
    否则 None（照原来的「不在线」说）。玩家从游戏库推送时连着的那台已顺带换上新壳，更新按钮指的是游戏库里另一台旧设备的记录"""
    import ipa as packer
    if not want:
        return None
    online = online_devices(c)
    sid = packer.current_shell_id(c)
    fresh = [k for k, r in layout.devices(c) if k != want and k in online and isinstance(r, dict) and r.get("shellId") == sid]
    if not fresh:
        return None
    return (f"要更新的是另一台设备（编号末尾 {want[-6:]}），它现在不在线；现在连着的这台（编号末尾 {fresh[0][-6:]}）已经是新版 S2Arm，不用更新。"
            f"那台以后要用时连上它再点更新；不再用了的话，删掉游戏库文件夹 devices 里名字以 {want[-6:]} 结尾的那个文件，这个更新提醒就不再出现。")


def update_prepare(c):
    """「更新 iPhone 上的 S2Arm」的电脑侧准备，不连手机（新版启动器首次启动时后台调，接着手机连上再走 installUpdate 装机）：
    各台手机记录里、游戏库里还在的款，按本引擎核一遍 iPhone 程序（改写产物）、补可读瓦片版着色器（rewrite_refresh.refresh_ios，结果记进各款 game.json）。
    之后装机时 refresh_ios 认出已是本版、直接跳过，装机只剩组容器、签名、装。
    和出包并发安全：每款单独拿这款的程序件锁（ipa.program_locks），做完就放，不长时间挡住那款的出包交付；本进程降优先级（子进程跟着），让出包和游戏先跑。
    → {prepared: 准备了哪几款, updated: 其中实际改了的}"""
    import ipa as packer
    from rewrite_refresh import refresh_ios
    try:
        os.nice(10)   # Windows 没有 os.nice：照常优先级
    except (AttributeError, OSError):
        pass
    have = {g["id"].upper() for g in c.catalog()["games"]}
    games = sorted({str(g).upper() for _, rec in layout.devices(c) if isinstance(rec, dict) for g in (rec.get("games") or {}) if str(g).upper() in have})
    c.begin("准备更新 iPhone 上的 S2Arm", 1, 1)
    updated = []
    done = []
    for g in games:
        # 前台装机类作业在跑（拿着手机锁）：不再拿程序锁跟它抢（11-17 #1450：后台降到最低优先级，前台排在它后面就是倒置）——停下，剩下的前台自己做
        with c.idle("phone") as free:
            pass
        if not free:
            trace(c, "前台装机作业在跑：准备更新先停，剩下的由它按正常优先级做")
            break
        with packer.program_locks(c, [g]):
            updated += refresh_ios(c, [g])
        done.append(g)
    return dict(prepared=done, updated=sorted(set(updated)))


def update_phone(c):
    """「更新 iPhone 上的 S2Arm」：用本版壳 + 手机上各款已有的程序模块组新容器 → 签名 → 只装 App；资源包（IMG）、直连库只推变了的（通常一个都不推），
    手机上的游戏库、存档不动。新壳认不得的款（要按新版重新出包）：没带 acceptStale 就停下报 container_stale 列出它们，玩家确认后不带它们装
    （它们的资源包和存档还在手机上，重新出包后再装就回来）。壳已是本版 → 不装，结果 updated = False"""
    with packer_phone_lock(c):   # 装机类作业一次一个（ipa.phone_lock）
        return _update_phone(c)


def _update_phone(c):
    import ipa as packer
    if wants_export(c):   # 「导出新版 S2Arm」：本版壳带上游戏库里能带的各款出到文件夹，玩家自己覆盖安装
        return dict(export_phone(c), updated=True)
    c.begin("找签名账号与 iPhone", 1, 6)
    try:
        ph = phone_for(c)
    except Failure as e:
        hint = e.code == "device_not_connected" and other_device_current(c, c.r.get("device") or "")
        if hint:
            raise Failure(hint, code="device_not_connected") from e
        raise
    import program_pack
    if program_pack.enabled(c):   # 通用壳（0.6.0，缺省关）：「更新 S2Arm」只装壳，不碰各款
        return install_shell(c, ph)
    trace(c, "认出手机：" + str(ph.info.get("deviceKind") or "") + "；读手机上有哪几款…")   # 11-17 #1450 第 5 次卡在第 1 步：分步记，下次分得出卡在哪  # 非玩家句
    rec = layout.load_device(c, ph.key)
    others = container_others(c, ph, rec)
    trace(c, f"手机上有 {len(others)} 款；核壳新旧…")
    sid = packer.current_shell_id(c)
    st = shell_outdated(c, rec, sid, others)
    trace(c, "收回手机上留下的 NRO…")
    ph.pull_kept(others)   # 机上留下的 NRO（#8be819）先收回：有新的就照样重组容器补上（sgrade_pending 认）
    trace(c, "核要不要补 S 级优化…")
    if st is None and (c.r.get("sgradeUpgrade") is True or sgrade_pending(c, others)):
        # 壳已是本版、但有款要补 S 级优化（「S 级优化升级」页；补丁库更新了 / 电脑上导入了要改游戏代码的金手指，11-14）：照样重组容器，
        #   游戏程序在 put_game → refresh_ios 里补上，资源包照旧不推。Windows「更新 iPhone 上的 S2Arm」同走这里
        st = dict(stale=[], fromShell=sid)
    if st is None:
        return dict(updated=False, bundleId=ph.bid, games=others, **ph.info)
    stale = [s["gameId"] for s in st["stale"]]
    agreed = set((rec.get("staleAgreed") or {}).get(sid) or [])   # #479：这一版壳上同意过不带的，不再问
    if any(g not in agreed for g in stale) and c.r.get("acceptStale") is not True:
        raise Failure("这几款要按新版重新出包，更新后在重新出包之前暂时打不开：" + "、".join(s["name"] for s in st["stale"]) + "。确认更新再点一次。",  # 非玩家句
                      code="container_stale", internal=" ".join(stale))
    keep = [g for g in others if g not in stale]
    if not keep:   # 每一款都要重出：换壳后容器里一款都没有——宿主 0 款的启动路径没在真机验过（同 remove_from_phone 不装空容器），物理上做不了，照旧停
        raise Failure("手机上的游戏都要按新版重新出包，这次没法只更新 S2Arm（更新后一款都打不开）。可以先给它们各「打 iPhone 包」，再点「装到 iPhone」，"
                      "游戏和 S2Arm 会一起换成新版；存档和资源都留在手机上。「只更新 S2Arm、暂不带游戏」下一版开放。", code="container_stale", internal=" ".join(stale))
    r = put_game(c, None, ph, others=keep, skipped=stale)
    return dict(r, updated=True, fromShell=st["fromShell"], toShell=sid, skipped=stale)


def install(c):
    """默认「装到 iPhone」：这款进容器（一个 App 装下整个游戏库，免费账号也只占 1 个 App 额度）。加款 = 同一个包名覆盖安装，Documents 保留"""
    with packer_phone_lock(c):   # 装机类作业一次一个（ipa.phone_lock）
        return _install(c)


def _install(c):
    gid = c.r.get("gameId") or ""
    import downstream
    scheme = downstream.requested(c, dict(id=gid))   # 下游深度方案出的是独立 App：自己的包名，不进容器（pack/jobs/downstream.py）
    if scheme:
        if wants_export(c):   # 导出自签包只组 S2Arm 容器；独立 App 的资源靠推送进去，玩家自签装上也拿不到资源——说清楚，不悄悄改成连手机装机
            raise Failure(f"这款用的是 {scheme['name']} 方案（独立 App），现在只能「装到 iPhone」，还不能导出自签包。", code="downstream_export_unsupported")
        return downstream.install_ios(c, next((g for g in c.catalog()["games"] if g["id"].upper() == gid.upper()), dict(id=gid)), scheme)
    ios_pack(c, gid)
    if wants_export(c):   # 这次是「导出自签包」：不连手机、不签名，出到文件夹；推不推到手机由玩家在完成页选（exportPush）
        return export_phone(c, gid)
    c.begin("找签名账号与 iPhone", 1, 6)
    import program_pack
    if program_pack.enabled(c):   # 通用壳（0.6.0，缺省关）：「推到 iPhone」只推这一款，不装壳
        return push_game(c, gid, phone_for(c))
    return put_game(c, gid, phone_for(c))


def restore_previous(c):
    """装回换壳前的那一版手机 S2Arm（默认位置根 S2Arm.previous.ipa）：新运行层在手机上不好用时的回滚。
    装上后现行与上一版对调（再点一次 = 换回来）；被换下的壳号记进这台的 failedShells，之后给这台装机不再把旧款只换宿主带进它（要按新版重出）。
    手机上的资源包和存档不动；换宿主之后才新装的游戏不在上一版里，App 里暂时看不到（数据还在）"""
    with packer_phone_lock(c):   # 装机类作业一次一个（ipa.phone_lock）
        return _restore_previous(c)


def _restore_previous(c):
    import ipa as packer
    current, previous = layout.phone_ipa(c), layout.phone_ipa(c, previous=True)
    games, old_sid = packer.ipa_games(previous)
    _, dropped = packer.ipa_games(current)
    if not games:
        raise Failure("没有可以装回的上一版手机 S2Arm。", code="job_failed")
    c.begin("找签名账号与 iPhone", 1, 3)
    ph = phone_for(c)
    c.begin("装回上一版 S2Arm", 2, 3)
    ph.install(previous, games, steps=False)
    c.begin("记下手机上现在的版本", 3, 3)
    tmp = current.with_name(current.name + ".swap")
    if current.is_file():
        os.replace(current, tmp)
    os.replace(previous, current)
    if tmp.is_file():
        os.replace(tmp, previous)
    rec = layout.load_device(c, ph.key)
    failed = sorted((set(rec.get("failedShells", [])) | ({dropped} if dropped else set())) - {old_sid})   # 装回的这一版不算「不好用」：连点两次 = 换回来，那一版照常能只换宿主
    layout.save_device(c, ph.key, dict(rec, games={g: rec["games"].get(g) or {} for g in games}, shellId=old_sid, failedShells=failed, bundleId=ph.bid or rec.get("bundleId", "")))
    return dict(games=games, bundleId=ph.bid, restoredShell=old_sid, **ph.info)


def remove_from_phone(c):
    """从手机上的 S2Arm 里删一款：备份本款存档 → 用剩下各款现组容器 → 覆盖装 → 删机上本款文档根。
    剩下的款有新运行层认不得的（升级后还没重出）：退回从 S2Arm.ipa 里摘掉这款（pack/ship_ext.py container-drop，其余各款逐字节不变、不换壳）。
    装上之后才改设备记录（装失败时两边还一致）；机上目录没删掉只报黄字（App 里这款已经没了，占的空间下次再清）"""
    with packer_phone_lock(c):   # 装机类作业一次一个（ipa.phone_lock）
        return _remove_from_phone(c)


def _remove_from_phone(c):
    import ipa as packer
    gid = (c.r.get("gameId") or "").upper()
    c.begin("找签名账号与 iPhone", 1, 4)
    ph = phone_for(c)
    rec = layout.load_device(c, ph.key)
    # 包名：这台记过的；没记过（Windows 第一次在这台电脑上操作）按当前账号算（预检清单 #36：原先没记就不让删）。真算不出才停——不知道动的是哪个 App
    ph.bid = phone_bid(ph)
    if not ph.bid:
        raise Failure("定不出手机上 S2Arm 的包名（这台电脑没装过、也读不到当前签名账号）：在这台电脑上装一次任意游戏后再删。", code="job_failed")
    if gid not in rec.get("games", {}):
        # 本机记录里没有这款（别的电脑装的）：真相在手机上（预检清单 #35：原先只看本机记录就说「没有这款」）
        on_phone = phone_games(c, ph)
        if on_phone is not None and on_phone and gid not in on_phone:
            note(c, f"手机上的 S2Arm 里本来就没有 {gid}，不用删")
            return dict(games=sorted(on_phone), bundleId=ph.bid, removed=gid, saveBackup="", dataRemoved=True, alreadyAbsent=True, **ph.info)
        if on_phone is None:
            note(c, f"手机上没装这个 S2Arm，{gid} 不在手机上，不用删")
            return dict(games=[], bundleId=ph.bid, removed=gid, saveBackup="", dataRemoved=True, alreadyAbsent=True, **ph.info)
    c.begin("备份这款的存档", 2, 4)
    backup = ph.backup(gid)
    c.begin("更新手机上的 S2Arm", 3, 4)
    left = container_others(c, ph, rec, leave=gid)   # 同装机：手机上另一台电脑装的款也带上，带不了的先问
    # 最后一款（#227）：不装空容器（宿主 0 款的启动路径没在真机验过，vawin.c 报红不占窗口），手机上的 App 原样留着，
    #   下一步删掉它的数据后库界面按「数据不在」不再显示 = 空库；下次装新游戏时覆盖装把旧程序一起换掉
    if left:
        try:
            with packer.program_locks(c, left):
                ipa, left, sid = packer.assemble(c, None, left, failed=rec.get("failedShells", []))
        except Failure as e:
            if e.code != "container_stale":
                raise
            ipa, left, sid = packer.drop_from_ipa(c, layout.phone_ipa(c), gid)
        ph.install(ipa, left, steps=False)
        packer.commit_phone_ipa(c, ipa, sid)
    rec = layout.load_device(c, ph.key)
    layout.save_device(c, ph.key, dict(rec, games={g: rec["games"].get(g) or {} for g in left}))
    c.begin("删除手机上这款的数据", 4, 4)
    ok, out = ph.purge(gid)
    if not ok:
        c.diagnostic("App 里这款已经删了，但手机上它的数据没删掉：" + out[-200:], code="container_purge_failed", severity="warning")
    return dict(games=left, bundleId=ph.bid, removed=gid, saveBackup=str(backup) if backup else "", dataRemoved=ok, **ph.info)
