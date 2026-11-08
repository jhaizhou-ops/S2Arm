#!/usr/bin/env python3
# 门禁手动：要联网：调 OpenRouter 对话接口（要仓库外密钥），要传截图与题面
# 视觉测试员·看图对话退路（只在 Mac 开发测试里用）：python3 vision_or.py <截图.png> <题面>  → 打印模型回答原文（vision.sh 照 claude CLI 的回答同样解析）
# vision.sh 在本机 claude CLI 不在或没登录时用它（10-26：Air / mini 上远端局用假家目录、ssh 会话拿不到钥匙串，claude CLI 报「Not logged in」，
#   升级那一问整个白丢）。走 OpenRouter 的对话接口，与 Jev 同一把钥匙（~/.s2arm/.secrets/openrouter.key，不打印、不写日志）。
# 顺序见下面「唯一顺序」（OpenRouter → 中转站 → OpenRouter 其余，S2A_VISION_OR_MODELS 逗号分隔），任何一档失败落下一档：Air 直连外网时 Anthropic / Google / OpenAI 都回 403（10-26 实测，本机走代理才通），
#   月之暗面 kimi-k3 直连能通；三张真截图（银河 2 存档页、创建游戏文件框、暗黑3 选难度）kimi-k3 答 TOUCH:343,420 / TOUCH:820,558 / A，与路线实测一致
import base64, io, json, os, sys, time, urllib.error, urllib.request

png, prompt = sys.argv[1], sys.argv[2]
# 外发范围（11-01 总指挥核）：每次只发这一张截图（游戏出图帧，转 JPEG）+ 题面文字；不发游戏文件 / 存档 / prod.keys / 局目录其他内容。
# 密钥只从仓库外 ~/.s2arm/.secrets/openrouter.key 读，只进请求头；不打印、不写日志 / 局目录 / 命令行。按量计费：每次把 OpenRouter 回的费用与 token 写 stderr（进 <回答.json>.err）
try: key = open(os.path.expanduser(os.environ.get("S2A_VISION_OR_KEY", "~/.s2arm/.secrets/openrouter.key"))).read().strip()   # S2A_VISION_OR_KEY / _RELAY_KEY / _OR_URL / _RELAY_URL 只给单测指到假服务
except OSError: key = ""   # 没有 OpenRouter 钥匙：OpenRouter 各档不问（快档只问中转站，不该因为缺这把钥匙起不来）
# 上传用 JPEG（质量 85、分辨率不变；同 vision_jev.py：PNG 690 KB → 90 KB，Air 往返省约 1.2 秒）
from PIL import Image
b = io.BytesIO(); Image.open(png).convert("RGB").save(b, "JPEG", quality=85)
img = "data:image/jpeg;base64," + base64.b64encode(b.getvalue()).decode()
TO = float(os.environ.get("S2A_VISION_TIMEOUT", 90))
# 模型请求代理（11-01 总指挥：Air 直连外网时 Anthropic 回 403、只能退 kimi，单问 20~48 秒吃光局时）：S2A_VISION_PROXY=http://127.0.0.1:18118（Air 上是本机 ssh 反向隧道的出口；8118 被 Air 自己的代理占了，11-01 运维线改端口）只用于这一个请求进程，
#   其它进程不走代理；代理连不上（隧道断）立刻退回直连。只作用于 OpenRouter 档
PROXY = os.environ.get("S2A_VISION_PROXY", "").strip()
used = {"px": PROXY}   # 这次请求实际走的路：代理不通退回直连后，403 要记在直连那份缓存下（不然隧道恢复后走代理也跳过 sonnet）
def ask_or(m):   # OpenRouter：回 (回答, 日志两行)
    body = {"model": m, "max_tokens": 2000, "reasoning": {"effort": "low"}, "usage": {"include": True},   # 推理模型 400 个输出额度会被思考用完、正文为空
            "messages": [{"role": "user", "content": [{"type": "image_url", "image_url": {"url": img}}, {"type": "text", "text": prompt}]}]}
    def fetch(px):
        req = urllib.request.Request(os.environ.get("S2A_VISION_OR_URL", "https://openrouter.ai/api/v1/chat/completions"), data=json.dumps(body).encode(),   # 每次新建：走代理会改写 Request 的主机，重试直连不能复用
                                     headers={"Authorization": "Bearer " + key, "Content-Type": "application/json"})
        op = urllib.request.build_opener(urllib.request.ProxyHandler({"https": px, "http": px})) if px else urllib.request.build_opener()   # 直连 = 原行为（仍认环境里的 HTTPS_PROXY）
        return json.load(op.open(req, timeout=TO))
    try: r = fetch(PROXY)
    except urllib.error.HTTPError: raise
    except (urllib.error.URLError, OSError) as e:   # 代理连不上（隧道断）→ 直连重试一次
        if not PROXY: raise
        print(f"代理 {PROXY} 不通（{e}），退回直连", file=sys.stderr); used["px"] = ""; r = fetch("")
    u = r.get("usage") or {}
    return r["choices"][0]["message"]["content"] or "", f"模型 {m}", f"费用 {u.get('cost', '?')} 美元 输入 {u.get('prompt_tokens', '?')} 输出 {u.get('completion_tokens', '?')} token"
