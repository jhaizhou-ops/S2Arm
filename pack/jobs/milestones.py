"""准备任务的里程碑进度（jhz 10-23：一个进度条标出各里程碑、当前阶段在做什么、已用时间、预计还需多久）。

- 计划：开始时发一个 plan 事件，列出全部里程碑（名称、作用、预计秒数）；之后每个事件带当前里程碑 id。
- 预计秒数只来自本机实测（jhz 10-25「不是即时计算或者假设写死的数字都改」）：每次成功按里程碑记一行到 <私有目录>/stats/prepare.jsonl
  （带任务种类：Mac 打包 build / 打 iPhone 包 ipa、ipa_dual，各算各的），按游戏体积换算取中位数；本机没有这一种任务的记录就不给预计
  （expected = None、source = none）。原先的缺省值是别的游戏、别的流程的旧实测（10-23 奥德赛 / 10-24 动森），Hades 6.2 GB 按它算出 70 分钟、
  实际 100 秒就到最后一步，不再用。
- 复用与冷做分开记、分开估（11-07：Hades 热出包 macOS 显示预计 11 分钟、实际 49 秒——命中缓存的步按冷出包的历史算）：后端知道某一步会复用缓存
  （共用解包快照对得上、这一份产物根以同样的代码与输入出成过）就标「复用」（reuse(c, 步)），能在开工前判就在发计划前判，判不了的在这一步开始、
  知道的那一刻改标并重发计划（同一组步、界面不清已用时间）；复用步只按本机复用时的记录估，没有就按 0 秒计，不拿冷记录顶。
  成功时历史这一行带 reused（复用了哪几步），冷步、复用步各自只用各自的记录。老记录没有 reused，一律当冷记录。
- 着色器阶段内部再分几步；进度不靠改 shader_pack.sh（它的内容进着色器缓存键，改它九款全要重烘），
  而是在它运行时数工作目录里的文件：已编 .air / .metal、已出管线分片 / 分片总数、已出函数体动态库 / 源码数，得到真实的完成数与总数。
"""
from __future__ import annotations
import json
import os
import re
from pathlib import Path
import statistics
import threading
import time

