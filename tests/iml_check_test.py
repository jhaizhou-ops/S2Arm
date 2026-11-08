#!/usr/bin/env python3
"""pack/iml_check.py 单测（合成数据，无真机 / 出包依赖）。

合成数据覆盖：
  - 带 / 缺 IML 的 plist
  - 含私有 JIT 键（com.apple.private.cs.debugger 等）的 plist
  - iOS 26 带 / 不带 IML 的窗口估算
  - iOS 17 带 IML 的窗口估算
  - iOS 27 带 / 不带 IML 的窗口估算
  - macOS（ios_ver=0）
  - 渠道推荐：AltStore Classic（应通过）、SideStore 0.7.0（应拒绝）
"""
from __future__ import annotations
import plistlib
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / "pack"))
import iml_check  # noqa: E402

fails = 0


def check(name: str, want, got) -> None:
    global fails
    ok = want == got
    fails += not ok
    print(f"{'✓' if ok else '✗'} {name}：期望 {want!r}，实 {got!r}")


def plist_bytes(**kv) -> bytes:
    """合成 plist（所有键值均为 bool True）。"""
    return plistlib.dumps(kv)


# ─── A. check_entitlements_plist ───────────────────────────────────────────

# A1 带 IML、无私有键 → ok
ok, missing, banned = iml_check.check_entitlements_plist(
    plist_bytes(**{"com.apple.developer.kernel.increased-memory-limit": True})
)
check("A1 带IML无私有键 ok=True", True, ok)
check("A1 missing=[]", [], missing)
check("A1 banned=[]", [], banned)

# A2 缺 IML → ok=False，missing=[IML_KEY]
ok, missing, banned = iml_check.check_entitlements_plist(
    plist_bytes(get_task_allow=True)
)
check("A2 缺IML ok=False", False, ok)
check("A2 missing=[IML_KEY]", [iml_check.IML_KEY], missing)
check("A2 banned=[]", [], banned)

# A3 含 com.apple.private.cs.debugger（TrollStore banned key）
ok, missing, banned = iml_check.check_entitlements_plist(
    plist_bytes(**{
        "com.apple.developer.kernel.increased-memory-limit": True,
        "com.apple.private.cs.debugger": True,
    })
)
check("A3 含debugger ok=False", False, ok)
check("A3 banned含debugger", True, "com.apple.private.cs.debugger" in banned)

# A4 含 dynamic-codesigning
ok, missing, banned = iml_check.check_entitlements_plist(
    plist_bytes(**{
        "com.apple.developer.kernel.increased-memory-limit": True,
        "dynamic-codesigning": True,
    })
)
check("A4 含dynamic-codesigning ok=False", False, ok)
check("A4 banned含dynamic-codesigning", True, "dynamic-codesigning" in banned)

# A5 含 allow-jit
ok, missing, banned = iml_check.check_entitlements_plist(
    plist_bytes(**{
        "com.apple.developer.kernel.increased-memory-limit": True,
        "com.apple.developer.kernel.allow-jit": True,
    })
)
check("A5 含allow-jit ok=False", False, ok)
check("A5 banned含allow-jit", True, "com.apple.developer.kernel.allow-jit" in banned)

# A6 缺 IML 且含 JIT 键 → 两个都报
ok, missing, banned = iml_check.check_entitlements_plist(
    plist_bytes(**{"com.apple.private.cs.debugger": True})
)
check("A6 缺IML+含debugger ok=False", False, ok)
check("A6 missing=[IML_KEY]", [iml_check.IML_KEY], missing)
check("A6 banned含debugger", True, len(banned) > 0)

# A7 损坏 bytes → 视为缺 IML
ok, missing, banned = iml_check.check_entitlements_plist(b"NOT_A_PLIST")
check("A7 损坏plist ok=False", False, ok)
check("A7 missing=[IML_KEY]", [iml_check.IML_KEY], missing)

# ─── B. window_gb ──────────────────────────────────────────────────────────

# B1 iOS 26 带 IML → 51 GiB（R02 xnu-12377）
check("B1 iOS26+IML=51", 51.0, iml_check.window_gb(26, True))

# B2 iOS 26 不带 IML → 5.375 GiB（DEVICE_LARGE）
check("B2 iOS26-IML=5.375", 5.375, iml_check.window_gb(26, False))

