"""一键出包的冷 / 热缓存标注（jhz 10-23：每次出到 IPA 都要标冷 / 热，标错就是误报）。

按各部件自己报的命中算，不靠日志里有没有「跳过 / 复用」字样
（10-24 实撞两次：丝之歌全冷局因宽屏阶段「没有要加宽的布局…跳过」被标成「有缓存命中」；
马车8 热局着色器 23570 条全命中却标成「冷缓存」——命中只写在 shader_pack.json 里）。

部件与判据：
  解包       oneclick 自己判（输入键没变就复用 extract/）
  六个阶段   pack/refresh.sh 按 改写 / 系统数据 / 宽屏界面布局 / 追加内容 / RomFS 索引 / 着色器 依次打每段最后一行；
             「现行已是…」「系统数据已齐」「只换特化组合表」「别的树已烘好」= 阶段键命中；
             「没有要加宽的布局」「没有 romfs/」「本机…没有…原始包」「追加内容没解」= 这款本来就没活，不计；其余 = 现做
  着色器内部 阶段现做时读产物根 shaders/shader_pack.json：MSL 重编数、管线分片重编数、函数体动态库命中数
  出包       ipa.log「现行已是包」= 整包命中；否则 C# 库看 build.log 有没有「nxaot：编」（命中时 nxaot 不打这行）
总标注：一项都没命中 = 冷缓存；全命中 = 热缓存；其余 = 部分命中。后面逐项列出。

用法：python3 cachehits.py --unpack reused|built --refresh <refresh.log> [--shader <shader_pack.json>] --ipa <ipa.log> [--build <build.log>]
"""
import argparse
import json
import os
import re

STAGES = ["改写", "系统数据", "宽屏界面布局", "追加内容", "RomFS 索引", "着色器"]
HIT = re.compile(r"现行已是|系统数据已齐|只换特化组合表|别的树已烘好")
NOOP = re.compile(r"没有要加宽的布局|没有 romfs/|本机.*没有.*原始包|追加内容没解")


def summarize(unpack, refresh_lines, shader, ipa_text, build_text):
    items = []  # (名字, 状态 hit / built / partial, 说明)
    items.append(("解包", "hit" if unpack == "reused" else "built", "复用" if unpack == "reused" else "现做"))
    lines = [l for l in refresh_lines if l.strip()][:len(STAGES)]
    for name, line in zip(STAGES, lines):
        if NOOP.search(line):
            continue
        if HIT.search(line):
            items.append((name, "hit", "阶段键命中"))
        elif name == "着色器" and shader:
            r = shader.get("rebuilt", {}); d = shader.get("link_dylib", {})
            parts = []
            hits = built = 0
            for label, done, total in (("MSL 重编", r.get("msl"), r.get("msl_total")),
                                       ("管线分片重编", r.get("pso_chunks"), r.get("pso_chunks_total"))):
                if total:
                    parts.append(f"{label} {done}/{total}")
                    hits += done < total; built += done > 0
            if d.get("total"):
                parts.append(f"函数体命中 {d.get('hit', 0)}/{d['total']}")
                hits += d.get("hit", 0) > 0; built += d.get("hit", 0) < d["total"]
            state = "partial" if hits and built else "hit" if hits else "built"
            items.append((name, state, "，".join(parts) or "现做"))
        else:
            items.append((name, "built", "现做"))
    if "现行已是包" in ipa_text:
        items.append(("出包", "hit", "包键命中"))
    elif "🟢 未签名 App" in build_text:   # pack/ship_ext.py build 的完成行
        items.append(("C# 库", "skip", "不用（预编壳）"))   # 预编壳模式（pack/ship_ext.py）不编宿主库：不算命中也不算现做
    else:
        items.append(("C# 库", "built" if "nxaot：编" in build_text else "hit", "现编" if "nxaot：编" in build_text else "命中"))
    hit = any(s in ("hit", "partial") for _, s, _ in items)
    built = any(s in ("built", "partial") for _, s, _ in items)
    label = "部分命中" if hit and built else "热缓存" if hit else "冷缓存"
    return label, "；".join(f"{n} {why}" for n, _, why in items)


def read(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            return f.read()
    except OSError:
        return ""


def main():
    a = argparse.ArgumentParser()
    a.add_argument("--unpack", required=True, choices=["reused", "built"])
    a.add_argument("--refresh", required=True)
    a.add_argument("--shader")
    a.add_argument("--ipa", required=True)
    a.add_argument("--build")
    o = a.parse_args()
    shader = None
    if o.shader and os.path.isfile(o.shader):
        try:
            shader = json.loads(read(o.shader))
        except ValueError:
            shader = None
    label, detail = summarize(o.unpack, read(o.refresh).splitlines(), shader, read(o.ipa), read(o.build) if o.build else "")
    print(f"{label}\t{detail}")


if __name__ == "__main__":
    main()
