#!/usr/bin/env python3
"""管线描述脚本（nxgal NXGAL_PSO_SCRIPT 收的 Metal 4 pipelines script）→ metal-tt 能编的输入（.mtl4-json）。
用法：pso_script.py <输出.mtl4-json> <gal.metallib> <描述.json> [描述.json …]
- 多份描述合并、按内容去重（种子局 / 回归局 / 各次回放收的都可以并进来）。
- 离线着色器库是从内存载入的，描述里 path 为「_Path_not_available_for_lib_from_data_with_UUID_…」：换成给定的 gal.metallib。
  只认一个离线库：各份描述里 from_data 的库 UUID 都映射到它（同一包内只有一个 gal.metallib）。
- 渲染器内部辅助管线（清屏 / 上屏 / 索引转换等，MSL 源码现编，from_source）没有文件可指：连同它们的函数描述一起去掉，报去掉几条。
之后：xcrun metal-tt -target air64-apple-ios27.0 <输出.mtl4-json> -o <归档.metallib>（Xcode 27 工具链；扩展名必须 .mtl4-json，.mtlp-json 是 Metal 3 格式）。"""
import json, sys

out, lib, ins = sys.argv[1], sys.argv[2], sys.argv[3:]
libs, fns, render, compute = {}, {}, {}, {}
dropped = 0
for p in ins:
    j = json.load(open(p))
    keep_lib = {}
    for l in j.get('libraries', []):
        if 'from_data' in l['path']: keep_lib[l['label']] = 'gal'   # 离线库
        elif not l['path'].startswith('_Path_not_available'): keep_lib[l['label']] = l['label']; libs[l['label']] = l['path']
    good_fn = set()
    for f in j.get('function_descriptors', {}).get('library_function_descriptors', []):
        if f['library'] in keep_lib:
            f = dict(f); f['library'] = keep_lib[f['library']]; fns[f['label']] = f; good_fn.add(f['label'])
    pd = j.get('pipeline_descriptors', {})
    for kind, dst, keys in (('render_pipeline_descriptors', render, ('vertex_function_descriptor', 'fragment_function_descriptor')),
                            ('compute_pipeline_descriptors', compute, ('compute_function_descriptor',))):
        for d in pd.get(kind, []):
            refs = [d[k][4:] for k in keys if d.get(k, '').startswith('fnd:')]
            d = {k: v for k, v in d.items() if k != 'options'}   # 诊断局（开着色器校验 / 反射）录的描述带 options.shader_validation_configuration 等，归档编译器不认、也不属于管线身份：剥掉再去重（10-19 动森归档因此编译失败）
            if all(r in good_fn for r in refs): dst[json.dumps(d, sort_keys=True)] = d
            else: dropped += 1
libs['gal'] = lib
used = {d[k][4:] for d in list(render.values()) + list(compute.values()) for k in d if k.endswith('function_descriptor') and isinstance(d[k], str) and d[k].startswith('fnd:')}
res = {'version': {'major': 0, 'minor': 1, 'sub_minor': 0}, 'generator': 'MetalFramework',
       'libraries': [{'label': k, 'path': v} for k, v in libs.items()],
       'function_descriptors': {'library_function_descriptors': [f for k, f in fns.items() if k in used]},
       'pipeline_descriptors': {'render_pipeline_descriptors': list(render.values()), 'compute_pipeline_descriptors': list(compute.values())}}
json.dump(res, open(out, 'w'), indent=1)
print(f'合并 {len(ins)} 份描述：渲染管线 {len(render)}、计算管线 {len(compute)}（去重后），函数 {len(res["function_descriptors"]["library_function_descriptors"])}；'
      f'去掉内部辅助管线 {dropped} 条（源码现编，无文件可指）', file=sys.stderr)
