"""Original synthetic checkpoint tests; no game/device input."""
import copy
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from pack.crosshost.prepared import seal, verify, compare, PreparedError

SHA = "1" * 40

class PreparedTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.base = Path(self.tmp.name)
        self.root = self.base / "root"
        self.root.mkdir()
        self.put("unpack.tsv", b"abc")
        self.put("exefs/main", b"NSO0original-main")
        self.put("exefs/main.npdm", b"original-npdm")
        self.put("romfs/original.txt", b"original-resource")
        self.man = self.base / "checkpoint.json"

    def tearDown(self):
        self.tmp.cleanup()

    def put(self, name, data):
        p = self.root / name
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(data)

    def make(self, profile="extract"):
        return seal(self.root, self.man, profile, SHA)

    def test_exact_identity_and_repeat(self):
        m = self.make()
        self.assertEqual(m["details"]["provenance"], {
            "sourceCommit": SHA,
            "unpackSha256": "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"})
        self.assertEqual([f["path"] for f in m["files"]],
                         ["exefs/main", "exefs/main.npdm", "romfs/original.txt", "unpack.tsv"])
        self.assertEqual(verify(self.root, self.man), m)
        other = self.base / "other.json"
        seal(self.root, other, "extract", SHA)
        self.assertEqual(self.man.read_bytes(), other.read_bytes())

    def test_same_length_mutation_red_restore_green(self):
        self.make()
        p = self.root / "unpack.tsv"
        stamp = p.stat()
        p.write_bytes(b"abd")
        os.utime(p, ns=(stamp.st_atime_ns, stamp.st_mtime_ns))
        with self.assertRaises(PreparedError): verify(self.root, self.man)
        p.write_bytes(b"abc")
        verify(self.root, self.man)

    def test_missing_extra_and_truncated(self):
        self.make()
        for data in (b"", b"ab"):
            self.put("romfs/original.txt", data)
            with self.assertRaises(PreparedError): verify(self.root, self.man)
        self.put("romfs/original.txt", b"original-resource")
        self.put("romfs/extra.txt", b"extra")
        with self.assertRaises(PreparedError): verify(self.root, self.man)

    def test_no_overwrite_or_manifest_in_root(self):
        self.man.write_bytes(b"keep")
        with self.assertRaises(PreparedError): self.make()
        self.assertEqual(self.man.read_bytes(), b"keep")
        with self.assertRaises(PreparedError):
            seal(self.root, self.root / "manifest.json", "extract", SHA)

    def test_symlink_and_unapproved_payload(self):
        (self.root / "romfs/original.txt").unlink()
        (self.root / "romfs/original.txt").symlink_to(self.root / "unpack.tsv")
        with self.assertRaises(PreparedError): self.make()
        (self.root / "romfs/original.txt").unlink()
        self.put("romfs/original.txt", b"original-resource")
        self.put("prod.keys", b"synthetic-not-real")
        with self.assertRaises(PreparedError): self.make()
        self.assertFalse(self.man.exists())

    def test_romfs_store_link(self):
        # pack/roots.sh RomFS 共享存储：产物根 <款>@<版本>/romfs 是 ../.romfs_store/<款>/<身份> 的相对软链。
        # 合规的这一条放行、展开成 romfs/…，账本与真目录时逐字节相同；其余链接一律拒绝。
        real = self.make()
        self.man.unlink()
        root = self.base / "g@v1"
        os.rename(self.root, root)
        store = self.base / ".romfs_store/g/id1"
        store.parent.mkdir(parents=True)
        os.rename(root / "romfs", store)
        (root / "romfs").symlink_to("../.romfs_store/g/id1")
        self.assertEqual(seal(root, self.man, "extract", SHA)["files"], real["files"])
        verify(root, self.man)
        self.man.unlink()
        bad = {"../.romfs_store/other/id1": "别的款", "../.romfs_store/g/.id1": "点开头身份",
               str(store): "绝对路径", "../.romfs_store/g/id1/": "带尾斜杠", "../elsewhere": "存储以外"}
        (self.base / ".romfs_store/other").mkdir()
        os.symlink("../g/id1", self.base / ".romfs_store/other/id1")
        (self.base / ".romfs_store/g/.id1").mkdir()
        (self.base / "elsewhere").mkdir()
        for target, why in bad.items():
            (root / "romfs").unlink()
            (root / "romfs").symlink_to(target)
            with self.assertRaises(PreparedError, msg=why): seal(root, self.man, "extract", SHA)
            self.assertFalse(self.man.exists(), why)
        # 存储里的身份本身是软链 → 拒绝
        (root / "romfs").unlink()
        os.rename(store, self.base / ".romfs_store/g/real")
        os.symlink("real", store)
        (root / "romfs").symlink_to("../.romfs_store/g/id1")
        with self.assertRaises(PreparedError): seal(root, self.man, "extract", SHA)
        # 存储里套着的链接照旧拒绝
        os.unlink(store); os.rename(self.base / ".romfs_store/g/real", store)
        (store / "inner").symlink_to(root / "unpack.tsv")
        with self.assertRaises(PreparedError): seal(root, self.man, "extract", SHA)

    def test_profiles_and_ios_negative(self):
        with self.assertRaises(PreparedError): self.make("pre-metal")
        with self.assertRaises(PreparedError): self.make("romfs-index")
        self.put("romfs.s2aidx", b"synthetic-index")
        m = self.make("romfs-index")
        from pack.contracts.validate import validate, ContractError
        m["target"] = "ios"
        with self.assertRaises(ContractError): validate("artifact", m)

    def test_rewrite_all_actual_modules(self):
        self.put("exefs/subsdk9", b"NSO0original-secondary")
        self.put("exefs/rtld", b"NSO0original-loader")
        for module in ("main", "subsdk9"):
            for suffix in ("patched.bin", "fixups.tsv", "gates.tsv", "sites.tsv", "gaps.tsv", "widen.tsv"):
                self.put(module + "." + suffix, b"original")
        for name in ("main.npdm", "widen_sites.tsv", "addr_need.tsv"):
            self.put(name, b"original")
        self.make("rewrite")
        (self.root / "subsdk9.widen.tsv").unlink()
        with self.assertRaises(PreparedError): verify(self.root, self.man)

    def rewrite_five(self):
        for suffix in ("patched.bin", "fixups.tsv", "gates.tsv", "sites.tsv", "gaps.tsv"):
            self.put("main." + suffix, b"original")
        for name in ("main.npdm", "widen_sites.tsv", "addr_need.tsv"):
            self.put(name, b"original")

    def test_optional_widen_and_required_five(self):
        self.rewrite_five()
        five = self.make("rewrite")
        self.man.unlink()
        self.put("main.widen.tsv", b"candidate")
        six = self.make("rewrite")
        self.assertEqual(set(f["path"] for f in six["files"]) -
                         set(f["path"] for f in five["files"]), {"main.widen.tsv"})
        self.man.unlink()
        for suffix in ("patched.bin", "fixups.tsv", "gates.tsv", "sites.tsv", "gaps.tsv"):
            p = self.root / ("main." + suffix)
            p.unlink()
            with self.assertRaises(PreparedError): self.make("rewrite")
            self.assertFalse(self.man.exists())
            p.write_bytes(b"original")
        for name in ("orphan.widen.tsv", "orphan.patched.bin", ".root_unknown"):
            self.put(name, b"not allowed")
            with self.assertRaises(PreparedError): self.make("rewrite")
            self.assertFalse(self.man.exists())
            (self.root / name).unlink()

    def test_root_metadata_is_readonly_unhashed_sidecar(self):
        self.rewrite_five()
        names = (".root_base", ".root_base_stages", ".root_src")
        for name in names:
            self.put(name, name.encode())
        before = {name: (self.root / name).read_bytes() for name in names}
        expected = self.make("rewrite")
        self.assertFalse(set(names) & {f["path"] for f in expected["files"]})
        self.assertEqual(before, {name: (self.root / name).read_bytes() for name in names})
        for name in names:
            p = self.root / name
            p.write_bytes(b"changed bookkeeping only")
            self.assertEqual(verify(self.root, self.man), expected)
            self.man.unlink()
            self.assertEqual(self.make("rewrite"), expected)
            p.unlink()
            self.assertEqual(verify(self.root, self.man), expected)
            self.man.unlink()
            self.assertEqual(self.make("rewrite"), expected)
            p.write_bytes(before[name])
        # Known names do not exempt symlinks from the safety preflight.
        (self.root / names[0]).unlink()
        (self.root / names[0]).symlink_to(self.root / "unpack.tsv")
        with self.assertRaises(PreparedError): verify(self.root, self.man)

    def test_compare_identity_and_content(self):
        import shutil
        self.make()
        other = self.base / "second"
        shutil.copytree(self.root, other)
        second_manifest = self.base / "second.json"
        seal(other, second_manifest, "extract", SHA)
        self.assertTrue(compare(self.root, self.man, other, second_manifest)["equal"])
        (other / "romfs/original.txt").write_bytes(b"other-resource")
        second_manifest.unlink()
        seal(other, second_manifest, "extract", SHA)
        self.assertFalse(compare(self.root, self.man, other, second_manifest)["equal"])
        second_manifest.unlink()
        seal(other, second_manifest, "extract", "2" * 40)
        with self.assertRaises(PreparedError): compare(self.root, self.man, other, second_manifest)

    def test_manifest_path_tampering(self):
        m = self.make()
        for name in ("../x", "C:/x", "exefs//main", "exefs/main/", "exefs\\main"):
            bad = copy.deepcopy(m)
            bad["files"][0]["path"] = name
            self.man.write_text(json.dumps(bad))
            with self.assertRaises(PreparedError): verify(self.root, self.man)

    def test_atomic_failure_does_not_publish(self):
        for call in ("os.fsync", "os.link"):
            with patch("pack.crosshost.prepared." + call, side_effect=OSError("injected")):
                with self.assertRaises(OSError): self.make()
            self.assertFalse(self.man.exists())
            self.assertEqual(list(self.base.glob(".prepared-*")), [])
        self.make()
        if os.name == "nt":
            # Windows 的 mode 位不表达 ACL；这里只核当前进程可读写与原子发布。
            # 不将 os.access 冒充“其他用户不可写”的隔离证明。
            self.assertTrue(os.access(self.man, os.R_OK | os.W_OK))
            self.assertEqual(list(self.base.glob(".prepared-*")), [])
        else:
            self.assertEqual(self.man.stat().st_mode & 0o777, 0o600)

    def test_input_changes_before_publication(self):
        from pack.crosshost import prepared
        original = prepared.verify
        def interrupted(root, manifest):
            self.put("unpack.tsv", b"abd")
            return original(root, manifest)
        with patch.object(prepared, "verify", interrupted):
            with self.assertRaises(PreparedError): self.make()
        self.assertFalse(self.man.exists())
        self.assertEqual(list(self.base.glob(".prepared-*")), [])

    def test_bad_source_and_duplicate_json(self):
        with self.assertRaises(PreparedError):
            seal(self.root, self.man, "extract", "main")
        self.make()
        self.man.write_bytes(b'{"schema":"s2a.artifact.v2","schema":"s2a.artifact.v2"}')
        with self.assertRaises(PreparedError): verify(self.root, self.man)

    def test_real_stage_sidecars_project_without_mutation(self):
        self.put(".stage_unpack", b"synthetic-key")
        self.put("unpack.log", b"synthetic-log")
        self.make()
        self.assertEqual((self.root / ".stage_unpack").read_bytes(), b"synthetic-key")
        self.assertNotIn(".stage_unpack", [f["path"] for f in verify(self.root, self.man)["files"]])
        self.put("unknown.tmp", b"extra")
        with self.assertRaises(PreparedError): verify(self.root, self.man)

    def test_index_accepts_cumulative_rewrite_root(self):
        for suffix in ("patched.bin", "fixups.tsv", "gates.tsv", "sites.tsv", "gaps.tsv", "widen.tsv"):
            self.put("main." + suffix, b"original")
        for name in ("main.npdm", "widen_sites.tsv", "addr_need.tsv", "gpu_drivers.tsv"):
            self.put(name, b"original")
        self.put(".stage_rewrite", b"stage-key")
        self.put(".stage_romfsidx", b"index-key")
        self.put("romfs.s2aidx", b"original-index")
        m = self.make("romfs-index")
        self.assertIn("main.patched.bin", [f["path"] for f in m["files"]])
        verify(self.root, self.man)

    def test_cli_roundtrip(self):
        cli = [sys.executable, "-I", "-S", "-B", str(ROOT / "pack/crosshost/prepared.py")]
        r = subprocess.run(cli + ["seal", "--root", str(self.root), "--manifest", str(self.man),
                                  "--profile", "extract", "--source-commit", SHA], capture_output=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        r = subprocess.run(cli + ["verify", "--root", str(self.root), "--manifest", str(self.man)], capture_output=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertNotIn(str(self.root).encode(), r.stdout)

class WindowsHostTests(unittest.TestCase):
    """Original bytes exercise the real CLI, process locks and spawn path."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.base = Path(self.tmp.name)
        self.env = {k: v for k, v in os.environ.items()
                    if not k.startswith("PYTHON") and k != "S2A_PROGRESS"}
        self.env["J"] = "2"

    def tearDown(self):
        self.tmp.cleanup()

    def test_pack_cli_unicode_cold_warm_and_changed(self):
        source = self.base / "source"
        nested = source / "nested"
        nested.mkdir(parents=True)
        for i in range(66):
            (nested / (str(i) + ".bin")).write_bytes(bytes([i]) * 17)
        (nested / "\u4e2d\u6587.txt").write_bytes("\u539f\u521b\u5939\u5177".encode("utf-8"))
        (source / ".original").write_bytes(b"keep-dotfile")
        (source / "empty").write_bytes(b"")
        out = self.base / "out"
        command = [sys.executable, "-X", "utf8=0", "-B", str(ROOT / "pack/pack.py"),
                   str(out), "romfs=" + str(source)]
        first = subprocess.run(command, capture_output=True, env=self.env, timeout=60)
        self.assertEqual(first.returncode, 0, first.stderr)
        index = (out / "index.tsv").read_bytes()
        self.assertNotIn(b"\r", index)
        manifest = json.loads((out / "manifest.json").read_bytes())
        self.assertEqual(manifest["files"], 69)
        self.assertEqual(manifest["index_sha256"], hashlib.sha256(index).hexdigest())
        for line in index.decode("utf-8").splitlines():
            relative, size, digest = line.split("\t")
            self.assertNotIn("\\", relative)
            data = (out / relative).read_bytes()
            self.assertEqual(len(data), int(size))
            self.assertEqual(hashlib.sha256(data).hexdigest(), digest)
        for extra in ([], ["--check"]):
            run = subprocess.run(command + extra, capture_output=True, env=self.env, timeout=60)
            self.assertEqual(run.returncode, 0, run.stderr)
            self.assertEqual((out / "index.tsv").read_bytes(), index)
        changed = nested / "0.bin"
        old = changed.stat()
        changed.write_bytes(b"changed")
        os.utime(changed, ns=(old.st_atime_ns, old.st_mtime_ns + 2_000_000_000))
        run = subprocess.run(command + ["--check"], capture_output=True, env=self.env, timeout=60)
        self.assertEqual(run.returncode, 1, run.stderr)


if __name__ == "__main__":
    unittest.main()