def post(url, rk, m, text):
    body = {"model": m, "max_tokens": 2000, "messages": [{"role": "user", "content": [{"type": "image_url", "image_url": {"url": img}}, {"type": "text", "text": text}]}]}
    req = urllib.request.Request(url, data=json.dumps(body).encode(), headers={"Authorization": "Bearer " + rk, "Content-Type": "application/json"})
    return json.load(urllib.request.build_opener(urllib.request.ProxyHandler({})).open(req, timeout=TO))
# 中转站长尾（11-03 普查读数：中位 7 秒，但 19:30–21:20 一段 13% 的问 ≥ 30 秒、最长 67 秒，单次调用本身慢——不是并发 / 渠道 / 机器，Air 与本机一样）：
#   发出 S2A_VISION_RELAY_HEDGE 秒（缺省 15，约中位 2 倍）还没回，同题再发一份，谁先回用谁；两份都失败才算失败。线程设成守护线程：先回的那份用完就退出，不等慢的那份
def hedged(call, text):
    import queue, threading
    q = queue.Queue(); hedge = float(os.environ.get("S2A_VISION_RELAY_HEDGE", 15))
    def run(t): 
        try: q.put((True, call(t)))
        except Exception as e: q.put((False, e))
    threading.Thread(target=run, args=(text,), daemon=True).start(); live, sent2 = 1, False
    deadline = time.time() + TO
    while True:
        try: ok, v = q.get(timeout=max(0.1, (min(hedge, TO) if not sent2 else deadline - time.time())))
        except queue.Empty:
            if not sent2: print(f"中转站 {hedge:g} 秒没回，同题再发一份（谁先回用谁）", file=sys.stderr); threading.Thread(target=run, args=(f"{text}\n（并发请求 {os.getpid()}-h）",), daemon=True).start(); sent2 = True; live += 1; continue
            raise TimeoutError(f"中转站 {TO:g} 秒没回")
        if ok: return v
        live -= 1
        if live == 0: raise v
def ask_relay(m):   # 自建 OpenAI 兼容中转站（地址 S2A_VISION_RELAY_URL，不走代理；没设地址 = 这一档失败）；钥匙 ~/.s2arm/.secrets/relay.key 只进请求头，不打印；没钥匙 = 这一档失败
    if not os.environ.get("S2A_VISION_RELAY_URL"): raise RuntimeError("没设 S2A_VISION_RELAY_URL，中转站这一档跳过")
    rk = open(os.path.expanduser(os.environ.get("S2A_VISION_RELAY_KEY", "~/.s2arm/.secrets/relay.key"))).read().strip()
    # 中转站会丢图（11-02 OpenRouter 402 期间全线退到这一档）：同一张截图，短题面每次都带图；整段驾驶员题面（约 5 KB）大多只计约 1400 个输入 token、
    #   模型回「未收到截图」或瞎猜，8 次里只有 2 次带图，换 Anthropic 原生接口 / 规则放 system / 文字在前都一样。我方改不了中转站，按回的输入 token 判：
    #   不到「题面字节 ÷ 3.5 + 500」（本图 1280×589 约 1000 个图片 token）就当丢图，题面尾加请求号再问，最多 S2A_VISION_RELAY_TRIES 次（缺省 4），
    #   仍丢图就算这一档失败、落下一档（最后由 vision.sh 退本机 claude CLI，CLI 直接内联图片）
    url = os.environ["S2A_VISION_RELAY_URL"]; est = len(prompt.encode()) / 3.5 + 500
    tries = int(os.environ.get("S2A_VISION_RELAY_TRIES", "2"))
    for t in range(tries):
        text = prompt if t == 0 else f"{prompt}\n（请求号 {os.getpid()}-{t}）"
        body = {"model": m, "max_tokens": 2000, "messages": [{"role": "user", "content": [{"type": "image_url", "image_url": {"url": img}}, {"type": "text", "text": text}]}]}
        r = hedged(lambda txt: post(url, rk, m, txt), text)
        u = r.get("usage") or {}; pt = u.get("prompt_tokens")
        if isinstance(pt, (int, float)) and pt < est:
            print(f"中转站 {m} 输入只有 {pt} 个 token（带图应 ≥ {est:.0f}），判丢图，第 {t + 1} / {tries} 次", file=sys.stderr); continue
        return r["choices"][0]["message"]["content"] or "", f"模型 中转站/{m}", f"输入 {pt if pt is not None else '?'} 输出 {u.get('completion_tokens', '?')} token"
    raise RuntimeError(f"中转站丢图 {tries} 次")
