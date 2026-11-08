using System;
using System.IO;
using System.Linq;
using System.Collections.Generic;
using System.Security.Cryptography;
using System.Text.Json;
using Ryujinx.Graphics.Shader;
using Ryujinx.Graphics.Shader.Translation;
static partial class Program
{
    static int VtgLayerCase()
    {
        var records = new List<object>();
        byte[][] baselineModules = null;
        foreach (bool linked in new[] { false, true })
        {
            TranslatorContext.S2AStageIndep = false;
            string label = linked ? "candidate" : "legacy-paired";
            try
            {
                var options = new TranslationOptions(TargetLanguage.Spirv, TargetApi.Vulkan, TranslationFlags.DebugMode);
                var v = Translator.CreateContext(0, new Accessor(Guest(false, [Ast(0), Ast(5), AtAddress(Ast(0), AttributeConsts.Layer), 0xEEDC00000007FFFFUL]), linked, nativeGs:true, layerVertex:false), options);
                var f = Translator.CreateContext(0, new Accessor(Guest(true, [Ald(5)], [5]), linked, nativeGs:true, layerVertex:false), options);
                if (!v.HasStore) throw new InvalidOperationException("real STG must set HasStore for actual VTG admission");
                Console.WriteLine(label+" HasStore="+v.HasStore+"; actual ShaderCache.ShouldConvertVertexToCompute admits when SupportsVertexStoreAndAtomics=false");
                v.SetNextStage(f);
                var compute = v.Translate(true);
                var vertex = v.GenerateVertexPassthroughForCompute();
                var geometry = v.GenerateGeometryPassthrough();
                var fragment = f.Translate();
                var modules = new[] { ("compute",compute), ("vertex",vertex), ("geometry",geometry), ("fragment",fragment) };
                if (!linked) baselineModules = modules.Select(m => m.Item2.BinaryCode).ToArray();
                else Check("VTG + Layer preserves all four complete modules", modules.Select(m => m.Item2.BinaryCode).Zip(baselineModules).All(p => p.First.SequenceEqual(p.Second)));
                Check(label + " actual STG enters HasStore contract", v.HasStore);
                var info = new List<object>();
                foreach (var (name,shader) in modules)
                {
                    string file = Path.Combine(Output,label+"-"+name+".spv");
                    File.WriteAllBytes(file,shader.BinaryCode);
                    info.Add(new { name, file, sha256=Convert.ToHexStringLower(SHA256.HashData(shader.BinaryCode)), inputs=Locations(shader.BinaryCode,1), outputs=Locations(shader.BinaryCode,3) });
                }
                var vo=Locations(vertex.BinaryCode,3); var gi=Locations(geometry.BinaryCode,1); var go=Locations(geometry.BinaryCode,3); var fi=Locations(fragment.BinaryCode,1);
                bool aligned=gi.Length>0 && gi.All(vo.Contains) && fi.Length>0 && fi.All(go.Contains);
                Console.WriteLine(label+" VS="+string.Join(',',vo)+" GS-in="+string.Join(',',gi)+" GS-out="+string.Join(',',go)+" FS="+string.Join(',',fi)+" aligned="+aligned+" original.FinalOutputAttributes="+v.AttributeUsage.FinalOutputAttributes);
                Check(label+" actual VTG generated Layer-GS interface aligns",aligned);
                records.Add(new { label, aligned, hasStore=v.HasStore, supportsVertexStoreAndAtomics=false, originalFinalOutputMask=v.AttributeUsage.FinalOutputAttributes, modules=info });
            }
            catch (Exception e)
            {
                Check(label+" actual VTG generated Layer-GS translates",false);
                Console.WriteLine(e.ToString()); records.Add(new { label, error=e.ToString() });
            }
        }
        foreach (int limit in new[] { 39, 38 })
        {
            var options = new TranslationOptions(TargetLanguage.Spirv, TargetApi.Vulkan, TranslationFlags.DebugMode);
            var v = Translator.CreateContext(0, new Accessor(Guest(false, [Ast(0), Ast(5), AtAddress(Ast(0), AttributeConsts.Layer), 0xEEDC00000007FFFFUL]), true, vertexLimit:limit, nativeGs:true, layerVertex:false), options);
            var f = Translator.CreateContext(0, new Accessor(Guest(true, [Ald(5)], [5]), true, nativeGs:true, layerVertex:false), options);
            v.SetNextStage(f); v.Translate(true);
            try
            {
                v.GenerateVertexPassthroughForCompute();
                Check("VTG actual VS exact budget " + limit, limit == 39);
            }
            catch (NotSupportedException e)
            {
                Console.WriteLine(e.Message);
                Check("VTG actual VS exact budget " + limit, limit == 38 && e.Message.Contains("24 user endpoint + 15 built-in components; host limit 38"));
                var producer = typeof(TranslatorContext).GetField("_vertexPassthroughAttributeUsage", System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Instance).GetValue(v);
                Check("failed VTG VS generation publishes no producer", producer == null);
            }
        }
        File.WriteAllText(Path.Combine(Output,"results.json"),JsonSerializer.Serialize(new {failed=Failed,checks=Checks,records},new JsonSerializerOptions {WriteIndented=true}));
        return Failed==0 ? 0 : 1;
    }
}
