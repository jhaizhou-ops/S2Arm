"""F06-5：旧引擎缺接口时提示要准确（不能一律报支持）。

jhz 复验（PR #122）第 2 条：结论不能取决于跑测试的机器上碰巧有没有宿主。
这里用 cc 现编两个最小可执行文件当宿主——一个导出 s2a_vpad_read，一个不导出——
再分别测「有符号 / 无符号 / 一个宿主都没有」三种情况，期望值不跑被测代码也能写出来。
Developer 目录按 DEVELOPER_DIR / xcode-select 推导，与 cc/nm 实际用的那个保持一致，不写死
/Applications/Xcode.app（#404：装 CLT 的机器上该路径不存在，编译成功但 nm 被路径错误挡住）。
"""
import contextlib
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
import uuid

JOBS = Path(__file__).resolve().parents[1]
ROOT = JOBS.parents[1]
sys.path.insert(0, str(JOBS))
from core import Context, atomic
import library
import toolchain

# 导出符号的那份：__attribute__((visibility("default"))) 保证进导出表，nm -gU 才看得见
EXPORTS_SYMBOL = r"""
#include <stdint.h>
__attribute__((visibility("default"))) int32_t s2a_vpad_read(uint32_t pad, void *out) { (void)pad; (void)out; return 0; }
int main(void) { return 0; }
"""
NO_SYMBOL = r"""
int main(void) { return 0; }
"""


def have_cc():
    return bool(shutil.which("cc")) and sys.platform == "darwin"


def developer_dir():
    """返回 (来源, 路径)：cc/nm 实际用的 Developer 目录，不能写死 Xcode.app 路径（#404）。

    显式 DEVELOPER_DIR 优先（xcrun 认的就是它，cc 编译时也吃同一个值），
    S2A_TEST_DEVELOPER_DIR 给测试单独指定、反向验证用；都没有就问 xcode-select。
    只装了 Command Line Tools 的机器上 xcode-select 返回 CLT 目录，nm 一样能用。
    """
    for name in ("S2A_TEST_DEVELOPER_DIR", "DEVELOPER_DIR"):
        value = os.environ.get(name, "").strip()
        if value:
            return name, Path(value)
    try:
        found = subprocess.run(["/usr/bin/xcode-select", "-p"], stdout=subprocess.PIPE,
                               stderr=subprocess.STDOUT, text=True, timeout=10, check=False)
    except (OSError, subprocess.TimeoutExpired):
        return "xcode-select -p", None
    value = found.stdout.strip()
    if found.returncode != 0 or not value:
        return "xcode-select -p", None
    return "xcode-select -p", Path(value)


