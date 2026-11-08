#!/bin/bash
# 社区存档导入单测（tools/save_import.py，约 2 秒）：bash tests/save_import_test.sh
# 期望（样本由本测试造，期望值不跑被测实现就定得出）：
#   ryujinx（ExtraData0 类型 3 = 设备）→ device/、程序号取属性；yuzu（用户号全 0）→ device/；yuzu（非 0 用户号）→ account/；
#   checkpoint 两份时间戳取较新那份；jksv zip 给 --tid → account/、下钻到有文件的那层；产物根给了按 control.nacp 定类型、按 exefs/main 定构建号；
#   文件逐字节相同、ExtraData 不带进来、user = 0…01…0；
#   反证：zip 里 ../ 越界路径拒绝；一个来源认出两款不给 --tid 报错；目标已在不覆盖；
#   PICK.tsv 用存档精选包真表头 + 头两行原文（第 2 列是游戏名，目录按程序号找）；raw 套层 / JKSV 套层 / EdiZon 取对层；金手指、缺目录报红不挡后面
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); bad=0
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
I="python3 $H/tools/save_import.py --saves $T/saves"
same() { cmp -s "$1" "$2"; }
# 样本：Ryujinx 设备存档（属性：程序号 0100aaaa00000000，用户号 0，类型 3）
R=$T/ryu/bis/user/save/0000000000000009; mkdir -p $R/0/sub
python3 -c "import struct,sys; open(sys.argv[1],'wb').write(struct.pack('<4Q',0x0100aaaa00000000,0,0,0)+bytes([3])+bytes(0x3f)+bytes(64))" $R/ExtraData0
printf 'island' > $R/0/main.dat; printf 'nested' > $R/0/sub/a.bin
o=$($I $T/ryu --name tryu 2>&1); d=$T/saves/tryu_00000000000000000000000000000000@community
ck "ryujinx：认出、按属性取程序号 / 设备类型（$(echo "$o" | head -1)）" '[ -d $d/device ] && same $R/0/main.dat $d/device/main.dat && same $R/0/sub/a.bin $d/device/sub/a.bin && [ ! -e $d/device/ExtraData0 ] && echo "$o" | grep -q "ryujinx 0100aaaa00000000 device"'
ck "user = 我方 Mac 局用户号、来源.txt 写明只内部用" '[ "$(cat $d/user)" = 00000000000000010000000000000000 ] && grep -q "不外发" $d/来源.txt'
# 样本：yuzu 设备 / 账户
Y=$T/yuzu/nand/user/save/0000000000000000; mkdir -p $Y/00000000000000000000000000000000/0100bbbb00000000 $Y/0123456789abcdef0123456789abcdef/0100cccc00000000
printf 'dev' > $Y/00000000000000000000000000000000/0100bbbb00000000/d.bin; printf 'acc' > $Y/0123456789abcdef0123456789abcdef/0100cccc00000000/s.bin
o2=$($I $T/yuzu --name tyuz 2>&1); r2=$?
ck "反证：一个 yuzu 根里两款、不给 --tid → 报错退出 1（$(echo "$o2" | head -1)）" '[ $r2 = 1 ] && echo "$o2" | grep -q "须指明程序号"'
$I $T/yuzu --name tyd --tid 0100bbbb00000000 > /dev/null 2>&1; $I $T/yuzu --name tya --tid 0100cccc00000000 > /dev/null 2>&1
ck "yuzu：用户号全 0 → device、非 0 → account" '[ -f $T/saves/tyd_00000000000000000000000000000000@community/device/d.bin ] && [ -f $T/saves/tya_00000000000000000000000000000000@community/account/s.bin ]'
# 样本：Checkpoint 两份时间戳，取较新
C="$T/ck/saves/0x0100dddd00000000 Some Game"; mkdir -p "$C/20261001-120000 old" "$C/20261020-120000 new"
printf 'old' > "$C/20261001-120000 old/f.bin"; printf 'new' > "$C/20261020-120000 new/f.bin"; touch -t 202610010000 "$C/20261001-120000 old"
$I "$T/ck" --name tck > /dev/null 2>&1
ck "checkpoint：路径取程序号、两份取较新" '[ "$(cat $T/saves/tck_00000000000000000000000000000000@community/account/f.bin 2>/dev/null)" = new ]'
# 样本：JKSV zip（JKSV/<游戏名>/<用户 - 时间>/），给 --tid；带产物根：control.nacp 设备存档、exefs/main 构建号
J=$T/jk/JKSV/Game/"User - 2026-10-20"; mkdir -p "$J"; printf 'jk' > "$J/save.bin"; (cd $T/jk && zip -qr $T/jk.zip JKSV)
RT=$T/root; mkdir -p $RT/ctl $RT/exefs
python3 -c "import struct,sys; b=bytearray(0x4000); struct.pack_into('<4q',b,0x3080,0,0,4096,4096); open(sys.argv[1],'wb').write(b)" $RT/ctl/control.nacp
python3 -c "import sys; open(sys.argv[1],'wb').write(bytes(0x40)+bytes(range(16))+bytes(16))" $RT/exefs/main
$I $T/jk.zip --name tjk --tid 0100eeee00000000 --root $RT > /dev/null 2>&1
ck "jksv zip + 产物根：下钻到有文件那层、类型按 nacp（设备）、构建号按 exefs/main" '[ "$(cat $T/saves/tjk_000102030405060708090a0b0c0d0e0f@community/device/save.bin 2>/dev/null)" = jk ]'
# 反证：越界路径、已存在不覆盖
python3 -c "import zipfile,sys; z=zipfile.ZipFile(sys.argv[1],'w'); z.writestr('../evil.bin','x'); z.close()" $T/evil.zip
o3=$($I $T/evil.zip --name tev --tid 0100ffff00000000 2>&1); r3=$?
ck "反证：zip 越界路径拒绝、不落盘（$(echo "$o3" | head -1)）" '[ $r3 = 1 ] && [ ! -e $T/evil.bin ] && [ ! -e $T/saves/tev_00000000000000000000000000000000@community ]'
o4=$($I $T/ryu --name tryu 2>&1); r4=$?
ck "反证：目标已在 → 不覆盖、退出 1" '[ $r4 = 1 ] && echo "$o4" | grep -q "不覆盖" && same $R/0/main.dat $d/device/main.dat'
# PICK.tsv 批量（正对照：存档精选包 switch1-saves-pick_20261027 真 PICK.tsv 的表头 + 头两行原文；目录按真包「<程序号>_<游戏名>」造）
K=$T/pick; mkdir -p "$K/0100000000010000_Super-Mario-Odyssey" "$K/0100000011D90000_Pok-mon-Brilliant-Diamond/20211114-184847 Yona/20211114-184847 Yona"
printf 'smo' > $K/0100000000010000_Super-Mario-Odyssey/File2_ForEditing.bin; printf 'bdsp' > "$K/0100000011D90000_Pok-mon-Brilliant-Diamond/20211114-184847 Yona/20211114-184847 Yona/SaveData.bin"
cat > $K/PICK.tsv <<'TSV'
title_id	game	chosen_progress	format	source_url	original_path	size	note
0100000000010000	Super Mario Odyssey™	100% | Super Mario Odyssey	raw	https://gbatemp.net/download/super-mario-odyssey.33754/	0100000000010000/gbatemp-33754-super-mario-odyssey	2097148	
0100000011D90000	Pokémon™ Brilliant Diamond	completed; Post Game | Pokémon Brilliant Diamond : Save File	Checkpoint	https://gbatemp.net/download/pokemon-brilliant-diamond-save-file.37348/	0100000011D90000/gbatemp-37348-pok-mon-brilliant-diamond-save-file	973856	
TSV
# 包里见过的套层（造样本）：raw 外套同号目录 + Ryujinx「0」、raw 实为 JKSV、EdiZon 备份、只有金手指、表里有目录没有
mkdir -p $K/0100aaaa11110000_Wrap/0100AAAA11110000/0 $K/0100aaaa22220000_Jk/JKSV/G/"U - 1" $K/0100aaaa33330000_Ez/0100aaaa33330000/slot $K/0100aaaa44440000_Ch/cheats
printf 'w' > $K/0100aaaa11110000_Wrap/0100AAAA11110000/0/game.sav; printf 'j' > $K/0100aaaa22220000_Jk/JKSV/G/"U - 1"/s0.sav
printf 'e' > $K/0100aaaa33330000_Ez/0100aaaa33330000/slot/Slot0; printf '{}' > $K/0100aaaa33330000_Ez/0100aaaa33330000/slot/edizon_save_metadata.json; printf 'c' > $K/0100aaaa44440000_Ch/cheats/x.txt
# 唯一子目录「0」（10-27）：两种解释和同程序号我方自有存档比——Wrap 的自有档顶层是 game.sav → 剥；Slot（塞尔达式）自有档顶层有 0/ 目录 → 不剥；
#   NoRef 没有自有档 → 不剥、报结构存疑。自有档用非 community 标签放进 saves/（导入时排除本次标签，不拿社区档当参照）
mkdir -p $T/saves/t0100aaaa11110000_00000000000000000000000000000000@own/account $T/saves/t0100aaaa66660000_00000000000000000000000000000000@own/account/0
printf 'o' > $T/saves/t0100aaaa11110000_00000000000000000000000000000000@own/account/game.sav; printf 'o' > $T/saves/t0100aaaa66660000_00000000000000000000000000000000@own/account/0/game_data.sav
# 类型（10-27 动森设备存档被放成 account）：没给产物根时按自有存档的类型——88880000 自有档在 device/ → device；没有自有档 → account 并报类型存疑
mkdir -p $T/saves/t0100aaaa88880000_00000000000000000000000000000000@own/device $K/0100aaaa88880000_Dev; printf 'o' > $T/saves/t0100aaaa88880000_00000000000000000000000000000000@own/device/main.dat; printf 'd' > $K/0100aaaa88880000_Dev/main.dat
mkdir -p $K/0100aaaa66660000_Slot/0 $K/0100aaaa77770000_NoRef/0; printf 's' > $K/0100aaaa66660000_Slot/0/game_data.sav; printf 'n' > $K/0100aaaa77770000_NoRef/0/game_data.sav
for t in 0100aaaa11110000 0100aaaa22220000 0100aaaa33330000 0100aaaa44440000 0100aaaa55550000 0100aaaa66660000 0100aaaa77770000 0100aaaa88880000; do printf '%s\tg\t\traw\t\t\t\t\n' $t >> $K/PICK.tsv; done
o5=$($I --pick $K/PICK.tsv --base $K 2>&1); r5=$?; g() { echo $T/saves/t$1_00000000000000000000000000000000@community/account/$2; }
ck "真 PICK.tsv 头两行：第 2 列是游戏名、按程序号对上目录（奥德赛 raw、珍钻 Checkpoint 下钻到 SaveData.bin）" '[ "$(cat $(g 0100000000010000 File2_ForEditing.bin) 2>/dev/null)" = smo ] && [ "$(cat $(g 0100000011d90000 SaveData.bin) 2>/dev/null)" = bdsp ] && grep -q "Super Mario Odyssey" $T/saves/t0100000000010000_*@community/来源.txt'
ck "唯一子目录 0：自有档是槽位式 → 不剥（塞尔达）、没有自有档 → 不剥并报结构存疑" '[ -f $(g 0100aaaa66660000 0/game_data.sav) ] && [ -f $(g 0100aaaa77770000 0/game_data.sav) ] && echo "$o5" | grep "t0100aaaa77770000" | grep -q "结构存疑" && ! echo "$o5" | grep "t0100aaaa66660000" | grep -q "结构存疑"'
ck "类型：自有档是设备存档 → device/、没有自有档 → account/ 并报类型存疑" '[ -f $T/saves/t0100aaaa88880000_00000000000000000000000000000000@community/device/main.dat ] && [ ! -e $T/saves/t0100aaaa88880000_00000000000000000000000000000000@community/account ] && ! echo "$o5" | grep "t0100aaaa88880000" | grep -q "类型存疑" && echo "$o5" | grep "t0100aaaa77770000" | grep -q "类型存疑"'
ck "raw 剥同号目录 + 「0」（自有档顶层对上 0/ 里的文件）、套 JKSV 的按 JKSV 下钻、EdiZon 取元数据那层且不带元数据" '[ -f $(g 0100aaaa11110000 game.sav) ] && [ -f $(g 0100aaaa22220000 s0.sav) ] && [ -f $(g 0100aaaa33330000 Slot0) ] && [ ! -e $(g 0100aaaa33330000 edizon_save_metadata.json) ]'
ck "反证：金手指包、缺目录各报红不挡后面，导入 8 / 10、退出 1（$(echo "$o5" | tail -1)）" '[ $r5 = 1 ] && echo "$o5" | grep -q "导入 8 / 10 款" && echo "$o5" | grep -q "cheats" && [ ! -e $T/saves/t0100aaaa44440000_00000000000000000000000000000000@community ]'
# 11-06 鬼灭：社区存档版本核不了 → 导入写 待核.txt，自动挑档跳过；跑一局确认能读、删掉 待核.txt 后才挑得到；改名 不兼容.txt 的永远不挑
SP=$T/saves/t0100000000010000_00000000000000000000000000000000@community; PK="S2A_SAVES=$T/saves bash $H/graphics/widen/scan/save_pick.sh t0100000000010000 0123456789abcdef0123456789abcdef"
ck "版本核不了的社区存档导入后有 待核.txt，save_pick.sh 不挑（出空、stderr 说跳过原因）" '[ -s $SP/待核.txt ] && [ -z "$(eval "$PK" 2> $T/pk.err)" ] && grep -q "跳过.*待核.txt" $T/pk.err'
mv $SP/待核.txt $T/待核.bak
ck "删掉 待核.txt（跑局确认过）后 save_pick.sh 挑得到全 0 构建号的导入存档（任意构建号）" '[ "$(eval "$PK")" = $SP ]'
mv $T/待核.bak $SP/不兼容.txt
ck "标了 不兼容.txt 的不挑" '[ -z "$(eval "$PK" 2> /dev/null)" ]'
rm -f $SP/不兼容.txt
mkdir -p $T/own_raw && printf 'own' > $T/own_raw/game.sav && $I $T/own_raw --name t0100aaaa99990000 --tid 0100aaaa99990000 --layout raw --tag jhz1106 > /dev/null 2>&1
ck "自有存档（标签 jhz…，不是 community）版本核不了也不写 待核.txt" '[ -d $T/saves/t0100aaaa99990000_00000000000000000000000000000000@jhz1106 ] && [ ! -e $T/saves/t0100aaaa99990000_00000000000000000000000000000000@jhz1106/待核.txt ]'

