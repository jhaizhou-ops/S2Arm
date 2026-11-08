"""装到 iPhone（pack/jobs/install.py，10-26）：选团队、包名、报错分类、整条流程（签名 / 装机 / 拷资源包打桩，IPA 夹具用 ditto 真解）。期望按规则手写"""
import json, os, plistlib, sys, tempfile, unittest, zipfile
import unittest.mock as um
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import install
from core import Failure
import tests.test_jobs as tj   # 只借 JobsTests 的夹具；不 from-import 类名，免得 unittest 把它整组再跑一遍


class PickTests(unittest.TestCase):
    def test_team_choice_and_bundle_id(self):
        free = dict(id="Z6563UVHKK", name="个人", free=True); paid = dict(id="D9G8MY5FB5", name="付费", free=False)
        self.assertEqual(install.pick_team([free, paid])["id"], "D9G8MY5FB5")   # 有付费团队用付费的
        self.assertEqual(install.pick_team([free])["id"], "Z6563UVHKK")          # 只有免费的用免费的
        self.assertEqual(install.pick_team([free, paid], "Z6563UVHKK")["id"], "Z6563UVHKK")
        with self.assertRaises(Failure) as e: install.pick_team([])
        self.assertEqual(e.exception.code, "xcode_account_missing")
        self.assertEqual(install.bundle_id("Z6563UVHKK", "0100535012974000"), "s2arm.z6563uvhkk.0100535012974000")
        self.assertEqual(install.container_bundle_id("TEAMABCDEF"), "s2arm.teamabcdef.games")                  # 多款容器：团队专属固定包名，与款无关
        self.assertEqual(install.game_docs("0100c2500fc20000"), "Documents/games/0100C2500FC20000")            # 每款设备侧文档根（游戏号大写，同容器 Games/<游戏号>）
        self.assertEqual(install.game_ctx("0100c2500fc20000"), "@bundle/Games/0100C2500FC20000/launch.ctx")

    def test_classify_signing_errors(self):
        self.assertEqual(install.classify("error: Your maximum App ID limit has been reached. You may create up to 10 App IDs every 7 days."), "free_app_limit")
        self.assertEqual(install.classify("This device has reached the maximum number of installed apps using a free developer profile"), "free_app_limit")   # 11-06 iOS 27 原文
        self.assertEqual(install.classify('error: No Account for Team "Z6563UVHKK".'), "xcode_account_missing")
        self.assertEqual(install.classify("error: something else"), "signing_failed")

    def test_xcode_teams_reads_prefs(self):
        d = tempfile.mkdtemp(); fake = Path(d) / "defaults"
        prefs = plistlib.dumps({"IDEProvisioningTeamByIdentifier": {"acc": [{"teamID": "Z6563UVHKK", "teamName": "我", "isFreeProvisioningTeam": True}, {"teamID": "Z6563UVHKK"}]}})
        (Path(d) / "p.plist").write_bytes(prefs)
        fake.write_text(f'#!/bin/sh\ncat "{d}/p.plist"\n'); fake.chmod(0o755)
        self.assertEqual(install.xcode_teams(dict(os.environ, PATH=d + ":" + os.environ["PATH"])), [dict(id="Z6563UVHKK", name="我", free=True)])


