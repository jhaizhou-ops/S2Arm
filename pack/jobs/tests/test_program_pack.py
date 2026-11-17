"""通用壳程序包（pack/jobs/program_pack.py、pack/ship_ext.py program、pack/orch/install_win.py sign_dylibs、tools/push_pack.py Devpush.mv）。
期望值不靠被测代码算：
  ① build：出的 dylib 与直接跑 ship_ext.py program 的逐字节相同；第二次键没变不重出（目录修改时间不变）；程序件里一个文件变了就重出
  ② sign：假签名器收到的团队 / 包名就是给的；catalogue.json 字段按约定手写，image_sha256 = 本测试对签好的文件算的 SHA-256；同团队同包名第二次不再签
  ③ need：六种原因各一例 + 都对得上 = 空集
  ④ sign_dylibs：假 plumesign 收到 --custom-identifier <包名>、没有 --register-and-install；小 IPA 里没有 PlugIns/；签好的 dylib 原地换回
  ⑤ Devpush.mv：假工具收到「mv <源> <目标>」
  ⑥ 开关（第 2 段）：缺省关；S2A_UNIVERSAL_SHELL=1 开、=0 关、别的值按缺省
  ⑦ 签名器按模式选：开发者证书 → rcodesign 读 p12 只签这个 dylib（不带 -e 权限、不嵌描述文件）；否则 Mac → dev_sign --dylib
  ⑧ install.push_program（写入规则 11-17 定稿）：手写的调用顺序（版本目录 v-<sha16>-pc/ 下 dylib → Games 各文件 → catalogue.json.pc.tmp → 改名覆盖 catalogue.json），
     清单带 dir；换上后只删换上前清单指着的旧版本目录（没有旧清单 / 指的就是这次的 → 不删）；续推时机上已完整（长度 + 开头一页对）的文件跳过；改名失败报红
  ⑨ install.push_programs：设备记录与要推的包对得上 → 不推、记录原样；没推过 → 推、记录换成这次的
"""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import stat
import struct
import subprocess
import sys
import tempfile
import unittest
import zipfile

from jobcase import JobCase, ROOT
import program_pack

sys.path.insert(0, str(ROOT))
from pack.shell import manifest as shell_manifest   # noqa: E402

GID = "0100000000010000"
INFO = dict(host_abi=7, chain="abcdef012345", rewriter_id="rw01")


def make_shell(d):
    r = Path(d) / "shell/root"; r.mkdir(parents=True)
    (r / "Info.plist").write_bytes(plistlib.dumps({"CFBundleExecutable": "S2Arm", "CFBundleIdentifier": "dev.s2arm.shell", "CFBundlePackageType": "APPL", "CFBundleName": "S2Arm"}))
    (r / "S2Arm").write_bytes(b"\xcf\xfa\xed\xfe" + bytes(60))
    (r / "Frameworks").mkdir(); (r / "PlugIns/W.appex").mkdir(parents=True); (r / "PlugIns/W.appex/W").write_bytes(b"x")
    (r / "S2AShell.tables").write_text("addr_need.tsv\n")
    shell_manifest.seal(r, Path(d) / "shell/manifest.json", *shell_manifest._defaults())
    return Path(d) / "shell"


def make_kit(d):
    k = Path(d) / "kit"; k.mkdir(parents=True)
    (k / "main.patched.bin").write_bytes(bytes((i * 7) & 0xFF for i in range(0xD000)))
    (k / "main.fixups.tsv").write_text("# TEXT_END 0x5000\n# PATCH_OFF 0xc000\n# KEY_PAGE_OFF 0x8000\n# KEY_PAGE_SIZE 0x4000\n")
    (k / "main.gates.tsv").write_text("g\n")
    b = bytearray(0x80 + 0x38); b[0:4] = b"META"; b[0x0C] = 3 << 1
    struct.pack_into("<I", b, 0x70, 0x80); b[0x80:0x84] = b"ACI0"; struct.pack_into("<Q", b, 0x90, int(GID, 16))
    (k / "main.npdm").write_bytes(bytes(b)); (k / "addr_need.tsv").write_text("a\n"); (k / "icon.jpg").write_bytes(b"JPGicon")
    nacp = bytearray(0x4000); t = "甲游戏".encode(); nacp[14 * 0x300:14 * 0x300 + len(t)] = t; nacp[0x3060:0x3065] = b"1.2.0"
    (k / "ctl").mkdir(); (k / "ctl/control.nacp").write_bytes(bytes(nacp))
    return k


