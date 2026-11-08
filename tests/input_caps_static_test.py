#!/usr/bin/env python3
"""Original synthetic NSO fixtures; expectations do not use the tool's name table."""
import importlib.util
import io
import json
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

REPO = Path(__file__).resolve().parents[1]
TOOL = REPO / "tools/input_caps_static.py"
SPEC = importlib.util.spec_from_file_location("input_caps_static", TOOL)
caps = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(caps)

VIBRATION = "_ZN2nn3hid19SendVibrationValuesEPKNS0_21VibrationDeviceHandleEPKNS0_14VibrationValueEi"
SIXAXIS = "_ZN2nn3hid18StartSixAxisSensorERKNS0_19SixAxisSensorHandleE"
STYLE = "_ZN2nn3hid22SetSupportedNpadIdTypeEPKjm"
CATEGORIES = ("styles", "vibration", "sixaxis")


def module(path, imports=(), definitions=(), *, compressed=False, mod0=True):
    """Hand-built NSO0 + MOD0 + DT_HASH/.dynamic/ELF64 symbols/strings, no assets."""
    img = bytearray(0x1000)
    struct.pack_into("<I", img, 4, 0x40)
    img[0x40:0x44] = b"MOD0" if mod0 else b"NONE"
    struct.pack_into("<i", img, 0x44, 0x40)
    entries = [(name, 0) for name in imports] + [(name, 1) for name in definitions]
    strings = bytearray(b"\0")
    for index, (name, section) in enumerate(entries, 1):
        struct.pack_into("<IBBHQQ", img, 0x300 + index * 24,
                         len(strings), 0x12, 0, section, 0, 0)
        strings += name.encode("ascii") + b"\0"
    assert 0x300 + 24 * (len(entries) + 1) <= 0x800
    assert 0x800 + len(strings) <= len(img)
    img[0x800:0x800 + len(strings)] = strings
    struct.pack_into("<II", img, 0x200, 1, len(entries) + 1)
    for index, (tag, value) in enumerate(((4, 0x200), (5, 0x800), (6, 0x300),
                                        (10, len(strings)), (11, 24), (0, 0))):
        struct.pack_into("<qQ", img, 0x80 + index * 16, tag, value)
    data = bytearray(0x100)
    data[:4] = b"NSO0"
    struct.pack_into("<I", data, 0xc, 7 if compressed else 0)
    for index, raw in enumerate((bytes(img), bytes(16), bytes(16))):
        stored = raw
        if compressed:
            # LZ4 literal-only block, constructed without a compression dependency.
            extra = bytearray()
            remaining = len(raw) - 15
            while remaining >= 255:
                extra.append(255)
                remaining -= 255
            extra.append(remaining)
            stored = b"\xf0" + extra + raw
        struct.pack_into("<III", data, 0x10 + index * 16,
                         len(data), index * 0x1000, len(raw))
        struct.pack_into("<I", data, 0x60 + index * 4, len(stored))
        data += stored
    path.write_bytes(data)


