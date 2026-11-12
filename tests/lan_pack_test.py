# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""局域网拉取资源包（tools/lan_pack*.py）：本机起只读服务、参考客户端拉到临时目录核口径。不连手机，期望按文件头规则手写。"""
import hashlib, io, json, os, sys, tarfile, tempfile, threading, unittest, urllib.request
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
import lan_pack as lp
import lan_pack_pull as pull
import lan_pack_server as server
server.Handler.log_message = lambda *a: None   # 单测不打访问日志


def sha(b): return hashlib.sha256(b).hexdigest()


def write_pack(d, files, manifest=True):
    d.mkdir(parents=True, exist_ok=True)
    for k, v in files.items():
        (d / k).parent.mkdir(parents=True, exist_ok=True); (d / k).write_bytes(v)
    ix = "".join(f"{k}\t{len(v)}\t{sha(v)}\n" for k, v in files.items())
    (d / "index.tsv").write_text(ix, encoding="utf-8", newline="")
    (d / "manifest.json").write_text(json.dumps({"version": 2, "files": len(files), "total": sum(map(len, files.values())), "index_sha256": sha(ix.encode())}) if manifest else "")


def untar_all(root):
    """模拟 App 启动解包：按名字序解 .incoming/*.tar 到资源包根，写 index.applied.tsv（pack_apply.c 的结果口径）"""
    inc = root / ".incoming"
    for t in sorted(inc.glob("*.tar")):
        with tarfile.open(t) as tf: tf.extractall(root, filter="data")
        t.unlink()
    (root / "index.applied.tsv").write_text((root / "index.tsv").read_text(encoding="utf-8"), encoding="utf-8")
    (root / ".pulled").unlink(missing_ok=True)


class Layout(unittest.TestCase):
    def test_deterministic_and_rangeable(self):
        with tempfile.TemporaryDirectory() as td:
            d = Path(td); files = {"a": b"A" * 700, "目录/中文名.bin": os.urandom(1500), "z" * 150: b"", "b": b"B"}
            for k, v in files.items(): (d / k).parent.mkdir(parents=True, exist_ok=True); (d / k).write_bytes(v)
            rows = [(k, len(v), sha(v)) for k, v in files.items()]
            L = lp.TarLayout(rows); op = lambda p: open(d / p, "rb")
            whole = b"".join(L.chunks(0, L.length, op))
            self.assertEqual(len(whole), L.length)
            self.assertTrue(lp.tar_ok(whole))
            self.assertEqual(whole, b"".join(lp.TarLayout(rows).chunks(0, L.length, op)), "同一列表两次打包逐字节相同")
            for a in (0, 1, 511, 512, 513, 1000, L.length - 1025, L.length - 1):   # 任意切点拼回去与整份相同（续传的前提）
                self.assertEqual(b"".join(L.chunks(0, a, op)) + b"".join(L.chunks(a, L.length, op)), whole)
            with tarfile.open(fileobj=io.BytesIO(whole)) as t:
                got = [(m.name, t.extractfile(m).read()) for m in t]
            self.assertEqual(got, list(files.items()))
            self.assertEqual(whole[-1024:], b"\0" * 1024)

    def test_range_parse(self):
        self.assertEqual(lp.parse_range("bytes=10-", 100), (10, 100))
        self.assertEqual(lp.parse_range("bytes=10-19", 100), (10, 20))
        self.assertEqual(lp.parse_range("bytes=-5", 100), (95, 100))
        self.assertEqual(lp.parse_range("bytes=100-", 100), "bad")
        self.assertIsNone(lp.parse_range(None, 100))

    def test_unsafe_index(self):
        for bad in ("../x\t1\th", "/abs\t1\th", "a\\b\t1\th"):
            with self.assertRaises(ValueError): lp.parse_index(bad)

    def test_lan_peer(self):
        for ok in ("127.0.0.1", "192.168.1.5", "10.0.0.2", "172.16.3.4", "fe80::1", "::1", "::ffff:192.168.1.9"): self.assertTrue(server.lan_peer(ok), ok)
        for no in ("8.8.8.8", "2001:4860::1", "::ffff:8.8.8.8", "bogus"): self.assertFalse(server.lan_peer(no), no)


