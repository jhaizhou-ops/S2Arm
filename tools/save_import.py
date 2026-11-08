#!/usr/bin/env python3
"""社区存档导入（10-27 总指挥：存档精选包 switch1-saves-pick 接进自动玩家和普查）。

把四种常见存档布局认出来，落成我方 saves/ 登记（同 graphics/widen/scan/save_pick.sh、tools/mac_save.sh 读的那一种）：
  <saves>/<款>_<构建号>[@<标签>]/{account|device}/<游戏存档文件…>、user、来源.txt
布局（自动识别，--layout 可点名）：
  ryujinx     Ryujinx 数据根 bis/user/save/<16 位十六进制>/0/（有 bis/system/save/8000000000000000/0/imkvdb.arc 时按索引，
              只有存档目录时按同级 ExtraData0 开头 0x40 字节的存档属性：程序号 u64、用户号 16 字节、…、类型 u8 在 0x20）
  yuzu        nand/user/save/0000000000000000/<32 位用户号>/<程序号>/（用户号全 0 = 设备存档）
  checkpoint  Checkpoint saves/0x<程序号> <游戏名>/<时间戳 …>/（取最新一份）
  jksv        JKSV/<游戏名>/<用户名 - 时间戳>/ 或 zip（路径里没有程序号，须给 --tid）；取最新一份
  raw         直接就是游戏存档文件的目录 / zip（须给 --tid）
类型：给了产物根（--root）按 control.nacp 偏移 0x3080 的账户 / 设备存档大小定（账户 > 0 → account，否则 device）；
  没给根时用布局自带的信息（ryujinx 属性类型、yuzu 用户号是否全 0），都没有按 account。
构建号：给了产物根取 exefs/main 偏移 0x40 的 16 字节；没给写全 0——save_pick.sh「同款别的构建号」照样挑得到，普查出根后不用改名。
用户号（user 文件）：我方 Mac 局固定用户号 0…01…0（同已登记资产；存档 user 从机上读的规矩：社区存档没有机器，按我方起局的用户放）。
只解析、不执行；只内部测试用，不进包、不进仓库、不外发（来源.txt 写明）。
用法：
  python3 tools/save_import.py <来源目录或 zip> --name <款> [--tid <程序号>] [--root <产物根>] [--tag community] [--note <来源说明>] [--saves <目录>]
  python3 tools/save_import.py --pick <PICK.tsv> --base <精选包根> [--saves <目录>]   批量：PICK.tsv 带表头（title_id / game / format / …），目录按程序号在包根下找「<程序号>_<游戏名>」
版本首片：星露谷单条 --root，仅比较可识别 XML gameVersion 与 NACP 显示版本；较新黄灯不导入。
  未知游戏保持原路径；版本不可比明确未判定后沿用原路径，不表示兼容。批量目标映射 / 启动器 / 旧缓存未接入。
退出码：0 全部导入；1 有失败（含较新版本拒绝，逐条打原因）；2 用法错。
"""
import argparse, os, re, shutil, struct, sys, tempfile
from xml.parsers import expat

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "pack", "jobs"))
import save_formats  # noqa: E402  启动器导入存档同一份识别（pack/jobs/save_formats.py）

USER = "00000000000000010000000000000000"
TITLES = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "pack", "oneclick", "titles.tsv")   # 程序号 → 款名
ZERO_BID = "0" * 32

STARDEW_TID = "0100e65002bb8000"  # docs/坑记录.md：星露谷程序号；不按 --name 猜游戏
VERSION_XML_BYTES = 16 << 20
VERSION_TOTAL_BYTES = 32 << 20
VERSION_FILES = 128


class NewerSaveError(Exception):
    """已明确存档版本较新；CLI 显示黄灯而不是普通导入错误的红灯。"""


class _UnknownVersion(Exception):
    pass


class _OtherXml(Exception):
    pass


