using Ryujinx.Graphics.GAL;
using S2Arm.Backends.Vulkan.ProgramCache;
using System;
using System.Buffers.Binary;
using System.Collections.Generic;
using System.Linq;
using System.Security.Cryptography;

// Exercise the public codec with real GAL values, independently of any GPU/device limits.
static class MetadataBoundaryTests
{
    private static void Check(bool condition, string message)
    {
        if (!condition)
            throw new Exception(message);
    }

    private static void Reject(Action action, string code)
    {
        try
        {
            action();
        }
        catch (ProgramBinaryException e)
        {
            Check(e.Code == code, "expected " + code + ", got " + e.Code);
            return;
        }
        throw new Exception("accepted invalid metadata; expected " + code);
    }

    private static ProgramBinary WithState(ProgramBinary p, ProgramPipelineState state) =>
        p with { Info = new(p.Info.FragmentOutputMap, p.Info.ResourceLayout, state, p.Info.FromCache) };

    private static ProgramBinary WithArray(ProgramBinary p, int capacity, int used)
    {
        ResourceLayout layout = new(
            Array.AsReadOnly(new[] { new ResourceDescriptorCollection(Array.AsReadOnly(new[] {
                new ResourceDescriptor(9, capacity, ResourceType.Image, ResourceStages.Fragment) })) }),
            Array.AsReadOnly(new[] { new ResourceUsageCollection(Array.AsReadOnly(new[] {
                new ResourceUsage(9, used, ResourceType.Image, ResourceStages.Fragment, true) })) }));
        return p with { Info = new(p.Info.FragmentOutputMap, layout, p.Info.State.Value, p.Info.FromCache) };
    }

    private static ProgramBinary WithRecords(ProgramBinary p, params int[] counts)
    {
        ResourceDescriptorCollection[] sets = counts.Select(count => new ResourceDescriptorCollection(
            Array.AsReadOnly(Enumerable.Range(0, count).Select(binding =>
                new ResourceDescriptor(binding, 1, ResourceType.Image, ResourceStages.Fragment)).ToArray()))).ToArray();
        ResourceUsageCollection[] usages = counts.Select(_ =>
            new ResourceUsageCollection(Array.AsReadOnly(Array.Empty<ResourceUsage>()))).ToArray();
        return p with { Info = new(p.Info.FragmentOutputMap,
            new ResourceLayout(Array.AsReadOnly(sets), Array.AsReadOnly(usages)), p.Info.State.Value, p.Info.FromCache) };
    }

    private static ProgramBinary RoundTrip(ProgramBinary p)
    {
        byte[] bytes = ProgramBinaryCodec.Encode(p);
        ProgramBinary decoded = ProgramBinaryCodec.Decode(bytes, p.Identity);
        Check(bytes.SequenceEqual(ProgramBinaryCodec.Encode(decoded)), "roundtrip changed bytes");
        return decoded;
    }

    // Locate a unique complete field pattern in a valid envelope, replace one signed integer,
    // and refresh the integrity digest so Decode must validate the metadata, not just the hash.
    private static byte[] ReplaceInt(byte[] bytes, byte[] pattern, int offset, int value)
    {
        byte[] changed = (byte[])bytes.Clone();
        int found = -1;
        for (int i = 48; i <= changed.Length - pattern.Length; i++)
        {
            if (!changed.AsSpan(i, pattern.Length).SequenceEqual(pattern))
                continue;
            Check(found == -1, "mutation pattern must be unique");
            found = i;
        }
        Check(found != -1, "mutation pattern missing");
        BinaryPrimitives.WriteInt32LittleEndian(changed.AsSpan(found + offset), value);
        SHA256.HashData(changed.AsSpan(48)).CopyTo(changed, 16);
        return changed;
    }

    private static byte[] Ints(params int[] values)
    {
        byte[] bytes = new byte[values.Length * 4];
        for (int i = 0; i < values.Length; i++)
            BinaryPrimitives.WriteInt32LittleEndian(bytes.AsSpan(i * 4), values[i]);
        return bytes;
    }