# F3：手写版本/元数据，真实单条 CLI；不使用实现的解析/比较函数生成期望。
if python3 - "$H" "$T" <<'PY_F3'
import hashlib
import os
from pathlib import Path
import struct
import subprocess
import sys

home, temp = map(Path, sys.argv[1:])
work = temp / "f3"
work.mkdir()
tool = home / "tools/save_import.py"
STARDEW = "0100e65002bb8000"
BID = "00112233445566778899aabbccddeeff"
failures = []

def xml(version):
    return f"<SaveGame><gameVersion>{version}</gameVersion></SaveGame>".encode()

def hashes(root):
    return {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in root.rglob("*") if p.is_file()}

def check(label, payload, target="1.3.33", *, tid=STARDEW, reject=False,
          unknown=False, use_root=True, extra=None):
    d = work / label
    source, root, registry = d / "source", d / "root", d / "saves"
    source.mkdir(parents=True)
    (source / "arbitrary_filename").write_bytes(payload)
    for name, data in (extra or {}).items():
        (source / name).write_bytes(data)
    (root / "ctl").mkdir(parents=True)
    (root / "exefs").mkdir()
    nacp = bytearray(0x4000)
    raw_version = target.encode("ascii") if isinstance(target, str) else target
    nacp[0x3060:0x3060 + len(raw_version)] = raw_version
    struct.pack_into("<qq", nacp, 0x3080, 4096, 0)
    (root / "ctl/control.nacp").write_bytes(nacp)
    (root / "exefs/main").write_bytes(b"NSO0" + bytes(0x3c) + bytes.fromhex(BID))
    # CNMT integer is deliberately larger than the display-version components.
    # Its value must never make 1.6 against 1.3.33 appear compatible.
    (root / "unpack.tsv").write_text(f"title_id\t{tid}\ndisplay_version\t{target}\nupdate\t999999\n")
    before, metadata = hashes(source), hashes(root)
    args = [sys.executable, "-B", str(tool), str(source), "--name", label,
            "--tid", tid, "--layout", "raw", "--saves", str(registry)]
    if use_root:
        args += ["--root", str(root)]
    proc = subprocess.run(args, capture_output=True, text=True, timeout=15)
    dest = registry / (label + "_" + (BID if use_root else "0" * 32) + "@community")
    errors = []
    if proc.returncode != (1 if reject else 0):
        errors.append(f"rc={proc.returncode}")
    if reject:
        if dest.exists() or list(registry.glob(".import.*")):
            errors.append("拒绝却落盘")
        if "🟡" not in proc.stdout or "新于" not in proc.stdout or "导入 0 / 1 款" not in proc.stdout:
            errors.append("缺黄灯/新于/失败计数")
        if "🔴" in proc.stdout:
            errors.append("版本拒绝误报红")
    elif not dest.is_dir() or hashes(dest / "account") != before:
        errors.append("放行字节不同")
    if unknown and "版本未判定" not in proc.stdout:
        errors.append("未标版本未知")
    if unknown and "不代表兼容" not in proc.stdout:
        errors.append("未标兼容性限制")
    if not unknown and "版本未判定" in proc.stdout:
        errors.append("可比较/未知游戏被误标")
    if before != hashes(source) or metadata != hashes(root):
        errors.append("输入被改")
    if list(registry.glob(".import.*")):
        errors.append("残留暂存")
    if errors:
        failures.append((label, errors, proc.stdout, proc.stderr))
        print("不通 F3", label, "; ".join(errors))
    else:
        print("通 F3", label)

