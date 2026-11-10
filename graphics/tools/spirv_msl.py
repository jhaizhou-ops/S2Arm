#!/usr/bin/env python3
"""Vulkan / GLSL 共用的 SPIR-V → MSL；缺省参数保留 vk_shaders.py 原产物。"""

import hashlib
import json
import os
import re
import struct
import subprocess
import sys

MAGIC = 0x07230203
OP_DECORATE, OP_MEMBER_DECORATE, OP_TYPE_ARRAY, OP_TYPE_RTARRAY, OP_TYPE_STRUCT = 71, 72, 28, 29, 30
DEC_ARRAY_STRIDE, DEC_BINDING, DEC_SET = 6, 33, 34
KINDS = {
    "ubos": "u",
    "ssbos": "b",
    "separate_images": "t",
    "images": "t",
    "separate_samplers": "s",
    "textures": "c",
    "subpass_inputs": "t",  # input attachments are read as textures
}
SLOT_CLASS = {
    "u": "buffer",
    "b": "buffer",
    "t": "texture",
    "s": "sampler",
    "c": "texture",
    "p": "buffer",
}
# GLSL's FMin / FMax / FClamp, which spirv-cross writes as fast::min / max / clamp, leave a NaN operand's result to the GPU; the Switch's GPU returns the other operand, as Metal's
# precise:: functions (IEEE fmin / fmax) do on every GPU. Super Mario Galaxy 2's GX lighting normalizes light directions the game leaves at (0, 0, 0) (the key and fill lights of
# its characters) and takes max(0, dot(ldir, NaN)) as the spot term: 0 on the Switch and on the M4 Pro, so the attenuation is 1; on an A20 Pro (iPhone) the half of Mario
# that the fill light (from the camera's left) faces came out white (GitHub issue 72)
PRECISE = re.compile(r"\bfast::(min|max|clamp)\(")


def metal_cmd(sdk, tool, *args):
    """Metal 编译器命令行：Mac 走 xcrun -sdk <平台> <工具>；Windows 出包机（Windows 出包机）没有 xcrun，用苹果官方 Metal Developer Tools for Windows 的 <工具>.exe
    （S2A_METAL_BIN，缺省 C:\\Program Files\\Metal Developer Tools\\bin；同 graphics/tools/direct/dsh/batch/Build.cs 的 Metal.WinBin / Tool）。参数同一份，只换前缀；
    Windows 上平台由参数里的最低版本号定（-mios-version-min / -mmacosx-version-min），调用方给 Mac 目标也要写明"""
    if os.name == 'nt':
        return [os.path.join(os.environ.get('S2A_METAL_BIN') or r'C:\Program Files\Metal Developer Tools\bin', tool + '.exe'), *[str(a) for a in args]]
    return ['xcrun', '-sdk', sdk, tool, *[str(a) for a in args]]


def metal_run(cmd, work, **kw):
    """跑 metal_cmd 给的命令。Windows 版 metal.exe / metallib.exe 会把参数里的空格再拆开（#257），metallib.exe 还按 ANSI 代码页开文件、
    路径里有非 ASCII 字符就「LLVM ERROR: Error opening」（11-09 外部报告：中文用户名，Windows 出包机实测中文绝对路径失败、工作目录 + 相对路径通过）。
    所以 Windows 上工作目录设成 work（调用方的临时目录，输入 / 输出都放在它下面），work 下的绝对路径一律改成相对路径；改完仍含空格或非 ASCII 就报错，
    不交给编译器（同 graphics/tools/direct/dsh/batch/Build.cs WinRelative）。Mac 原样跑"""
    if os.name != 'nt':
        return subprocess.run(cmd, **kw)
    out = [cmd[0]]
    for a in cmd[1:]:
        a = str(a)
        if os.path.isabs(a):
            r = os.path.relpath(a, work)
            if not r.startswith('..'):
                a = r
        if any(ch == ' ' or ord(ch) > 127 for ch in a):
            raise ValueError(f'Metal 编译器（Windows 版）不认带空格或非 ASCII 字符的路径，而 {a} 不在工作目录 {work} 下，没法改成相对路径')
        out.append(a)
    return subprocess.run(out, cwd=work, **kw)


def red(msg):
    sys.exit("[RED] " + msg)


