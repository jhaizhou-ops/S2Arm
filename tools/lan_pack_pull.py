#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""局域网拉取资源包（参考客户端）：手机端各外壳（iOS / Android / 鸿蒙）照这份实现，电脑上也可直接拿它把包拉到一个目录里核对。

  python3 tools/lan_pack_pull.py list <配对串>
  python3 tools/lan_pack_pull.py pull <配对串> <包号> <本机资源包根> [--full]
  配对串：tools/lan_pack_server.py 打印的 s2arm-lan://<地址>:<端口>/?t=<令牌>

写入口径与 tools/push_pack.py 相同（App 侧 runtime/src/pack_apply.c 不改）：
  ① 机上已有什么按 <资源包根>/index.applied.tsv 认（没有它、清单非空时退回 index.tsv）；sha 相同的文件不再要
  ② 开拉先把 manifest.json 置空（「清单读得出」= 这次传完整）；要传单文件镜像时先把 .applied 置空
  ③ 单文件镜像按 Range 拉到 <路径>.part，sha256 对了再改名到最终路径
  ④ 其余文件按 ≤1 GB 分批，每批向服务端要确定性 tar，拉到 .incoming/<时刻>_<序号>.tar.part（旁边 .list 记这批要了什么，断了下次按 Range 接着拉），
     拉完核 tar-ok 与每个文件的 sha256，再改名成 .tar（App 下次启动解开），批内文件记进 .pulled
  ⑤ 最后写 index.tsv、manifest.json
退出码：0 成功；1 失败（末行【红】说明）；2 用法
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
import tarfile
import time
import urllib.error
import urllib.request
from pathlib import Path
from urllib.parse import parse_qs, quote, urlsplit

sys.path.insert(0, str(Path(__file__).resolve().parent))
import lan_pack as lp

CHUNK = 1 << 20
RETRIES = 3


class Fail(Exception):
    pass


def parse_pairing(s):
    u = urlsplit(s)
    if u.scheme != "s2arm-lan" or not u.hostname or not u.port: raise Fail(f"配对串不对：{s}")
    tok = (parse_qs(u.query).get("t") or [""])[0]
    if not tok: raise Fail("配对串里没有令牌")
    host = f"[{u.hostname}]" if ":" in u.hostname else u.hostname
    return f"http://{host}:{u.port}", tok


class Client:
    def __init__(self, pairing, timeout=60):
        self.base, self.token = parse_pairing(pairing); self.timeout = timeout

    def req(self, path, data=None, rng=None):
        r = urllib.request.Request(self.base + path, data=data, method="POST" if data is not None else "GET")
        r.add_header("Authorization", f"Bearer {self.token}")
        if rng: r.add_header("Range", f"bytes={rng}-")
        try: return urllib.request.urlopen(r, timeout=self.timeout)
        except urllib.error.HTTPError as e:
            try: why = json.loads(e.read()).get("error")
            except ValueError: why = None
            raise Fail(f"服务端 {e.code}：{why or e.reason}") from None
        except OSError as e:
            raise Fail(f"连不上 {self.base}：{e}") from None

    def text(self, path): return self.req(path).read().decode("utf-8")

    def library(self): return json.loads(self.text(f"/{lp.API}/library"))["packs"]

    def fetch(self, path, dst, body=None, total=None, say=print):
        """拉到 dst（续传：dst 已有的字节按 Range 接着要）；返回最终大小"""
        dst = Path(dst)
        for attempt in range(RETRIES):
            have = dst.stat().st_size if dst.exists() else 0
            if total is not None and have == total: return have
            if total is not None and have > total: dst.unlink(); have = 0
            try:
                with self.req(path, body, rng=have or None) as r:
                    if have and r.status != 206: have = 0   # 服务端不给续传：从头来
                    with open(dst, "r+b" if have else "wb") as f:
                        f.seek(have); f.truncate()
                        while True:
                            buf = r.read(CHUNK)
                            if not buf: break
                            f.write(buf)
                n = dst.stat().st_size
                if total is None or n == total: return n
                say(f"  {dst.name} 只拉到 {n}/{total} 字节，接着拉")
            except (Fail, OSError) as e:
                if attempt == RETRIES - 1: raise Fail(str(e)) from None
                say(f"  {dst.name} 中断（{e}），{attempt + 1} 秒后接着拉"); time.sleep(attempt + 1)
        raise Fail(f"{dst.name} 拉不完整")


def sha_file(p):
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for b in iter(lambda: f.read(CHUNK), b""): h.update(b)
    return h.hexdigest()


def rows(text, n):
    out = {}
    for l in (text or "").splitlines():
        w = l.split("\t")
        if len(w) == n: out[w[0]] = w[-1]
    return out


def rd(p):
    try: return Path(p).read_text(encoding="utf-8")
    except OSError: return None


def verify_tar(path, want):
    """tar-ok + 每个条目路径 / 大小 / sha256 与要的一致（顺序也一致）"""
    if not lp.tar_ok(path): return "批不完整（tar-ok 不过）"
    got = []
    try:
        with tarfile.open(path, "r:") as t:
            for m in t:
                if not m.isreg(): return f"条目类型不对：{m.name}"
                h = hashlib.sha256()
                with t.extractfile(m) as f:
                    for b in iter(lambda: f.read(CHUNK), b""): h.update(b)
                got.append((m.name, m.size, h.hexdigest()))
    except tarfile.TarError as e:
        return f"批读不出（{e}）"
    return None if got == [tuple(w) for w in want] else "批内容与索引不符"


