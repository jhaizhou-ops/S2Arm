#!/bin/bash
# 源码包共用下载 + 按 SHA 的共享缓存单测（android/tools/fetch_source.sh；离线：本机起假源，约 15 秒）：bash tests/fetch_source_test.sh
# 全程清掉代理环境（HTTPS_PROXY / HTTP_PROXY / ALL_PROXY 及小写、NO_PROXY），只用 127.0.0.1 假源与不可达地址。期望（按构造手写）：
# ① 缓存命中：下载源指向不可达地址、curl / gh 换成「一调就记账」的桩 → 打印缓存路径、桩一次没被调；codec_prepare 照样把源码放进 codecs/sources（准备步骤走完）
# ② 缓存里同名文件 SHA 不对 → 从假源重下、落位后内容 = 假源字节、目录里不留临时文件
# ③ 假源发 5 字节后挂住、无进展上限 2 秒 → 不早于 2 秒、假源还挂着（没自己收尾）就红「下载无进展」、点名 URL、缓存里没有成品也没有临时文件
# ④ 假源每 0.5 秒滴 1 字节（一直有进展）、整体上限 3 秒 → 不早于 3 秒、假源还在滴就红「整体超时」
#   ③④ 按事件判、不设墙钟上限（11-03 mini 无缓存全套负载高，③ 用了 9 秒 > 8 假红）：假源挂满 / 滴完才写 <名>.served，返回时没有它 = 是看守杀的、不是等假源收尾
# ⑤ 假源下来的字节 SHA 不符 → 红「sha256 不符」、不落位；⑥ 404 → 红「下载失败」带 URL；⑦ 不可达地址、缓存未命中 → 红「下载失败」且原因是 curl 自己的退出码（连不上就退），不是看守的整体超时 / 无进展
# ⑧ github.com 地址（gh / curl 都是桩，不联网）：gh 成功 → 落位、curl 没被调；gh 失败 → 退到 curl，两次原因都写进红行
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); bad=0; srv=
trap '[ -n "$srv" ] && kill "$srv" 2> /dev/null; rm -rf "$T"' EXIT
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
export LC_ALL=en_US.UTF-8   # UTF-8 locale 下 bash 把紧跟 $变量名 的中文字节当成名字的一部分（11-01 实踩 name\xef: unbound variable；C locale 不犯，所以这里钉 UTF-8）
unset HTTPS_PROXY HTTP_PROXY ALL_PROXY NO_PROXY https_proxy http_proxy all_proxy no_proxy
export S2A_BUILD_CACHE=$T/cache
. "$H/android/tools/fetch_source.sh"
sha() { shasum -a 256 "$1" | cut -d' ' -f1; }

# 假源：/ok 发固定字节；/stall 发 5 字节后挂住；/trickle 每 0.5 秒 1 字节；其余 404
cat > $T/srv.py <<'EOF'
import http.server, os, socketserver, sys, time
D = os.path.dirname(sys.argv[1])
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        if self.path == '/ok.tar.gz':
            body = b'fixture source bytes\n'
            self.send_response(200); self.send_header('Content-Length', str(len(body))); self.end_headers(); self.wfile.write(body); return
        if self.path in ('/stall.tar.gz', '/trickle.tar.gz'):
            self.send_response(200); self.send_header('Content-Length', '100000'); self.end_headers()
            try:
                if self.path == '/stall.tar.gz':
                    self.wfile.write(b'12345'); self.wfile.flush(); time.sleep(60)
                else:
                    for _ in range(120):
                        self.wfile.write(b'x'); self.wfile.flush(); time.sleep(0.5)
            except OSError: return   # 客户端先断（看守杀了下载）
            open(os.path.join(D, self.path[1:] + '.served'), 'w').close()   # 假源自己挂满 60 秒 / 滴完才写
            return
        self.send_response(404); self.end_headers()
class S(http.server.ThreadingHTTPServer):
    def server_bind(self):   # 不调 getfqdn：mini 反查 127.0.0.1 卡 20 秒以上
        socketserver.TCPServer.server_bind(self); self.server_name, self.server_port = self.server_address[:2]