class InputCaps(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="s2a_input_caps_")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)

    def cli(self, root=None, *, optimized=False):
        command = [sys.executable] + (["-O"] if optimized else [])
        result = subprocess.run(command + [str(TOOL), str(root or self.root)],
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(len(result.stdout.splitlines()), 1, result)
        self.assertEqual(result.stderr, "", result)
        report = json.loads(result.stdout)
        self.assertIsInstance(report["ok"], bool)
        self.assertIn("声明引用", report["why"])
        self.assertIn("实际调用", report["why"])
        self.assertEqual(result.returncode, 0 if report["ok"] else 1, result)
        for key in CATEGORIES:
            self.assertIsInstance(report[key], bool)
            self.assertIsInstance(report["evidence"][key], list)
        return report

    def expect_flags(self, report, styles=False, vibration=False, sixaxis=False):
        self.assertTrue(report["ok"], report)
        self.assertEqual([report[key] for key in CATEGORIES], [styles, vibration, sixaxis])

    def test_01_main_imports_vibration_batch(self):
        module(self.root / "main", imports=[VIBRATION])
        report = caps.scan(self.root)
        self.expect_flags(report, vibration=True)
        self.assertEqual(report["evidence"], {"styles": [], "vibration": ["main:" + VIBRATION], "sixaxis": []})
        self.assertEqual(self.cli(), report)

    def test_02_sdk_definitions_and_imports_are_not_game_references(self):
        module(self.root / "sdk", definitions=[SIXAXIS], imports=[STYLE, VIBRATION])
        module(self.root / "main", definitions=[SIXAXIS])
        self.expect_flags(self.cli())

    def test_03_subsdk_imports_sixaxis(self):
        module(self.root / "main")
        module(self.root / "subsdk0", imports=[SIXAXIS])
        report = self.cli()
        self.expect_flags(report, sixaxis=True)
        self.assertEqual(report["evidence"]["sixaxis"], ["subsdk0:" + SIXAXIS])

    def test_04_no_known_imports_is_valid_not_runtime_support(self):
        module(self.root / "main", imports=["puts", "_ZN2nn2fs9MountSaveEv"])
        (self.root / "main.npdm").write_bytes(b"META")
        self.expect_flags(self.cli())

    def test_05_truncated_nso_is_unknown_without_traceback(self):
        module(self.root / "main", imports=[VIBRATION])
        original = (self.root / "main").read_bytes()
        for size in (0, 4, 0x80, 0x100, len(original) - 1):
            with self.subTest(size=size):
                (self.root / "main").write_bytes(original[:size])
                report = self.cli()
                self.assertFalse(report["ok"])
                self.assertIn("main", report["why"])

    def test_06_removing_vibration_names_makes_case_01_red(self):
        # Re-run case 01 itself: only the production constant table changes.
        with patch.dict(caps.FUNCTIONS, {"vibration": ()}):
            suite = unittest.TestSuite([InputCaps("test_01_main_imports_vibration_batch")])
            stream = io.StringIO()
            result = unittest.TextTestRunner(stream=stream).run(suite)
        self.assertEqual(len(result.errors), 0, stream.getvalue())
        self.assertEqual(len(result.failures), 1, stream.getvalue())
        self.assertIn("test_01_main_imports_vibration_batch", stream.getvalue())
        self.assertIn("[False, False, False] != [False, True, False]", stream.getvalue())

    def test_each_documented_name_is_recognized_independently(self):
        # This list is deliberate independent fixture input, not copied at runtime from FUNCTIONS.
        expected = {
            "styles": ("SetSupportedNpadStyleSet", "SetSupportedNpadIdType"),
            "vibration": ("SendVibrationValue", "SendVibrationValues", "InitializeVibrationDevice",
                          "GetVibrationDeviceHandles", "SendVibrationGcErmCommand"),
            "sixaxis": ("StartSixAxisSensor", "GetSixAxisSensorHandles", "GetSixAxisSensorState",
                        "GetSixAxisSensorStates", "StartConsoleSixAxisSensor"),
        }
        for category, names in expected.items():
            for name in names:
                with self.subTest(name=name):
                    symbol = f"_ZN2nn3hid{len(name)}{name}Ev"
                    module(self.root / "main", imports=[symbol])
                    report = self.cli()
                    self.assertEqual([report[key] for key in CATEGORIES],
                                     [key == category for key in CATEGORIES])
                    self.assertEqual(report["evidence"][category], ["main:" + symbol])

    def test_exact_namespace_and_function_not_substrings_or_argument_types(self):
        decoys = ["SendVibrationValues", VIBRATION.replace("2nn", "2xx", 1),
                  VIBRATION.replace("3hid", "3hid4test", 1),
                  "_ZN2nn3hid24SendVibrationValuesExtraEv", "_ZN2nn3hid18SendVibrationValuesEv",
                  "_ZN4test3RunEPN2nn3hid19SendVibrationValuesE"]
        module(self.root / "main", imports=decoys)
        self.expect_flags(self.cli())

    def test_detail_namespace_and_compressed_custom_module(self):
        symbol = VIBRATION.replace("3hid", "3hid6detail", 1)
        module(self.root / "engine.nso", imports=[symbol, symbol], compressed=True)
        report = self.cli()
        self.expect_flags(report, vibration=True)
        self.assertEqual(report["evidence"]["vibration"], ["engine.nso:" + symbol])

    def test_missing_mod0_and_partial_failure_are_unknown(self):
        module(self.root / "main", imports=[VIBRATION])
        module(self.root / "subsdk0", mod0=False)
        for optimized in (False, True):
            report = self.cli(optimized=optimized)
            self.assertFalse(report["ok"])
            self.assertIn("MOD0", report["why"])

    def test_gnu_hash_only_contiguous_symbols_remain_readable(self):
        module(self.root / "main", imports=[VIBRATION])
        data = bytearray((self.root / "main").read_bytes())
        base = 0x100
        # No SysV DT_HASH: the shared reader infers count from adjacent tables.
        symbols = data[base + 0x300:base + 0x330]
        data[base + 0x7d0:base + 0x800] = symbols
        struct.pack_into("<qQ", data, base + 0x80, 0x6ffffef5, 0x200)
        struct.pack_into("<Q", data, base + 0x80 + 2 * 16 + 8, 0x7d0)
        hash_value = 5381
        for byte in VIBRATION.encode("ascii"):
            hash_value = (hash_value * 33 + byte) & 0xffffffff
        bloom = (1 << (hash_value % 64)) | (1 << ((hash_value >> 5) % 64))
        struct.pack_into("<IIIIQII", data, base + 0x200,
                         1, 1, 1, 5, bloom, 1, hash_value | 1)
        (self.root / "main").write_bytes(data)
        self.expect_flags(self.cli(), vibration=True)

    def test_corrupt_dynamic_metadata_is_unknown_not_negative(self):
        module(self.root / "main", imports=[VIBRATION])
        original = (self.root / "main").read_bytes()
        mutations = (
            ("empty hash count", 0x204, "<I", 0),
            ("symbol entry size", 0x80 + 4 * 16 + 8, "<Q", 23),
            ("short string table", 0x80 + 3 * 16 + 8, "<Q", 1),
            ("out of bounds hash", 0x200, "<I", 0xffffffff),
            ("out of bounds symbol name", 0x300 + 24, "<I", 0xffffffff),
            ("negative dynamic pointer", 0x44, "<i", -0x50),
        )
        for label, offset, fmt, value in mutations:
            with self.subTest(label=label):
                data = bytearray(original)
                struct.pack_into(fmt, data, 0x100 + offset, value)
                (self.root / "main").write_bytes(data)
                self.assertFalse(self.cli()["ok"])

    def test_empty_sdk_only_missing_directory_and_bad_magic_are_unknown(self):
        self.assertFalse(self.cli()["ok"])
        module(self.root / "sdk", definitions=[SIXAXIS])
        self.assertFalse(self.cli()["ok"])
        self.assertFalse(self.cli(self.root / "absent")["ok"])
        module(self.root / "main")
        data = bytearray((self.root / "main").read_bytes())
        data[:4] = b"NOPE"
        (self.root / "main").write_bytes(data)
        self.assertFalse(self.cli()["ok"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