check("newer", xml("1.6"), reject=True)
check("numeric_newer", xml("1.10"), "1.9", reject=True)
check("same", xml("1.3.33"))
check("older", xml("1.3.9"))
check("utf8_bom", b"\xef\xbb\xbf" + xml("1.6"), reject=True)
check("utf16", '<?xml version="1.0" encoding="utf-16"?><SaveGame><gameVersion>1.6</gameVersion></SaveGame>'.encode("utf-16"), reject=True)
check("unknown_game", xml("9.0"), tid="0100aaaa00000000")
check("unknown_format", b"UNRECOGNIZED SYNTHETIC BYTES", unknown=True)
check("other_xml", b"<Other><gameVersion>9.0</gameVersion></Other>", unknown=True)
check("missing_marker", b"<SaveGame><value>9.0</value></SaveGame>", unknown=True)
check("nested_marker", b"<SaveGame><other><gameVersion>9.0</gameVersion></other></SaveGame>", unknown=True)
check("real_shape_nested_plus_direct", b"<SaveGame><player><gameVersion>9.0</gameVersion></player><gameVersion>1.6</gameVersion></SaveGame>", reject=True)   # 真存档 player/gameVersion 嵌套 + 直接一层（11-02 星露谷社区档）：只认直接那层 1.6 > 1.3.33
check("duplicate_marker", b"<SaveGame><gameVersion>1.3.33</gameVersion><gameVersion>9.0</gameVersion></SaveGame>", unknown=True)
check("marker_with_child", b"<SaveGame><gameVersion>1.6<extra/></gameVersion></SaveGame>", unknown=True)
check("multiple_xml", xml("1.3.33"), extra={"another": xml("9.0")}, unknown=True)
check("malformed", xml("1.6")[:-2], unknown=True)
check("suffix", xml("1.6-beta"), unknown=True)
check("equal_prefix", xml("1.6"), "1.6.0", unknown=True)
check("missing_target", xml("1.6"), "", unknown=True)
check("target_suffix", xml("1.6"), "1.3.33-beta", unknown=True)
check("target_non_ascii", xml("1.6"), b"1.3.\xff", unknown=True)
check("no_root", xml("1.6"), use_root=False, unknown=True)
check("comment", b"<SaveGame><!-- <gameVersion>9.0</gameVersion> --><gameVersion>1.3.33</gameVersion></SaveGame>")
check("cdata", b"<SaveGame><note><![CDATA[<gameVersion>9.0</gameVersion>]]></note><gameVersion>1.3.33</gameVersion></SaveGame>")
check("internal_entity", b'<!DOCTYPE SaveGame [<!ENTITY v "1.6">]><SaveGame><gameVersion>&v;</gameVersion></SaveGame>', unknown=True)
external = work / "external"
external.write_text("1.6")
entity = f'<!DOCTYPE SaveGame [<!ENTITY v SYSTEM "{external.as_uri()}">]><SaveGame><gameVersion>&v;</gameVersion></SaveGame>'
check("external_entity", entity.encode(), unknown=True)
check("utf16_doctype", ('<?xml version="1.0" encoding="utf-16"?>' + entity).encode("utf-16"), unknown=True)
check("deep", b"<SaveGame>" + b"<x>" * 130 + b"</x>" * 130 + b"<gameVersion>1.6</gameVersion></SaveGame>", unknown=True)
check("large_xml", b"<SaveGame><note>" + b"x" * (16 * 1024 * 1024 + 1) + b"</note><gameVersion>1.6</gameVersion></SaveGame>", unknown=True)
check("many_files", xml("1.6"), extra={f"other_{i}": b"x" for i in range(128)}, unknown=True)
if failures:
    for label, errors, out, err in failures:
        print(label, errors, out, err)
    raise SystemExit(1)
print("F3 合成 CLI 全过（不代表真实游戏兼容）")
PY_F3
then :; else bad=1; fi
rm -rf $T
[ $bad = 0 ] && echo "社区存档导入单测全过" || { echo "社区存档导入单测有不通"; exit 1; }
