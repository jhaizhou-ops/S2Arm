#!/usr/bin/env python3
"""#281 R3 首片：离线交换 R1 的三张元数据表，不交换着色器代码。

export --source <R1表目录> --program-id <16位程序号> --game-version <版本>
       --output <新文件，建议以程序号命名>
import --input <元数据JSON> --program-id <本机程序号> --game-version <本机版本>
       --output <尚不存在的目录>

schema_version=1；只含 program_id、game_version、keys[{key,stage,chain}]、
fout[{key,unsigned,signed}]、vt[key]。键16位/链12位小写hex，阶段vs/hs/ds/gs/ps/cs，
掩码uint8；版本为1–64位字母/数字/点/下划线/加减号（首位字母或数字）。
程序号统一大写；导入须与明确指定的本机程序号、版本相同。所有字段严格白名单，
不透传JSON、注释或文件；三张TSV均须存在，软链拒收。合计至多16MiB、100000行。
三表本身不含游戏身份；程序号/版本由调用者从本机游戏取得，校验声明一致不等于来源认证。
同记录去重、同键的阶段/链冲突拒收；导入复用rt_collect.write生成R1同格式三表。
完整校验后才原子发布新文件/目录；不覆盖既有路径、不修改输入。
发布支持Linux renameat2(RENAME_NOREPLACE)及macOS renamex_np(RENAME_EXCL)；
系统/文件系统不支持就失败，不退回有覆盖窗口的实现。强杀可能留私有临时目录，
但发布前目标不存在，发布后是完整产物；不承诺断电持久性。macOS路径需在Mac验收。

仅元数据交换，不接direct_lib、不编译、不联网。pso_user.tsv/不透明R行不在首片，
不会读写；导入只提供后续本机重出的线索。三表逐字节回环不等于Metal出包或游戏
回收验收；R2-b接线、真游戏N>0→回收→同路线复跑仍由维护方接续。
"""
import argparse
import ctypes
import errno
import json
import os
from pathlib import Path
import re
import sys
import tempfile

from rt_collect import write as write_tables

MAX_BYTES = 16 * 1024 * 1024
MAX_ROWS = 100000
TABLE_NAMES = ("rt_keys.tsv", "rt_fout.tsv", "rt_vt.tsv")
KEY = re.compile(r"[0-9a-f]{16}")
CHAIN = re.compile(r"[0-9a-f]{12}")
PROGRAM = re.compile(r"[0-9a-fA-F]{16}")
VERSION = re.compile(r"[A-Za-z0-9][A-Za-z0-9._+-]{0,63}")
STAGES = frozenset(("vs", "hs", "ds", "gs", "ps", "cs"))


def string(value, pattern, name):
    if not isinstance(value, str) or not pattern.fullmatch(value):
        raise ValueError(name + " 格式不合法")
    return value


def identity(program_id, game_version):
    return (string(program_id, PROGRAM, "程序号").upper(),
            string(game_version, VERSION, "游戏版本"))


def object_fields(value, fields, name):
    if not isinstance(value, dict):
        raise ValueError(name + " 必须为对象")
    if set(value) != fields:
        raise ValueError(name + " 字段缺失或含不允许的字段")


