#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""局域网资源包服务（电脑端，只读）：把本机已出好的资源包借给同一局域网里的手机拉取，不用数据线。

只发「已出好的资源包」（目录里有 manifest.json + index.tsv，清单非空 = 包完整），只发 index.tsv 里登记的文件；
不碰游戏原文件、keys、存档。只回应局域网 / 本机地址，每次启动随机令牌，令牌不对一律 401。

  python3 tools/lan_pack_server.py <资源包库目录> [--host 0.0.0.0] [--port 47860] [--token T]
  资源包库目录：每个子目录一款（一键出包的 <款>资源包 目录原样放进去或软链进去）；子目录名就是包号。
  启动后打印配对串：s2arm-lan://<地址>:<端口>/?t=<令牌>，在手机端（或 tools/lan_pack_pull.py）填它。

接口（全部要 Authorization: Bearer <令牌>）：
  GET  /v1/library                         → {"schema":1,"packs":[{id,title,version,files,total,index_sha256}]}
  GET  /v1/packs/<包号>/manifest.json       原样
  GET  /v1/packs/<包号>/index.tsv           原样
  POST /v1/packs/<包号>/tar                 正文 = 要的路径（UTF-8，每行一个，须在 index.tsv 里）→ 确定性 pax tar，支持 Range 续传
  GET  /v1/packs/<包号>/file/<路径>         单个文件（单文件镜像直写用），支持 Range
