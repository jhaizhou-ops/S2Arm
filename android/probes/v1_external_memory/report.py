#!/usr/bin/env python3
"""Prints the V1 reading tables (Markdown) from a reading directory laid out as
<dir>/<device>/{adb,apk,bench_1..3,sparse}.jsonl, *_avc.txt, state.txt, device.txt.

    python3 -I android/probes/v1_external_memory/report.py /tmp/sgm-s2arm-games/wp17-v1 8E 9000
"""
import json
import os
import re
import statistics
import sys

MB = 1 << 20


def load(path):
    if not os.path.exists(path):
        return []
    with open(path, encoding="utf-8") as f:
        return [json.loads(line) for line in f if line.strip()]


def size(n):
    return f"{n // MB}M" if n >= MB else f"{n // 1024}K"


def yn(v):
    return {True: "是", False: "否", None: "-"}.get(v, str(v))


def val(d, k):
    v = d.get(k)
    return "-" if v is None else yn(v) if isinstance(v, bool) else str(v)


def table(head, rows):
    out = ["| " + " | ".join(head) + " |", "|" + "---|" * len(head)]
    out += ["| " + " | ".join(str(c).replace("|", "\\|") for c in r) + " |" for r in rows]
    return "\n".join(out)


def run_meta(root, devs):
    rows = []
    for dev in devs:
        benches = sorted((f[:-6] for f in os.listdir(f"{root}/{dev}") if re.fullmatch(r"bench_\d+\.jsonl", f)), key=lambda f: int(f[6:]))
        for name in ["adb", "apk"] + benches + ["sparse"]:
            lines = load(f"{root}/{dev}/{name}.jsonl")
            if not lines:
                continue
            st = next(x for x in lines if x["sec"] == "start")
            end = next((x for x in lines if x["sec"] == "end"), {})
            secs = [f"{x['name']}:{x['status']}" for x in lines if x["sec"] == "section"]
            rows.append([dev, name, st["rev"], st["mode"], st["uid"], f"`{st['selinux']}`", " ".join(secs),
                         f"{end.get('sections_done', '-')}/{end.get('sections_run', '-')}", end.get("total_ms", "-")])
    fp = []
    for dev in devs:
        st = next((x for x in load(f"{root}/{dev}/adb.jsonl") if x["sec"] == "start"), None)
        if st:
            fp.append(f"- {dev}：{st['model']}（`ro.soc.model={st['soc']}`），fingerprint `{st['fingerprint']}`")
    return "\n".join(fp) + "\n\n" + table(["机", "运行", "rev", "mode", "uid", "SELinux", "节:状态", "完成", "total_ms"], rows)


def swap_rows(root, devs, mode):
    rows = []
    for dev in devs:
        for d in load(f"{root}/{dev}/{mode}.jsonl"):
            if d["sec"] not in ("swap_ahb", "swap_heap") or "shape" not in d:
                continue
            fail = "" if d["status"] == "ok" else f"{d.get('step', '')} errno={d.get('errno', '-')}"
            rows.append([
                dev, d["backing"], d["shape"], size(d["size"]), d["status"] + (f"（{fail}）" if fail else ""),
                val(d, "after_swap_in_cpu_bad_bytes"),
                f"{val(d, 'after_swap_in_neighbour_maps_same')}/{val(d, 'after_swap_in_lo_bad_bytes')}/{val(d, 'after_swap_in_hi_bad_bytes')}",
                val(d, "alias_sees_pool_write_while_swapped"),
                f"{val(d, 'type')} {val(d, 'type_flags')}" if "type" in d else "-",
                val(d, "gpu_reads_original_bad_bytes"), val(d, "c2g_bad_bytes"), val(d, "g2c_bad_bytes"),
                f"{val(d, 'after_swap_back_cpu_bad_bytes')}/{val(d, 'after_release_cpu_bad_bytes')}",
                f"{val(d, 'after_swap_back_neighbour_maps_same')}/{val(d, 'after_swap_back_lo_bad_bytes')}/{val(d, 'after_swap_back_hi_bad_bytes')}",
                val(d, "window_maps_same_as_before"), val(d, "alias_after_swap_back_bad_bytes"),
                f"{val(d, 'alloc_us')} / {val(d, 'swap_in_us')} / {val(d, 'import_us')} / {val(d, 'swap_back_us')}",
            ])
    head = ["机", "新后备", "客体形状", "大小", "结果", "换入后 CPU 坏字节", "换入后 邻居maps同/lo坏/hi坏", "别名见换入后写",
            "导入类型", "GPU 读原内容坏字节", "c2g 坏字节", "g2c 坏字节", "换回后/释放后 CPU 坏字节",
            "换回后 邻居maps同/lo坏/hi坏", "整窗maps同换入前", "别名换回后坏字节", "alloc / swap_in / import / swap_back us"]
    return table(head, rows)


