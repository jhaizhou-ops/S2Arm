#!/usr/bin/env python3
# 门禁手动：要联网：调 OpenRouter Decisions API（要仓库外密钥），要传截图与回答路径
# 视觉驾驶员·Jev 后端（OpenRouter Decisions API，jhz 10-20 定用 Jev 本体）：python3 vision_jev.py <截图.png> <回答.json>
# 一次问三道选择题：按哪个键（选项 = 允许按键表）、按几下（1–5）、现在是否在游戏场景里直接操纵角色 / 载具（play）。
# 输出同 vision.sh：{"keys":[…],"playable":true|false,"p_play":0.93,"why":"…"}，退出码 0 = 拿到、把握够。
#   playable = p_play ≥ 0.5；自动玩家只在 playable 且宿主读数到场景量级时打 MARK（双证），模型不单独判过。
# 把握（confidence）< S2A_JEV_MIN_CONF（缺省 0.6）退出码 3（vision.sh 再问一次，仍不够就退到 claude CLI）。
# 选 TOUCH（这页要点触 / 指针，#196）：选择题给不出坐标，退出码 4，vision.sh 交 claude CLI 定坐标。
# 外发范围：只发这一张截图（游戏出图帧）+ 固定目标说明与选项表；不发游戏文件 / 存档 / prod.keys。密钥只从仓库外 ~/.s2arm/.secrets/openrouter.key 读，不打印、不写日志 / 局目录 / 命令行。每次调用的模型名、耗时、费用写 <回答.json>.log。
import base64, io, json, os, sys, time, urllib.error, urllib.request


def img_url(path):
    # Jev 只收边长 256–1568 的图（10-20 切主机档后截图 1920×1080，接口回 400「Invalid image dimensions」、否决题取不到值被放行）：长边超了就等比缩到 1568
    # 上传用 JPEG（质量 85、分辨率不变）：11-01 实测同一张 1280×589 截图 PNG 690 KB → JPEG 90 KB，Air 往返 3.5 → 2.3 秒、本机 1.7 → 1.2 秒，答案相同
    from PIL import Image
    im = Image.open(path)
    if max(im.size) > 1568: im.thumbnail((1568, 1568))
    b = io.BytesIO(); im.convert("RGB").save(b, "JPEG", quality=85)
    return "data:image/jpeg;base64," + base64.b64encode(b.getvalue()).decode()

png, out = sys.argv[1], sys.argv[2]
KEYS = {   # 选项名 → (自动玩家键名, 长按秒, 说明)
    "A": ("A", 0, "press A (confirm / OK / select the highlighted item; only when the highlighted item is the one you want — "
                  "on a Yes / No dialog with No highlighted, A just closes it)"),
    "HOLD_A": ("A", 2, "hold A for 2 seconds (hold-to-skip prompts)"),
    "B": ("B", 0, "press B (back / cancel / close a popup)"),
    "HOLD_B": ("B", 2, "hold B for 2 seconds (hold-to-skip prompts)"),
    "X": ("X", 0, "press X"), "Y": ("Y", 0, "press Y"),
    "PLUS": ("PLUS", 0, "press + (start / accept a default name / skip a story cutscene or opening movie: no HUD, characters talking or the camera moving on its own; if the screen already shows PAUSE, + closes it — then hold X instead)"), "MINUS": ("MINUS", 0, "press -"),
    "UP": ("UP", 0, "d-pad up (move the menu cursor up, e.g. from No to Yes on a stacked dialog)"), "DOWN": ("DOWN", 0, "d-pad down (move the menu cursor down)"),
    "LEFT": ("LEFT", 0, "d-pad left (move the cursor left, e.g. from No to Yes on a side-by-side Yes / No dialog)"), "RIGHT": ("RIGHT", 0, "d-pad right"),
    "L": ("L", 0, "press L"), "R": ("R", 0, "press R"), "ZL": ("ZL", 0, "press ZL"), "ZR": ("ZR", 0, "press ZR"),
    "L_R": ("L|R", 0, "press L and R at the same time (a 'press L + R' / 'L+R' prompt)"),
    "ZL_ZR": ("ZL|ZR", 0, "press ZL and ZR at the same time (a 'press ZL + ZR' / 'ZL+ZR' prompt)"),
    "HOLD_ZL": ("ZL", 2, "hold ZL for 2 seconds (a 'Hold ZL' prompt)"), "HOLD_ZR": ("ZR", 2, "hold ZR for 2 seconds (a 'Hold ZR' prompt)"),
    "HOLD_X": ("X", 2, "hold X for 2 seconds (a 'Hold X' prompt, or to skip a story cutscene when + only shows PAUSE)"), "HOLD_Y": ("Y", 2, "hold Y for 2 seconds (a 'Hold Y' prompt)"),
    "SCROLL_RS": ("RS_DOWN", 3, "hold the right stick down for 3 seconds (scroll a long text with a scrollbar to the bottom: its OK / Done button often does nothing until then)"),
    "SCROLL_DOWN": ("DOWN", 3, "hold d-pad down for 3 seconds (scroll a long text with a scrollbar to the bottom when the right stick does not scroll it)"),
    "TOUCH": (None, 0, "tap the touch screen (the screen asks to touch / tap, e.g. 'touch the screen in handheld mode', "
                       "or a pointer-only selection page that buttons do not move)"),
}
# S2A_VISION_TRIED=A[,…]：这些键在这一页上已经按过、页面没变——从选项里拿掉，题面也说明（否则模型每次仍答最像的 A）
TRIED = [k for k in os.environ.get("S2A_VISION_TRIED", "").split(",") if k]
# 按完整动作比（同 autoplay.c tried_add）：A 与长按 A（A:2）是两个选项
for k in [k for k, v in KEYS.items() if (v[0] and (f"{v[0]}:{v[1]}" if v[1] else v[0]) in TRIED) or (k == 'TOUCH' and 'TOUCH' in TRIED)]: del KEYS[k]   # 点触没反应过（TOUCH）也从选项里拿掉
# 导航规则只有一份：nav_rules.txt（vision.sh 升级后端读同一份）。11-02 nav1102r：规则原先只写在 vision.sh 中文题面，Jev 答了 75% 的问、看不到；
#   同 4 张卡点截图各问 3 次：泰拉瑞亚建角色页 B×3 → X×3，太鼓协议 R×3（切语言页签）→ RIGHT×2 R×1，银河2 暂停 / 确认框 A 不变
goal = "A Nintendo Switch game screenshot. You are a game tester. " + open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "nav_rules.txt")).read()
questions = {
    "key": {"type": "choice", "instructions": "Which controller input should be pressed next to progress toward gameplay?" + (f" Already tried on this screen with no effect: {', '.join(TRIED)} (do not choose them again; if it was A, the highlighted item cannot be confirmed, move the selection first)." if TRIED else ""),
            "criteria": {k: v[2] for k, v in KEYS.items()}},
    "times": {"type": "choice", "instructions": "How many times should that input be pressed in a row (e.g. moving a menu cursor several items)?",
              "criteria": {"1": "once", "2": "twice", "3": "three times", "4": "four times", "5": "five times"}},
    "play": {"type": "choice", "instructions": "Is the player directly controlling a character or vehicle inside the game world right now?",
             "criteria": {"YES": "yes: in-game, a playable character / vehicle is on screen in the game world (HUD may be present)",
                          "NO": "no: a menu, map / level / character selection, title screen, cutscene, loading screen, a pause screen (dimmed with PAUSE text or a pause menu), or the character is not visible"}}}