class ShellSdkTests(unittest.TestCase):
    # 11-07 Duo 实测：旧 SDK 链接的壳在 iOS 新一代机型上按旧尺寸缩小居中 → 装机时比「壳链接 SDK 大版本」与「iPhone 系统大版本」
    def _app(self, sdk):
        import struct
        d = Path(tempfile.mkdtemp()) / "S2Arm.app"; d.mkdir()
        (d / "Info.plist").write_bytes(plistlib.dumps({"CFBundleExecutable": "S2Arm"}))
        seg = struct.pack("<II", 0x19, 72) + bytes(64)                                   # 先放一条无关的 LC_SEGMENT_64，确认按 cmdsize 往后走
        bv = struct.pack("<IIIIII", 0x32, 24, 2, 0x00120000, sdk, 0) if sdk is not None else b""   # LC_BUILD_VERSION：platform 2（iOS）、minos 18.0
        cmds = seg + bv
        hdr = struct.pack("<IiiIIIII", 0xFEEDFACF, 0x0100000C, 0, 2, 2 if bv else 1, len(cmds), 0, 0)
        (d / "S2Arm").write_bytes(hdr + cmds); return d

    def test_linked_sdk_decodes_nibbles(self):
        self.assertEqual(install.linked_sdk(self._app(0x001A0500) / "S2Arm"), (26, 5, 0))   # 0x1A=26、0x05=5
        self.assertEqual(install.linked_sdk(self._app(0x001B0100) / "S2Arm"), (27, 1, 0))
        self.assertIsNone(install.linked_sdk(self._app(None) / "S2Arm"))                  # 没有 LC_BUILD_VERSION
        bad = Path(tempfile.mkdtemp()) / "x"; bad.write_bytes(b"#!/bin/sh\n"); self.assertIsNone(install.linked_sdk(bad))

    def test_warns_only_when_phone_newer_than_sdk(self):
        for sdk, os_ver, want in ((0x001A0500, "27.1", 1), (0x001B0100, "27.1", 0), (0x001A0500, "26.4", 0), (0x001A0500, "", 0)):
            c = um.Mock(); install.check_shell_sdk(c, self._app(sdk), {"os": os_ver})
            self.assertEqual(c.diagnostic.call_count, want, (hex(sdk), os_ver))
            if want:
                self.assertEqual(c.diagnostic.call_args.kwargs, dict(code="shell_sdk_old", severity="warning"))
                self.assertIn("iOS 26.5", c.diagnostic.call_args.args[0]); self.assertIn("iOS 27.1", c.diagnostic.call_args.args[0])