MILESTONES = [
    # id, 名称, 作用说明, 是否随体积缩放（本机历史按游戏体积换算）
    ("unpack", "解包", "用你的密钥解出游戏程序和资源，合并更新与 DLC。", True),
    ("rewrite", "改写游戏代码", "把 Switch 的 ARM 程序改写成能在苹果设备上直接运行的形式。", False),
    ("sysdata", "系统数据", "准备字体、时区等 Switch 系统数据。", False),
    ("index", "资源索引", "给游戏资源建索引，运行时读取更快。", True),
    # 打 iPhone 包的「④ 刷新」前段（pack/refresh.sh：改写 ‖ 系统数据 ‖ 宽屏布局 ‖ 追加内容 → 直连配置推导 → RomFS 索引 → 抽取着色器），到着色器开烘为止
    ("refresh", "改写与准备资源", "改写游戏代码，准备系统数据、宽屏布局、追加内容和资源索引；出直连包时还会推导直连配置、抽出着色器。", False),
    ("sh_extract", "找出着色器", "从游戏文件里找出全部着色器程序（决定画面怎么画的小程序）。", True),
    ("sh_translate", "翻译着色器", "把 Switch 的着色器翻译成苹果设备能用的 Metal 着色器。", True),
    ("sh_compile", "编译着色器", "提前把着色器编好，进游戏时不用临时编译，避免卡顿。", True),
    ("sh_pipeline", "预建渲染管线", "把会用到的画面组合提前建好，第一次遇到也不卡。", True),
    ("sh_link", "备用快速版本", "为极少数没预建到的画面准备一个能立即顶上的版本。", True),
    ("host", "准备游戏程序", "准备在 Mac 上运行这款游戏的主程序。", False),
    ("install", "安装并校验", "把准备好的文件装进游戏库，并逐个校验。", True),
    ("direct", "直连着色器库", "按游戏文件出直连着色器库，与通用兜底着色器同时进行。", True),
    ("ipa", "编 App 与签名", "编出 iPhone 版程序、签名，并打好要拷进手机的资源包。", False),
]
# 各种任务的里程碑（与现行流程逐段对上）：
# - build：Mac 打包兼容模式（S2A_DUAL=0，只出通用，同样走 pack/refresh.sh），通用着色器全量（含管线归档、函数体动态库）
# - build_dual：Mac 打包缺省（直连单轨，10-30 jhz；pack/refresh.sh S2A_PACK_PLAT=macos，同一键出包 --target mac）
# - ipa：打 iPhone 包兼容模式（S2A_DUAL=0，只出通用）：refresh.sh 跑全量通用着色器，五段都有
# - ipa_dual：打 iPhone 包缺省（直连单轨，pack/oneclick/oneclick.sh）：refresh.sh 出直连库，着色器阶段只记键（不抽取 / 不翻译 / 不编译 / 不预建管线），
#   所以计划里没有通用的四段着色器步骤。直连做不成任务报红、不退成通用（10-30 jhz）
PLANS = {"build": ["unpack", "refresh", "sh_extract", "sh_translate", "sh_compile", "sh_pipeline", "sh_link", "host", "install"],
         "ipa": ["unpack", "refresh", "sh_extract", "sh_translate", "sh_compile", "sh_pipeline", "sh_link", "ipa"],
         "ipa_dual": ["unpack", "refresh", "direct", "ipa"],
         # Mac 打包缺省（直连优先，10-26 总指挥 / jhz「出包慢得令人发指」）：同 ipa_dual 走 pack/refresh.sh，直连出成 = 通用 lazy 不预编，
         #   没有「预建渲染管线」「备用快速版本」；直连做不成报红、不退成通用（10-30 jhz 直连单轨）
         "build_dual": ["unpack", "refresh", "direct", "host", "install"]}
SHADER_STEPS = ["sh_extract", "sh_translate", "sh_compile", "sh_pipeline", "sh_link"]


def history_path(c):
    return c.private / "stats" / "prepare.jsonl"


def estimate_details(c, size_gb, kind="build", reused=()):
    """每个里程碑的预计秒数及来源：本机这一种任务（kind）的历史中位数（source=history，samples 条）；没有记录就是 None（source=none），不拿缺省值顶。
    reused 里的步（这次会复用缓存）只用复用时的记录（历史行的 reused 含这一步）；没有复用记录按 0 秒计（source=reuse）。其余步只用冷记录"""
    per = {}
    try:
        for line in history_path(c).read_text().splitlines()[-50:]:
            row = json.loads(line)
            if row.get("kind", "build") != kind:   # 老记录没有 kind，都是 Mac 打包记的
                continue
            gb = float(row.get("size_gb") or 0)
            warm = set(row.get("reused") or ())   # 老记录没有 reused：当冷记录
            for mid, sec in (row.get("seconds") or {}).items():
                per.setdefault((mid, mid in warm), []).append((float(sec), gb))
    except (OSError, ValueError):
        pass
    out = {}
    for mid, _, _, scaled in MILESTONES:
        reuse = mid in reused
        samples = [(s, g) for s, g in per.get((mid, reuse), []) if g > 0 or not scaled]   # 要按体积换算的，缺体积的记录不用
        if samples and size_gb > 0:
            out[mid] = dict(seconds=statistics.median(s / g * size_gb if scaled else s for s, g in samples), source="history",
                            samples=len(samples), basis="本机最近" + ("复用缓存时" if reuse else "") + "记录的中位数" + ("，按游戏体积换算" if scaled else ""))
        elif reuse:
            out[mid] = dict(seconds=0.0, source="reuse", samples=0, basis="复用缓存；本机还没有这一步复用时的记录，按 0 秒计")
        else:
            out[mid] = dict(seconds=None, source="none", samples=0, basis="本机还没有这一步的记录")
    return out