body = {"model": os.environ.get("S2A_JEV_MODEL", "~typesafe/jev-latest"),
        "state": [goal, {"type": "image_url", "image_url": {"url": img_url(png)}}],
        "questions": questions}
key = open(os.path.expanduser("~/.s2arm/.secrets/openrouter.key")).read().strip()
req = urllib.request.Request("https://openrouter.ai/api/alpha/decisions", data=json.dumps(body).encode(),
                             headers={"Authorization": "Bearer " + key, "Content-Type": "application/json"})
t0 = time.time()
try:
    r = json.load(urllib.request.urlopen(req, timeout=float(os.environ.get("S2A_VISION_TIMEOUT", 60))))
except urllib.error.HTTPError as e:
    if e.code == 402:   # 额度用完（11-02 jhz：不再充值、长期状态）：记共用标记，vision.sh / vision_or.py / quality_check.py 1 小时内都跳过 OpenRouter
        m = os.path.expanduser(os.environ.get("S2A_OR_402_MARK", "~/.cache/s2a/openrouter_402")); os.makedirs(os.path.dirname(m), exist_ok=True); open(m, "w").close()
    open(out + ".log", "a").write(f"Jev HTTP {e.code} {round(time.time() - t0, 2)} 秒：{e.read()[:200]!r}\n"); sys.exit(1)
except Exception as e:
    open(out + ".log", "a").write(f"Jev 失败 {round(time.time() - t0, 2)} 秒：{type(e).__name__}\n"); sys.exit(1)
dt = round(time.time() - t0, 2); a = r.get("answers") or {}; ka, ta = a.get("key") or {}, a.get("times") or {}
u = r.get("usage") or {}
pa = a.get("play") or {}; pr = pa.get("probabilities") or {}
p_play = float(pr.get("YES", 1.0 if pa.get("choice") == "YES" else 0.0))
choice, conf = ka.get("choice"), float(ka.get("confidence") or 0)
n = int(ta.get("choice") or 1) if str(ta.get("choice") or "1").isdigit() else 1
open(out + ".log", "a").write(f"Jev 模型 {r.get('model')} 供应 {r.get('provider')} {dt} 秒 费用 {u.get('cost', '?')} 美元；选 {choice} ×{n}，把握 {conf:.2f}；在场景里操纵的概率 {p_play:.2f}\n")
if choice not in KEYS: sys.exit(1)
k, hold, _ = KEYS[choice]
if k is None: sys.exit(4)   # TOUCH：坐标交 claude CLI
open(out + ".conf", "w").write(f"{conf:.4f}\n")   # vision.sh 两次里取把握高的那个
json.dump({"keys": [f"{k}:{hold}" if hold else k] * max(1, min(n, 5)), "conf": round(conf, 4), "playable": p_play >= 0.5, "p_play": round(p_play, 4),
           "why": f"Jev 选 {choice} ×{n}（把握 {conf:.2f}，次数把握 {float(ta.get('confidence') or 0):.2f}；可操控概率 {p_play:.2f}）"}, open(out, "w"), ensure_ascii=False)
sys.exit(0 if conf >= float(os.environ.get("S2A_JEV_MIN_CONF", 0.6)) else 3)
