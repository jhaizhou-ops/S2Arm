#!/usr/bin/env python3
"""直连配置版本旁注 direct-profile-input.json 的唯一算法（出包期元数据，不是运行协议）。

用法：direct_profile_input.py <解包目录>（读 <目录>/unpack.tsv，写 <目录>/direct-profile-input.json）
目录里已有旁注时原样保留、不覆盖（一键出包 10-25 起的语义：从解包目录往下不覆盖调用方给的旁注）。

口径与一键出包「从原件认」一致：
  content_version = 最新更新的 CNMT 版本；没有更新取本体 CNMT 版本（**不是**显示版本，两者不能互相替代）
  title_id / display / name 同 unpack.tsv（display 取控制分区的显示版本；控制分区来自最新更新，没有更新取本体）
  name 优先中文名，与 nx_unpack --inspect 的 TitleName(nacp, 14) ?? TitleName(nacp, 0) 同序

写旁注的入口只有这一份：解包阶段（pack/stages/unpack.sh extract）出包后调它，一键出包两支持有解包目录后也调它。
新增一条出包路径不必自己算版本，只要手上是解包目录即可。
"""
import json
import os
import sys


class Invalid(ValueError):
    pass


def metadata(root):
    """unpack.tsv 的键值；同一键出现两次一律拒（两份值谁对说不清，不猜）"""
    path = os.path.join(root, "unpack.tsv")
    fields = {}
    try:
        with open(path, encoding="utf-8") as stream:
            for number, line in enumerate(stream, 1):
                line = line.rstrip("\n")
                if not line:
                    continue
                parts = line.split("\t", 1)
                if len(parts) != 2 or not parts[0]:
                    raise Invalid(f"{path} 第 {number} 行不是「键 TAB 值」")
                if parts[0] in fields:
                    raise Invalid(f"{path} 第 {number} 行键 {parts[0]} 重复")
                fields[parts[0]] = parts[1]
    except OSError as error:
        raise Invalid(f"读不了 {path}（{error.strerror or error}）") from error
    return fields


def content_version(fields):
    """最新更新的内容版本；没有更新取本体内容版本。两个都读不出就报错，不拿 0 顶替。"""
    update = fields.get("update", "")
    base = fields.get("base", "")
    if update:
        raw = update
    elif base:
        raw = base
    else:
        raise Invalid("unpack.tsv 没有更新也没有本体内容版本（update / base 都空）：解包产物太旧，"
                      "用新版 nx_unpack 重新解包，或显式给内容版本")
    if not raw.isdecimal():
        raise Invalid(f"unpack.tsv 的内容版本不是十进制整数：{raw!r}")
    value = int(raw)
    if not 0 <= value <= 0xFFFFFFFF:
        raise Invalid(f"unpack.tsv 的内容版本超出 32 位范围：{raw}")
    return value


def build(root):
    """解包目录 → 旁注内容（dict）。读不出身份 / 版本一律抛 Invalid。"""
    root = os.path.abspath(root)
    fields = metadata(root)
    title = (fields.get("title_id") or "").upper()
    if len(title) != 16 or any(c not in "0123456789ABCDEF" for c in title):
        raise Invalid(f"{root}/unpack.tsv 没有 16 位十六进制 title_id：{title or '空'}")
    return {"format": 1, "title_id": title, "content_version": content_version(fields),
            "display": fields.get("display_version", ""),
            "name": fields.get("name_zh") or fields.get("name", "")}


def write(root):
    """有旁注就保持不动（返回 False），没有才写（返回 True）。"""
    root = os.path.abspath(root)
    target = os.path.join(root, "direct-profile-input.json")
    if os.path.exists(target):
        return False
    data = build(root)
    temporary = target + f".tmp.{os.getpid()}"
    try:
        with open(temporary, "w", encoding="utf-8") as stream:
            json.dump(data, stream, ensure_ascii=False)
        os.replace(temporary, target)
    except OSError as error:
        try:
            os.unlink(temporary)
        except OSError:
            pass
        raise Invalid(f"写不了 {target}（{error.strerror or error}）") from error
    return True


def main(argv):
    if len(argv) != 2:
        print("用法：direct_profile_input.py <解包目录>", file=sys.stderr)
        return 2
    try:
        write(argv[1])
    except Invalid as error:
        print(f"【红】直连配置版本旁注：{error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