class FlowTests(unittest.TestCase):
    setUp = tj.JobsTests.setUp; tearDown = tj.JobsTests.tearDown   # 只借夹具（临时游戏库 / 私有目录 / 任务上下文），不继承它的用例

    def _fixture(self, gid):
        out = self.c.library / "iPhone" / gid; out.mkdir(parents=True)
        with zipfile.ZipFile(out / "t.ipa", "w") as z:
            z.writestr("Payload/S2Arm.app/Info.plist", plistlib.dumps({"CFBundleIdentifier": "com.s2arm.x", "CFBundleExecutable": "S2Arm"}))
            z.writestr("Payload/S2Arm.app/S2Arm", b"bin")
        pack = out / "t资源包"; (pack / "romfs").mkdir(parents=True); (pack / "romfs/a").write_bytes(b"12345"); (pack / "index.tsv").write_text("romfs/a\t5\th\n")
        (pack / "manifest.json").write_text('{"version": 2, "index_sha256": "cafe01"}')
        return out, pack

    def _install(self, gid, pushed, applied_before, mbps=0, unpack_ok=True):
        """跑 install：tools/push_pack.py run --apply 打「推 pushed 个文件」；替身按 push_pack.apply 的口径记「起 App 解包」：
        没推东西且机上 .applied 已是本包（applied_before = cafe01）→ 不起；否则起一次（launches），unpack_ok=False 时像工具那样退出并写「机上解包 180 秒没有新进展」
        （等解包的规则本身在 tests/push_pack_test.py 核）"""
        runs, seen, launches, state = [], {}, [], {"applied": applied_before, "unpack": "10-01 09:00:00 解开 3 个包 9 个文件 1 MB，.applied = cafe01（0.2 秒）\n"}
        def run(args, log=None, env=None, cwd=None, on_line=None):
            args = [str(a) for a in args]; runs.append(args)
            if args[1].endswith("dev_sign.py"): seen["bid"] = plistlib.loads((Path(args[2]) / "Info.plist").read_bytes())["CFBundleIdentifier"]
            if args[2].endswith("tools/push_pack.py"):
                seen["env"] = env; on_line(f"[12:00:00] 资源包：推 {pushed} 个文件 3 MB，分 1 批 + 索引 + 清单（1 秒）")
                if "--apply" in args and not (pushed == 0 and state["applied"] == "cafe01"):
                    launches.append({"S2A_PACK_APPLY_ONLY": "1"})
                    on_line("[12:00:05] 机上解包 13/17")
                    if not unpack_ok:
                        Path(log).parent.mkdir(parents=True, exist_ok=True)
                        Path(log).write_text("【红】资源包推进去了，但机上解包 180 秒没有新进展（停在第 13 包）：打开这款游戏、保持在前台等它导入完\n", encoding="utf-8")
                        raise install.Failure("tool", code="tool_exit")
                    state["applied"] = "cafe01"
        def devicectl(c, *a, timeout=0):
            if a[:3] == ("device", "process", "launch"):
                launches.append(a)
                if unpack_ok: state["applied"] = "cafe01"; state["unpack"] += "11-06 12:00:00 解开 1 个包 2 个文件 0 MB，.applied = cafe01（0.1 秒）\n"
                return 0, {}, ""
            if a[:3] == ("device", "copy", "from"):
                src = a[a.index("--source") + 1]
                Path(a[a.index("--destination") + 1]).write_text(state["unpack"] if src.endswith("unpack.log") else state["applied"] + "\n", encoding="utf-8"); return 0, {}, ""
            return 0, {}, ""
        import diag
        with um.patch.object(install, "xcode_teams", return_value=[dict(id="Z6563UVHKK", name="我", free=True)]), \
             um.patch.object(install, "phone", return_value=dict(id="C891", name="测试机2")), um.patch.object(install, "udid_of", return_value="00000000-0000000000000002"), \
             um.patch.object(install, "usb_mbps", return_value=mbps), \
             um.patch.object(self.c, "run", run), um.patch.object(diag, "devicectl", devicectl), um.patch.object(install.time, "sleep"):
            r = install.install(self.c)
        return r, runs, seen, launches

    def test_repush_same_pack_unpack_timeout_maps_to_player_message(self):   # 推包工具报解包超时 → 玩家看到「打开游戏保持前台」、job_failed（不是推送失败）
        gid = "0100535012974000"; self._fixture(gid); self.c.r.update(gameId=gid)
        with self.assertRaises(install.Failure) as cm:
            self._install(gid, pushed=2, applied_before="cafe01", unpack_ok=False)
        self.assertIn("机上解包 180 秒没有新进展（停在第 13 包）", str(cm.exception)); self.assertEqual(cm.exception.code, "job_failed")
        r, runs, seen, launches = self._install(gid, pushed=2, applied_before="cafe01", unpack_ok=True)
        self.assertEqual(len(launches), 1)
        ev = [json.loads(l) for l in self.c.events.read_text(encoding="utf-8").splitlines() if l.strip()]   # 推包工具的「机上解包 k/n」→ 作业进度事件（启动器显示）
        self.assertTrue(any(e["type"] == "progress" and e["message"] == "机上解包 13/17" and (e["done"], e["total"], e.get("unit")) == (13, 17, "包") for e in ev), ev[-3:])

    def test_install_signs_installs_and_pushes(self):
        gid = "0100535012974000"; out, pack = self._fixture(gid); self.c.r.update(gameId=gid)
        r, runs, seen, launches = self._install(gid, pushed=2, applied_before="")
        bid = "s2arm.z6563uvhkk.0100535012974000"
        self.assertEqual(runs[0][-2:], [str(self.c.engine / "pack/app.entitlements"), "00000000-0000000000000002"])   # 描述文件申请带设备 UDID（登记这台）
        self.assertIn(bid, runs[0]); self.assertEqual(seen["bid"], bid)                                    # 签名前 Info.plist 已换成团队专属包名
        push = next(a for a in runs if a[2].endswith("tools/push_pack.py"))
        self.assertEqual(push[3:], ["run", "C891", bid, str(pack), "--via", "devicectl", "--apply"])         # 资源包走两端共用的增量推送 + 推完解开（同 dev_run、Windows、s2armctl）
        self.assertTrue(seen["env"]["S2A_DEVICECTL"].endswith("Resources/bin/devicectl"))
        self.assertEqual(seen["env"]["S2A_PUSH_UDID"], "00000000-0000000000000002")   # 推包脚本据 UDID 走 s2a-devpush 流式（11-06）
        self.assertEqual(launches, [{"S2A_PACK_APPLY_ONLY": "1"}])                                           # 推了就起一次 App 只解包
        self.assertEqual((r["device"], r["bundleId"], r["packFiles"], r["free"]), ("测试机2", bid, 2, True))

    def test_container_install_paths(self):
        """多款容器：包名 s2arm.<团队>.games；装前各款按 Documents/games/<游戏号> 拉见过的键、列存档；装后各款资源包推进本款文档根、起 App 带本款启动上下文"""
        A, B = "0100000000010000", "0100000000020000"
        packs = {g: self._fixture(g)[1] for g in (A, B)}
        out = self.c.library / "iPhone/container"; (out / "S2Arm.app").mkdir(parents=True)
        (out / "S2Arm.app/s2a_catalogue.json").write_text(json.dumps({"schema": 1, "games": [{"title_id": A, "name": "甲"}, {"title_id": B, "name": "乙"}]}))
        with zipfile.ZipFile(out / "S2Arm.ipa", "w") as z:
            z.writestr("Payload/S2Arm.app/Info.plist", plistlib.dumps({"CFBundleIdentifier": "dev.s2arm.games", "CFBundleExecutable": "S2Arm"}))
            z.writestr("Payload/S2Arm.app/S2Arm", b"bin")
        runs, seen, dc = [], {}, []
        def run(args, log=None, env=None, cwd=None, on_line=None):
            args = [str(a) for a in args]; runs.append(args)
            if args[1].endswith("dev_sign.py"): seen["bid"] = plistlib.loads((Path(args[2]) / "Info.plist").read_bytes())["CFBundleIdentifier"]
            if args[2].endswith("tools/push_pack.py"): on_line("[12:00:00] 资源包：推 1 个文件 3 MB，分 1 批 + 索引 + 清单（1 秒）")
        def devicectl(c, *a, timeout=0):
            dc.append(a)
            return (1, {}, "no such file") if a[:3] == ("device", "copy", "from") else (0, {"result": {"files": [], "apps": []}}, "")
        import diag
        with um.patch.object(install, "xcode_teams", return_value=[dict(id="TEAMABCDEF", name="我", free=True)]), \
             um.patch.object(install, "phone", return_value=dict(id="C891", name="测试机2")), um.patch.object(install, "udid_of", return_value="00000000-0000000000000002"), \
             um.patch.object(self.c, "run", run), um.patch.object(diag, "devicectl", devicectl):
            r = install.install_container(self.c)
        bid = "s2arm.teamabcdef.games"
        self.assertEqual(seen["bid"], bid); self.assertEqual((r["bundleId"], r["games"], r["packFiles"]), (bid, [A, B], 2))
        src = [a[a.index("--source") + 1] for a in dc if a[:3] == ("device", "copy", "from")]
        self.assertEqual(src, [f"Documents/games/{A}/wire/{A}/pso_user.tsv", f"Documents/games/{B}/wire/{B}/pso_user.tsv"])
        sub = [a[a.index("--subdirectory") + 1] for a in dc if a[:3] == ("device", "info", "files")]
        self.assertEqual(sub, [f"Documents/games/{A}/S2A/ryujinx/bis/user/save", f"Documents/games/{B}/S2A/ryujinx/bis/user/save"])
        self.assertTrue(any(a[:3] == ("device", "install", "app") for a in dc)); self.assertFalse(any("uninstall" in a for a in dc))   # 覆盖装、不卸载
        push = [a[3:] for a in runs if a[2].endswith("tools/push_pack.py")]
        self.assertEqual(push, [["run", "C891", bid, str(packs[g]), "--via", "devicectl", "--apply", "--docs", f"Documents/games/{g}", "--launch-ctx", f"@bundle/Games/{g}/launch.ctx"] for g in (A, B)])

    def test_container_missing_pack_refuses_before_install(self):
        A = "0100000000010000"; out = self.c.library / "iPhone/container"; (out / "S2Arm.app").mkdir(parents=True)
        (out / "S2Arm.app/s2a_catalogue.json").write_text(json.dumps({"schema": 1, "games": [{"title_id": A, "name": "甲"}]})); (out / "S2Arm.ipa").write_bytes(b"x")
        with self.assertRaises(Failure) as e: install.install_container(self.c)   # 这款游戏库里没有 iPhone 产物 / 资源包：一款都不装
        self.assertEqual(e.exception.code, "job_failed")

    def test_container_assemble_uses_library_roots_and_base(self):
        """组装多款容器（ipa.container）：各款取游戏库 iPhone/<游戏号>/roots/t<游戏号小写>@现行；第一次没有底子，第二次带 --base 已有容器；产物换到 iPhone/container/"""
        import ipa
        A, B = "0100000000010000", "0100000000020000"
        for g in (A, B):
            r = self.c.library / "iPhone" / g / "roots" / f"t{g.lower()}@现行"; r.mkdir(parents=True); (r / "main.npdm").write_bytes(b"META")
        shell = self.c.private / "shell"; shell.mkdir(); (shell / "manifest.json").write_text("{}")
        runs = []
        def run(args, log=None, env=None, cwd=None, on_line=None):
            args = [str(a) for a in args]; runs.append(args)
            if args[3] == "container":
                o = Path(args[args.index("--out") + 1]); o.mkdir(parents=True)
                (o / "s2a_catalogue.json").write_text(json.dumps({"schema": 1, "games": [{"title_id": x} for x in (A, B)]}))
            if args[3] == "write_ipa": Path(args[5]).write_bytes(b"ipa")
        self.c.r.update(gameIds=[A.lower()], shellDir=str(shell))
        with um.patch.object(self.c, "run", run):
            r1 = ipa.container(self.c)
            self.c.r.update(gameIds=[B])
            r2 = ipa.container(self.c)
        out = self.c.library / "iPhone/container"
        c1, c2 = [a for a in runs if a[3] == "container"]
        self.assertNotIn("--base", c1); self.assertEqual(c2[c2.index("--base") + 1], str(out / "S2Arm.app"))
        self.assertEqual([c1[i + 1] for i, x in enumerate(c1) if x == "--game"], [str((self.c.library / "iPhone" / A / "roots" / f"t{A.lower()}@现行").resolve())])
        self.assertEqual((c1[c1.index("--sign") + 1], c1[c1.index("--shell") + 1]), ("adhoc", str(shell)))
        self.assertEqual((r2["ipa"], r2["games"], r2["added"]), (str(out / "S2Arm.ipa"), [A, B], [B]))
        self.assertEqual(sorted(p.name for p in out.iterdir()), ["S2Arm.app", "S2Arm.ipa"])   # 临时目录与旧容器都清掉
        self.c.r.update(gameIds=["0100000000090000"])
        with self.assertRaises(Failure) as e: ipa.container(self.c)                           # 没出过 iPhone 版的款：先出单款
        self.assertIn("还没出 iPhone 版", str(e.exception))

    def _ready(self, devices, teams=(dict(id="team-a", name="我", free=True),), rc=0):
        """跑装机前清单：devicectl list devices 回 devices（手造的 devicectl 行），Xcode 团队 teams"""
        import diag
        data = {"result": {"devices": list(devices)}}
        with um.patch.object(install, "xcode_teams", return_value=list(teams)), um.patch.object(diag, "devicectl", lambda c, *a, timeout=0: (rc, data, "")):
            r = install.readiness(self.c)
        return r, {i["id"]: i for i in r["items"]}

    @staticmethod
    def _dev(name="测试机2", transport="wired", pairing="paired", devmode="enabled", tunnel="disconnected", platform="iOS", reality="physical"):
        return {"hardwareProperties": {"reality": reality, "platform": platform},
                "connectionProperties": {"transportType": transport, "pairingState": pairing, "tunnelState": tunnel},
                "deviceProperties": {"name": name, "developerModeStatus": devmode}}

    def test_readiness_all_ready(self):
        gid = "0100535012974000"; self._fixture(gid); self.c.r.update(gameId=gid)
        r, it = self._ready([self._dev()])
        self.assertTrue(r["ready"]); self.assertEqual(r["device"], "测试机2")
        self.assertEqual([i["id"] for i in r["items"]], ["package", "appleId", "connected", "trusted", "developerMode"])
        self.assertEqual((r["account"], it["appleId"]["title"]), ("我", "本机开发签名团队可用"))
        self.assertTrue(all(i["detail"] == "" for i in r["items"]))   # 好了的项不带说明

    def test_readiness_steps_in_order(self):
        gid = "0100535012974000"; self.c.r.update(gameId=gid)   # 没出 iPhone 包
        r, it = self._ready([], teams=())                       # 没登录、没连
        self.assertFalse(r["ready"])
        self.assertEqual((it["package"]["ok"], it["package"]["who"]), (False, "app"))
        self.assertFalse(it["appleId"]["ok"]); self.assertIn("「账户」", it["appleId"]["detail"])
        self.assertFalse(it["connected"]["ok"])
        self.assertTrue(it["trusted"]["waiting"]); self.assertTrue(it["developerMode"]["waiting"])   # 没连上：后两项是「等前一步」，不报没打开
        self.assertEqual((it["trusted"]["detail"], it["developerMode"]["detail"]), ("", ""))
        # 连上了但没点信任：信任这项要玩家做，开发者模式仍在等
        r, it = self._ready([self._dev(pairing="unpaired", devmode=None)])
        self.assertTrue(it["connected"]["ok"]); self.assertFalse(it["trusted"]["ok"]); self.assertFalse(it["trusted"]["waiting"])
        self.assertTrue(it["developerMode"]["waiting"])
        # 信任了、开发者模式没开
        r, it = self._ready([self._dev(devmode="disabled")])
        self.assertTrue(it["trusted"]["ok"]); self.assertFalse(it["developerMode"]["ok"]); self.assertFalse(it["developerMode"]["waiting"])
        self.assertIn("开发者模式", it["developerMode"]["detail"])

    def test_readiness_device_filtering(self):
        gid = "0100535012974000"; self._fixture(gid); self.c.r.update(gameId=gid)
        # 模拟器、Mac、只走无线隧道没通的不算连上
        r, it = self._ready([self._dev(reality="simulated"), self._dev(platform="macOS"), self._dev(transport=None, tunnel="unavailable")])
        self.assertFalse(it["connected"]["ok"])
        # 两台都连着：要只留一台
        r, it = self._ready([self._dev(), self._dev(name="测试机1")])
        self.assertFalse(it["connected"]["ok"]); self.assertIn("不止一台", it["connected"]["detail"]); self.assertEqual(r["device"], ""); self.assertTrue(it["trusted"]["waiting"])
        # 读不到设备列表（devicectl 失败）= 当没连
        r, it = self._ready([self._dev()], rc=1)
        self.assertFalse(it["connected"]["ok"])

    def test_no_pack_dir_fails_before_install(self):
        # 审计 18:00 P1-58：没有「…资源包」目录不装、不报成功（原先照装，启动器写死「资源包也拷好了」）
        gid = "0100535012974000"; out, pack = self._fixture(gid); self.c.r.update(gameId=gid)
        import shutil; shutil.rmtree(pack)
        with self.assertRaises(install.Failure) as e:
            self._install(gid, pushed=0, applied_before="")
        self.assertEqual(e.exception.code, "pack_missing"); self.assertIn("资源包", str(e.exception))

    def test_reinstall_nothing_changed_skips_apply(self):
        # 免费账号 7 天到期重装：资源包没变（推 0 个文件）且机上 .applied 已是本包 → 不起 App 解包
        gid = "0100535012974000"; out, pack = self._fixture(gid); self.c.r.update(gameId=gid)
        r, runs, seen, launches = self._install(gid, pushed=0, applied_before="cafe01")
        self.assertEqual(launches, []); self.assertEqual(r["packFiles"], 0)

    def test_usb2_link_warns_usb3_hint(self):
        # 10-26：测试机经集线器只有 480 Mb/s → 黄字 usb_slow 提示换 USB 3；5 Gb/s 不提示；装机照常完成
        gid = "0100535012974000"
        for mbps, want in ((480, 1), (5000, 0), (0, 0)):
            self.tearDown(); self.setUp(); out, pack = self._fixture(gid); self.c.r.update(gameId=gid)
            r, *_ = self._install(gid, pushed=1, applied_before="", mbps=mbps)
            d = [x for x in self.c.job["diagnostics"] if x["code"] == "usb_slow"]
            self.assertEqual(len(d), want, mbps); self.assertEqual(r["packFiles"], 1)
            if want:
                self.assertEqual(d[0]["severity"], "warning"); self.assertIn("USB 2.0（480 Mb/s）", d[0]["summary"])

    def test_usb_mbps_matches_serial(self):
        # system_profiler 的序列号 = 去掉横杠的 UDID；别的设备、没插的不算
        d = tempfile.mkdtemp(); fake = Path(d) / "system_profiler"
        data = {"SPUSBHostDataType": [{"_name": "hub", "_items": [
            {"_name": "iPhone", "USBDeviceKeySerialNumber": "000000000000000000000002", "USBDeviceKeyLinkSpeed": "480 Mb/s"},
            {"_name": "iPhone", "USBDeviceKeySerialNumber": "000000000000000000000001", "USBDeviceKeyLinkSpeed": "5 Gb/s"}]}]}
        (Path(d) / "o.json").write_text(json.dumps(data)); fake.write_text(f'#!/bin/sh\ncat "{d}/o.json"\n'); fake.chmod(0o755)
        env = dict(os.environ, PATH=d + ":" + os.environ["PATH"])
        self.assertEqual(install.usb_mbps("00000000-0000000000000002", env), 480)
        self.assertEqual(install.usb_mbps("00000000-0000000000000001", env), 5000)
        self.assertEqual(install.usb_mbps("00000000-0000000000000004", env), 0)
        self.assertEqual(install.usb_mbps("", env), 0)

    def test_locked_phone_maps_device_locked(self):
        # 10-26 测试机2 锁屏：ensure_profile.sh 带出 xcodebuild 的目的设备报错，归成「iPhone 锁屏了」（原先是含糊的「签名没成」）
        line = "{ platform:iOS, arch:arm64, id:00000000-0000000000000002, name:测试机2, error:The device needs to be unlocked to continue Unlock the device"
        self.assertEqual(install.classify(line), "device_locked")

    def test_profile_failure_maps_free_limit(self):
        gid = "0100535012974000"; out, pack = self._fixture(gid); self.c.r.update(gameId=gid)
        def run(args, log=None, env=None, cwd=None, on_line=None):
            Path(log).parent.mkdir(parents=True, exist_ok=True); Path(log).write_text("error: Your maximum App ID limit has been reached.\n")
            raise Failure("S2Arm 工具退出，当前阶段未完成。", code="tool_exit")
        with um.patch.object(install, "xcode_teams", return_value=[dict(id="Z6563UVHKK", name="我", free=True)]), \
             um.patch.object(install, "phone", return_value=dict(id="C891", name="测试机2")), um.patch.object(install, "udid_of", return_value=""), \
             um.patch.object(self.c, "run", run):
            with self.assertRaises(Failure) as e: install.install(self.c)
        self.assertEqual(e.exception.code, "free_app_limit")
        self.assertIn("3 个自签 App", str(e.exception))