class Live(unittest.TestCase):
    def setUp(self):
        self.td = tempfile.TemporaryDirectory(); d = Path(self.td.name)
        self.lib = d / "lib"; self.dev = d / "dev"
        self.files = {"exefs/main": os.urandom(3000), "romfs/数据.bin": os.urandom(5000), "shaders/lib.idx": b"idx"}
        write_pack(self.lib / "0100633007D48000", self.files)
        write_pack(self.lib / "half", {"x": b"x"}, manifest=False)   # 清单空 = 不完整，不发
        self.srv, self.tok = server.make_server(self.lib, "127.0.0.1", 0, "tok")
        threading.Thread(target=self.srv.serve_forever, daemon=True).start()
        self.pair = f"s2arm-lan://127.0.0.1:{self.srv.server_address[1]}/?t=tok"
        self.c = pull.Client(self.pair); self.log = []

    def tearDown(self):
        self.srv.shutdown(); self.srv.server_close(); self.td.cleanup()

    def say(self, s): self.log.append(s)

    def raw(self, path, data=None, token="tok", rng=None):
        r = urllib.request.Request(self.c.base + path, data=data, method="POST" if data is not None else "GET")
        if token: r.add_header("Authorization", f"Bearer {token}")
        if rng: r.add_header("Range", rng)
        try:
            with urllib.request.urlopen(r) as x: return x.status, x.read()
        except urllib.error.HTTPError as e:
            with e: return e.code, e.read()

    def test_library_and_auth(self):
        self.assertEqual([p["id"] for p in self.c.library()], ["0100633007D48000"])
        self.assertEqual(self.raw("/v1/library", token=None)[0], 401)
        self.assertEqual(self.raw("/v1/library", token="wrong")[0], 401)
        self.assertEqual(self.raw("/v1/packs/half/index.tsv")[0], 404)
        self.assertEqual(self.raw("/v1/packs/..%2Flib/index.tsv")[0], 404)

    def test_only_indexed_paths(self):
        P = "/v1/packs/0100633007D48000"
        self.assertEqual(self.raw(P + "/tar", b"index.tsv\n")[0], 400)
        self.assertEqual(self.raw(P + "/tar", b"../../etc/passwd\n")[0], 400)
        self.assertEqual(self.raw(P + "/file/manifest.json")[0], 404)
        code, body = self.raw(P + "/file/exefs/main", rng="bytes=100-199")
        self.assertEqual((code, body), (206, self.files["exefs/main"][100:200]))

    def test_size_mismatch_409(self):
        (self.lib / "0100633007D48000/exefs/main").write_bytes(b"short")
        self.assertEqual(self.raw("/v1/packs/0100633007D48000/tar", b"exefs/main\n")[0], 409)

    def test_full_then_noop_then_delta(self):
        root = self.dev / "资源包"
        self.assertEqual(pull.pull(self.c, "0100633007D48000", root, say=self.say), 1)
        self.assertEqual(len(list((root / ".incoming").glob("*.tar"))), 1)
        self.assertNotEqual((root / "manifest.json").read_text(), "")
        untar_all(root)
        for k, v in self.files.items(): self.assertEqual((root / k).read_bytes(), v)
        self.assertEqual(pull.pull(self.c, "0100633007D48000", root, say=self.say), 0, "机上已应用的不再拉")
        self.files["shaders/lib.idx"] = b"idx2"; write_pack(self.lib / "0100633007D48000", self.files)
        pull.pull(self.c, "0100633007D48000", root, say=self.say)
        (t,) = (root / ".incoming").glob("*.tar")
        with tarfile.open(t) as tf: self.assertEqual(tf.getnames(), ["shaders/lib.idx"], "只拉变了的文件")

    def test_resume_partial_batch(self):
        root = self.dev / "资源包"; inc = root / ".incoming"; inc.mkdir(parents=True)
        rows = lp.parse_index((self.lib / "0100633007D48000/index.tsv").read_text(encoding="utf-8"))
        L = lp.TarLayout(rows); op = lambda p: open(self.lib / "0100633007D48000" / p, "rb")
        whole = b"".join(L.chunks(0, L.length, op))
        (inc / "1_000.tar.list").write_text("".join(f"{p}\t{n}\t{h}\n" for p, n, h in rows), encoding="utf-8")
        (inc / "1_000.tar.part").write_bytes(whole[:4000])   # 上次断在半路
        pull.pull(self.c, "0100633007D48000", root, say=self.say)
        self.assertEqual((inc / "1_000.tar").read_bytes(), whole)
        self.assertFalse((inc / "1_000.tar.list").exists())
        self.assertEqual(len(list(inc.glob("*.tar"))), 1, "续完不另开新批")

    def test_corrupt_part_rejected(self):
        root = self.dev / "资源包"; inc = root / ".incoming"; inc.mkdir(parents=True)
        rows = lp.parse_index((self.lib / "0100633007D48000/index.tsv").read_text(encoding="utf-8"))
        (inc / "1_000.tar.list").write_text("".join(f"{p}\t{n}\t{h}\n" for p, n, h in rows), encoding="utf-8")
        (inc / "1_000.tar.part").write_bytes(b"\xff" * 4000)   # 续传前半截是坏的
        with self.assertRaises(pull.Fail): pull.pull(self.c, "0100633007D48000", root, say=self.say)
        self.assertFalse((inc / "1_000.tar.part").exists())
        self.assertEqual((root / "manifest.json").read_text(), "", "没拉完清单保持空")
        pull.pull(self.c, "0100633007D48000", root, say=self.say)   # 重拉即好
        self.assertNotEqual((root / "manifest.json").read_text(), "")

    def test_image_direct(self):
        self.files["game.img"] = os.urandom(20000); write_pack(self.lib / "0100633007D48000", self.files)
        root = self.dev / "资源包"
        pull.pull(self.c, "0100633007D48000", root, say=self.say)
        self.assertEqual((root / "game.img").read_bytes(), self.files["game.img"])
        (t,) = (root / ".incoming").glob("*.tar")
        with tarfile.open(t) as tf: self.assertNotIn("game.img", tf.getnames(), "镜像不进 tar")
        self.assertEqual(self.raw("/v1/packs/0100633007D48000/tar", b"game.img\n")[0], 400)


if __name__ == "__main__":
    unittest.main(verbosity=1)
