#!/usr/bin/env python3
# 门禁手动：要传参数：--deps 预构建 Ryujinx.Common.dll / Spv.Generator.dll 目录（门禁机没有固定的依赖目录）；Varying.Tests.csproj 无参部分已由 tests/vulkan_backend_test.sh 门禁跑
"""Snapshot actual translator inputs, then compile/run offline in an isolated output directory."""
import argparse, hashlib, json, pathlib, shutil, subprocess
p=argparse.ArgumentParser()
p.add_argument('--dotnet', required=True); p.add_argument('--deps', type=pathlib.Path, required=True)
group=p.add_mutually_exclusive_group()
group.add_argument('--late-interface', action='store_true')
group.add_argument('--vtg-layer', action='store_true')
group.add_argument('--spirv-layer', action='store_true')
p.add_argument('--mutation', choices=('omit-input-map','omit-passthrough-map','omit-producer-union','omit-cache-policy','collide-locations','omit-budget','omit-decoder-predicate','omit-gs-map','omit-identity','omit-late-guard','omit-language','omit-language-policy','omit-indexed-domain','omit-vtg-producer','omit-core-layer','rotate-legacy-metal','omit-legacy-route-key'))
p.add_argument('--out', type=pathlib.Path, required=True); p.add_argument('--source-root', type=pathlib.Path)
a=p.parse_args(); here=pathlib.Path(__file__).resolve().parent
repo=(a.source_root or here.parents[3]).resolve(); out=a.out.resolve()
shader=(repo/'compat/tree/src/Ryujinx.Graphics.Shader').resolve(); deps=a.deps.resolve()
# Reject before mkdir: otherwise rglob can discover and recursively copy its own output.
for source in (repo, shader, deps, here):
    if out == source or out.is_relative_to(source):
        p.error(f'--out must be outside every input tree: {source}')
out.mkdir(parents=True,exist_ok=False)
records={}
def copy(src,dst):
    dst.parent.mkdir(parents=True,exist_ok=True); shutil.copyfile(src,dst)
    records[str(src)]=hashlib.sha256(dst.read_bytes()).hexdigest()
for f in shader.rglob('*'):
    if f.suffix in ('.cs','.glsl') and not any(x in ('bin','obj') for x in f.relative_to(shader).parts): copy(f,out/'source'/f.relative_to(shader))
for rel in ('graphics/vulkan/cache/ComputeTranslationProfile.cs','compat/tree/src/Ryujinx.Graphics.GAL/IComputeTranslationProfileProvider.cs','compat/tree/src/Ryujinx.Graphics.GAL/Capabilities.cs','compat/tree/src/Ryujinx.Graphics.GAL/Format.cs','compat/tree/src/Ryujinx.Graphics.GAL/SystemMemoryType.cs','compat/tree/src/Ryujinx.Graphics.Gpu/Shader/DiskCache/HostCacheCapabilities.cs','compat/tree/src/Ryujinx.Graphics.Gpu/GraphicsConfig.cs','graphics/metal/cs/caps/NxCaps.cs'):
    copy(repo/rel,out/'source/fixture-dependencies'/pathlib.Path(rel).name)