    internal static int Run(ProgramBinary graphics)
    {
        List<(string Name, Action Test)> cases = new();
        ProgramPipelineState state = graphics.Info.State.Value;
        state.VertexAttribCount = 1;
        state.VertexBufferCount = 1;
        state.VertexAttribs[0] = new(0, 0x1234, false, Format.R32Float);
        ProgramBinary vertex = WithState(graphics, state);
        byte[] attribute = Ints(0, 0x1234).Concat(new byte[] { 0 }).Concat(Ints((int)Format.R32Float)).ToArray();
        foreach (int index in new[] { -1, int.MinValue, 1, 32, int.MaxValue })
        {
            cases.Add(("active vertex index " + index + " rejected by Encode", () =>
            {
                ProgramPipelineState bad = state;
                bad.VertexAttribs[0] = new(index, 0x1234, false, Format.R32Float);
                Reject(() => ProgramBinaryCodec.Encode(WithState(graphics, bad)), "METADATA");
            }));
            cases.Add(("active vertex index " + index + " rejected by Decode", () =>
                Reject(() => ProgramBinaryCodec.Decode(ReplaceInt(ProgramBinaryCodec.Encode(vertex), attribute, 0, index),
                    graphics.Identity), "METADATA")));
        }
        cases.Add(("last active GAL buffer slot accepted", () =>
        {
            ProgramPipelineState last = state;
            last.VertexBufferCount = 32;
            last.VertexBuffers[31] = new(true, 16, 0);
            last.VertexAttribs[0] = new(31, 0x1234, false, Format.R32Float);
            Check(RoundTrip(WithState(graphics, last)).Info.State.Value.VertexAttribs[0].BufferIndex == 31,
                "last valid buffer slot lost");
        }));
        cases.Add(("zero attribute and dormant vertex slots retain unused signed fields", () =>
        {
            ProgramPipelineState dormant = state;
            dormant.VertexBufferCount = 0;
            dormant.VertexAttribs[0] = new(int.MinValue, 0, true, Format.R32Float);
            dormant.VertexAttribs[1] = new(-1, int.MinValue, false, Format.R32Float);
            dormant.VertexAttribs[31] = new(int.MaxValue, -1, false, Format.R32Float);
            dormant.VertexBuffers[31] = new(true, -1, int.MinValue);
            Check(RoundTrip(WithState(graphics, dormant)).Info.State.Value.Equals(dormant), "dormant metadata lost");
        }));
        cases.Add(("usage exceeding descriptor capacity rejected by Encode", () =>
            Reject(() => ProgramBinaryCodec.Encode(WithArray(graphics, 1, 2)), "LAYOUT")));
        cases.Add(("usage exceeding descriptor capacity rejected by Decode", () =>
        {
            byte[] encoded = ProgramBinaryCodec.Encode(WithArray(graphics, 2, 2));
            byte[] descriptor = Ints(1, 9, 2, (int)ResourceType.Image, (int)ResourceStages.Fragment, 1);
            Reject(() => ProgramBinaryCodec.Decode(ReplaceInt(encoded, descriptor, 8, 1), graphics.Identity), "LAYOUT");
        }));
        cases.Add(("usage smaller than descriptor capacity retained", () =>
        {
            ResourceLayout decoded = RoundTrip(WithArray(graphics, 4, 2)).Info.ResourceLayout;
            Check(decoded.Sets[0].Descriptors[0].Count == 4 && decoded.SetUsages[0].Usages[0].ArrayLength == 2,
                "capacity and usage conflated");
        }));
        // 8192 is reachable from a 64 KiB guest uniform buffer / 8-byte texture handle.
        // Larger scalar values prove this is a representation check, not an invented device limit.
        foreach (int elements in new[] { 1, 8192, 16384, int.MaxValue })
        {
            cases.Add(("scalar array extent " + elements + " retained without element allocation", () =>
            {
                ProgramBinary p = WithArray(graphics, elements, elements);
                ProgramBinary decoded = RoundTrip(p);
                Check(decoded.Info.ResourceLayout.Sets[0].Descriptors[0].Count == elements &&
                    decoded.Info.ResourceLayout.SetUsages[0].Usages[0].ArrayLength == elements, "array extent changed");
                Check(ProgramBinaryCodec.Encode(p).Length == ProgramBinaryCodec.Encode(WithArray(graphics, 1, 1)).Length,
                    "scalar extent must not allocate per-element wire data");
            }));
        }
        foreach (int invalid in new[] { 0, -1, int.MinValue })
        {
            cases.Add(("non-positive array capacity " + invalid + " rejected", () =>
                Reject(() => ProgramBinaryCodec.Encode(WithArray(graphics, invalid, 1)), "LAYOUT")));
            cases.Add(("non-positive usage extent " + invalid + " rejected", () =>
                Reject(() => ProgramBinaryCodec.Encode(WithArray(graphics, 1, invalid)), "LAYOUT")));
        }
        cases.Add(("8192 resource records across sets fit the collection budget", () =>
        {
            ResourceLayout decoded = RoundTrip(WithRecords(graphics, 4096, 4096)).Info.ResourceLayout;
            Check(decoded.Sets.Sum(set => set.Descriptors.Count) == 8192, "record collection lost entries");
        }));
        cases.Add(("per-set record budget still rejects 4097 records", () =>
            Reject(() => ProgramBinaryCodec.Encode(WithRecords(graphics, 4097)), "LAYOUT")));
        cases.Add(("total record budget still rejects 8193 records", () =>
            Reject(() => ProgramBinaryCodec.Encode(WithRecords(graphics, 4096, 4096, 1)), "LIMIT")));
        cases.Add(("oversized wire record count rejected before collection allocation", () =>
        {
            byte[] encoded = ProgramBinaryCodec.Encode(WithArray(graphics, 2, 2));
            byte[] descriptor = Ints(1, 9, 2, (int)ResourceType.Image, (int)ResourceStages.Fragment, 1);
            Reject(() => ProgramBinaryCodec.Decode(ReplaceInt(encoded, descriptor, 0, int.MaxValue), graphics.Identity), "LIMIT");
        }));
        int failures = 0;
        foreach ((string name, Action test) in cases)
        {
            try
            {
                test();
                Console.WriteLine("PASS " + name);
            }
            catch (Exception e)
            {
                failures++;
                Console.WriteLine("FAIL " + name + ": " + e.Message);
            }
        }
        Console.WriteLine($"METADATA_BOUNDARIES total={cases.Count} passed={cases.Count - failures} failed={failures} gpu_executed=false");
        Check(failures == 0, "metadata boundary failures: " + failures);
        return cases.Count;
    }
}