def maps_example(root, dev, mode, backing_kind):
    for d in load(f"{root}/{dev}/{mode}.jsonl"):
        if d["sec"] == backing_kind and d.get("shape") == "memfd_shared" and d.get("size") == 2 * MB and d["status"] == "ok":
            return "\n".join([f"- 换入前：`{d['before_maps']}`", f"- 换入后：`{d['after_swap_in_maps']}`",
                              f"- 换回后：`{d['after_swap_back_maps']}`"])
    return "（无）"


AHB_KEYS = ["status", "type", "cycle_c2g_bad_bytes", "cycle_g2c_bad_bytes", "persistent_c2g_bad_bytes",
            "persistent_g2c_bad_bytes", "fixed", "fixed_mmap_errno", "fixed_nosync_c2g_bad_bytes", "fixed_nosync_g2c_bad_bytes",
            "fixed_sync_c2g_bad_bytes", "fixed_sync_g2c_bad_bytes", "fixed_alias_lock_ptr", "step", "ahb_err"]
HEAP_KEYS = ["status", "step", "errno", "mmap_fixed_ok", "type", "sync_c2g_bad_bytes", "sync_g2c_bad_bytes",
             "nosync_c2g_bad_bytes", "nosync_g2c_bad_bytes", "cpu_step", "cpu_bad_bytes"]
SWAP_KEYS = ["status", "step", "errno", "after_swap_in_cpu_bad_bytes", "gpu_reads_original_bad_bytes", "c2g_bad_bytes",
             "g2c_bad_bytes", "after_release_cpu_bad_bytes", "window_maps_same_as_before"]


def keyed(lines):
    out = {}
    for d in lines:
        s = d["sec"]
        if s in ("ahb", "ahb_max"):
            out[(s, "", d["size"])] = (d, AHB_KEYS)
        elif s in ("dmabuf", "dmabuf_max", "heapcpu"):
            out[(s, d.get("heap", ""), d.get("size", 0))] = (d, HEAP_KEYS)
        elif s in ("swap_ahb", "swap_heap") and "shape" in d:
            out[(s, d["shape"], d["size"])] = (d, SWAP_KEYS)
        elif s in ("swap_ahb", "swap_heap", "dmabuf") and d["status"] == "unsupported":
            out[(s, "unsupported", 0)] = (d, ["status", "reason"])
        elif s == "dma_heaps":
            out[(s, "", 0)] = (d, ["status", "step", "errno"])
    return out


def brief(d, keys):
    return ", ".join(f"{k}={d[k]}" for k in keys if k in d and k not in ("status",))


def adb_vs_apk(root, devs):
    rows = []
    for dev in devs:
        a, p = keyed(load(f"{root}/{dev}/adb.jsonl")), keyed(load(f"{root}/{dev}/apk.jsonl"))
        same = diff = 0
        for k in sorted(set(a) | set(p), key=lambda x: (x[0], x[1], x[2])):
            da, keys = a.get(k, ({}, []))
            dp, keys2 = p.get(k, ({}, []))
            keys = keys or keys2
            va = {x: da.get(x) for x in keys}
            vp = {x: dp.get(x) for x in keys}
            if va == vp:
                same += 1
                continue
            diff += 1
            rows.append([dev, k[0], k[1], size(k[2]) if k[2] else "-", f"{da.get('status', '缺')}: {brief(da, keys)}",
                         f"{dp.get('status', '缺')}: {brief(dp, keys)}"])
        rows.append([dev, "（合计）", "", "", f"字段一致 {same} 行", f"不一致 {diff} 行"])
    return table(["机", "节", "堆/形状", "大小", "adb（shell）", "APK（untrusted_app）"], rows)