def spirv_files(root):
    # 遍历与文件头经 graphics/nvn/tools/romfs_list.py（仓库里唯一的 RomFS 遍历；RomFS 的头按内容身份落盘清单，同一份 RomFS 各阶段只读一次）；
    # 顺序同原先 os.walk + 每层 sorted，打不开的文件同原先在碰到时抛错
    sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "nvn", "tools"))
    import romfs_list
    tree = romfs_list.heads(root)
    byrel = {e.rel: e for e in tree.entries}
    for d, _, fs in tree.walk():
        rd = os.path.relpath(d, tree.top)
        for f in sorted(fs):
            p = os.path.join(d, f)
            e = byrel.get(f if rd == "." else rd.replace(os.sep, "/") + "/" + f)
            if e is None or not e.file:
                open(p, "rb").close()
                continue
            head = e.read()[1][:4]
            if len(head) == 4 and struct.unpack("<I", head)[0] == MAGIC:
                yield p


def decorations(words):
    """variable id → {'set': n, 'binding': n, 'binding_at': word index of the binding value}"""
    out, i = {}, 5
    while i < len(words):
        op, n = words[i] & 0xFFFF, words[i] >> 16
        if n == 0:
            red("SPIR-V instruction length 0")
        if op == OP_DECORATE and n >= 4:
            v = out.setdefault(words[i + 1], {})
            if words[i + 2] == DEC_BINDING:
                v["binding"], v["binding_at"] = words[i + 3], i + 3
            elif words[i + 2] == DEC_SET:
                v["set"] = words[i + 3]
        i += n
    return out


def fix_strides(words):
    """Super Mario Galaxy's generated shaders put ArrayStride on the struct member (OpMemberDecorate) instead of on the array type: NVIDIA's driver accepts it, spirv-cross
    stops with "Struct member does not have ArrayStride set". Copy each such stride onto its array type, inserted after the last of those member decorations"""
    arrays, have, member, members, at, i = set(), set(), [], {}, None, 5
    while i < len(words):
        op, n = words[i] & 0xFFFF, words[i] >> 16
        if n == 0:
            red("SPIR-V instruction length 0")
        if op == OP_DECORATE and n >= 4 and words[i + 2] == DEC_ARRAY_STRIDE:
            have.add(words[i + 1])
        elif op == OP_MEMBER_DECORATE and n >= 5 and words[i + 3] == DEC_ARRAY_STRIDE:
            member.append((words[i + 1], words[i + 2], words[i + 4]))
            at = i + n
        elif op in (OP_TYPE_ARRAY, OP_TYPE_RTARRAY):
            arrays.add(words[i + 1])
        elif op == OP_TYPE_STRUCT:
            members[words[i + 1]] = words[i + 2 : i + n]
        i += n
    add = {}
    for st, m, stride in member:
        t = members.get(st, [])[m] if m < len(members.get(st, [])) else None
        if t in arrays and t not in have:
            add.setdefault(t, stride)
    if not add:
        return words
    return (
        words[:at]
        + [w for t, s in add.items() for w in ((4 << 16) | OP_DECORATE, t, DEC_ARRAY_STRIDE, s)]
        + words[at:]
    )


OP_VARIABLE, OP_DECORATION_GROUP, OP_GROUP_DECORATE, OP_GROUP_MEMBER_DECORATE, OP_DECORATE_ID, OP_DECORATE_STRING, OP_MEMBER_DECORATE_STRING = 59, 73, 74, 75, 332, 5632, 5633
RESOURCE_CLASSES = {0: "UniformConstant", 2: "Uniform", 12: "StorageBuffer"}