def estimates(c, size_gb, kind="build", reused=()):
    """每个里程碑的预计秒数：本机历史按体积换算后的中位数，没有记录的是 None"""
    return {m: d["seconds"] for m, d in estimate_details(c, size_gb, kind, reused).items()}


def plan(c, size_gb, kind="build", reused=()):
    """发计划。reused：开工前就知道会复用缓存的步（只认本计划里有的）"""
    c.milestone_t = {}
    c.milestone_kind = kind
    c.milestone_ids = PLANS[kind]
    c.milestone_size = size_gb
    c.milestone_reused = {m for m in reused if m in c.milestone_ids}
    _emit_plan(c)


def _emit_plan(c):
    est = estimate_details(c, c.milestone_size, c.milestone_kind, c.milestone_reused)
    rows = {m: (l, p) for m, l, p, _ in MILESTONES}
    c.emit("plan", "准备计划", milestones=[dict(id=m, label=rows[m][0], purpose=rows[m][1],
                                            expected=None if est[m]["seconds"] is None else round(est[m]["seconds"], 1),
                                            source=est[m]["source"], samples=est[m]["samples"], basis=est[m]["basis"],
                                            reuse=m in c.milestone_reused)
                                       for m in c.milestone_ids],
           sizeGb=round(c.milestone_size, 2))


def reuse(c, mid, on=True):
    """开工后才知道某一步复用（或原以为复用、其实要重做）：改标并重发计划（同一组步，前端接着走表、只换预计）。
    没发过计划（如别的作业调到）或不在本计划里的步不动"""
    ids, marked = getattr(c, "milestone_ids", None), getattr(c, "milestone_reused", None)
    if not ids or marked is None or mid not in ids or (mid in marked) == on:
        return
    (c.milestone_reused.add if on else c.milestone_reused.discard)(mid)
    _emit_plan(c)


def enter(c, mid):
    """进入一个里程碑：发 stage 事件（带里程碑 id），并记开始时间（结束时间 = 下一个里程碑开始）"""
    label = next(l for m, l, _, _ in MILESTONES if m == mid)
    with c.guard:
        now = time.monotonic()
        for m, t in list(c.milestone_t.items()):
            if isinstance(t, float):
                c.milestone_t[m] = (t, now)
        c.milestone_t[mid] = now
        c.milestone = mid
        ids = getattr(c, "milestone_ids", None) or [m for m, *_ in MILESTONES]
        c.begin(label, ids.index(mid) + 1, len(ids))


def record(c, size_gb, **extra):
    """准备成功：把各里程碑实测秒数记进历史（下次同一种任务的预计用）；extra 照原样并进这一行（打 iPhone 包记 gameId）"""
    now = time.monotonic()
    sec = {m: (t[1] - t[0]) if isinstance(t, tuple) else now - t for m, t in getattr(c, "milestone_t", {}).items()}
    p = history_path(c)
    p.parent.mkdir(parents=True, exist_ok=True)
    with p.open("a") as f:
        f.write(json.dumps(dict(at=time.time(), kind=getattr(c, "milestone_kind", "build"), size_gb=round(size_gb, 2), seconds={m: round(s, 1) for m, s in sec.items()},
                                reused=sorted(getattr(c, "milestone_reused", ()) or ()), **extra)) + "\n")


def _count(d, suffix):
    try:
        return sum(1 for e in os.scandir(d) if e.name.endswith(suffix))
    except OSError:
        return 0