def sha(p):
    return hashlib.sha256(Path(p).read_bytes()).hexdigest()


class ProgramPackTests(JobCase):
    def setUp(self):
        super().setUp()
        self.shell = make_shell(self.root / "s"); self.kit = make_kit(self.root / "k")

    def build(self, banner=""):
        return program_pack.build(self.c, GID, kit=self.kit, shell=self.shell, info=INFO, banner=banner)

    def test_banner_goes_into_package_and_key(self):
        b = self.root / "banner.jpg"; b.write_bytes(b"JPGbanner")
        pkg = self.build(banner=b)
        self.assertEqual((pkg / "Games" / GID / "banner.jpg").read_bytes(), b"JPGbanner")
        out = program_pack.sign(self.c, GID, "T", "io.b", lambda d, t, bd: None, pkg=pkg)
        self.assertEqual(json.loads((out / "catalogue.json").read_text(encoding="utf-8"))["banner"], f"Games/{GID}/banner.jpg")
        t0 = (pkg / "meta.json").stat().st_mtime_ns
        b.write_bytes(b"JPGbanner2"); self.build(banner=b)
        self.assertNotEqual((pkg / "meta.json").stat().st_mtime_ns, t0, "横图换了要重出")

    def test_build_matches_ship_ext_and_caches(self):
        pkg = self.build()
        ref = self.root / "ref/program"
        subprocess.run([sys.executable, str(ROOT / "pack/ship_ext.py"), "program", "--shell", str(self.shell), "--root", str(self.kit), "--out", str(ref)], check=True, capture_output=True)
        self.assertEqual((pkg / f"S2AImages-{GID}.dylib").read_bytes(), (ref / f"S2AImages-{GID}.dylib").read_bytes())
        meta = json.loads((pkg / "meta.json").read_text(encoding="utf-8"))
        self.assertEqual((meta["host_abi"], meta["chain"], meta["rewriter_id"], meta["name"], meta["display_version"]), (7, "abcdef012345", "rw01", "甲游戏", "1.2.0"))
        t0 = (pkg / "meta.json").stat().st_mtime_ns
        self.assertEqual(self.build(), pkg); self.assertEqual((pkg / "meta.json").stat().st_mtime_ns, t0, "键没变不重出")
        (self.kit / "addr_need.tsv").write_text("b\n")
        self.build(); self.assertNotEqual((pkg / "meta.json").stat().st_mtime_ns, t0, "程序件变了要重出")

    def test_sign_writes_catalogue_and_caches_per_team(self):
        pkg = self.build(); calls = []
        def signer(dylib, team, bundle):
            calls.append((Path(dylib).name, team, bundle)); Path(dylib).write_bytes(Path(dylib).read_bytes() + team.encode())
        out = program_pack.sign(self.c, GID, "TEAMA", "io.example.games", signer, pkg=pkg)
        self.assertEqual(calls, [(f"S2AImages-{GID}.dylib", "TEAMA", "io.example.games")])
        cat = json.loads((out / "catalogue.json").read_text(encoding="utf-8"))
        want = dict(schema=1, title_id=GID, name="甲游戏", display_version="1.2.0", host_abi=7, chain="abcdef012345", rewriter_id="rw01",
                    image=f"S2AImages-{GID}.dylib", image_sha256=sha(out / f"S2AImages-{GID}.dylib"), team="TEAMA", icon=f"Games/{GID}/icon.jpg")
        self.assertEqual(cat, want)
        self.assertEqual(sorted(p.name for p in out.iterdir() if not p.name.startswith(".")), ["Games", f"S2AImages-{GID}.dylib", "catalogue.json"])
        program_pack.sign(self.c, GID, "TEAMA", "io.example.games", signer, pkg=pkg); self.assertEqual(len(calls), 1, "同团队同包名不再签")
        program_pack.sign(self.c, GID, "TEAMB", "io.example.games", signer, pkg=pkg); self.assertEqual(len(calls), 2, "换团队要重签")

    def test_need_reasons(self):
        want = dict(host_abi=7, rewriter_id="rw01", image_sha256="s1")
        ok = dict(sha="s1", team="T", cert="C", host_abi=7, rewriter_id="rw01")
        N = lambda phone, team="T", cert="C": program_pack.need(self.c, GID, phone, team, cert, want=want)
        self.assertEqual(N(None), {"missing"})
        self.assertEqual(N(ok), set())
        self.assertEqual(N(dict(ok, host_abi=6)), {"abi"})
        self.assertEqual(N(dict(ok, rewriter_id="rw00")), {"rewriter"})
        self.assertEqual(N(dict(ok, sha="s0")), {"sha"})
        self.assertEqual(N(ok, team="U"), {"team"})
        self.assertEqual(N(ok, cert="D"), {"cert"})