# 唯一顺序（11-02 jhz：OpenRouter 不再充值，中转站做主力、本机 claude CLI 兜底）：中转站 → OpenRouter 各模型（1 小时内回过 402 就整档跳过，见 OR402）→ 都失败退出非 0（有中转站钥匙的机器 vision.sh 不再退 CLI：CLI 配的是同一个中转站）。
#   中转站模型 claude-sonnet-5（11-02 实测：同一张真截图 + 整段驾驶员题面，claude-sonnet-5-5 只有约 30% 带图、和题面长短 / 并发 / 消息结构都无关，
#   claude-sonnet-5 / claude-opus-5-5 / gemini-3.8-flash 全带图；sonnet-5 两张图各 10 次 20/20 答对、每问约 5 秒）。丢图判据仍留着兜底。任何一档失败（HTTP 错 / 网络 / 超时 / 没钥匙 / 空回答 / 丢图）落下一档。
ors = os.environ.get("S2A_VISION_OR_MODELS", "anthropic/claude-sonnet-5.5,moonshotai/kimi-k3").split(",")
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__))); import or402   # 402 / 余额不足标记（vision_jev.py / quality_check.py 共用）：永久跳过，直到删标记或换钥匙
# S2A_VISION_RELAY_ONLY=1（vision.sh 快档）：只问中转站这一个模型，失败就失败，由 vision.sh 升级到中转站 sonnet
or_ok = bool(key) and not or402.blocked(key) and not os.environ.get("S2A_VISION_RELAY_ONLY")
chain = [("relay", os.environ.get("S2A_VISION_RELAY_MODEL", "claude-sonnet-5"))] + ([("or", m) for m in ors] if or_ok else [])
# 这条网络上回过 HTTP 403 的档跳过（11-01 普查：Air 直连每次升级都先请求 sonnet 吃 403，145 次白跑一趟）：缓存只记 403 的「档:模型」，
#   按「走代理 / 直连」分开存（隧道通了用另一份、照常先试 sonnet）。超时 / 网络抖动这类偶发失败不记——记「上次成功」会把偶发一次落到慢档后永远先问慢档
def cache(px): return os.path.expanduser("~/.cache/s2a/vision_or_403" + ("_px" if px else ""))
# 每条记「档:模型<TAB>记下时刻」，一小时后作废：网络变了（11-01 jhz 给 Air 开 VPN，直连 sonnet 就通）自己恢复，不用人去清缓存
import time
def load(f):
    try: return {a: float(t) for a, _, t in (l.strip().partition("\t") for l in open(f) if l.strip()) if t and time.time() - float(t) < 3600}
    except (OSError, ValueError): return {}
blocked = set(load(cache(PROXY)))
if any(f"{k}:{m}" not in blocked for k, m in chain): chain = [c for c in chain if f"{c[0]}:{c[1]}" not in blocked]
def block(c):   # 记在这次实际走的那条路的缓存下
    f = cache(used["px"]); cur = load(f); cur[c] = time.time()
    try:   # 先写临时文件再改名：同机并发局不读到半份
        os.makedirs(os.path.dirname(f), exist_ok=True); tmp = f"{f}.{os.getpid()}.tmp"; open(tmp, "w").write("".join(f"{x}\t{t:.0f}\n" for x, t in sorted(cur.items()))); os.replace(tmp, f)
    except OSError: pass
for i, (kind, m) in enumerate(chain):
    try: out, l1, l2 = (ask_relay if kind == "relay" else ask_or)(m)
    except Exception as e:
        print(f"{'中转站' if kind == 'relay' else 'OpenRouter'} {m} 失败（{type(e).__name__}{' HTTP %d' % e.code if isinstance(e, urllib.error.HTTPError) else ''}），换下一档", file=sys.stderr)
        if isinstance(e, urllib.error.HTTPError) and e.code == 403: block(f"{kind}:{m}")
        if isinstance(e, urllib.error.HTTPError) and kind == "or" and or402.is_quota(e.code, e.read() if e.fp else b""):   # 额度用完是整把钥匙的事：记永久标记、后面的 OpenRouter 模型不再白问
            or402.mark(key); chain[i + 1:] = [c for c in chain[i + 1:] if c[0] != "or"]
        if i + 1 < len(chain): continue
        raise
    if not out.strip():
        print(f"{'中转站' if kind == 'relay' else 'OpenRouter'} {m} 回答为空，换下一档", file=sys.stderr)
        if i + 1 < len(chain): continue
    print(l1, file=sys.stderr); print(l2, file=sys.stderr)
    print(out); break