def _xml_version(path, budget):
    """有界只读：精确 SaveGame 根、唯一直接 gameVersion；不执行 DTD/实体。

    返回 (是否可能是 SaveGame, 版本或 None, 实读字节数)。其它 XML 根不参与；
    损坏的 SaveGame、声明/实体、超限均不能支持版本比较。文件名不是 schema。
    来源：https://stardewvalleywiki.com/Saves （gameVersion）；
    https://www.stardewvalley.net/missing-corrupt-save-file-troubleshooting-guide/ （SaveGame）。
    这是窄识别器，不是完整 Switch 存档验证器。
    """
    parser = expat.ParserCreate(namespace_separator="|")
    depth, markers, version, used = 0, 0, [], 0
    recognized, in_version = False, False

    def unsupported(*args):
        raise _UnknownVersion

    def start(name, attrs):
        nonlocal depth, markers, recognized, in_version
        depth += 1
        if depth == 1:
            if name != "SaveGame":
                raise _OtherXml
            recognized = True
        if depth > 128 or in_version:
            raise _UnknownVersion
        # 只认 SaveGame 直接下一层的 gameVersion；更深的同名节点（真存档 player/gameVersion 等，11-02 星露谷社区档实测）不算版本标记、不当格式不明
        if name == "gameVersion" and depth == 2:
            markers += 1
            if markers != 1 or attrs:
                raise _UnknownVersion
            in_version = True

    def end(name):
        nonlocal depth, in_version
        if depth == 2 and name == "gameVersion":
            in_version = False
        depth -= 1

    def data(value):
        if in_version:
            version.append(value)
            if sum(map(len, version)) > 128:
                raise _UnknownVersion

    parser.StartElementHandler = start
    parser.EndElementHandler = end
    parser.CharacterDataHandler = data
    parser.StartDoctypeDeclHandler = unsupported
    parser.EntityDeclHandler = unsupported
    parser.ExternalEntityRefHandler = unsupported
    parser.SetParamEntityParsing(expat.XML_PARAM_ENTITY_PARSING_NEVER)
    # Do not disable Expat's reparse deferral or install an external resolver.
    limit = min(VERSION_XML_BYTES, budget)
    try:
        with open(path, "rb") as f:
            while True:
                chunk = f.read(min(65536, limit - used + 1))
                used += len(chunk)
                if used > limit:
                    raise _UnknownVersion
                parser.Parse(chunk, not chunk)
                if not chunk:
                    break
    except _OtherXml:
        return False, None, used
    except _UnknownVersion:
        return True, None, used
    except expat.ExpatError:
        return recognized, None, used
    return recognized, "".join(version).strip() if markers == 1 else None, used


def _numeric_version(value):
    # No suffix stripping, float conversion, lexical comparison or CNMT fallback.
    if not value or not re.fullmatch(r"[0-9]{1,9}(?:\.[0-9]{1,9}){1,7}", value):
        return None
    return tuple(map(int, value.split(".")))


def _compare_versions(save, game):
    a, b = _numeric_version(save), _numeric_version(game)
    if a is None or b is None:
        return None
    for x, y in zip(a, b):
        if x != y:
            return 1 if x > y else -1
    # 1.6 vs 1.6.0 has no owner-defined padding rule. Do not guess equality.
    return 0 if len(a) == len(b) else None


def save_game_version(directory, tid, strict=True):
    """存档里写的游戏版本（只认得出的游戏：星露谷 SaveGame/gameVersion）→ (版本或 None, 读不出的原因)。不需要产物根。
    11-02 jhz 手测星露谷：社区档（gameVersion 1.4.4）导入时没给 --root、没核版本，挑档按「同款别的构建号」借给 1.3.33 的包，读档即 Break；
    导入时把版本记进来源.txt，save_pick.sh 挑档时拿它和游戏显示版本比"""
    if tid != STARDEW_TID:
        return None, "不认识这款的存档版本格式"
    try:
        files = save_formats.files_under(directory)
        if len(files) > VERSION_FILES:
            return None, "文件数超出版本检查边界"
        candidates, budget = [], VERSION_TOTAL_BYTES
        for path in files:
            recognized, value, used = _xml_version(path, budget)
            budget -= used
            if recognized:
                candidates.append(value)
            if budget <= 0:
                return None, "数据量超出版本检查边界"
        if not strict:   # 挑档用：主存档 + Backup/ 下各份备份都算，取最高版本（有一份新于游戏就不借，宁可不带）
            known = [v for v in candidates if _numeric_version(v)]
            return (max(known, key=_numeric_version), "") if known else (None, "没有读得出版本的 SaveGame")
        if len(candidates) != 1 or candidates[0] is None:
            return None, "未取得唯一完整的 SaveGame/gameVersion（未知格式、损坏或多份）"
        return candidates[0], ""
    except (OSError, UnicodeError):
        return None, "版本元数据无法读取"