def b_detail(root, devs, mode):
    rows = []
    for dev in devs:
        for d in load(f"{root}/{dev}/{mode}.jsonl"):
            s = d["sec"]
            if s in ("ahb", "ahb_max"):
                rows.append([dev, s, "-", size(d["size"]), d["status"],
                             f"类型{val(d, 'type')}; cycle {val(d, 'cycle_c2g_bad_bytes')}/{val(d, 'cycle_g2c_bad_bytes')}; "
                             f"persistent {val(d, 'persistent_c2g_bad_bytes')}/{val(d, 'persistent_g2c_bad_bytes')}; "
                             f"fixed {val(d, 'fixed')} errno={val(d, 'fixed_mmap_errno')} nosync {val(d, 'fixed_nosync_c2g_bad_bytes')}/{val(d, 'fixed_nosync_g2c_bad_bytes')} "
                             f"sync {val(d, 'fixed_sync_c2g_bad_bytes')}/{val(d, 'fixed_sync_g2c_bad_bytes')}"])
            elif s in ("dmabuf", "dmabuf_max") and "size" in d:
                rows.append([dev, s, d["heap"], size(d["size"]), d["status"],
                             f"MAP_FIXED {val(d, 'mmap_fixed_ok')}; 类型{val(d, 'type')}; sync {val(d, 'sync_c2g_bad_bytes')}/{val(d, 'sync_g2c_bad_bytes')}; "
                             f"nosync {val(d, 'nosync_c2g_bad_bytes')}/{val(d, 'nosync_g2c_bad_bytes')}"])
            elif s in ("dmabuf", "heapcpu") and d["status"] in ("absent", "fail", "unsupported") and "size" not in d or s == "heapcpu":
                rows.append([dev, s, d.get("heap", "-"), size(d["size"]) if "size" in d else "-", d["status"],
                             d.get("reason") or f"step={val(d, 'step')} errno={val(d, 'errno')} cpu={val(d, 'cpu_step')} 坏字节={val(d, 'cpu_bad_bytes')}"])
            elif s == "dma_heaps":
                rows.append([dev, s, "-", "-", d["status"], f"entries={d.get('entries', len(d.get('names', [])))} {brief(d, ['step', 'errno'])}"])
    return table(["机", "节", "堆", "大小", "状态", "读数（坏字节 c2g/g2c）"], rows)


AVC = re.compile(r'avc: +denied +\{ ([^}]*) \} for +(?:comm="([^"]*)" )?.*?scontext=(\S+) tcontext=(\S+) tclass=(\S+)')


def avc_summary(root, devs):
    rows = []
    for dev in devs:
        for mode in ("adb", "apk", "sparse"):
            path = f"{root}/{dev}/{mode}_avc.txt"
            if not os.path.exists(path):
                continue
            seen = {}
            with open(path, encoding="utf-8", errors="replace") as f:
                for line in f:
                    if "v1probe" not in line and "org.s2arm.probe.v1" not in line:
                        continue  # other apps' denials in the same time window
                    if ("scontext=u:r:untrusted_app" in line) != (mode == "apk"):
                        continue  # the previous adb run's last second overlaps the next window
                    m = AVC.search(line)
                    if not m:
                        continue
                    sctx = re.sub(r":c\d+.*", "", m.group(3))
                    name = re.search(r'name="([^"]*)"', line)
                    key = (m.group(1).strip(), sctx, m.group(4), m.group(5), name.group(1) if name else "")
                    seen[key] = seen.get(key, 0) + 1
            if not seen:
                rows.append([dev, mode, "无 avc denied 行", "", "", "", ""])
            for (perm, s, t, c, n), cnt in sorted(seen.items()):
                rows.append([dev, mode, perm, f"`{s}`", f"`{t}`", c, f"{n} ×{cnt // 2 if cnt > 1 else cnt}"])
    return table(["机", "运行", "权限", "scontext", "tcontext", "tclass", "name ×次（auditd 与进程各记一行，已折半）"], rows)