# B3 iOS 27 带 IML → 64 GiB（实测）
check("B3 iOS27+IML=64", 64.0, iml_check.window_gb(27, True))

# B4 iOS 27 不带 IML → 6 GiB（实测）
check("B4 iOS27-IML=6", 6.0, iml_check.window_gb(27, False))

# B5 iOS 17 带 IML → 51 GiB（xnu-10063+）
check("B5 iOS17+IML=51", 51.0, iml_check.window_gb(17, True))

# B6 iOS 18 带 IML → 51 GiB（xnu-11215）
check("B6 iOS18+IML=51", 51.0, iml_check.window_gb(18, True))

# B7 macOS（ios_ver=0）→ 0.0
check("B7 macOS=0", 0.0, iml_check.window_gb(0, True))
check("B7 macOS-IML=0", 0.0, iml_check.window_gb(0, False))

# B8 iOS 16 带 IML → 53 GiB（xnu-8796）
check("B8 iOS16+IML=53", 53.0, iml_check.window_gb(16, True))

# ─── C. window_hint ────────────────────────────────────────────────────────

# C1 iOS 26 带 IML，需求 50 GB → 提示「充足」，不含「超出」
h = iml_check.window_hint(26, True, 50.0)
check("C1 iOS26+IML need50 含'充足'", True, "充足" in h)
check("C1 不含'超出'", True, "超出" not in h)
check("C1 含'51'", True, "51" in h)

# C2 iOS 26 不带 IML，需求 50 GB → 提示「超出」+「建议用带 IML」
h = iml_check.window_hint(26, False, 50.0)
check("C2 iOS26-IML need50 含'超出'", True, "超出" in h)
check("C2 含'建议用带 IML'", True, "建议用带 IML" in h)
check("C2 含SideStore提示", True, "SideStore" in h)

# C3 iOS 27 带 IML，需求 50 GB → 64 GB，充足
h = iml_check.window_hint(27, True, 50.0)
check("C3 iOS27+IML need50 充足", True, "充足" in h)

# C4 need_gb=None → 不含「需约」
h = iml_check.window_hint(26, True, None)
check("C4 no need 不含'需约'", True, "需约" not in h)

# C5 macOS → 返回待实测
h = iml_check.window_hint(0, True, None)
check("C5 macOS 含'待实测'", True, "待实测" in h)

# ─── D. channel_ok ─────────────────────────────────────────────────────────

# D1 AltStore Classic → ok
ok, note = iml_check.channel_ok("altstore_classic")
check("D1 altstore_classic ok=True", True, ok)
check("D1 note含'AltStore Classic'", True, "AltStore Classic" in note)

# D2 SideStore 0.7.0 → 丢 IML
ok, note = iml_check.channel_ok("sidestore_0.7.0")
check("D2 sidestore_0.7.0 ok=False", False, ok)
check("D2 note含'丢失'", True, "丢" in note or "#1616" in note)

# D3 SideStore 0.7.0-alpha → 丢 IML
ok, note = iml_check.channel_ok("sidestore_0.7.0-alpha")
check("D3 sidestore_0.7.0-alpha ok=False", False, ok)

# D4 Xcode Personal Team → ok
ok, _ = iml_check.channel_ok("xcode_personal_team")
check("D4 xcode_personal_team ok=True", True, ok)

# D5 未知渠道 → 默认 ok=True，提示核实
ok, note = iml_check.channel_ok("unknown_signer_xyz")
check("D5 未知渠道 ok=True", True, ok)
check("D5 note含'核实'", True, "核实" in note)

# D6 TrollStore → ok=False（上界 iOS 17.0，不适用大众分发）
ok, note = iml_check.channel_ok("trollstore")
check("D6 trollstore ok=False", False, ok)

# D7 空格形式等价
ok1, _ = iml_check.channel_ok("AltStore Classic")
ok2, _ = iml_check.channel_ok("altstore_classic")
check("D7 空格与下划线等价", ok1, ok2)

# ─── 汇总 ──────────────────────────────────────────────────────────────────
print(f"{'✓' if not fails else '✗'} iml_check_test：{fails} 处不符")
sys.exit(1 if fails else 0)