class PullSeenTests(unittest.TestCase):
    setUp = tj.JobsTests.setUp; tearDown = tj.JobsTests.tearDown

    def _pull(self, device_text):
        got = {}
        def devicectl(c, *a, timeout=0):
            got["src"] = a[a.index("--source") + 1]
            if device_text is None: return 1, {}, "no such file"
            Path(a[a.index("--destination") + 1]).write_text(device_text); return 0, {}, ""
        import diag
        with um.patch.object(diag, "devicectl", devicectl):
            r = install.pull_seen(self.c, "C891", "s2arm.z.0100c2500fc20000", "0100c2500fc20000", "00000000-0000000000000002")
        return r, got

    def test_append_overwrite_and_fork(self):
        seen = self.c.library / "games/0100c2500fc20000/seen"
        r, got = self._pull(None)
        self.assertEqual((r, got["src"], seen.exists()), (False, "Documents/wire/0100C2500FC20000/pso_user.tsv", False))   # 机上没有不算错
        self.assertTrue(self._pull("S\ta\n")[0]); self.assertEqual((seen / "00000000-0000000000000002.tsv").read_text(), "S\ta\n")
        self.assertFalse(self._pull("S\ta\n")[0])                                       # 没变
        self.assertTrue(self._pull("S\ta\nS\tb\n")[0])                                  # 续写 → 覆盖
        self.assertEqual((seen / "00000000-0000000000000002.tsv").read_text(), "S\ta\nS\tb\n")
        self.assertTrue(self._pull("S\tc\n")[0])                                        # 换包后重新记 → 另存，旧的保留
        self.assertEqual(sorted(p.read_text() for p in seen.glob("*.tsv")), ["S\ta\nS\tb\n", "S\tc\n"])