class SignDylibsTests(unittest.TestCase):
    def test_custom_identifier_no_register_no_plugins(self):
        with tempfile.TemporaryDirectory() as d:
            d = Path(d); shell = make_shell(d) / "root"
            dy = d / f"S2AImages-{GID}.dylib"; dy.write_bytes(b"UNSIGNED")
            argv, seen = d / "argv.json", d / "seen.json"
            fake = d / "plumesign"
            fake.write_text(f"""#!{sys.executable}
import json, sys, zipfile
a = sys.argv[1:]; json.dump(a, open({str(argv)!r}, "w"))
src, out = a[a.index("--package") + 1], a[a.index("-o") + 1]
with zipfile.ZipFile(src) as zi, zipfile.ZipFile(out, "w") as zo:
    json.dump(zi.namelist(), open({str(seen)!r}, "w"))
    for n in zi.namelist(): zo.writestr(n, zi.read(n) + (b"+SIGNED" if n.endswith(".dylib") else b""))
""")
            fake.chmod(fake.stat().st_mode | stat.S_IEXEC)
            sys.path.insert(0, str(ROOT))
            from pack.orch import install_win
            install_win.sign_dylibs(str(fake), shell, [dy], "io.example.games.team", d / "sign.log")
            a = json.loads(argv.read_text())
            self.assertIn("--custom-identifier", a); self.assertEqual(a[a.index("--custom-identifier") + 1], "io.example.games.team")
            self.assertNotIn("--register-and-install", a)
            names = json.loads(seen.read_text())
            self.assertIn(f"Payload/S2Arm.app/Frameworks/S2AImages-{GID}.dylib", names)
            self.assertFalse(any("/PlugIns/" in n for n in names), "小 IPA 不带小组件扩展")
            self.assertEqual(dy.read_bytes(), b"UNSIGNED+SIGNED")


class DevpushMvTests(unittest.TestCase):
    def test_mv_calls_tool(self):
        with tempfile.TemporaryDirectory() as d:
            d = Path(d); rec = d / "argv.json"; fake = d / "devpush"
            fake.write_text(f"#!{sys.executable}\nimport json, sys\njson.dump(sys.argv[1:], open({str(rec)!r}, 'w'))\nprint('mv ok')\n")
            fake.chmod(fake.stat().st_mode | stat.S_IEXEC)
            sys.path.insert(0, str(ROOT / "tools"))
            import push_pack
            dp = push_pack.Devpush(str(fake), "UDID", "io.example", d)
            ok, _ = dp.mv("Library/x/catalogue.json.tmp", "Library/x/catalogue.json")
            self.assertTrue(ok)
            self.assertEqual(json.loads(rec.read_text())[-3:], ["mv", "Library/x/catalogue.json.tmp", "Library/x/catalogue.json"])


class SwitchAndSignerTests(JobCase):
    def test_switch_default_off(self):
        self.assertFalse(program_pack.ON_BY_DEFAULT, "0.6.0 之前缺省关（维护者 11-17 定）")
        for v, want in (("", False), ("1", True), ("0", False), ("yes", False)):
            self.c.env = lambda v=v: dict(os.environ, S2A_UNIVERSAL_SHELL=v)
            self.assertEqual(program_pack.enabled(self.c), want, repr(v))

    def test_signer_by_mode(self):
        import devcert
        from unittest import mock
        dylib = self.root / "a.dylib"; dylib.write_bytes(b"x")
        runs = []
        self.c.run = lambda args, log=None, env=None, **k: runs.append([str(a) for a in args])
        with mock.patch.object(devcert, "active", lambda c: True), mock.patch.object(devcert, "stored", lambda c: (Path("/p/cert.p12"), b"prof", "pw")), \
             mock.patch.object(devcert, "rcodesign_path", lambda c: "/bin/rcodesign"), mock.patch.object(devcert, "folder", lambda c: self.root):
            program_pack.signer_for(self.c)(dylib, "TEAMA", "io.example.games")
        a = runs[-1]
        self.assertEqual(a[:4], ["/bin/rcodesign", "sign", "--p12-file", "/p/cert.p12"])
        self.assertEqual(a[a.index("--team-name") + 1], "TEAMA"); self.assertEqual(a[a.index("--timestamp-url") + 1], "none")
        self.assertEqual(a[-1], str(dylib)); self.assertNotIn("-e", a, "只签 dylib：不带权限")
        if os.name != "nt":
            with mock.patch.object(devcert, "active", lambda c: False):
                program_pack.signer_for(self.c)(dylib, "TEAMA", "io.example.games")
            self.assertEqual(runs[-1][1:], [str(Path(self.c.engine) / "pack/dev_sign.py"), "--dylib", str(dylib), "io.example.games", "TEAMA"])