def fix_bindings(words, path=""):
    """A descriptor variable with no Binding decoration (Minecraft's bgfx shaders: the HLSL `$Global` uniform block carries DescriptorSet 0 but no Binding)
    is bound at 0 by the console's driver, as SPIR-V decorations take their default 0 (spirv-cross reads it as 0 as well; its reflection merely omits the key).
    Write that 0 into the module as a real OpDecorate, so the slot assignment below (which patches the Binding word in place) sees every resource.
    Two resources ending up on the same (set, binding) is a real conflict, not a default: stop with a red line instead of guessing"""
    dec, var, ann_end, i = {}, {}, None, 5
    while i < len(words):
        op, n = words[i] & 0xFFFF, words[i] >> 16
        if n == 0:
            red("SPIR-V instruction length 0")
        if op in (OP_DECORATE, OP_MEMBER_DECORATE, OP_DECORATION_GROUP, OP_GROUP_DECORATE, OP_GROUP_MEMBER_DECORATE,
                  OP_DECORATE_ID, OP_DECORATE_STRING, OP_MEMBER_DECORATE_STRING):
            ann_end = i + n
            if op == OP_DECORATE and n >= 4 and words[i + 2] in (DEC_BINDING, DEC_SET):
                dec.setdefault(words[i + 1], {})[words[i + 2]] = words[i + 3]
        elif op == OP_VARIABLE and n >= 4 and words[i + 3] in RESOURCE_CLASSES:
            var[words[i + 2]] = words[i + 3]
        i += n
    missing = [v for v in var if DEC_BINDING not in dec.get(v, {})]
    if not missing:
        return words
    if ann_end is None:
        red(f"{path}: descriptor variables {missing} have no Binding decoration and the module has no annotation section to put one in")
    taken = {(d.get(DEC_SET, 0), d[DEC_BINDING]) for v, d in dec.items() if v in var and DEC_BINDING in d}
    for v in missing:
        pair = (dec.get(v, {}).get(DEC_SET, 0), 0)
        if pair in taken:
            red(f"{path}: descriptor variable %{v} ({RESOURCE_CLASSES[var[v]]}) has no Binding; its default (set {pair[0]}, binding 0) is already taken")
        taken.add(pair)
    return words[:ann_end] + [w for v in missing for w in ((4 << 16) | OP_DECORATE, v, DEC_BINDING, 0)] + words[ann_end:]