def save_version_check(directory, tid, root):
    """F3 单条 --root 首片：较新抛 NewerSaveError，其余返回说明。

    不认识的游戏完全不解析。已知游戏但未能明确比较只报告未判定，沿用
    既有导入路径；不是兼容性成功，也不修改 #516 的来源/标题选择政策。
    """
    if tid != STARDEW_TID:
        return ""

    def unknown(reason):
        return f"版本未判定（{reason}；沿用原导入路径，不代表兼容）"

    if not root:
        return unknown("未给 --root，批量目标映射不在本片")
    try:
        # Same producer/domain as pack/nx_unpack/Program.cs dver / display_version.
        with open(os.path.join(root, "ctl", "control.nacp"), "rb") as f:
            f.seek(0x3060)
            raw = f.read(16)
        if len(raw) != 16:
            return unknown("目标 NACP 显示版本截断")
        game = raw.rstrip(b"\0").decode("ascii")
        if _numeric_version(game) is None:
            return unknown("目标 NACP 显示版本缺失或不支持")
        save, why = save_game_version(directory, tid)
        if save is None:
            return unknown(why)
        order = _compare_versions(save, game)
        if order is None:
            return unknown("存档/游戏版本语法不支持或无法明确判序")
        if order > 0:
            raise NewerSaveError(f"存档版本 {save} 新于游戏版本 {game}，不导入（目标 --root 的 NACP 显示版本）")
        return f"存档版本 {save} 不新于游戏版本 {game}（仅版本检查，不保证游戏兼容）"
    except (OSError, UnicodeError):
        return unknown("版本元数据无法读取")


def nacp_kind(root):
    p = os.path.join(root, "ctl", "control.nacp")
    if not os.path.isfile(p):
        return None
    # NACP：0x3080 账户存档大小、0x3088 账户日志、0x3090 设备存档大小、0x3098 设备日志（10-27 前误把 0x3088 当设备，动森这类只用设备存档的款判不出类型）
    d = open(p, "rb").read(0x30A0)
    acc, dev = struct.unpack_from("<q", d, 0x3080)[0], struct.unpack_from("<q", d, 0x3090)[0]
    return "account" if acc > 0 else "device" if dev > 0 else None


def build_id(root):
    p = os.path.join(root, "exefs", "main")
    with open(p, "rb") as f:
        f.seek(0x40)
        return f.read(16).hex()


def place(save_dir, name, bid, tag, kind, layout, tid, note, saves, files_from, sver=None):
    dest = os.path.join(saves, f"{name}_{bid}" + (f"@{tag}" if tag else ""))
    if os.path.exists(dest):
        return None, f"已有 {dest}，不覆盖（换 --tag 或先挪走）"
    files = save_formats.files_under(files_from)
    if not files:
        return None, f"{files_from} 下没有存档文件"
    stage = tempfile.mkdtemp(prefix=".import.", dir=saves)
    try:
        for f in files:
            rel = os.path.relpath(f, files_from)
            out = os.path.join(stage, kind, rel)
            os.makedirs(os.path.dirname(out), exist_ok=True)
            shutil.copy2(f, out)
        with open(os.path.join(stage, "user"), "w") as fo:
            fo.write(USER + "\n")
        total = sum(os.path.getsize(f) for f in files)
        with open(os.path.join(stage, "来源.txt"), "w") as fo:
            fo.write(f"来源：{note or '社区存档'}；只内部测试用，不进包、不进仓库、不外发\n")
            fo.write(f"导入：tools/save_import.py，布局 {layout}，程序号 {tid}，类型 {kind}（{len(files)} 个文件，{total} 字节）\n")
            fo.write(f"原件：{save_dir}\n")
            fo.write(f"构建号：{bid}" + ("（全 0 = 导入时没有产物根，save_pick.sh 按「同款别的构建号」挑）" if bid == ZERO_BID else "") + "\n")
            fo.write(f"用户号：{USER}（我方 Mac 局固定用户）\n")
            if sver:
                fo.write(f"存档游戏版本：{sver}（save_pick.sh 不把它借给显示版本更旧的游戏）\n")
        if not sver and (tag or "").startswith("community"):
            # 11-06 总指挥：鬼灭社区 100% 存档是更新版游戏存的，库里这一版读不了（弹「请更新游戏」后整局卡死），自动局全挑中它。
            # 版本核不了的社区存档先不进自动挑选：save_pick.sh / mac_save.sh 认到 待核.txt 就跳过；跑一局确认能读后删掉本文件
            with open(os.path.join(stage, "待核.txt"), "w") as fo:
                fo.write("待核：社区存档，导入时读不出存档里的游戏版本，不知道库里这一版游戏读不读得了。"
                         "自动挑档跳过本份；用 S2A_SAVE_DIR 显式带它跑一局，确认游戏读得了存档、能进局后删掉本文件；读不了就改名为 不兼容.txt 留作对照\n")
        os.rename(stage, dest)
    except Exception:
        shutil.rmtree(stage, ignore_errors=True)
        raise
    return dest, f"{len(files)} 个文件"