s = S(('127.0.0.1', 0), H); s.daemon_threads = True
with open(sys.argv[1], 'w') as f: f.write(str(s.server_address[1]))
s.serve_forever()
EOF
python3 -I $T/srv.py $T/port & srv=$!
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do [ -s $T/port ] && break; sleep 0.2; done
P=$(cat $T/port 2> /dev/null); B=http://127.0.0.1:$P
[ -n "$P" ] || { echo "假源没起来：20 次 × 0.2 秒内没拿到端口"; exit 1; }
printf 'fixture source bytes\n' > $T/ok.bytes; OK=$(sha $T/ok.bytes)
DEAD=http://127.0.0.1:9/never.tar.gz   # discard 端口，本机不监听 → 连接被拒

# ① 缓存命中：不发起任何下载
mkdir -p $T/bin "$S2A_BUILD_CACHE/sources/$OK"; cp $T/ok.bytes "$S2A_BUILD_CACHE/sources/$OK/hit.tar.gz"
for c in curl gh wget; do printf '#!/bin/sh\necho "$0 $*" >> %s/net.log\nexit 7\n' "$T" > $T/bin/$c; chmod +x $T/bin/$c; done
o=$(PATH=$T/bin:$PATH s2a_source_fetch hit.tar.gz "$DEAD" "$OK" 2> $T/e1); r=$?
ck "① 缓存命中：打印缓存路径、没调任何下载命令（rc=${r}）" '[ $r = 0 ] && [ "$o" = "$S2A_BUILD_CACHE/sources/$OK/hit.tar.gz" ] && [ ! -e $T/net.log ]'
o=$(PATH=$T/bin:$PATH bash -c 'set -euo pipefail; . "$1/platforms/android/tools/ndk_toolchain.sh"; . "$1/platforms/android/tools/fetch_source.sh"; . "$1/platforms/android/codecs/cache.sh"; cache_root=$2; codec_prepare hit.tar.gz "$3" "$4"; codec_source "$4"' _ "$H" $T/codec "$DEAD" "$OK" 2> $T/e1b); r=$?
ck "① 无代理 + 源不可达 + 缓存命中：codec_prepare 走完、codecs/sources 里是同一份字节、没联网（rc=${r}）" '[ $r = 0 ] && cmp -s "$o" $T/ok.bytes && [ "$o" = "$T/codec/codecs/sources/$OK.tar.gz" ] && [ ! -e $T/net.log ]'
[ $r = 0 ] || cat $T/e1b

# ② 缓存里 SHA 不对 → 重下替换
mkdir -p "$S2A_BUILD_CACHE/sources/$OK"; printf corrupt > "$S2A_BUILD_CACHE/sources/$OK/ok.tar.gz"
o=$(s2a_source_fetch ok.tar.gz "$B/ok.tar.gz" "$OK" 2> $T/e2); r=$?
ck "② SHA 不对：重下、落位内容 = 假源字节、不留临时文件（rc=${r}）" '[ $r = 0 ] && cmp -s "$o" $T/ok.bytes && [ "$(ls -A "$S2A_BUILD_CACHE/sources/$OK" | grep -c "^\.")" = 0 ] && grep -q "校验不过，重新下载" $T/e2'

# ③ 挂住：无进展判挂死
S1=$(printf a | shasum -a 256 | cut -d' ' -f1); t0=$SECONDS
o=$(S2A_FETCH_STALL_SECS=2 S2A_FETCH_MAX_SECS=60 s2a_source_fetch stall.tar.gz "$B/stall.tar.gz" "$S1" 2> $T/e3); r=$?; dt=$((SECONDS - t0))
ck "③ 发 5 字节后挂住：假源还挂着就红「下载无进展」、点名 URL（用时 ${dt} 秒、假源收尾了：$([ -e $T/stall.tar.gz.served ] && echo 是 || echo 否)、rc=${r}）" '[ $r != 0 ] && [ $dt -ge 2 ] && [ ! -e $T/stall.tar.gz.served ] && grep -q "【红】下载无进展 $B/stall.tar.gz" $T/e3 && grep -q "2 秒没收到新字节（已收 5 字节）" $T/e3'
ck "③ 挂死后缓存里没有成品、没有临时文件" '[ -z "$(ls -A "$S2A_BUILD_CACHE/sources/$S1" 2> /dev/null)" ]'

