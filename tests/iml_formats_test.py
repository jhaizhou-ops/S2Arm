#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""Independent byte fixtures for IML readers; no signing tools or devices needed."""
import contextlib
import datetime as dt
import io
import plistlib
import struct
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "pack"))
import iml_check
import iml_formats

IML = "com.apple.developer.kernel.increased-memory-limit"
GOOD = {IML: True}


def tlv(tag, value):
    n = len(value)
    size = bytes([n]) if n < 128 else bytes([0x80 + (n.bit_length()+7)//8]) + n.to_bytes((n.bit_length()+7)//8, "big")
    return bytes([tag]) + size + value


def der_value(value, legacy=False):
    if type(value) is bool:
        return tlv(1, b"\xff" if value else b"\0")
    if type(value) is int:
        n = max(1, (value.bit_length()+8)//8)
        return tlv(2, value.to_bytes(n, "big", signed=True))
    if isinstance(value, str):
        return tlv(12, value.encode("utf-8"))
    if isinstance(value, bytes):
        return tlv(4, value)
    if isinstance(value, list):
        return tlv(0x30, b"".join(der_value(x, legacy) for x in value))
    pairs = [tlv(0x30, tlv(12, k.encode()) + der_value(v, legacy)) for k, v in value.items()]
    return tlv(0x31 if legacy else 0xb0, b"".join(sorted(pairs)))


def der_entitlements(value, legacy=False):
    raw = der_value(value, legacy)
    return raw if legacy else tlv(0x70, b"\x02\x01\x01" + raw)


def superblob(xml=GOOD, der=GOOD, extra=()):
    entries = list(extra)
    if xml is not None:
        raw = xml if isinstance(xml, bytes) else plistlib.dumps(xml)
        entries.append((5, 0xfade7171, raw))
    if der is not None:
        raw = der if isinstance(der, bytes) else der_entitlements(der)
        entries.append((7, 0xfade7172, raw))
    cursor = 12 + 8*len(entries)
    index, payload = b"", b""
    for slot, magic, value in entries:
        index += struct.pack(">II", slot, cursor)
        blob = struct.pack(">II", magic, 8+len(value)) + value
        payload += blob
        cursor += len(blob)
    return struct.pack(">III", 0xfade0cc0, cursor, len(entries)) + index + payload


def macho(signature=None, endian="<", bits=64, cpu=0x100000c, sub=0):
    signature = superblob() if signature is None else signature
    header_size = 32 if bits == 64 else 28
    fields = [0xfeedfacf if bits == 64 else 0xfeedface, cpu, sub, 2, 1, 16, 0]
    if bits == 64:
        fields.append(0)
    return struct.pack(endian+"I"*len(fields), *fields) + struct.pack(endian+"4I", 0x1d, 16, header_size+16, len(signature)) + signature


def fat(slices, bits=32, endian=">"):
    entry_size = 20 if bits == 32 else 32
    offset = 8 + entry_size*len(slices)
    entries, data = b"", b""
    for i, payload in enumerate(slices):
        cpu, sub = struct.unpack_from("<II", payload, 4)
        values = [cpu, sub, offset, len(payload), 0] + ([] if bits == 32 else [0])
        entries += struct.pack(endian+("5I" if bits == 32 else "IIQQII"), *values)
        data += payload
        offset += len(payload)
    return struct.pack(endian+"II", 0xcafebabe if bits == 32 else 0xcafebabf, len(slices)) + entries + data


def cms(payload, oid=b"\x2a\x86\x48\x86\xf7\x0d\x01\x07\x02", extra=b""):
    data_oid = b"\x2a\x86\x48\x86\xf7\x0d\x01\x07\x01"
    encap = tlv(0x30, tlv(6, data_oid) + tlv(0xa0, tlv(4, payload)))
    signed = tlv(0x30, b"\x02\x01\x01\x31\0" + encap + extra + b"\x31\0")
    return tlv(0x30, tlv(6, oid) + tlv(0xa0, signed))


def profile():
    return {"Entitlements": {IML: True, "application-identifier": "TESTTEAM.org.s2arm.*",
                             "com.apple.developer.team-identifier": "TESTTEAM"},
            "TeamIdentifier": ["TESTTEAM"], "ApplicationIdentifierPrefix": ["TESTTEAM"],
            "ProvisionedDevices": ["SYNTHETIC-DEVICE"],
            "ExpirationDate": dt.datetime(2099, 1, 1)}


def signed_ents():
    return {IML: True, "application-identifier": "TESTTEAM.org.s2arm.probe",
            "com.apple.developer.team-identifier": "TESTTEAM"}


class FormatTests(unittest.TestCase):
    def test_xml_der_and_macho_endianness(self):
        for bits in (32, 64):
            for endian in ("<", ">"):
                for xml, der in ((GOOD, GOOD), (GOOD, None), (None, GOOD)):
                    with self.subTest(bits=bits, endian=endian, xml=xml is not None, der=der is not None):
                        self.assertEqual([GOOD], iml_formats.read_macho_entitlements(macho(superblob(xml, der), endian, bits)))

    def test_fat_all_slices(self):
        for bits in (32, 64):
            for endian in ("<", ">"):
                with self.subTest(bits=bits, endian=endian):
                    b = fat([macho(), macho(sub=2)], bits, endian)
                    self.assertEqual([GOOD, GOOD], iml_formats.read_macho_entitlements(b))

    def test_der_types_and_legacy(self):
        value = {IML: True, "false": False, "num": -7, "large": 1234567,
                 "arr": ["中文", 3, False], "dict": {"x": "y"}, "data": b"\0\1"}
        for legacy in (False, True):
            with self.subTest(legacy=legacy):
                raw = macho(superblob(value, der_entitlements(value, legacy)))
                self.assertEqual([value], iml_formats.read_macho_entitlements(raw))

    def test_xml_der_strict_agreement(self):
        for value in ({IML: False}, {IML: 1}, {**GOOD, "extra": True}):
            with self.subTest(value=value):
                with self.assertRaises(ValueError):
                    iml_formats.read_macho_entitlements(macho(superblob(GOOD, value)))

    def test_missing_entitlements_and_fake_xml(self):
        for blob in (superblob(None, None), superblob(None, None, [(0, 0xfade0c02, plistlib.dumps(GOOD))])):
            with self.subTest(blob=blob[:12]):
                with self.assertRaises(ValueError):
                    iml_formats.read_macho_entitlements(macho(blob))

    def test_superblob_bounds_duplicates(self):
        good = superblob()
        bad = [superblob(extra=[(5, 0xfade7171, plistlib.dumps(GOOD))]),
               superblob(xml=b"no plist"), superblob(xml=plistlib.dumps([True])),
               good[:19], good[:4]+struct.pack(">I", len(good)+1)+good[8:],
               good[:16]+struct.pack(">I", 12)+good[20:],
               superblob(None, None, [(5, 0x12345678, plistlib.dumps(GOOD))])]
        for blob in bad:
            with self.subTest(blob=blob[:20]):
                with self.assertRaises(ValueError):
                    iml_formats.read_macho_entitlements(macho(blob))

    def test_macho_bounds(self):
        good = macho()
        bad = [b"", b"not macho", good[:31], good[:36]+struct.pack("<I", 0)+good[40:],
               good[:40]+struct.pack("<I", 0xffffffff)+good[44:],
               good[:20]+struct.pack("<I", 0xffffffff)+good[24:]]
        for data in bad:
            with self.subTest(data=data[:32]):
                with self.assertRaises(ValueError):
                    iml_formats.read_macho_entitlements(data)

    def test_fat_bounds_overlap_mismatch(self):
        good = fat([macho(), macho(sub=2)])
        bad = [good[:8]+struct.pack(">I", 1)+good[12:],
               good[:16]+struct.pack(">I", 8)+good[20:],
               good[:36]+good[16:20]+good[40:], good[:20]]
        for data in bad:
            with self.subTest(data=data[:48]):
                with self.assertRaises(ValueError):
                    iml_formats.read_macho_entitlements(data)

    def test_fat_overlapping_identical_architectures(self):
        raw = fat([macho(), macho()])
        raw = raw[:36]+raw[16:20]+raw[40:]
        with self.assertRaises(ValueError):
            iml_formats.read_macho_entitlements(raw)

    def test_duplicate_signature_commands(self):
        raw = macho()
        commands = struct.pack("<4I", 0x1d, 16, 64, len(raw)-48)*2
        raw = raw[:16]+struct.pack("<II",2,32)+raw[24:32]+commands+raw[48:]
        with self.assertRaises(ValueError):
            iml_formats.read_macho_entitlements(raw)

    def test_der_malformed(self):
        pairs = tlv(0x30, tlv(12, b"x")+tlv(1, b"\xff"))
        bad = [b"", b"\x70\x80\0\0", b"\x70\x81\x00", der_entitlements(GOOD)+b"x",
               tlv(0x70, b"\x02\x01\x02"+der_value(GOOD)),
               tlv(0x70, b"\x02\x01\x01"+tlv(0xb0, pairs+pairs)),
               tlv(0x70, b"\x02\x01\x01"+tlv(0xb0, tlv(0x30, tlv(12,b"x")+tlv(1,b"\x01")))),
               tlv(0x70, b"\x02\x01\x01"+tlv(0xb0, tlv(0x30, tlv(12,b"x")+tlv(2,b"\0\1"))))]
        for raw in bad:
            with self.subTest(raw=raw[:25]):
                with self.assertRaises(ValueError):
                    iml_formats.read_macho_entitlements(macho(superblob(None, raw)))

    def test_duplicate_xml_keys(self):
        raw = b'<plist version="1.0"><dict><key>x</key><true/><key>x</key><false/></dict></plist>'
        with self.assertRaises(ValueError):
            iml_formats.read_macho_entitlements(macho(superblob(raw, None)))

    def test_cms_exact_payload(self):
        expected = profile()
        for fmt in (plistlib.FMT_XML, plistlib.FMT_BINARY):
            with self.subTest(fmt=fmt):
                raw = cms(plistlib.dumps(expected, fmt=fmt), extra=tlv(0xa0, plistlib.dumps({"fake": True})))
                self.assertEqual(expected, iml_formats.read_profile(raw))

    def test_cms_not_xml_search(self):
        payload = plistlib.dumps(profile())
        for data in (payload, b"garbage"+payload, cms(payload, oid=b"\x2a\x03"), cms(payload)+b"x", cms(b"bad"), cms(payload)[:-1], cms(b"bad", extra=tlv(0xa0,payload))):
            with self.subTest(data=data[:12]):
                with self.assertRaises(ValueError):
                    iml_formats.read_profile(data)


class AppTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.app = Path(self.tmp.name) / "中文 Probe.app"
        self.app.mkdir()
        (self.app / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleExecutable": "Probe", "CFBundleIdentifier": "org.s2arm.probe"}))
        (self.app / "Probe").write_bytes(macho(superblob(signed_ents(), signed_ents())))

    def run_check(self, **kw):
        stream = io.StringIO()
        with contextlib.redirect_stdout(stream), patch("subprocess.run", side_effect=AssertionError("external tool called")):
            rc = iml_check._check_app(str(self.app), **kw)
        return rc, stream.getvalue()

    def write_profile(self, value):
        (self.app / "embedded.mobileprovision").write_bytes(cms(plistlib.dumps(value)))

    def test_no_profile_adhoc(self):
        rc, out = self.run_check()
        self.assertEqual(0, rc)
        self.assertIn("未验安装描述文件", out)
        self.assertIn("信任链", out)

    def test_embedded_profile_is_strict(self):
        self.write_profile(profile())
        self.assertEqual(0, self.run_check(device_udid="SYNTHETIC-DEVICE")[0])
        self.assertEqual(0, self.run_check()[0])

    def test_profile_failures(self):
        changes = [("ExpirationDate", dt.datetime(2000,1,1)), ("ExpirationDate", "2099-01-01"),
                   ("ProvisionedDevices", []), ("TeamIdentifier", ["WRONG"]),
                   ("ApplicationIdentifierPrefix", ["WRONG"]),
                   ("Entitlements", {IML: False}),
                   ("Entitlements", {**profile()["Entitlements"], "application-identifier": "TESTTEAM.org.other.*"}),
                   ("Entitlements", {**profile()["Entitlements"], "application-identifier": "*"}),
                   ("Entitlements", {**profile()["Entitlements"], "dynamic-codesigning": True})]
        for key, value in changes:
            with self.subTest(key=key, value=value):
                p = profile(); p[key] = value; self.write_profile(p)
                rc, out = self.run_check(device_udid="SYNTHETIC-DEVICE")
                self.assertEqual(1, rc)
                self.assertNotIn("SYNTHETIC-DEVICE", out)
                self.assertNotIn(str(self.app), out)

    def test_signed_identity_must_match_profile(self):
        for key, value in (("application-identifier", "TESTTEAM.org.other"),
                           ("com.apple.developer.team-identifier", "WRONG")):
            with self.subTest(key=key):
                e = signed_ents(); e[key] = value
                (self.app / "Probe").write_bytes(macho(superblob(e,e)))
                self.write_profile(profile())
                self.assertEqual(1, self.run_check()[0])

    def test_explicit_profile_and_device_require_profile(self):
        self.assertEqual(1, self.run_check(device_udid="SYNTHETIC-DEVICE")[0])
        self.assertEqual(1, self.run_check(profile_path=str(self.app / "missing"))[0])
        self.write_profile(profile())
        self.assertEqual(1, self.run_check(device_udid="WRONG-DEVICE")[0])
        self.assertEqual(0, self.run_check(profile_path=str(self.app / "embedded.mobileprovision"))[0])

    def test_fat_mixed_or_bad_permissions(self):
        for ents in ({}, {**GOOD, "dynamic-codesigning": True}):
            with self.subTest(ents=ents):
                raw = fat([macho(), macho(superblob(ents, ents), sub=2)])
                (self.app / "Probe").write_bytes(raw)
                self.assertEqual(1, self.run_check()[0])

    def test_fat_both_valid_permissions(self):
        extra = {**GOOD, "extra": "different"}
        (self.app / "Probe").write_bytes(fat([macho(), macho(superblob(extra, extra), sub=2)]))
        self.assertEqual(0, self.run_check()[0])

    def test_each_banned_key_and_missing(self):
        for e in ({}, *({**GOOD, key: True} for key in iml_check.BANNED_KEYS)):
            with self.subTest(e=e):
                (self.app / "Probe").write_bytes(macho(superblob(e,e)))
                self.assertEqual(1, self.run_check()[0])

    def test_bad_app_paths_and_plists(self):
        for exe in ("../Probe", "C:\\Probe", "../private", ""):
            with self.subTest(exe=exe):
                (self.app / "Info.plist").write_bytes(plistlib.dumps({"CFBundleExecutable": exe,"CFBundleIdentifier":"org.s2arm.probe"}))
                self.assertEqual(1, self.run_check()[0])

    def test_macos_contents_layout(self):
        contents = self.app / "Contents"
        (contents / "MacOS").mkdir(parents=True)
        (self.app / "Info.plist").rename(contents / "Info.plist")
        (self.app / "Probe").rename(contents / "MacOS/Probe")
        self.assertEqual(0, self.run_check()[0])

    def test_embedded_profile_cannot_be_bypassed(self):
        external = self.app / "explicit.cms"
        external.write_bytes(cms(plistlib.dumps(profile())))
        self.write_profile({**profile(), "ExpirationDate": dt.datetime(2000,1,1)})
        self.assertEqual(1, self.run_check(profile_path=str(external))[0])

    def test_actual_cli_no_host_tools(self):
        import subprocess
        with patch.dict("os.environ", {"PATH":"", "PYTHONIOENCODING":"cp1252"}):
            result = subprocess.run([sys.executable, "-X", "utf8=0", str(ROOT / "pack/iml_check.py"),
                                     "check_app", str(self.app)], capture_output=True, text=True, encoding="utf-8")
        self.assertEqual(0, result.returncode, result.stdout+result.stderr)
        self.assertIn("未验安装描述文件",result.stdout)

    def test_isolated_importlib_consumer(self):
        import subprocess
        code = ("import importlib.util; p="+repr(str(ROOT / "pack/iml_check.py"))+"; "
                "s=importlib.util.spec_from_file_location('probe_iml',p); "
                "m=importlib.util.module_from_spec(s); s.loader.exec_module(m); "
                "assert m.window_gb(26,True)==51.0")
        result = subprocess.run([sys.executable,"-I","-c",code], cwd=self.tmp.name, capture_output=True)
        self.assertEqual(0,result.returncode,result.stderr)

    def test_nonboolean_iml_fails(self):
        for value in ("true", 1, [], {"x":True}):
            with self.subTest(value=value):
                self.assertFalse(iml_check.check_entitlements_plist(plistlib.dumps({IML:value}))[0])


if __name__ == "__main__":
    unittest.main(verbosity=2)