def plan(root, want, full):
    """→ (要的行, 仍有效的待续批 [(名字, 行)], 已拉未解的账)"""
    root = Path(root); inc = root / ".incoming"
    wanted = {p: (n, h) for p, n, h in want}
    if full: have = {}
    else:
        idx = rd(root / "index.applied.tsv")
        mf = rd(root / "manifest.json")
        if not idx and mf and mf.strip(): idx = rd(root / "index.tsv")
        have = rows(idx, 3)
    complete = sorted(p.name for p in inc.glob("*.tar") if lp.batch_name(p.name)) if inc.is_dir() else []
    for n in list(complete):
        if not lp.tar_ok(inc / n): (inc / n).write_bytes(lp.END); complete.remove(n)   # 残批用空包盖掉（同 push_pack ②）
    pulled = rows(rd(root / ".pulled"), 2) if complete else {}
    if not complete: (root / ".pulled").unlink(missing_ok=True)
    resume = []
    for lst in sorted(inc.glob("*.tar.list")) if inc.is_dir() else []:
        b = [tuple(w[:1]) + (int(w[1]), w[2]) for w in (l.split("\t") for l in lst.read_text(encoding="utf-8").splitlines()) if len(w) == 3]
        name = lst.name[:-5]
        if b and all(wanted.get(p) == (n, h) for p, n, h in b) and not full: resume.append((name, b))
        else: lst.unlink(); (inc / (name + ".part")).unlink(missing_ok=True)   # 服务端那份变了：作废
    acct = {**have, **pulled}
    inflight = {p for _, b in resume for p, _, _ in b}
    todo = [w for w in want if acct.get(w[0]) != w[2] and w[0] not in inflight]
    return todo, resume, pulled


def pull(client, pid, root, full=False, say=print):
    root = Path(root); inc = root / ".incoming"; inc.mkdir(parents=True, exist_ok=True)
    q = quote(pid, safe="")
    mf = client.text(f"/{lp.API}/packs/{q}/manifest.json"); ix = client.text(f"/{lp.API}/packs/{q}/index.tsv")
    if lp.json_version(mf) not in lp.VERSIONS: raise Fail(f"资源包清单版本 {lp.json_version(mf)} 不认")
    want = lp.parse_index(ix)
    todo, resume, _ = plan(root, want, full)
    direct = [w for w in todo if lp.IMG.fullmatch(w[0])]
    new = lp.batches([w for w in todo if not lp.IMG.fullmatch(w[0])])
    nbytes = sum(w[1] for w in todo) + sum(w[1] for _, b in resume for w in b)
    say(f"{pid}：要拉 {len(todo) + sum(len(b) for _, b in resume)} 个文件 {nbytes >> 20} MB（续 {len(resume)} 批 + 新 {len(new)} 批 + 镜像 {len(direct)} 个）")
    if todo or resume:
        (root / "manifest.json").write_bytes(b"")
    if direct:
        (root / ".applied").write_bytes(b"")
        for p, n, h in direct:
            part = root / (p + ".part"); part.parent.mkdir(parents=True, exist_ok=True)
            client.fetch(f"/{lp.API}/packs/{q}/file/{quote(p)}", part, total=n, say=say)
            if sha_file(part) != h: part.unlink(); raise Fail(f"{p} sha256 不对，已删掉，重拉即可")
            os.replace(part, root / p)
    ts = int(time.time())
    jobs = resume + [(f"{ts}_{k:03d}.tar", b) for k, b in enumerate(new)]
    for name, b in jobs:
        lst = inc / (name + ".list")
        if not lst.exists(): lst.write_text("".join(f"{p}\t{n}\t{h}\n" for p, n, h in b), encoding="utf-8")
        part = inc / (name + ".part")
        body = "".join(p + "\n" for p, _, _ in b).encode("utf-8")
        total = lp.TarLayout(b).length
        client.fetch(f"/{lp.API}/packs/{q}/tar", part, body=body, total=total, say=say)
        why = verify_tar(part, b)
        if why: part.unlink(); lst.unlink(); raise Fail(f"{name}：{why}，已删掉，重拉即可")
        os.replace(part, inc / name); lst.unlink()
        with open(root / ".pulled", "a", encoding="utf-8") as f: f.write("".join(f"{p}\t{h}\n" for p, _, h in b))
        say(f"  {name}：{len(b)} 个文件 {sum(w[1] for w in b) >> 20} MB")
    (root / "index.tsv").write_text(ix, encoding="utf-8", newline="")
    (root / "manifest.json").write_text(mf, encoding="utf-8", newline="")   # 清单最后写
    say(f"{pid}：拉完，App 下次启动时解开")
    return len(jobs)


def main(argv=None):
    ap = argparse.ArgumentParser(description="局域网拉取资源包（参考客户端）")
    sp = ap.add_subparsers(dest="cmd", required=True)
    a1 = sp.add_parser("list"); a1.add_argument("pairing")
    a2 = sp.add_parser("pull"); a2.add_argument("pairing"); a2.add_argument("pack"); a2.add_argument("root"); a2.add_argument("--full", action="store_true")
    a = ap.parse_args(argv)
    try:
        c = Client(a.pairing)
        if a.cmd == "list":
            for p in c.library(): print(f"{p['id']}\t{p['files']} 个文件\t{(p['total'] or 0) >> 20} MB")
        else:
            pull(c, a.pack, a.root, a.full)
        return 0
    except Fail as e:
        print(f"【红】{e}"); return 1


if __name__ == "__main__":
    sys.exit(main())