class FakeClient:
    def __init__(self, mv_ok=True, have=None):
        self.calls, self.mv_ok, self.have, self.puts = [], mv_ok, dict(have or {}), {}
    def rm(self, rel):
        self.calls.append(("rm", rel)); return True, ""
    def head(self, rel, n):
        b = self.have.get(rel); return (-1, b"") if b is None else (len(b), b[:n])
    def get(self, rel, dst):
        self.calls.append(("get", rel)); b = self.have.get(rel)
        if b is None: return False
        Path(dst).write_bytes(b); return True
    def put(self, src, rel):
        self.calls.append(("put", Path(src).name, rel)); self.puts[rel] = Path(src).read_bytes()
    def mv(self, a, b):
        self.calls.append(("mv", a, b)); return self.mv_ok, "" if self.mv_ok else "afc error"


class PushProgramTests(JobCase):
    def setUp(self):
        super().setUp()
        import install
        self.install = install
        pkg = self.root / "pkg"; (pkg / "Games" / GID / "sub").mkdir(parents=True)
        (pkg / f"S2AImages-{GID}.dylib").write_bytes(b"dy" * 3000)
        (pkg / "Games" / GID / "main.npdm").write_bytes(b"n"); (pkg / "Games" / GID / "sub/t.tsv").write_text("t")
        (pkg / "catalogue.json").write_text(json.dumps(dict(image=f"S2AImages-{GID}.dylib", image_sha256="0123456789abcdef" + "f" * 48, team="T", host_abi=7, rewriter_id="rw")))
        self.pkg = pkg
        self.pr = f"Library/Application Support/S2Arm/games/{GID}/资源包"
        self.P = f"Library/Application Support/S2Arm/games/{GID}/program"
        self.V = f"{self.P}/v-0123456789abcdef-pc"

    def test_order(self):
        cl = FakeClient()
        got = self.install.push_program(cl, GID.lower(), self.pkg, self.pr)
        P, V = self.P, self.V
        self.assertEqual(cl.calls, [("put", f"S2AImages-{GID}.dylib", f"{V}/S2AImages-{GID}.dylib"),
                                    ("put", "main.npdm", f"{V}/Games/{GID}/main.npdm"), ("put", "t.tsv", f"{V}/Games/{GID}/sub/t.tsv"),
                                    ("get", f"{P}/catalogue.json"),
                                    ("put", "catalogue.json", f"{P}/catalogue.json.pc.tmp"), ("mv", f"{P}/catalogue.json.pc.tmp", f"{P}/catalogue.json")])   # 第一次推：没有旧清单，不删
        self.assertEqual(json.loads(cl.puts[f"{P}/catalogue.json.pc.tmp"])["dir"], "v-0123456789abcdef-pc")
        self.assertEqual(got, dict(sha="0123456789abcdef" + "f" * 48, team="T", host_abi=7, rewriter_id="rw", dir="v-0123456789abcdef-pc", look=self.install.look_of(None)))

    def test_resume_skips_complete_files(self):
        V = self.V
        cl = FakeClient(have={f"{V}/S2AImages-{GID}.dylib": b"dy" * 3000, f"{V}/Games/{GID}/main.npdm": b"x",
                              f"{V}/Games/{GID}/sub/t.tsv": b""})   # dylib 已完整；npdm 长度对、内容不对；t.tsv 写了一半
        self.install.push_program(cl, GID, self.pkg, self.pr)
        self.assertEqual([c[2] for c in cl.calls if c[0] == "put"], [f"{V}/Games/{GID}/main.npdm", f"{V}/Games/{GID}/sub/t.tsv", f"{self.P}/catalogue.json.pc.tmp"])

    def test_deletes_only_previous_pointed_dir(self):
        P = self.P
        cl = FakeClient(have={f"{P}/catalogue.json": json.dumps(dict(dir="v-aaaaaaaaaaaaaaaa-import")).encode()})
        self.install.push_program(cl, GID, self.pkg, self.pr)
        self.assertEqual([c for c in cl.calls if c[0] == "rm"], [("rm", f"{P}/v-aaaaaaaaaaaaaaaa-import")])
        self.assertEqual(cl.calls[-2][0], "mv", "先换上、再删旧的")
        cl = FakeClient(have={f"{P}/catalogue.json": json.dumps(dict(dir="v-0123456789abcdef-pc")).encode()})
        self.install.push_program(cl, GID, self.pkg, self.pr)
        self.assertEqual([c for c in cl.calls if c[0] == "rm"], [], "旧清单指的就是这次的目录：不删")
        cl = FakeClient(have={f"{P}/catalogue.json": json.dumps(dict(dir="v-aaaaaaaaaaaaaaaa-import")).encode()})
        self.install.push_program(cl, GID, self.pkg, self.pr, keep_old=True)
        self.assertEqual([c for c in cl.calls if c[0] == "rm"], [], "这款可能在运行（keep_old）：不删，留给 App 清")
        cl = FakeClient(have={f"{P}/catalogue.json": json.dumps(dict(dir="../资源包")).encode()})
        self.install.push_program(cl, GID, self.pkg, self.pr)
        self.assertEqual([c for c in cl.calls if c[0] == "rm"], [], "清单里不是版本目录名：不删")

    def test_custom_name_and_cover(self):
        # 只有壳的 App 不带各款条目：启动器里改的名字写进清单、封面盖到版本目录的 Games/<号>/icon.jpg（在随行文件之后、清单之前）
        cover = self.root / "my.jpg"; cover.write_bytes(b"JPGmine")
        cl = FakeClient()
        got = self.install.push_program(cl, GID, self.pkg, self.pr, custom=dict(custom=True, name="我的名字", cover=str(cover)))
        puts = [c for c in cl.calls if c[0] == "put"]
        self.assertEqual(puts[-2], ("put", "my.jpg", f"{self.V}/Games/{GID}/icon.jpg"))
        shown = json.loads(cl.puts[f"{self.P}/catalogue.json.pc.tmp"])
        self.assertEqual((shown["name"], shown["icon"]), ("我的名字", f"Games/{GID}/icon.jpg"))
        self.assertEqual(got["look"], self.install.look_of(dict(name="我的名字", cover=str(cover))))
        self.assertNotEqual(got["look"], self.install.look_of(None), "改了名字封面指纹要变")

    def test_look_change_triggers_push(self):
        import ipa
        from unittest import mock
        same = dict(sha="0123456789abcdef" + "f" * 48, team="T", host_abi=7, rewriter_id="rw", dir="v-0123456789abcdef-pc", look=self.install.look_of(None))
        with mock.patch.object(program_pack, "sign", lambda c, g, team, bundle, signer: self.pkg), \
             mock.patch.object(ipa, "container_custom", lambda c: {GID: dict(custom=True, name="新名字", cover="")}):
            cl = FakeClient()
            got = self.install.push_programs(self.c, cl, [GID], dict(games={GID: dict(program=same)}), "T", "io.b", None, {GID: self.pr})
        self.assertEqual(cl.calls[-1][0], "mv", "只改了名字：照推（程序文件续推会跳过）")
        self.assertEqual(json.loads(cl.puts[f"{self.P}/catalogue.json.pc.tmp"])["name"], "新名字")
        self.assertNotEqual(got[GID]["look"], same["look"])

    def test_mv_failure_raises(self):
        with self.assertRaises(self.install.Failure):
            self.install.push_program(FakeClient(mv_ok=False), GID, self.pkg, self.pr)

    def test_push_programs_skips_matching_record(self):
        from unittest import mock
        import ipa
        same = dict(sha="0123456789abcdef" + "f" * 48, team="T", host_abi=7, rewriter_id="rw", dir="v-0123456789abcdef-pc", look=self.install.look_of(None))
        with mock.patch.object(program_pack, "sign", lambda c, g, team, bundle, signer: self.pkg), mock.patch.object(ipa, "container_custom", lambda c: {}):
            cl = FakeClient()
            got = self.install.push_programs(self.c, cl, [GID], dict(games={GID: dict(program=same)}), "T", "io.b", None, {GID: self.pr})
            self.assertEqual((cl.calls, got), ([], {GID: same}), "对得上：一个文件都不推")
            cl = FakeClient()
            got = self.install.push_programs(self.c, cl, [GID], dict(games={}), "T", "io.b", None, {GID: self.pr})
            self.assertEqual(cl.calls[-1][0], "mv"); self.assertEqual(got, {GID: same}, "没推过：推了、记录换成这次的")


if __name__ == "__main__":
    unittest.main()