def own_save_ref(saves, tid, tag):
    """同程序号我方已有存档（款名按 titles.tsv 或 t<程序号>，不含本次这类导入标签）→ (顶层名字, 类型集合)：
    顶层名字给 save_formats.zero_layer 判唯一子目录「0」剥不剥（10-27 塞尔达 0/…5/ 被误剥）；
    类型（account / device）在没给产物根时定类型（10-27 动森是设备存档，社区档缺省放成 account，游戏读不到）。"""
    tid = tid.lower().removeprefix("0x") if tid else ""
    if not tid or not saves or not os.path.isdir(saves):
        return set(), set()
    names = {"t" + tid}
    try:
        for ln in open(TITLES, encoding="utf-8"):
            p = ln.split()
            if len(p) >= 2 and not ln.startswith("#") and p[0].lower() == tid:
                names.add(p[1])
    except OSError:
        pass
    out, kinds = set(), set()
    for x in os.listdir(saves):
        m = re.fullmatch(r"(.+?)_[0-9a-f]{32}(?:@(.+))?", x)
        if not m or m.group(1) not in names or m.group(2) == tag:
            continue
        for k in ("account", "device"):
            if os.path.isdir(os.path.join(saves, x, k)):
                out |= save_formats.own_top(os.path.join(saves, x, k)); kinds.add(k)
    return out, kinds


def import_one(src, name, tid=None, root=None, tag="community", note="", saves=None, layout=None):
    """返回 (目的目录或 None, 一行说明)。"""
    try:
        ref, own_kinds = own_save_ref(saves, tid, tag)
        with save_formats.extracted(src, tid, layout, ref=ref) as (lay, d, got, kind, why):
            if not own_kinds and got:   # 程序号是布局里认出来的（Ryujinx / yuzu / Checkpoint）
                ref, own_kinds = own_save_ref(saves, got, tag)
            bid, k_root = (build_id(root), nacp_kind(root)) if root else (ZERO_BID, None)
            k_own = next(iter(own_kinds)) if len(own_kinds) == 1 else None
            if not (k_root or kind or k_own):
                why = "；".join(x for x in (why, "类型存疑：没有产物根、布局不带类型、也没有这款游戏自己的存档可比，按账户存档" + ("（自有存档账户 / 设备都有）" if own_kinds else "")) if x)
            kind = k_root or kind or k_own or "account"
            version_note = save_version_check(d, got, root)
            dest, msg = place(d, name, bid, tag, kind, lay, got, note, saves, d, sver=save_game_version(d, got, strict=False)[0])
            return dest, f"{lay} {got} {kind}：{msg}" + (f"（{why}）" if why else "") + (f"；{version_note}" if version_note else "")
    except ValueError as e:
        return None, str(e)