OPS = ["seq_write_memset", "seq_write_64b", "seq_read", "rand_read_4b"]


def bench(root, dev):
    names = sorted((f for f in os.listdir(f"{root}/{dev}") if re.fullmatch(r"bench_\d+\.jsonl", f)), key=lambda f: int(f[6:-6]))
    runs = [r for r in (load(f"{root}/{dev}/{f}") for f in names) if r]
    if not runs:
        return "（无读数）", {}
    setup = [next(x for x in r if x["sec"] == "bench_setup") for r in runs]
    endl = [next((x for x in r if x["sec"] == "bench_end"), {}) for r in runs]
    meta = "; ".join(f"第{i + 1}次 绑核 cpu{s['pinned_cpu']}（max {s['cpu_max_khz']} kHz，起 {s.get('cur_khz_start', '-')} / 止 {e.get('cur_khz_end', '-')} kHz）"
                     for i, (s, e) in enumerate(zip(setup, endl)))
    med = {}
    per_run = {}
    rows = []
    fails = []
    for b in setup[0]["backings"]:
        per = {op: [] for op in OPS}
        sync = []
        detail = gpu = ""
        for r in runs:
            d = next((x for x in r if x["sec"] == "bench" and x["backing"] == b), None)
            if not d:
                continue
            detail, gpu = d["detail"], d.get("gpu", "")
            if d["status"] != "ok":
                fails.append(f"`{b}` 失败：step={d.get('step')} err={d.get('err')}")
                break
            for op in OPS:
                per[op].append(d[op]["median_mib_s"])
                sync += d[op].get("sync_us", [])
        if not per[OPS[0]]:
            continue
        med[b] = {op: statistics.median(per[op]) for op in OPS}
        per_run[b] = per
        rows.append([f"`{b}`", detail, gpu] + [f"**{med[b][op]:.0f}**（{' / '.join(f'{v:.0f}' for v in per[op])}）" for op in OPS]
                    + [f"{min(sync):.0f}–{max(sync):.0f}" if sync else "-"])
    head = ["后备", "映射方式", "GPU 导入"] + [f"{op} MiB/s" for op in OPS] + ["SYNC 耗时 us（单次首+尾）"]
    out = f"{meta}\n\n" + table(head, rows)
    if fails:
        out += "\n\n" + "；".join(dict.fromkeys(fails))
    return out, per_run


def ratios(per_run, pairs):
    """Per run: ratio of the two backings' medians (same run, interleaved passes); then the median."""
    rows = []
    for a, b in pairs:
        if a in per_run and b in per_run:
            cells = []
            for op in OPS:
                rs = [x / y for x, y in zip(per_run[a][op], per_run[b][op])]
                cells.append(f"**{statistics.median(rs):.2f}×**（{' / '.join(f'{r:.2f}' for r in rs)}）")
            rows.append([f"`{a}` ÷ `{b}`"] + cells)
    return table(["比值（每次运行内两后备中位数之比；粗体为各次的中位数）"] + OPS, rows) if rows else "（无可比后备）"


def state(root, dev):
    path = f"{root}/{dev}/state.txt"
    if not os.path.exists(path):
        return "（无）"
    txt = open(path, encoding="utf-8").read()
    temps = re.findall(r"temperature: (\d+)", txt)
    plugged = sorted(set(re.findall(r"(AC|USB|Wireless) powered: true", txt)))
    status = sorted(set(re.findall(r"Thermal Status: (\d+)", txt)))
    return (f"电池温度 {min(temps, default='-')}–{max(temps, default='-')}（0.1°C）；充电：{'/'.join(plugged) or '未插电'} 供电；"
            f"Thermal Status：{'/'.join(status) or '-'}（每次运行前后各记一次，原文见 state.txt）")


