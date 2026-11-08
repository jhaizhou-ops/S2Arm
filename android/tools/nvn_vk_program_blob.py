#!/usr/bin/env python3
"""C2 program.json → 新 Vulkan 后端（nvn_vk_be）的程序二进制描述。

布局（小端）：magic "NVKP", u32 version=1, u32 stage_count, u32 binding_count,
stage_count × { u32 nvn_stage(0=vs,4=ps), u32 spirv_bytes, SPIR-V（4 字节对齐）},
binding_count × { u32 set, u32 binding, u32 kind(1=uniform_buffer,2=combined_image_sampler), u32 count }。
只做格式转换，不改编译结果；不写游戏专用规则。
"""
import base64, json, struct, sys

def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    doc = json.load(open(sys.argv[1], encoding='utf-8'))
    content = doc['content']
    stages, bindings = [], []
    for st in content['stages']:
        name = st['stage']
        no = {'vs': 0, 'fs': 4, 'ps': 4}.get(name)
        if no is None:
            raise SystemExit(f'unsupported stage {name}')
        spv = base64.b64decode(st['spirv'])
        if len(spv) % 4:
            raise SystemExit(f'{name}: SPIR-V not 4-byte aligned')
        stages.append((no, spv))
    for b in content['bindings']:
        kind = {'uniform': 1, 'support': 1, 'texture': 2}.get(b['kind'])
        if kind is None:
            raise SystemExit(f"unsupported binding kind {b['kind']}")
        bindings.append((b.get('set', 0), b.get('binding', 0), kind, b.get('count', 1)))
    out = bytearray(b'NVKP' + struct.pack('<III', 1, len(stages), len(bindings)))
    for no, spv in stages:
        out += struct.pack('<II', no, len(spv)) + spv + b'\0' * (-len(spv) % 4)
    for st, bi, kind, count in bindings:
        out += struct.pack('<IIII', st, bi, kind, count)
    open(sys.argv[2], 'wb').write(out)
    print(f'nvn_vk program blob: {len(stages)} stage(s), {len(bindings)} binding(s), {len(out)} B')

if __name__ == '__main__':
    main()
