using System;
using System.IO;
using System.Linq;
using Ryujinx.Graphics.Shader;
using Ryujinx.Graphics.Shader.Translation;

static partial class Program
{
    static int SpirvLayerCase()
    {
        foreach (bool core in new[] { false, true })
        foreach (int outputs in new[] { 1, 2, 3 })
        {
            var ops = new System.Collections.Generic.List<ulong> { Ast(0) };
            if ((outputs & 1) != 0) ops.Add(AtAddress(Ast(0), AttributeConsts.Layer));
            if ((outputs & 2) != 0) ops.Add(AtAddress(Ast(0), AttributeConsts.ViewportIndex));
            // A real global store exercises storage buffer declarations and entry-point interfaces.
            ops.Add(0xEEDC00000007FFFFUL);
            var options = new TranslationOptions(TargetLanguage.Spirv, TargetApi.Vulkan, TranslationFlags.DebugMode);
            var context = Translator.CreateContext(0, new Accessor(Guest(false, ops.ToArray()), false, spirv15: core), options);
            var module = context.Translate();
            byte[] bytes = module.BinaryCode;
            string label = (core ? "core" : "ext") + outputs;
            File.WriteAllBytes(Path.Combine(Output, label + ".spv"), bytes);
            uint[] words = new uint[bytes.Length / 4];
            Buffer.BlockCopy(bytes, 0, words, 0, bytes.Length);
            var capabilities = new System.Collections.Generic.HashSet<uint>();
            for (int i = 5; i < words.Length;)
            {
                int size = (int)(words[i] >> 16);
                if (size <= 0 || i + size > words.Length) throw new InvalidDataException("invalid instruction");
                if ((words[i] & 0xffff) == 17 && size == 2) capabilities.Add(words[i + 1]);
                i += size;
            }
            Check(label + " version", words[1] == (core ? 0x00010500u : 0x00010300u));
            Check(label + " capability selection", core
                ? !capabilities.Contains(5254) && capabilities.Contains(69) == ((outputs & 1) != 0) && capabilities.Contains(70) == ((outputs & 2) != 0)
                : capabilities.Contains(5254) && !capabilities.Contains(69) && !capabilities.Contains(70));
        }
        foreach (bool core in new[] { false, true })
        {
            var options = new TranslationOptions(TargetLanguage.Spirv, TargetApi.Vulkan, TranslationFlags.DebugMode);
            var v = Translator.CreateContext(0, new Accessor(Guest(false,
                [Ast(0), Ast(5), AtAddress(Ast(0), AttributeConsts.Layer), 0xEEDC00000007FFFFUL]),
                false, nativeGs: true, layerVertex: true, spirv15: core), options);
            var f = Translator.CreateContext(0, new Accessor(Guest(true, [Ald(5)], [5]), false,
                nativeGs: true, layerVertex: true, spirv15: core), options);
            v.SetNextStage(f);
            v.Translate(true);
            byte[] bytes = v.GenerateVertexPassthroughForCompute().BinaryCode;
            string label = core ? "vtg-core" : "vtg-ext";
            File.WriteAllBytes(Path.Combine(Output, label + ".spv"), bytes);
            uint[] words = new uint[bytes.Length / 4];
            Buffer.BlockCopy(bytes, 0, words, 0, bytes.Length);
            bool hasCore = false, hasExt = false;
            for (int i = 5; i < words.Length; i += (int)(words[i] >> 16))
            {
                if ((words[i] & 0xffff) == 17) { hasCore |= words[i + 1] == 69; hasExt |= words[i + 1] == 5254; }
            }
            Check(label + " actual VTG passthrough capability", core ? hasCore && !hasExt : hasExt && !hasCore);
        }
        var guest = Guest(false, [Ast(0), AtAddress(Ast(0), AttributeConsts.Layer)]);
        var legacyOptions = new TranslationOptions(TargetLanguage.Spirv, TargetApi.Vulkan, TranslationFlags.DebugMode);
        byte[] nv = Translator.CreateContext(0, new Accessor(guest, false, legacyExt: false, legacyNv: true), legacyOptions).Translate().BinaryCode;
        File.WriteAllBytes(Path.Combine(Output, "nv.spv"), nv);
        string nvText = System.Text.Encoding.ASCII.GetString(nv);
        Check("NV-only path declares its own SPIR-V extension", nvText.Contains("SPV_NV_viewport_array2") && !nvText.Contains("SPV_EXT_shader_viewport_index_layer"));
        bool rejected = false;
        try { Translator.CreateContext(0, new Accessor(guest, false, legacyExt: false), legacyOptions).Translate(); }
        catch (NotSupportedException e) { rejected = e.Message.Contains("No enabled SPIR-V Layer/ViewportIndex output route"); }
        Check("no enabled legacy route is rejected", rejected);
        return Failed == 0 ? 0 : 1;
    }
}