def sparse(root, devs):
    rows = []
    for dev in devs:
        lines = load(f"{root}/{dev}/sparse.jsonl")
        caps = next((x for x in lines if x["sec"] == "sparse_caps"), None)
        sp = next((x for x in lines if x["sec"] == "sparse"), None)
        if not caps or not sp:
            continue
        qf = "; ".join(f"族{q['i']} flags {q['flags']} ×{q['count']}{' SPARSE' if q['sparse'] else ''}" for q in caps["queue_families"])
        res = sp["status"] + "：" + (sp.get("reason") or sp.get("step", ""))
        if "chunk_imports" in sp:
            ci = sp["chunk_imports"][0]
            res += (f"；稀疏缓冲 req_bits {sp.get('req_bits')}（对齐 {sp.get('req_alignment')}），AHB 100M 块 memory_type_bits {ci.get('memory_type_bits')}；"
                    f"不带 AHB 句柄的稀疏缓冲 req_bits {sp.get('plain_sparse_req_bits', '-')}；带 AHB 句柄的普通缓冲 req_bits {sp.get('nonsparse_ahb_req_bits', '-')}")
        if "whole_c2g_bad_bytes" in sp:
            res += f"；整段 c2g {sp['whole_c2g_bad_bytes']} / g2c {sp['whole_g2c_bad_bytes']}；边界 {sp.get('boundaries')}"
        rows.append([dev, yn(caps["sparseBinding"]), yn(caps["sparseResidencyBuffer"]), qf,
                     f"{caps.get('ahb_ext_props_sparse_binding')} / {caps.get('ahb_ext_props_sparse_residency')}", res])
    return table(["机", "sparseBinding", "sparseResidencyBuffer", "队列族", "AHB 外部属性（SPARSE_BINDING / +RESIDENCY）", "结果"], rows)


def main():
    root = sys.argv[1]
    devs = sys.argv[2:] or ["8E", "9000"]
    print("### 运行清单\n")
    print(run_meta(root, devs))
    print("\n### V1-a 原地换底（adb shell）\n")
    print(swap_rows(root, devs, "adb"))
    print("\n### V1-a 原地换底（APK 进程内）\n")
    print(swap_rows(root, devs, "apk"))
    for dev in devs:
        kind = "swap_ahb" if dev == "8E" else "swap_heap"
        print(f"\n{dev} `{kind}` memfd_shared 2M 的窗口映射（相对窗口起点，`起-止 权限 inode 名字+文件偏移`）：\n")
        print(maps_example(root, dev, "adb", kind))
    print("\n### V1-b adb 与 APK 对照（逐行比较关键字段，只列不一致的行）\n")
    print(adb_vs_apk(root, devs))
    print("\n### V1-b APK 进程内读数\n")
    print(b_detail(root, devs, "apk"))
    print("\n### V1-b avc denied 行（logcat -b all，运行时间段内，只取 comm/进程为 v1probe 或 app=org.s2arm.probe.v1 的行）\n")
    print(avc_summary(root, devs))
    for dev in devs:
        n = len([f for f in os.listdir(f"{root}/{dev}") if re.fullmatch(r"bench_\d+\.jsonl", f)])
        print(f"\n### V1-c CPU 吞吐（{dev}，64 MiB，{n} 次运行 × 每次 3 轮取中位；粗体为各次运行中位数的中位数，括号内为各次）\n")
        print(state(root, dev) + "\n")
        out, med = bench(root, dev)
        print(out + "\n")
        print(ratios(med, [("heap_system_uncached", "heap_system_nosync"), ("heap_system_uncached", "memfd"),
                           ("heap_system_sync_ends", "heap_system_nosync"), ("ahb_fixed", "memfd")]))
    print("\n### V1-e 稀疏绑定\n")
    print(sparse(root, devs))


if __name__ == "__main__":
    main()