def translate(
    path,
    tmp,
    root,
    *,
    stages=("vert", "frag", "comp"),
    key=None,
    entry_name=None,
    flip_vert_y=True,
    fixup_clipspace=False,
    varying_names=False,
    dual_source=True,
    texture_1d_as_2d=True,
):
    data = open(path, "rb").read()
    if len(data) % 4:
        red(f"{path}: SPIR-V length {len(data)} is not a multiple of 4")
    key = key or hashlib.sha256(data).hexdigest()[:16]  # of the game's words, which the host hashes
    name = entry_name or f"vk_{key}"
    stem = entry_name or key
    words = fix_bindings(fix_strides(list(struct.unpack(f"<{len(data) // 4}I", data))), path)
    src_spv = os.path.join(tmp, stem + ".in.spv")
    open(src_spv, "wb").write(struct.pack(f"<{len(words)}I", *words))
    refl = json.loads(
        subprocess.run(
            ["spirv-cross", src_spv, "--reflect"], capture_output=True, text=True, check=True
        ).stdout
    )
    eps = refl.get("entryPoints", [])
    if len(eps) != 1:
        red(f"{path}: entry points {eps} are not exactly one")
    stage = eps[0]["mode"]
    if stage not in stages:
        return stage  # skipped (main counts them)
    wg = None
    if stage == "comp":
        if any(eps[0].get("workgroup_size_is_spec_constant_id", [0, 0, 0])):
            return "comp (workgroup size from specialization constants)"
        wg = eps[0].get("workgroup_size") or [1, 1, 1]
    dec = decorations(words)
    by_pair, count = {}, {}
    for k, kind in KINDS.items():
        for r in refl.get(k, []):
            pair = (r.get("set", 0), r["binding"])
            by_pair[pair] = kind
            dims = r.get("array") or [1]
            if len(dims) != 1 or not dims[0]:
                red(
                    f"{path}: array dimensions {dims} of resource {r.get('name')} are not implemented"
                )
            count[pair] = dims[
                0
            ]  # an array of n descriptors takes n consecutive slots (Super Mario Galaxy: 4 position-matrix uniform buffers, 8 textures)
    pcs = refl.get("push_constants", [])
    if len(pcs) > 1:
        red(f"{path}: {len(pcs)} push constant blocks")
    slots, nxt, res = {}, {"buffer": 0, "texture": 0, "sampler": 0}, []
    for _vid, d in sorted(dec.items(), key=lambda t: (t[1].get("set", 0), t[1].get("binding", 0))):
        if "binding_at" not in d:
            continue
        pair = (d.get("set", 0), d["binding"])
        kind = by_pair.get(pair)
        if not kind:
            continue  # declared but unused: spirv-cross drops it
        if pair in slots:
            n = slots[pair]
        else:
            cls, k = SLOT_CLASS[kind], count[pair]
            if kind == "c":  # a combined sampler takes the same index as texture and as sampler: past both cursors (gal_vkx.m does the same; audit 1101 18:00 P1-19)
                n = max(nxt["texture"], nxt["sampler"])
                nxt["texture"] = nxt["sampler"] = n + k
            else:
                n = nxt[cls]
                nxt[cls] += k
            slots[pair] = n
            res.append(f"{kind}:{pair[0]}.{pair[1]}={n}" + (f"*{k}" if k > 1 else ""))
        words[d["binding_at"]] = n
    pc_slot = nxt["buffer"] if pcs else None
    if pcs:
        nxt["buffer"] += 1
    if nxt["buffer"] > 16 or nxt["texture"] > 31 or nxt["sampler"] > 16:
        red(f"{path}: resource slots exceeded {nxt}")
    spv = os.path.join(tmp, stem + ".spv")
    msl = os.path.join(tmp, stem + ".metal")
    open(spv, "wb").write(struct.pack(f"<{len(words)}I", *words))
    cmd = [
        "spirv-cross",
        spv,
        "--msl",
        "--msl-version",
        "30100",  # MSL 3.1, same as the direct NVN chain and the generic renderer: image atomics are native (2.3 emulates them with an extra buffer the host never binds; audit #1534 P1-66)
        "--msl-decoration-binding",
        *(["--msl-texture-1d-as-2d"] if texture_1d_as_2d else []),
        "--rename-entry-point",
        "main",
        name,
        stage,
        "--output",
        msl,
    ]
    if stage == "vert" and flip_vert_y:
        cmd.append("--flip-vert-y")
    if stage == "vert" and fixup_clipspace:
        cmd.append("--fixup-clipspace")
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode:
        red(f"{path}: spirv-cross failed: {r.stderr.strip()[:300]}")
    # The reflection lists every declared resource; the Metal entry point only takes the ones the shader uses (Hades' ShadowMap.frag declares a buffer it never reads,
    # which the game's own pipeline layout leaves out): keep the rows whose slot is an argument of the entry point, so the host only binds, and only reports, real ones
    src = open(msl).read()
    m = re.search(r"\b" + re.escape(name) + r"\((.*?)\)\s*\{", src, re.S)
    if not m:
        red(f"{path}: entry point {name} not found in the translated MSL")
    if pcs:  # the push-constant argument is `constant <block type>& name [[buffer(0)]]`: move it to its own slot
        tname = refl["types"][pcs[0]["type"]]["name"]
        a = re.search(
            r"constant\s+" + re.escape(tname) + r"&\s+\w+\s+\[\[buffer\((\d+)\)\]\]", m.group(1)
        )
        if a:
            s0, s1 = m.start(1) + a.start(1), m.start(1) + a.end(1)
            src = src[:s0] + str(pc_slot) + src[s1:]
            open(msl, "w", encoding="utf-8", newline="\n").write(src)
            m = re.search(r"\b" + re.escape(name) + r"\((.*?)\)\s*\{", src, re.S)
            res.append(f"p:0.0={pc_slot}")
    used = {
        (c, int(n)) for c, n in re.findall(r"\[\[(buffer|texture|sampler)\((\d+)\)\]\]", m.group(1))
    }
    res = [x for x in res if (SLOT_CLASS[x[0]], int(x.rsplit("=", 1)[1].split("*")[0])) in used]
    if wg:
        res.append(f"w:{wg[0]}.{wg[1]}={wg[2]}")
    if varying_names:
        # GL links implicit varyings by name; stages are compiled independently.
        src = re.sub(
            r"(\b(\w+)\s+\[\[)user\(locn\d+\)", lambda match: f"{match[1]}user({match[2]})", src
        )
    src = PRECISE.sub(r"precise::\1(", src)
    open(msl, "w", encoding="utf-8", newline="\n").write(src)
    msls = [msl]
    if (
        dual_source and stage == "frag" and "[[color(1)]]" in src
    ):  # dual-source variant vk_<key>_d: the output at location 1 becomes the second blend source of attachment 0
        msl_d = os.path.join(tmp, stem + "_d.metal")
        msls.append(msl_d)
        open(msl_d, "w", encoding="utf-8", newline="\n").write(
            src.replace(name, name + "_d").replace("[[color(1)]]", "[[color(0), index(1)]]")
        )
    return key, stage, res, msls, "/" + os.path.relpath(path, root)