文件大小与 index.tsv 对不上（正在出包）→ 409，客户端稍后重试。
"""
from __future__ import annotations

import argparse
import hmac
import ipaddress
import json
import os
import secrets
import socket
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import unquote

sys.path.insert(0, str(Path(__file__).resolve().parent))
import lan_pack as lp

PORT = 47860
MAX_BODY = 64 << 20   # 路径列表上限（几十万个文件也够）


class Library:
    def __init__(self, root):
        self.root = Path(root).resolve()

    def packs(self):
        out = []
        for d in sorted(self.root.iterdir() if self.root.is_dir() else []):
            m = self.manifest(d.name)
            if m: out.append(dict(id=d.name, title=d.name, version=m.get("version"), files=m.get("files"), total=m.get("total"), index_sha256=m.get("index_sha256")))
        return out

    def pack_dir(self, pid):
        if not pid or pid.startswith(".") or not lp.safe(pid) or "/" in pid: return None
        d = self.root / pid
        return d if d.is_dir() else None

    def manifest(self, pid):
        d = self.pack_dir(pid)
        if not d or not (d / "index.tsv").is_file(): return None
        try: m = json.loads((d / "manifest.json").read_text(encoding="utf-8"))
        except (OSError, ValueError): return None   # 没有 / 空清单 = 包不完整，不发
        return m if isinstance(m, dict) and m.get("version") in lp.VERSIONS else None

    def index(self, pid):
        return {p: (n, h) for p, n, h in lp.parse_index((self.pack_dir(pid) / "index.tsv").read_text(encoding="utf-8"))}


def lan_peer(addr):
    try: ip = ipaddress.ip_address(addr.split("%")[0])
    except ValueError: return False
    if getattr(ip, "ipv4_mapped", None): ip = ip.ipv4_mapped
    return ip.is_private or ip.is_loopback or ip.is_link_local


class Handler(BaseHTTPRequestHandler):
    server_version = "s2arm-lan/1"
    lib: Library
    token: str

    def log_message(self, fmt, *args):
        sys.stderr.write("%s %s\n" % (self.client_address[0], fmt % args))

    def send(self, code, body=b"", ctype="application/json; charset=utf-8", extra=()):
        if isinstance(body, str): body = body.encode()
        self.send_response(code); self.send_header("Content-Type", ctype); self.send_header("Content-Length", str(len(body)))
        for k, v in extra: self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD": self.wfile.write(body)

    def err(self, code, why): self.send(code, json.dumps({"error": why}, ensure_ascii=False))

    def gate(self):
        if not lan_peer(self.client_address[0]): self.err(403, "只回应局域网地址"); return False
        got = self.headers.get("Authorization", "")
        if not (got.startswith("Bearer ") and hmac.compare_digest(got[7:].encode(), self.token.encode())): self.err(401, "令牌不对"); return False
        return True

    def route(self):
        parts = self.path.split("?", 1)[0].split("/", 4)   # ['', 'v1', 'packs', id, rest]
        if len(parts) < 3 or parts[1] != lp.API: return None, None, None
        if parts[2] == "library" and len(parts) == 3: return "library", None, None
        if parts[2] == "packs" and len(parts) == 5: return "pack", unquote(parts[3]), unquote(parts[4])
        return None, None, None

    def do_GET(self):
        if not self.gate(): return
        kind, pid, rest = self.route()
        if kind == "library": return self.send(200, json.dumps({"schema": 1, "packs": self.lib.packs()}, ensure_ascii=False))
        if kind != "pack" or not self.lib.manifest(pid): return self.err(404, "没有这个资源包")
        d = self.lib.pack_dir(pid)
        if rest in ("manifest.json", "index.tsv"): return self.send(200, (d / rest).read_bytes(), "application/octet-stream")
        if rest.startswith("file/"):
            p = rest[5:]; want = self.lib.index(pid).get(p)
            if not want: return self.err(404, "索引里没有这个文件")
            return self.ranged(None, d, [(p, *want)], single=True)
        self.err(404, "没有这个接口")

    def do_POST(self):
        if not self.gate(): return
        kind, pid, rest = self.route()
        if kind != "pack" or rest != "tar" or not self.lib.manifest(pid): return self.err(404, "没有这个资源包")
        n = int(self.headers.get("Content-Length") or 0)
        if n <= 0 or n > MAX_BODY: return self.err(400, "路径列表为空或太大")
        idx = self.lib.index(pid); rows = []
        for p in self.rfile.read(n).decode("utf-8").splitlines():
            if not p: continue
            if p not in idx: return self.err(400, f"索引里没有：{p[:120]}")
            if lp.IMG.fullmatch(p): return self.err(400, f"单文件镜像不进 tar，用 file 接口：{p}")
            rows.append((p, *idx[p]))
        self.ranged(lp.TarLayout(rows), self.lib.pack_dir(pid), rows)

    def ranged(self, layout, d, rows, single=False):
        for p, size, _ in rows:   # 大小对不上 = 正在出包，别发半截
            try: ok = (d / p).stat().st_size == size
            except OSError: ok = False
            if not ok: return self.err(409, f"{p} 与索引不符（资源包可能正在更新），稍后重试")
        length = rows[0][1] if single else layout.length
        r = lp.parse_range(self.headers.get("Range"), length)
        if r == "bad": return self.send(416, extra=[("Content-Range", f"bytes */{length}")])
        a, b = r or (0, length)
        self.send_response(206 if r else 200)
        self.send_header("Content-Type", "application/x-tar" if not single else "application/octet-stream")
        self.send_header("Content-Length", str(b - a)); self.send_header("Accept-Ranges", "bytes")
        if r: self.send_header("Content-Range", f"bytes {a}-{b - 1}/{length}")
        self.end_headers()
        opener = lambda p: open(d / p, "rb")
        try:
            if single:
                with opener(rows[0][0]) as f:
                    f.seek(a); left = b - a
                    while left:
                        buf = f.read(min(1 << 20, left))
                        if not buf: break
                        self.wfile.write(buf); left -= len(buf)
            else:
                for buf in layout.chunks(a, b, opener): self.wfile.write(buf)
        except (BrokenPipeError, ConnectionResetError):
            pass   # 手机断开 / 切后台：客户端下次按 Range 续


def lan_addrs():
    out = set()
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.connect(("192.0.2.1", 9)); out.add(s.getsockname()[0]); s.close()   # 不真发包，只问路由选哪个网卡
    except OSError: pass
    return sorted(a for a in out if lan_peer(a)) or ["127.0.0.1"]


def make_server(root, host="0.0.0.0", port=PORT, token=None):
    h = type("H", (Handler,), {"lib": Library(root), "token": token or secrets.token_urlsafe(18)})
    return ThreadingHTTPServer((host, port), h), h.token


def main(argv=None):
    ap = argparse.ArgumentParser(description="局域网资源包服务（只读）")
    ap.add_argument("library"); ap.add_argument("--host", default="0.0.0.0"); ap.add_argument("--port", type=int, default=PORT); ap.add_argument("--token")
    a = ap.parse_args(argv)
    if not Path(a.library).is_dir(): print(f"【红】资源包库目录不存在：{a.library}"); return 2
    srv, tok = make_server(a.library, a.host, a.port, a.token)
    packs = srv.RequestHandlerClass.lib.packs()
    print(f"资源包 {len(packs)} 款：{', '.join(p['id'] for p in packs)[:200]}")
    for ip in lan_addrs(): print(f"配对串：s2arm-lan://{ip}:{srv.server_address[1]}/?t={tok}")
    try: srv.serve_forever()
    except KeyboardInterrupt: pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
