# OpenRouter 额度用完（HTTP 402 / 回包写着余额不足）的共用标记：vision.sh / vision_or.py / vision_jev.py / tools/quality_check.py 都走这里。
# 永久跳过（11-04）：11-02 jhz 定 OpenRouter 不再充值，原先「1 小时过期再试」每小时白撞一次 402；现在标记一直有效，直到人工删标记或钥匙变了（换钥匙 = 充值 / 换号，自己恢复）。
# 标记内容 = 钥匙指纹（sha256 前 16 位，推不回钥匙）；空标记（11-04 前的旧格式）/ 指纹对不上 = 不算，再撞一次 402 就按新格式写上。403 不走这里（vision_or.py 一小时缓存照旧）
import hashlib, os, re

def _mark(): return os.path.expanduser(os.environ.get("S2A_OR_402_MARK", "~/.cache/s2a/openrouter_402"))
def _fp(key):
    if key is None:
        try: key = open(os.path.expanduser(os.environ.get("S2A_VISION_OR_KEY", "~/.s2arm/.secrets/openrouter.key"))).read()
        except OSError: return ""
    key = key.strip(); return hashlib.sha256(key.encode()).hexdigest()[:16] if key else ""
def blocked(key=None):   # key = 这次要用的钥匙原文；不给 = 读缺省钥匙文件
    f = _fp(key)
    try: return bool(f) and open(_mark()).read().strip() == f
    except OSError: return False
def mark(key=None):
    m = _mark(); os.makedirs(os.path.dirname(m), exist_ok=True); tmp = f"{m}.{os.getpid()}.tmp"
    open(tmp, "w").write(_fp(key) + "\n"); os.replace(tmp, m)
def is_quota(code, body=b""):   # 402，或别的码但回包写着额度 / 余额不足（OpenRouter 的 402 正文是「Insufficient credits」）
    t = body.decode("utf-8", "replace") if isinstance(body, bytes) else str(body or "")
    return code == 402 or re.search(r"insufficient[ _](credits|balance|quota)|余额不足|额度不足", t, re.I) is not None