class SaveBackupTests(unittest.TestCase):
    setUp = tj.JobsTests.setUp; tearDown = tj.JobsTests.tearDown

    def _run(self, files, fail=None, list_rc=0, installed=False):
        got = []
        def devicectl(c, *a, timeout=0):
            if a[:3] == ("device", "info", "apps"):
                return 0, {"result": {"apps": [{"bundleIdentifier": "s2arm.z.0100c2500fc20000"}] if installed else []}}, ""
            if a[:3] == ("device", "info", "files") and list_rc:
                return list_rc, {}, "The operation couldn’t be completed"
            if a[:3] == ("device", "info", "files"):
                return 0, {"result": {"files": [dict(relativePath=r, resources=dict(isDirectory=d)) for r, d in files]}}, ""
            src = a[a.index("--source") + 1]; got.append(src)
            if fail and src.endswith(fail): return 1, {}, "Device locked"
            Path(a[a.index("--destination") + 1]).write_text("内容:" + src); return 0, {}, ""
        import diag
        with um.patch.object(diag, "devicectl", devicectl):
            return install.backup_saves(self.c, "C891", "s2arm.z.0100c2500fc20000", "0100C2500FC20000"), got

    def test_backs_up_every_file(self):
        d, got = self._run([("0000000000000001", True), ("0000000000000001/0", True), ("0000000000000001/0/save.dat", False),
                            ("0000000000000001/1/save.dat", False), ("0000000000000001/.lock", False)])
        self.assertEqual(got, [install.SAVE_DIR + "/0000000000000001/0/save.dat", install.SAVE_DIR + "/0000000000000001/1/save.dat"])   # 目录与 .lock 不拷
        self.assertEqual((d / "0000000000000001/0/save.dat").read_text(), "内容:" + got[0])
        self.assertEqual(d.parent, self.c.library / "games/0100C2500FC20000/save_backup")

    def test_nothing_on_device(self):
        self.assertEqual(self._run([])[0], None)                       # 第一次装：机上没有存档，不备份不报错

    def test_list_failure(self):
        self.assertEqual(self._run([], list_rc=1, installed=False)[0], None)   # App 不在机上：第一次装，照装
        with self.assertRaises(Failure):
            self._run([], list_rc=1, installed=True)                           # App 在却列不出：停装

    def _tree(self, tree, docs, locked=()):
        # 假设备文件系统（11-07 满屏线 Duo 实测）：列不存在的目录 devicectl 也报「failed to get a list of files」——和锁屏同一个错，只能靠父目录分辨
        def devicectl(c, *a, timeout=0):
            if a[:3] == ("device", "info", "apps"):
                return 0, {"result": {"apps": [{"bundleIdentifier": "s2arm.z.games"}]}}, ""   # App 在机上
            if a[:3] == ("device", "info", "files"):
                sub = a[a.index("--subdirectory") + 1]
                if sub in locked or not any(t == sub or t.startswith(sub + "/") for t in tree):
                    return 1, {}, "StreamingAction: The system failed to get a list of files on the remote device."
                return 0, {"result": {"files": [dict(relativePath=t[len(sub) + 1:], resources=dict(isDirectory=True)) for t in tree if t.startswith(sub + "/")]}}, ""
            raise AssertionError(a)
        import diag
        with um.patch.object(diag, "devicectl", devicectl):
            return install.backup_saves(self.c, "C891", "s2arm.z.games", "0100C2500FC20000", docs=docs)

    def test_missing_save_dir_under_listable_parent_installs(self):
        # 容器第一次装半途失败 / 从没进过游戏：机上 Documents/games 是空目录，存档目录不在 → 没有存档，照装（原先每次都拒装，玩家永久卡死）
        g = "Documents/games/0100C2500FC20000"
        self.assertIsNone(self._tree({"Documents", "Documents/games"}, g))
        self.assertIsNone(self._tree({"Documents", "Documents/games", g, g + "/资源包"}, g))       # 本款目录在、S2A 不在
        self.assertIsNone(self._tree({"Documents", "Documents/logs"}, "Documents"))                # 单款：Documents 在、S2A 不在

    def test_unlistable_parent_or_existing_save_dir_stops(self):
        g = "Documents/games/0100C2500FC20000"
        with self.assertRaises(Failure):   # Documents 也列不出（锁屏 / 隧道断）：分不清有没有存档，停装
            self._tree({"Documents", "Documents/games"}, g, locked={"Documents", "Documents/games", g, g + "/" + install.SAVE_REL})
        with self.assertRaises(Failure):   # 父目录里看得到存档目录、它本身却列不出：有档读不到，停装
            self._tree({"Documents", g + "/" + install.SAVE_REL + "/0000000000000001"}, g, locked={g + "/" + install.SAVE_REL})

    def test_copy_failure_stops_install(self):
        with self.assertRaises(Failure):
            self._run([("0000000000000001/0/save.dat", False)], fail="save.dat")


if __name__ == "__main__":
    unittest.main()
