using System;
using System.IO;
using System.Linq;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text.Json;
using Ryujinx.Graphics.Shader;
using Ryujinx.Graphics.Shader.Decoders;
using System.Reflection;
using Ryujinx.Graphics.Shader.Translation;

static partial class Program
{
    static ulong AtAddress(ulong op, int address) => (op & ~(0x7ffUL << 20)) | ((ulong)address << 20);
    static List<Module> LateModules(bool linked, string test, TargetLanguage language)
    {
        TranslatorContext.S2AStageIndep = false;
        bool layer = test.StartsWith("layer"); bool xfb = test.StartsWith("xfb");
        int varying = test == "xfb-over-limit" ? 31 : test == "xfb-five" ? 5 : 2;
        int fixedAddress = test == "fog" ? AttributeConsts.FogCoord : AttributeConsts.FrontColorDiffuseR;
        ulong[] writes, reads;
        if (layer)
        {
            writes = test == "layer-membership" ? [Ast(5), AtAddress(Ast(0), AttributeConsts.Layer)]
                : [Ast(0), Ast(5), AtAddress(Ast(0), AttributeConsts.Layer)];
            reads = [Ald(5)];
        }
        else if (xfb) { writes = [Ast(varying)]; reads = [Ald(varying)]; }
        else { writes = [AtAddress(Ast(0), fixedAddress)]; reads = [AtAddress(Ald(0), fixedAddress)]; }
        var options = new TranslationOptions(language, TargetApi.Vulkan, TranslationFlags.DebugMode);
        TranslatorContext Context(byte[] code) => Translator.CreateContext(0, new Accessor(code, linked, nativeGs: true, layerVertex: !layer, xfb: xfb, xfbLocation: varying), options);
        var v = Context(Guest(false, writes)); var f = Context(Guest(true, reads, layer ? [5] : xfb ? [varying] : []));
        v.SetNextStage(f);
        var result = new List<Module> { new("vertex", v.Translate(), [3]) };
        if (layer)
        {
            Check(test + "/LayerOutputWritten from actual AST emission", v.LayerOutputWritten);
            result.Add(new("geometry", v.GenerateGeometryPassthrough(), [1, 3]));
        }
        result.Add(new("fragment", f.Translate(), [1]));
        return result;
    }
    static int[] Locations(byte[] bytes, uint storage)
    {
        var w = MemoryMarshal.Cast<byte, uint>(bytes).ToArray(); var variables = new HashSet<uint>(); var locations = new SortedSet<int>();
        for (int i = 5; i < w.Length; i += (int)(w[i] >> 16))
            if ((w[i] & 65535) == 59 && w[i + 3] == storage) variables.Add(w[i + 2]);
        for (int i = 5; i < w.Length; i += (int)(w[i] >> 16))
            if ((w[i] & 65535) == 71 && w[i + 2] == 30 && variables.Contains(w[i + 1])) locations.Add((int)w[i + 3]);
        return locations.ToArray();
    }
    static int[] ShaderLocations(ShaderProgram shader, uint storage)
    {
        if (shader.Language == TargetLanguage.Spirv) return Locations(shader.BinaryCode, storage);
        return System.Text.RegularExpressions.Regex.Matches(shader.Code, @"layout \([^\r\n)]*location = (?<loc>\d+)[^\r\n)]*\)(?<decl>[^;\r\n]*);")
            .Where(m => System.Text.RegularExpressions.Regex.IsMatch(m.Groups["decl"].Value, storage == 1 ? @"\bin\b" : @"\bout\b"))
            .Select(m => int.Parse(m.Groups["loc"].Value)).Distinct().Order().ToArray();
    }
    static int LateInterfaceCases()
    {
        var records = new List<object>();
        foreach (string test in new[] { "fog", "fixed-color", "layer-membership", "layer-geometry", "xfb-identity", "xfb-five", "xfb-over-limit" })
        foreach (var language in new[] { TargetLanguage.Spirv, TargetLanguage.Glsl })
        {
            string name = test + "-" + language; List<Module> baseline;
            try { baseline = LateModules(false, test, language); Check(name + "/legacy paired translates", true); }
            catch (Exception e) { Check(name + "/legacy paired translates", false); records.Add(new { name, baselineError = e.ToString() }); continue; }
            foreach (var m in baseline)
            {
                string stem = Path.Combine(Output, name + "-legacy-" + m.Name);
                if (language == TargetLanguage.Spirv) File.WriteAllBytes(stem + ".spv", m.Shader.BinaryCode);
                else File.WriteAllText(stem + ".glsl", m.Shader.Code);
            }
            try
            {
                var candidate = LateModules(true, test, language);
                if (test == "xfb-over-limit" && language == TargetLanguage.Spirv) { Check(name + "/over-limit identity must be rejected by budget", false); continue; }
                var interfaces = new List<object>();
                foreach (var m in candidate)
                {
                    string stem = Path.Combine(Output, name + "-linked-" + m.Name);
                    if (language == TargetLanguage.Spirv)
                    {
                        File.WriteAllBytes(stem + ".spv", m.Shader.BinaryCode);
                        
                    }
                    else File.WriteAllText(stem + ".glsl", m.Shader.Code);
                }
                if (test.StartsWith("layer"))
                {
                    var vs = ShaderLocations(candidate[0].Shader, 3); var gi = ShaderLocations(candidate[1].Shader, 1);
                    var go = ShaderLocations(candidate[1].Shader, 3); var fi = ShaderLocations(candidate[2].Shader, 1);
                    Check(name + "/actual generated GS consumes producer locations", gi.Length > 0 && gi.All(vs.Contains));
                    Check(name + "/actual FS consumes generated GS locations", fi.Length > 0 && fi.All(go.Contains));
                    Check(name + "/generated GS preserves complete identity modules", candidate.Zip(baseline).All(pair => language == TargetLanguage.Spirv
                        ? pair.First.Shader.BinaryCode.SequenceEqual(pair.Second.Shader.BinaryCode)
                        : pair.First.Shader.Code == pair.Second.Shader.Code));
                }
                else if (test is "fog" or "fixed-color" or "xfb-identity" or "xfb-five" or "xfb-over-limit")
                {
                    Check(name + "/identity preserves complete emitted module", candidate.Zip(baseline).All(pair => language == TargetLanguage.Spirv
                        ? pair.First.Shader.BinaryCode.SequenceEqual(pair.Second.Shader.BinaryCode)
                        : pair.First.Shader.Code == pair.Second.Shader.Code));
                }
                else Check(name + "/linked translates", true);
                records.Add(new { name, linkedException = (string)null, interfaces });
            }
            catch (Exception e)
            {
                bool expectedBudget = test == "xfb-over-limit" && e is NotSupportedException && e.Message.Contains("host limit");
                Check(name + (test == "xfb-over-limit" ? "/over-limit identity must be rejected by budget" : "/linked interface remains supported"), expectedBudget);
                Console.WriteLine(e.ToString()); records.Add(new { name, linkedException = e.ToString() });
            }
        }
        try
        {
            var baseline29 = Translate(false, Enumerable.Range(0, 29).ToArray(), [0], "direct", TargetLanguage.Glsl);
            File.WriteAllText(Path.Combine(Output, "glsl-29-legacy.vert"), baseline29[0].Shader.Code);
            Check("29 output legacy GLSL translates", true);
            var candidate29 = Translate(true, Enumerable.Range(0, 29).ToArray(), [0], "direct", TargetLanguage.Glsl);
            File.WriteAllText(Path.Combine(Output, "glsl-29-candidate.vert"), candidate29[0].Shader.Code);
            Check("29 output linked-cap GLSL retains exact legacy source", candidate29[0].Shader.Code == baseline29[0].Shader.Code);
        }
        catch (Exception e)
        {
            Check("29 output linked GLSL remains legal", false);
            records.Add(new { name = "glsl-29", linkedException = e.ToString() });
            Console.WriteLine(e.ToString());
        }
        try
        {
            var options = new TranslationOptions(TargetLanguage.Spirv, TargetApi.Vulkan, TranslationFlags.DebugMode);
            var ops = Enumerable.Range(0, 31).Select(l => Ast(l) | (1UL << 19)).Append(Ast(31)).ToArray();
            List<Module> Predicated(bool linked)
            {
                TranslatorContext.S2AStageIndep = false;
                var v = Translator.CreateContext(0, new Accessor(Guest(false, ops), linked), options);
                var f = Translator.CreateContext(0, new Accessor(Guest(true, [Ald(31)], [31]), linked), options);
                Check("false-predicate decoder keeps only live output demand", v.AttributeUsage.UsedOutputAttributes == (1 << 31));
                v.SetNextStage(f);
                return [new("vertex", v.Translate(), [3]), new("fragment", f.Translate(), [1])];
            }
            var baseline = Predicated(false);
            Check("false-predicate actual legacy IR emits only Location31", Locations(baseline[0].Shader.BinaryCode, 3).SequenceEqual([31]));
            var linked = Predicated(true);
            foreach (var m in linked) File.WriteAllBytes(Path.Combine(Output, "false-producer-" + m.Name + ".spv"), m.Shader.BinaryCode);
            Check("false-predicate final interface fits one varying", Locations(linked[0].Shader.BinaryCode, 3).SequenceEqual([0]));
            Check("false-predicate preserves complete module", linked.Zip(baseline).All(pair => Normalize(pair.First.Shader.BinaryCode, pair.First.MappedStorage, [31]).SequenceEqual(pair.Second.Shader.BinaryCode)));
        }
        catch (Exception e)
        {
            Check("false-predicate final interface fits one varying", false);
            records.Add(new { name = "false-predicate", linkedException = e.ToString() });
        }
        try
        {
            TranslatorContext.S2AStageIndep = false;
            var options = new TranslationOptions(TargetLanguage.Spirv, TargetApi.Vulkan, TranslationFlags.DebugMode);
            var reads = Enumerable.Range(0, 31).Select(l => Ald(l) | (1UL << 19)).Append(Ald(31)).ToArray();
            List<Module> Consumer(bool linked)
            {
                var v = Translator.CreateContext(0, new Accessor(Guest(false, [Ast(31)]), linked), options);
                var f = Translator.CreateContext(0, new Accessor(Guest(true, reads, Enumerable.Range(0, 32).ToArray()), linked), options);
                v.SetNextStage(f);
                return [new("vertex", v.Translate(), [3]), new("fragment", f.Translate(), [1])];
            }
            var baseline = Consumer(false); var linked = Consumer(true);
            foreach (var m in linked) File.WriteAllBytes(Path.Combine(Output, "false-consumer-" + m.Name + ".spv"), m.Shader.BinaryCode);
            Check("false-consumer demand keeps one real output and input", Locations(linked[0].Shader.BinaryCode, 3).SequenceEqual([0]) && Locations(linked[1].Shader.BinaryCode, 1).SequenceEqual([0]));
            Check("false-consumer preserves complete emitted modules", linked.Zip(baseline).All(pair => Normalize(pair.First.Shader.BinaryCode, pair.First.MappedStorage, [31]).SequenceEqual(pair.Second.Shader.BinaryCode)));
        }
        catch (Exception e)
        {
            Check("false-consumer demand keeps one real output and input", false);
            records.Add(new { name = "false-consumer", linkedException = e.ToString() });
        }
        PredicateUsageCases();
        LateEmissionOrderCases();
        File.WriteAllText(Path.Combine(Output, "results.json"), JsonSerializer.Serialize(new { failed = Failed, checks = Checks, records }, new JsonSerializerOptions { WriteIndented = true }));
        return Failed == 0 ? 0 : 1;
    }
    static void PredicateUsageCases()
    {
        var options = new TranslationOptions(TargetLanguage.Spirv, TargetApi.Vulkan, TranslationFlags.DebugMode);
        var accessor = new Accessor(Guest(false, []), true);
        var translator = Translator.CreateContext(0, accessor, options);
        var contextType = typeof(Decoder).GetNestedType("Context", BindingFlags.NonPublic);
        var register = typeof(Decoder).GetMethod("SetUserAttributeUses", BindingFlags.NonPublic | BindingFlags.Static);
        foreach (string opcode in new[] { "AST", "ALD", "IPA" })
        foreach (string predicate in new[] { "true", "false", "dynamic", "nopred" })
        {
            ulong raw = opcode == "AST" ? Ast(5) : opcode == "ALD" ? Ald(5) : 0xe000000000000000UL | ((ulong)(0x80 + 5 * 16) << 28) | (7UL << 16);
            if (predicate is "false" or "nopred") raw |= 1UL << 19;
            if (predicate == "dynamic") raw &= ~(7UL << 16);
            var instruction = InstTable.GetOp(0, raw);
            // NoPred is a controlled flag at the real registration boundary; these three decoded opcodes are predicated.
            if (predicate == "nopred") instruction = new InstOp(0, raw, instruction.Name, instruction.Emitter, instruction.Props | InstProps.NoPred);
            object context = Activator.CreateInstance(contextType, [accessor]);
            register.Invoke(null, [translator.Definitions, context, instruction]);
            var usage = (AttributeUsage)contextType.GetProperty("AttributeUsage").GetValue(context);
            int mask = opcode == "AST" ? usage.UsedOutputAttributes : usage.UsedInputAttributes;
            Check(opcode + "/" + predicate + " actual IO registration", mask == (predicate == "false" ? 0 : 1 << 5));
        }
        foreach (bool never in new[] { false, true })
        {
            ulong raw = AtAddress(Ald(0), AttributeConsts.FogCoord) | (never ? 1UL << 19 : 0);
            var instruction = InstTable.GetOp(0, raw);
            object context = Activator.CreateInstance(contextType, [accessor]);
            register.Invoke(null, [translator.Definitions, context, instruction]);
            var flags = (FeatureFlags)contextType.GetProperty("UsedFeatures").GetValue(context);
            Check("fixed-function demand tracks predicate " + never, flags.HasFlag(FeatureFlags.FixedFuncAttr) == !never);
        }
    }
    static void LateEmissionOrderCases()
    {
        foreach (bool consumerFirst in new[] { false, true })
        {
            TranslatorContext.S2AStageIndep = false;
            var options = new TranslationOptions(TargetLanguage.Spirv, TargetApi.Vulkan, TranslationFlags.DebugMode);
            var v = Translator.CreateContext(0, new Accessor(Guest(false, [AtAddress(Ast(0), AttributeConsts.FogCoord)]), true), options);
            var f = Translator.CreateContext(0, new Accessor(Guest(true, [AtAddress(Ald(0), AttributeConsts.FogCoord)]), true), options);
            v.SetNextStage(f);
            ShaderProgram fs = consumerFirst ? f.Translate() : null;
            var vs = v.Translate(); fs ??= f.Translate();
            Check("late Fog remains aligned with consumerFirst=" + consumerFirst,
                Locations(fs.BinaryCode, 1).Length > 0 && Locations(fs.BinaryCode, 1).All(Locations(vs.BinaryCode, 3).Contains));
        }
        try
        {
            var options = new TranslationOptions(TargetLanguage.Spirv, TargetApi.Vulkan, TranslationFlags.DebugMode);
            var v = Translator.CreateContext(0, new Accessor(Guest(false, [Ast(5), AtAddress(Ast(0), AttributeConsts.Layer)]), true, nativeGs: true, layerVertex: false), options);
            var f = Translator.CreateContext(0, new Accessor(Guest(true, [Ald(5)], [5]), true), options);
            v.SetNextStage(f); f.Translate(); v.Translate();
            Check("late identity cannot alter already emitted compact consumer", false);
        }
        catch (InvalidOperationException e)
        {
            Check("late identity cannot alter already emitted compact consumer", e.Message.Contains("after compact shader emission"));
        }
        // Invoke the real generated-GS API with a compact interface; Layer's required identity alone cannot prove inheritance.
        List<Module> CompactGeometry(bool linked)
        {
            TranslatorContext.S2AStageIndep = false;
            var options = new TranslationOptions(TargetLanguage.Spirv, TargetApi.Vulkan, TranslationFlags.DebugMode);
            var v = Translator.CreateContext(0, new Accessor(Guest(false, [Ast(5)]), linked), options);
            var f = Translator.CreateContext(0, new Accessor(Guest(true, [Ald(5)], [5]), linked), options);
            v.SetNextStage(f);
            return [new("vertex", v.Translate(), [3]), new("geometry", v.GenerateGeometryPassthrough(), [1, 3]), new("fragment", f.Translate(), [1])];
        }
        var compact = CompactGeometry(true); var legacyCompact = CompactGeometry(false);
        foreach (var m in compact) File.WriteAllBytes(Path.Combine(Output, "compact-helper-" + m.Name + ".spv"), m.Shader.BinaryCode);
        Check("compact generated GS inherits both real interface ends", ShaderLocations(compact[1].Shader, 1).SequenceEqual([0]) && ShaderLocations(compact[1].Shader, 3).SequenceEqual([0]));
        Check("compact generated GS preserves all module semantics", compact.Zip(legacyCompact).All(p => Normalize(p.First.Shader.BinaryCode, p.First.MappedStorage, [5]).SequenceEqual(p.Second.Shader.BinaryCode)));
        foreach (bool independent in new[] { false, true })
        {
            ShaderProgram Glsl(bool linked)
            {
                TranslatorContext.S2AStageIndep = independent;
                var options = new TranslationOptions(TargetLanguage.Glsl, TargetApi.Vulkan, TranslationFlags.DebugMode);
                var v = Translator.CreateContext(0, new Accessor(Guest(false, [Ast(5)]), linked), options);
                var f = Translator.CreateContext(0, new Accessor(Guest(true, [Ald(5)], [5]), linked), options);
                v.SetNextStage(f); return v.Translate();
            }
            var old = Glsl(false); var current = Glsl(true);
            Check("GLSL effective policy unchanged at stage-independent=" + independent, old.Code == current.Code);
        }
    }

}