def pick_rows(pick, base):
    """PICK.tsv（表头 title_id / game / chosen_progress / format / source_url / …）→ [(程序号, 目录, 布局, 说明)]。
    第 2 列是游戏名不是路径：目录按程序号在精选包根下找「<程序号>_<游戏名>」或「<程序号>」，找不到 / 多个给 None（导入时报红）。"""
    rows = [ln.rstrip("\n").split("\t") for ln in open(pick, encoding="utf-8") if ln.strip() and not ln.startswith("#")]
    head = [x.strip().lower() for x in rows[0]] if rows else []
    if "title_id" not in head:
        raise SystemExit(f"{pick} 没有 title_id 表头，不是存档精选包的 PICK.tsv")
    col = lambda r, k: r[head.index(k)].strip() if k in head and head.index(k) < len(r) else ""
    dirs = {}
    for x in os.listdir(base):
        m = re.fullmatch(r"(0x)?([0-9a-fA-F]{16})(_.*)?", x)
        if m and os.path.isdir(os.path.join(base, x)):
            dirs.setdefault(m.group(2).lower(), []).append(x)
    out = []
    for r in rows[1:]:
        tid = col(r, "title_id").lower().removeprefix("0x")
        if not re.fullmatch(r"[0-9a-f]{16}", tid):
            continue
        hit = dirs.get(tid, [])
        fmt = col(r, "format").lower()
        note = "；".join(x for x in (col(r, "game"), col(r, "chosen_progress"), col(r, "source_url"), col(r, "note")) if x)
        out.append((tid, os.path.join(base, hit[0]) if len(hit) == 1 else os.path.join(base, f"{tid}（{len(hit)} 个目录）"),
                    fmt if fmt in save_formats.LAYOUTS else None, note))
    return out


def save_newer_than(save_dir, game):
    """已登记的存档目录 save_dir 是否明确新于游戏显示版本 game（save_pick.sh 挑档用）。
    先读来源.txt 的「存档游戏版本：」；没有（这一版之前导入的）就按来源.txt 的程序号现读存档文件。读不出 / 判不了序 = 不算新（维持原挑法，不加名单）"""
    sver, tid = None, None
    try:
        for line in open(os.path.join(save_dir, "来源.txt"), encoding="utf-8"):
            if line.startswith("存档游戏版本："):
                sver = line.split("：", 1)[1].split("（", 1)[0].strip()
            m = re.search(r"程序号 ([0-9a-fA-F]{16})", line)
            if m:
                tid = m.group(1).lower()
    except OSError:
        pass
    if sver is None and tid:
        sver = next((v for v in (save_game_version(os.path.join(save_dir, k), tid, strict=False)[0] for k in ("account", "device") if os.path.isdir(os.path.join(save_dir, k))) if v), None)
    return _compare_versions(sver, game) == 1 if sver else False


def main():
    if len(sys.argv) == 4 and sys.argv[1] == "--newer":   # save_import.py --newer <存档目录> <游戏显示版本>：明确更新退 0，否则退 1
        sys.exit(0 if save_newer_than(sys.argv[2], sys.argv[3]) else 1)
    ap = argparse.ArgumentParser(description="社区存档导入（四种布局 → 我方 saves/ 登记）")
    ap.add_argument("src", nargs="?")
    ap.add_argument("--name"); ap.add_argument("--tid"); ap.add_argument("--root"); ap.add_argument("--layout", choices=["ryujinx", "yuzu", "checkpoint", "jksv", "raw"])
    ap.add_argument("--tag", default="community"); ap.add_argument("--note", default="")
    ap.add_argument("--saves", default=os.environ.get("S2A_SAVES", os.path.expanduser("~/.s2arm/run/s2arm/saves")))
    ap.add_argument("--pick"); ap.add_argument("--base")
    a = ap.parse_args()
    os.makedirs(a.saves, exist_ok=True)
    jobs = []
    if a.pick:
        if not a.base:
            ap.error("--pick 要同时给 --base")
        for tid, d, lay, note in pick_rows(a.pick, a.base):
            jobs.append((d, f"t{tid}", tid, None, f"存档精选包 PICK.tsv：{note}", lay))
    else:
        if not a.src or not a.name:
            ap.error("给 <来源> 和 --name，或 --pick / --base")
        jobs.append((a.src, a.name, a.tid, a.root, a.note, a.layout))
    bad = 0
    for src, name, tid, root, note, lay in jobs:
        warning = False
        try:
            dest, msg = import_one(src, name, tid, root, a.tag, note, a.saves, lay)
        except NewerSaveError as e:
            dest, msg, warning = None, str(e), True
        except Exception as e:   # 坏包不挡后面的
            dest, msg = None, f"异常：{e}"
        bad += dest is None
        print(f"{'🟢' if dest else '🟡' if warning else '🔴'} {name}：{msg}" + (f" → {dest}" if dest else ""))
    print(f"导入 {len(jobs) - bad} / {len(jobs)} 款")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