def validate(value):
    """Return a newly built whitelist-only canonical document, never the input."""
    object_fields(value, {"schema_version", "program_id", "game_version", "keys", "fout", "vt"}, "元数据")
    if type(value["schema_version"]) is not int or value["schema_version"] != 1:
        raise ValueError("只支持整数 schema_version=1")
    program_id, version = identity(value["program_id"], value["game_version"])
    for name in ("keys", "fout", "vt"):
        if not isinstance(value[name], list):
            raise ValueError(name + " 必须为数组")
    if sum(len(value[name]) for name in ("keys", "fout", "vt")) > MAX_ROWS:
        raise ValueError("元数据超过 100000 行")
    keys, fout, vt = {}, set(), set()
    for row in value["keys"]:
        object_fields(row, {"key", "stage", "chain"}, "keys行")
        key = string(row["key"], KEY, "着色器键")
        stage = row["stage"]
        if not isinstance(stage, str) or stage not in STAGES:
            raise ValueError("阶段只认 vs/hs/ds/gs/ps/cs")
        chain = string(row["chain"], CHAIN, "链版本")
        if key in keys and keys[key] != (stage, chain):
            raise ValueError("同键的阶段或链版本冲突")
        keys[key] = (stage, chain)
    for row in value["fout"]:
        object_fields(row, {"key", "unsigned", "signed"}, "fout行")
        key = string(row["key"], KEY, "着色器键")
        masks = row["unsigned"], row["signed"]
        if any(type(mask) is not int or not 0 <= mask <= 255 for mask in masks):
            raise ValueError("输出类型掩码必须为 0..255 的整数（不是布尔值）")
        fout.add((key, *masks))
    for key in value["vt"]:
        vt.add(string(key, KEY, "曲面前顶点键"))
    return {"schema_version": 1, "program_id": program_id, "game_version": version,
            "keys": [{"key": key, "stage": stage, "chain": chain}
                     for key, (stage, chain) in sorted(keys.items())],
            "fout": [{"key": key, "unsigned": unsigned, "signed": signed}
                     for key, unsigned, signed in sorted(fout)],
            "vt": sorted(vt)}


def read_limited(path, budget=MAX_BYTES):
    if path.is_symlink() or not path.is_file():
        raise ValueError("输入必须是普通文件，不能是软链：" + path.name)
    with path.open("rb") as stream:
        data = stream.read(budget + 1)
    if len(data) > budget:
        raise ValueError("输入超过 16 MiB")
    return data


def read_tables(source, program_id, game_version):
    if source.is_symlink() or not source.is_dir():
        raise ValueError("源必须是三表目录，不能是软链")
    doc = {"schema_version": 1, "program_id": program_id, "game_version": game_version,
           "keys": [], "fout": [], "vt": []}
    remaining, rows = MAX_BYTES, 0
    for name, kind, columns in zip(TABLE_NAMES, ("keys", "fout", "vt"), (3, 3, 1)):
        data = read_limited(source / name, remaining)
        remaining -= len(data)
        for line in data.decode("utf-8").splitlines():
            if not line.strip() or line.startswith("#"):
                continue
            rows += 1
            if rows > MAX_ROWS:
                raise ValueError("元数据超过 100000 行")
            fields = line.split("\t")
            if len(fields) != columns:
                raise ValueError(name + " 列数不合法")
            if kind == "keys":
                doc[kind].append(dict(zip(("key", "stage", "chain"), fields)))
            elif kind == "fout":
                if any(not re.fullmatch(r"[0-9a-f]{1,2}", field) for field in fields[1:]):
                    raise ValueError("输出类型掩码必须是 1–2 位小写十六进制")
                doc[kind].append({"key": fields[0], "unsigned": int(fields[1], 16), "signed": int(fields[2], 16)})
            else:
                doc[kind].append(fields[0])
    return validate(doc)