# ④ 一直有进展但超过整体上限
t0=$SECONDS
o=$(S2A_FETCH_STALL_SECS=30 S2A_FETCH_MAX_SECS=3 s2a_source_fetch trickle.tar.gz "$B/trickle.tar.gz" "$S1" 2> $T/e4); r=$?; dt=$((SECONDS - t0))
ck "④ 每 0.5 秒 1 字节：假源还在滴就红「整体超时」（用时 ${dt} 秒、假源滴完了：$([ -e $T/trickle.tar.gz.served ] && echo 是 || echo 否)、rc=${r}）" '[ $r != 0 ] && [ $dt -ge 3 ] && [ ! -e $T/trickle.tar.gz.served ] && grep -q "整体超时：3 秒" $T/e4 && grep -q "$B/trickle.tar.gz" $T/e4'

# ⑤ SHA 不符不落位
o=$(s2a_source_fetch ok.tar.gz "$B/ok.tar.gz" "$S1" 2> $T/e5); r=$?
ck "⑤ 下来的字节 SHA 不符：红、不落位（rc=${r}）" '[ $r != 0 ] && grep -q "sha256 不符" $T/e5 && [ -z "$(ls -A "$S2A_BUILD_CACHE/sources/$S1" 2> /dev/null)" ]'

# ⑥ 404
o=$(s2a_source_fetch none.tar.gz "$B/none.tar.gz" "$S1" 2> $T/e6); r=$?
ck "⑥ 404：红「下载失败」带 URL（rc=${r}）" '[ $r != 0 ] && grep -q "【红】下载失败 $B/none.tar.gz" $T/e6'

# ⑦ 无代理、源不可达、缓存未命中：明确报红不挂住
t0=$SECONDS
o=$(S2A_FETCH_STALL_SECS=5 S2A_FETCH_MAX_SECS=8 s2a_source_fetch never.tar.gz "$DEAD" "$S1" 2> $T/e7); r=$?; dt=$((SECONDS - t0))
ck "⑦ 不可达 + 未命中：红「下载失败」、原因是 curl 自己退出（不是看守杀的；用时 ${dt} 秒、rc=${r}）" '[ $r != 0 ] && grep -q "【红】下载失败 ${DEAD}：curl：curl 退出码 [0-9]" $T/e7'

# ⑧ github.com：先 gh api、失败退 curl
GH=https://github.com/example/fixture/archive/v1.tar.gz
mkdir -p $T/gh; printf '#!/bin/sh\necho "gh $*" >> %s/gh.log\n[ "$1 $2" = "api %s" ] && [ -z "${GH_FAIL:-}" ] && { cat %s; exit 0; }\necho gh-broken >&2; exit 4\n' "$T" "$GH" "$T/ok.bytes" > $T/gh/gh
printf '#!/bin/sh\necho "curl $*" >> %s/gh.log\necho curl-broken >&2; exit 6\n' "$T" > $T/gh/curl; chmod +x $T/gh/gh $T/gh/curl
o=$(PATH=$T/gh:$PATH s2a_source_fetch gh.tar.gz "$GH" "$OK" 2> $T/e8); r=$?
ck "⑧ github 地址走 gh api：落位、curl 没被调（rc=${r}）" '[ $r = 0 ] && cmp -s "$o" $T/ok.bytes && grep -q "^gh api $GH" $T/gh.log && ! grep -q "^curl" $T/gh.log'
o=$(PATH=$T/gh:$PATH GH_FAIL=1 s2a_source_fetch gh2.tar.gz "$GH" "$OK" 2> $T/e8b); r=$?
ck "⑧ gh 失败退 curl：两次原因都在红行（rc=${r}）" '[ $r != 0 ] && grep -q "^curl .*$GH" $T/gh.log && grep -q "【红】下载失败 ${GH}：gh api：.*gh-broken.*curl：.*curl-broken" $T/e8b'

[ $bad = 0 ] && echo "fetch_source 单测全过" || { for f in $T/e*; do echo "== $f"; cat "$f"; done; echo "fetch_source 单测有不通"; exit 1; }