@unittest.skipUnless(have_cc(), "需要 macOS + cc 才能现编宿主做对照")
class InputInterfaceTests(unittest.TestCase):
    """engineInfo.inputConfig 必须反映宿主二进制的真实能力。"""

    @classmethod
    def setUpClass(cls):
        # 先定下与 cc/nm 一致的 Developer 目录：路径选错时要说清是工具链问题，不能让 5 个判断跟着乱红
        cls.developer_source, cls.developer = developer_dir()
        cls.developer_explicit = cls.developer_source != "xcode-select -p"
        if cls.developer is None or not cls.developer.is_dir():
            cls._toolchain_problem(f"{cls.developer_source} 给出的 Developer 目录不可用：{cls.developer}"
                                   "（测试要求与 cc/nm 用同一个实际路径）")
        cls.tool = tempfile.TemporaryDirectory(prefix="s2arm input iface tool ")
        cls.with_symbol = Path(cls.tool.name) / "with-symbol"
        cls.without_symbol = Path(cls.tool.name) / "without-symbol"
        cls._build(cls.with_symbol, EXPORTS_SYMBOL)
        cls._build(cls.without_symbol, NO_SYMBOL)
        cls._check_nm()

    @classmethod
    def _toolchain_problem(cls, message):
        """显式指定的路径不对 = 配错了，直接报错；自动探测不到 = 这台机器没法跑，跳过并说明。"""
        if cls.developer_explicit:
            raise AssertionError(message)
        raise unittest.SkipTest(message)

    @classmethod
    def tearDownClass(cls):
        cls.tool.cleanup()

    @classmethod
    def _build(cls, output, source):
        """cc 编一个最小可执行文件；编不出来就跳过整个类（不是把测试改成通过）。"""
        src = Path(cls.tool.name) / (output.name + ".c")
        src.write_text(source)
        result = subprocess.run(["cc", "-o", str(output), str(src)],
                                env=dict(os.environ, DEVELOPER_DIR=str(cls.developer)),
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, check=False)
        if result.returncode != 0:
            cls._toolchain_problem(f"cc 编不出宿主对照程序：{result.stdout.strip()[:300]}")

    @classmethod
    def _check_nm(cls):
        """先确认这个 Developer 目录下 nm 真能读符号：路径不对要直接点名，而不是归因成「宿主不支持」。"""
        result = subprocess.run(["nm", "-gU", str(cls.with_symbol)],
                                env=dict(os.environ, DEVELOPER_DIR=str(cls.developer)),
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                                timeout=60, check=False)
        if result.returncode != 0 or "_s2a_vpad_read" not in result.stdout:
            detail = (result.stderr.strip() or result.stdout.strip())[:300]
            cls._toolchain_problem(f"{cls.developer_source} 指向的 Developer 目录 {cls.developer} 下 nm 读不出"
                                   f"刚编好宿主的导出符号（nm exit {result.returncode}）：{detail}")

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="s2arm input iface ")
        self.root = Path(self.tmp.name)
        self.output = io.StringIO()
        self.redirect = contextlib.redirect_stdout(self.output)
        self.redirect.__enter__()
        self.request = dict(schema=1, taskId=str(uuid.uuid4()), operation="setup",
                            engineDir=str(ROOT), privateRoot=str(self.root / "private"),
                            library=str(self.root / "library"), libraryId="",
                            developerDir=str(self.developer))
        c = Context(self.request)
        result = library.setup(c)
        self.request.update(libraryId=result["libraryId"])
        self.c = Context(self.request)
        self.tid = "0100000000000000"
        atomic(self.c.library / "catalog.json",
               dict(schema=1, games=[dict(id=self.tid, name="T", display="1.0", hidden=False, packages=[])]))
        # 让被测代码只看得到我们注入的宿主，不受跑测试的机器上真实宿主影响
        self.request["engineDir"] = str(self.root / "engine")
        self.c = Context(self.request)

    def tearDown(self):
        self.redirect.__exit__(None, None, None)
        self.tmp.cleanup()

    def install_host(self, source):
        """按被测代码找宿主的路径放一个：c.private/tools/mac-host/<x>/S2ArmGame.app/Contents/MacOS/s2arm-host。"""
        path = self.c.private / "tools/mac-host" / "x" / "S2ArmGame.app/Contents/MacOS/s2arm-host"
        path.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, path)
        return path

    def test_exports_the_symbol_reports_supported(self):
        self.install_host(self.with_symbol)
        supported, reason = toolchain.input_interface(self.c)
        self.assertIs(supported, True)
        self.assertIn("s2a_vpad_read", reason)

    def test_lacks_the_symbol_reports_unsupported_with_reason(self):
        self.install_host(self.without_symbol)
        supported, reason = toolchain.input_interface(self.c)
        self.assertIs(supported, False)
        self.assertIn("s2a_vpad_read", reason, "不支持时必须点名缺哪个符号，不能只说一句不支持")

    def test_no_host_at_all_says_it_cannot_tell(self):
        supported, reason = toolchain.input_interface(self.c)
        self.assertIs(supported, False)
        self.assertIn("无法确认", reason)

    def test_prepared_host_does_not_borrow_new_engine_cache_capability(self):
        self.install_host(self.with_symbol)
        self.assertTrue(toolchain.input_interface(self.c)[0])
        self.assertFalse(toolchain.input_interface(self.c, self.without_symbol)[0])
        self.assertFalse(toolchain.input_interface(self.c, self.root / "missing-host")[0])
        self.assertTrue(toolchain.input_interface(self.c, self.with_symbol)[0])

    def test_catalog_and_preflight_agree_and_are_not_hardcoded(self):
        self.install_host(self.without_symbol)
        cat = library.catalog(self.c)
        game = next(g for g in cat["games"] if g["id"] == self.tid)
        pre = toolchain.preflight(self.c)
        # 两处必须一致（原来是各自硬编码 True，UI 判断用了两套来源）
        self.assertEqual(game["inputConfig"], pre["engineInfo"]["inputConfig"])
        self.assertIs(game["inputConfig"], False)
        self.assertIsInstance(pre["engineInfo"].get("inputConfigReason"), str)
        self.assertTrue(pre["engineInfo"]["inputConfigReason"], "必须带具体原因供 UI 显示")

    def test_judgement_follows_the_actual_binary(self):
        """同一个 c，换掉宿主二进制 → 结论必须跟着变（证明不是写死的）。"""
        self.install_host(self.with_symbol)
        self.assertIs(toolchain.input_interface(self.c)[0], True)
        self.install_host(self.without_symbol)
        self.assertIs(toolchain.input_interface(self.c)[0], False)

    def test_probe_result_is_cached_until_the_host_changes(self):
        """jhz 复验第 3 条：宿主没变就不该再跑 nm；宿主变了必须重新探。"""
        host = self.install_host(self.with_symbol)
        self.assertIs(toolchain.input_interface(self.c)[0], True)
        cache = self.c.private / "tools/mac-host-cache"
        self.assertEqual(len(list(cache.glob("*.json"))), 1, "首次探测后应留下一条缓存")
        # 宿主没动：nm 应当不再被调用
        calls = []
        real_run = subprocess.run

        def spy(*args, **kwargs):
            calls.append(args)
            return real_run(*args, **kwargs)

        toolchain.subprocess.run = spy
        try:
            self.assertIs(toolchain.input_interface(self.c)[0], True)
        finally:
            toolchain.subprocess.run = real_run
        self.assertEqual([c for c in calls if "nm" in str(c[0][0])], [], "宿主没变时不该再跑 nm")
        # 宿主换了（大小变了）：必须重新探，结论跟着变
        self.install_host(self.without_symbol)
        self.assertGreater(host.stat().st_size, 0)
        self.assertIs(toolchain.input_interface(self.c)[0], False)


if __name__ == "__main__":
    unittest.main()