for name in ('Ryujinx.Common.dll','Spv.Generator.dll'): copy(deps/name,out/'deps'/name)
for name in ('Program.cs','LateInterfaceCases.cs','VtgLayerCase.cs','SpirvLayerCase.cs','Varying.Tests.csproj'): copy(here/name,out/name)
(out/'NuGet.Config').write_text('<configuration><packageSources><clear/></packageSources></configuration>\n')
mutations={
 'rotate-legacy-metal': ('source/fixture-dependencies/HostCacheCapabilities.cs','if (usesSpirv && !capabilities.S2ASpirv15 && !capabilities.S2ASpirvLayerExt)','if (usesSpirv)'),
 'omit-legacy-route-key': ('source/fixture-dependencies/HostCacheCapabilities.cs','if (usesSpirv && !capabilities.S2ASpirv15 && !capabilities.S2ASpirvLayerExt)','if (false)'),
 'omit-core-layer': ('source/CodeGen/Spirv/SpirvGenerator.cs','if (context.IsSpirv15)','if (false && context.IsSpirv15)'),
 'omit-vtg-producer': ('source/Translation/TranslatorContext.cs','_vertexPassthroughAttributeUsage = attributeUsage;',''),
 'omit-input-map': ('source/Translation/AttributeUsage.cs','nextStage._linkedInputs = _linkedOutputs;',''),
 'omit-passthrough-map': ('source/Translation/TranslatorContext.cs','attributeUsage.InheritLinkedOutputs(AttributeUsage);',''),
 'omit-producer-union': ('source/Translation/AttributeUsage.cs','_linkedOutputs?.Include(outputMask);',''),
 'collide-locations': ('source/Translation/AttributeUsage.cs','return BitOperations.PopCount(_mask & ((1u << logicalLocation) - 1));','return 0;'),
 'omit-budget': ('source/CodeGen/Spirv/Declarations.cs','budget.Validate();',''),
 'omit-decoder-predicate': ('source/Decoders/Decoder.cs','if (!instruction.Props.HasFlag(InstProps.NoPred) &&','if (false && !instruction.Props.HasFlag(InstProps.NoPred) &&'),
 'omit-gs-map': ('source/Translation/TranslatorContext.cs','attributeUsage.InheritLinkedOutputs(producerUsage, passthroughInputs: true);',''),
 'omit-identity': ('source/Translation/AttributeUsage.cs','if (_identityOnlyReason != null) return logicalLocation;',''),
 'omit-late-guard': ('source/Translation/AttributeUsage.cs','if (_emitted)\n                    {','if (false)\n                    {'),
 'omit-language': ('source/fixture-dependencies/HostCacheCapabilities.cs','writer.Write(usesSpirv);\n            writer.Write(usesSpirv && capabilities.RequiresLinkedVaryingInterface);',''),
 'omit-language-policy': ('source/Translation/AttributeUsage.cs','language == TargetLanguage.Spirv && _gpuAccessor.QueryHostRequiresLinkedVaryingInterface()','_gpuAccessor.QueryHostRequiresLinkedVaryingInterface()'),
 'omit-indexed-domain': ('source/Translation/AttributeUsage.cs','if (logicalLocation >= _locationCount)','if (false)'),

 'omit-cache-policy': ('source/fixture-dependencies/HostCacheCapabilities.cs','writer.Write(usesSpirv && capabilities.RequiresLinkedVaryingInterface);\n            writer.Write(capabilities.RequiresLinkedVaryingInterface);',''),
}
if a.mutation:
    rel,old,new=mutations[a.mutation]; path=out/rel; text=path.read_text()
    if text.count(old)!=1: raise RuntimeError('mutation seam changed')
    path.write_text(text.replace(old,new)); records['MUTANT:'+rel]=hashlib.sha256(path.read_bytes()).hexdigest()
(out/'input-sha.json').write_text(json.dumps(records,indent=2)+'\n')
commands=[[a.dotnet,'build','Varying.Tests.csproj','-c','Release','--configfile','NuGet.Config','--nologo'],[a.dotnet,'bin/Release/net10.0/Ryujinx.Graphics.Shader.dll',str(out/'results')]+(['late-interface'] if a.late_interface else ['vtg-layer'] if a.vtg_layer else ['spirv-layer'] if a.spirv_layer else [])]
rc=0
for index,cmd in enumerate(commands):
    with (out/f'command-{index}.log').open('w') as log: r=subprocess.run(cmd,cwd=out,stdout=log,stderr=subprocess.STDOUT)
    rc=r.returncode
    if rc: break
expected={
 'rotate-legacy-metal': 'FAIL legacy Metal EXT cache identity remains unchanged',
 'omit-legacy-route-key': 'FAIL unsupported layer route cannot load legacy EXT cache',
 'omit-core-layer': 'FAIL core1 capability selection',
 'omit-vtg-producer': 'FAIL candidate actual VTG generated Layer-GS interface aligns',
 'omit-input-map': 'IndexOutOfRangeException',
 'omit-passthrough-map': 'IndexOutOfRangeException',
 'omit-producer-union': 'Unlinked varying location',
 'omit-cache-policy': 'FAIL cache identity changes: RequiresLinkedVaryingInterface',
 'collide-locations': 'FAIL direct-both/vertex preserves complete module except paired Location',
 'omit-budget': 'FAIL actual 32 outputs cannot fit; no output dropped',
 'omit-decoder-predicate': 'FAIL false-consumer demand keeps one real output and input',
 'omit-gs-map': 'FAIL compact generated GS inherits both real interface ends',
 'omit-identity': 'FAIL xfb-identity-Spirv/identity preserves complete emitted module',
 'omit-late-guard': 'FAIL late identity cannot alter already emitted compact consumer',
 'omit-language': 'FAIL actual GLSL selection has distinct host cache identity',
 'omit-language-policy': 'FAIL GLSL effective policy unchanged at stage-independent=True',
 'omit-indexed-domain': 'FAIL dynamic sparse beyond actual array domain is diagnosed',

}
matched = rc == 0 if not a.mutation else index == 1 and rc != 0 and expected[a.mutation] in (out/'command-1.log').read_text()
(out/'receipt.json').write_text(json.dumps({'commands':commands,'exit_code':rc,'mutation':a.mutation,'expectation_matched':matched,'scope':'Host Release JIT; actual authored Maxwell/IR/codegen. No GPU/device execution.'},indent=2)+'\n')
print(out,rc,'expectation_matched',matched);raise SystemExit(0 if matched else 1)