def unique_fields(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("JSON 对象有重复字段")
        result[key] = value
    return result


def invalid_constant(value):
    raise ValueError("JSON 不允许非有限数值：" + value)


def new_output(path):
    if os.path.lexists(path):
        raise ValueError("输出已存在，拒绝覆盖")
    if not path.parent.is_dir():
        raise ValueError("输出父目录不存在")


def publish(source, output):
    """Atomically rename without replacing even an empty concurrent target."""
    # Official API contracts, not copied implementation:
    # https://man7.org/linux/man-pages/man2/rename.2.html
    # https://github.com/apple-oss-distributions/xnu/blob/main/bsd/man/man2/rename.2
    # Flag values: Linux include/uapi/linux/fs.h; Apple bsd/sys/stdio.h.
    if sys.platform not in ("linux", "darwin"):
        raise ValueError("原子不覆盖发布只支持 Linux/macOS；当前平台不支持")
    libc = ctypes.CDLL(None, use_errno=True)
    name = "renameat2" if sys.platform == "linux" else "renamex_np"
    function = getattr(libc, name, None)
    if function is None:
        raise ValueError("本机缺 " + name + "；无法原子不覆盖发布")
    if sys.platform == "linux":
        function.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
        args = (-100, os.fsencode(source), -100, os.fsencode(output), 1)  # AT_FDCWD, RENAME_NOREPLACE
    else:
        function.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
        args = (os.fsencode(source), os.fsencode(output), 4)  # RENAME_EXCL
    function.restype = ctypes.c_int
    if function(*args) != 0:
        error = ctypes.get_errno()
        if error in (errno.ENOSYS, errno.EINVAL, errno.EOPNOTSUPP):
            raise ValueError("系统或目标文件系统不支持原子不覆盖发布（" + name + "）；未发布")
        raise OSError(error, os.strerror(error), str(output))


def export_metadata(source, output, program_id, game_version):
    source, output = Path(source), Path(output)
    program_id, game_version = identity(program_id, game_version)
    if output.resolve().is_relative_to(source.resolve()):
        raise ValueError("输出不能位于输入目录内")
    new_output(output)
    doc = read_tables(source, program_id, game_version)
    data = (json.dumps(doc, ensure_ascii=True, sort_keys=True, indent=2) + "\n").encode()
    if len(data) > MAX_BYTES:
        raise ValueError("导出 JSON 超过 16 MiB，请拆分来源")
    # Temporary file and destination share a filesystem. Never reserve the final
    # path first: a crash before publication must leave it absent and retryable.
    with tempfile.TemporaryDirectory(prefix=".rt-metadata-", dir=output.parent) as tmp:
        stage = Path(tmp) / "metadata.json"
        with stage.open("xb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        publish(stage, output)
    return doc


def import_metadata(source, output, program_id, game_version):
    source, output = Path(source), Path(output)
    program_id, game_version = identity(program_id, game_version)
    new_output(output)
    if source.resolve().is_relative_to(output.resolve()):
        raise ValueError("输出不能包含输入文件")
    doc = validate(json.loads(read_limited(source).decode("utf-8"),
                              object_pairs_hook=unique_fields, parse_constant=invalid_constant))
    if doc["program_id"] != program_id:
        raise ValueError("元数据程序号与本机程序号不一致")
    if doc["game_version"] != game_version:
        raise ValueError("元数据游戏版本与本机版本不一致")
    with tempfile.TemporaryDirectory(prefix=".rt-metadata-", dir=output.parent) as tmp:
        stage = Path(tmp) / "tables"
        write_tables(stage, {r["key"]: (r["stage"], r["chain"]) for r in doc["keys"]},
                     {(r["key"], r["unsigned"], r["signed"]) for r in doc["fout"]}, set(doc["vt"]))
        for name in TABLE_NAMES:
            with (stage / name).open("rb") as stream:
                os.fsync(stream.fileno())
        publish(stage, output)
    return doc


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    for mode in ("export", "import"):
        command = commands.add_parser(mode)
        command.add_argument("--source" if mode == "export" else "--input", required=True)
        command.add_argument("--output", required=True)
        command.add_argument("--program-id", required=True)
        command.add_argument("--game-version", required=True)
    args = parser.parse_args()
    try:
        if args.command == "export":
            doc = export_metadata(args.source, args.output, args.program_id, args.game_version)
        else:
            doc = import_metadata(args.input, args.output, args.program_id, args.game_version)
    except (OSError, ValueError, TypeError, RecursionError) as error:
        parser.exit(1, "【红】现编元数据：" + str(error) + "\n")
    print(f"现编元数据 {args.command}：程序号 {doc['program_id']}，版本 {doc['game_version']}；"
          f"键 {len(doc['keys'])}、输出类型变体 {len(doc['fout'])}、曲面前顶点 {len(doc['vt'])}；"
          "仅三表线索，不含代码或管线描述，不代表出包/游戏验证")


if __name__ == "__main__":
    main()