def shader_state(shaders_tmp: Path):
    """着色器阶段正在第几步、完成数 / 总数（数工作目录里的文件；None = 总数未知）"""
    o = shaders_tmp; w = o / "work"
    if not w.is_dir():
        return "sh_extract", None, None
    dl_src = _count(w / "dl_msl", ".metal")
    dl_dirs = [d for d in o.glob("gal_dl.*") if d.is_dir()]
    if dl_dirs and dl_src:
        return "sh_link", sum(_count(d, ".metallib") for d in dl_dirs), dl_src
    pso_total = _count(w, ".mtl4-json")
    if pso_total:
        return "sh_pipeline", len(list(o.glob("gal_pso.*.bin"))), pso_total
    msl = w / "lib" / "msl"
    if msl.is_dir():
        # 合并编译（10-23 起缺省开）：一个 <首键>_u<支数>.air 装一整批，按支数累加；逐支编的 .air 记 1（原来只数文件，进度卡在约 2%）
        air = 0
        try:
            for e in os.scandir(msl):
                if e.name.endswith(".air"):
                    m = re.search(r"_u(\d+)\.air$", e.name)
                    air += int(m.group(1)) if m else 1
        except OSError:
            pass
        if air:
            return "sh_compile", air, _count(msl, ".metal")
    if (w / "bake.log").exists():
        return "sh_translate", None, None
    return "sh_extract", None, None


class ShaderWatcher:
    """着色器阶段运行时每秒看一次产物根里的临时版本，切里程碑、发完成数"""
    def __init__(self, c, roots: Path, game_id: str, enter_first=True):
        # enter_first=False：着色器临时目录出现后才进「找出着色器」（打 iPhone 包时前面还有改写等几步，同一个进程里跑）
        self.c, self.roots, self.game_id, self.enter_first = c, roots, game_id, enter_first
        self.stop = threading.Event()
        self.t = threading.Thread(target=self.loop, daemon=True)

    def __enter__(self):
        if self.enter_first:
            enter(self.c, "sh_extract")
        self.t.start()
        return self

    def __exit__(self, *a):
        self.stop.set()
        with self.c.guard:
            pass  # Finish any in-flight publication; later writers must observe stop.
        self.t.join(timeout=3)

    def loop(self):
        cur = "sh_extract" if self.enter_first else None
        while not self.stop.wait(1):
            # 直连库阶段（直连包，与通用着色器并行）：临时版本叫 <款>@dl-*.tmp，出现就进「直连着色器库」
            ids = getattr(self.c, "milestone_ids", None) or [m for m, *_ in MILESTONES]
            if cur != "direct" and "direct" in ids and any(self.roots.glob(self.game_id + "@dl-*.tmp")):
                for s in SHADER_STEPS[SHADER_STEPS.index(cur) + 1:] if cur in SHADER_STEPS else []:
                    if s in ids:   # 只进本计划里有的步（直连包的通用段不出管线归档 / 函数体动态库）
                        with self.c.guard:
                            if self.stop.is_set():
                                return
                            enter(self.c, s)
                with self.c.guard:
                    if self.stop.is_set():
                        return
                    reuse(self.c, "direct", False)   # 直连临时版本出现 = 这一步真在重出（键变了），不是复用：当场改回冷步、重发计划
                    enter(self.c, "direct")
                cur = "direct"
            if cur == "direct":
                continue
            try:
                tmps = sorted(self.roots.glob(self.game_id + "@sh-*.tmp"), key=lambda p: p.stat().st_mtime)
            except OSError:
                # A temporary version can disappear while the producer replaces it.
                continue
            if not tmps:
                continue
            if cur is None:
                with self.c.guard:
                    if self.stop.is_set():
                        return
                    enter(self.c, "sh_extract")
                cur = "sh_extract"
            try:
                step, done, total = shader_state(tmps[-1] / "shaders")
            except OSError:
                continue
            if SHADER_STEPS.index(step) > SHADER_STEPS.index(cur):
                for s in SHADER_STEPS[SHADER_STEPS.index(cur) + 1:SHADER_STEPS.index(step) + 1]:
                    if s in ids:
                        with self.c.guard:
                            if self.stop.is_set():
                                return
                            enter(self.c, s)
                cur = step
            if done is not None and total:
                try:
                    with self.c.guard:
                        if self.stop.is_set():
                            return
                        self.c.emit(done=min(done, total), total=total, unit={"sh_compile": "shaders", "sh_link": "shaders"}.get(step, "chunks"))
                except Exception:
                    return
