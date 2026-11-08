using Ryujinx.Graphics.GAL;
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using static S2Arm.Backends.Vulkan.ProgramCache.ProgramBinaryCodec;

namespace S2Arm.Backends.Vulkan.ProgramCache;

// Field codec over actual GAL structs, not a parallel reflection/layout model.
internal static class ProgramBinaryMetadata
{
    internal static void Validate(ShaderInfo info)
    {
        ResourceLayout layout = info.ResourceLayout;
        Require(layout.Sets != null && layout.SetUsages != null && layout.Sets.Count == layout.SetUsages.Count &&
            layout.Sets.Count <= 16, "LAYOUT", "complete descriptor and usage sets required");
        int total = 0;
        for (int set = 0; set < layout.Sets.Count; set++)
        {
            var descriptors = layout.Sets[set].Descriptors;
            var usages = layout.SetUsages[set].Usages;
            Require(descriptors != null && usages != null && descriptors.Count <= 4096 && usages.Count <= 4096,
                "LAYOUT", "missing/oversized resource collections");
            total += descriptors.Count + usages.Count;
            Require(total <= 8192, "LIMIT", "resource total exceeds local bound");
            HashSet<int> bindings = new();
            foreach (ResourceDescriptor d in descriptors)
            {
                Resource(d.Binding, d.Count, d.Type, d.Stages);
                Require(bindings.Add(d.Binding), "LAYOUT", "duplicate descriptor binding");
            }
            foreach (ResourceUsage u in usages)
            {
                Resource(u.Binding, u.ArrayLength, u.Type, u.Stages);
                // ShaderInfoBuilder reserves stages absent from this program too; do not narrow masks.
                Require(descriptors.Any(d => d.Binding == u.Binding && d.Type == u.Type &&
                    (u.Stages & ~d.Stages) == 0 && u.ArrayLength <= d.Count),
                    "LAYOUT", "usage has no matching descriptor capacity");
            }
        }
        if (info.State is ProgramPipelineState state)
        {
            Require(state.VertexAttribCount is >= 0 and <= 32 && state.VertexBufferCount is >= 0 and <= 32,
                "METADATA", "pipeline vertex counts out of range");
            for (int i = 0; i < state.VertexAttribCount; i++)
            {
                VertexAttribDescriptor attribute = state.VertexAttribs[i];
                // PipelineConverter adds one for its zero binding before indexing buffer state.
                // IsZero ignores BufferIndex; dormant attributes are serialized without alteration.
                Require(attribute.IsZero || (attribute.BufferIndex >= 0 && attribute.BufferIndex < state.VertexBufferCount),
                    "METADATA", "active vertex attribute references an undeclared buffer slot");
            }
            Require(float.IsFinite(state.LineWidth), "METADATA", "non-finite line width");
            Require(state.SamplesCount == 0 || (state.SamplesCount <= 64 && state.SamplesCount > 0 &&
                (state.SamplesCount & (state.SamplesCount - 1)) == 0), "METADATA", "invalid sample count");
        }
    }

    private static void Resource(int binding, int count, ResourceType type, ResourceStages stages)
    {
        // Count/ArrayLength is a scalar GAL extent, not the number of serialized records.
        // Device descriptor limits belong to the effective-capability admission step.
        Require(binding >= 0 && binding <= 65535 && count > 0 && Enum.IsDefined(type) &&
            stages != 0 && ((int)stages & ~63) == 0, "LAYOUT", "invalid resource metadata");
    }

    internal static void Write(BinaryWriter w, ShaderInfo info)
    {
        w.Write(info.FragmentOutputMap);
        w.Write(info.FromCache);
        w.Write(info.State.HasValue);
        ResourceLayout l = info.ResourceLayout;
        w.Write(l.Sets.Count);
        for (int set = 0; set < l.Sets.Count; set++)
        {
            w.Write(l.Sets[set].Descriptors.Count);
            foreach (ResourceDescriptor d in l.Sets[set].Descriptors)
            {
                w.Write(d.Binding);
                w.Write(d.Count);
                w.Write((int)d.Type);
                w.Write((int)d.Stages);
            }
            w.Write(l.SetUsages[set].Usages.Count);
            foreach (ResourceUsage u in l.SetUsages[set].Usages)
            {
                w.Write(u.Binding);
                w.Write(u.ArrayLength);
                w.Write((int)u.Type);
                w.Write((int)u.Stages);
                w.Write(u.Write);
            }
        }
        if (info.State.HasValue)
            WriteState(w, info.State.Value);
    }

    internal static ShaderInfo Read(BinaryReader r)
    {
        int fragmentMap = r.ReadInt32();
        bool fromCache = Bool(r), hasState = Bool(r);
        int n = Count(r, 16);
        ResourceDescriptorCollection[] sets = new ResourceDescriptorCollection[n];
        ResourceUsageCollection[] uses = new ResourceUsageCollection[n];
        int total = 0;
        for (int set = 0; set < n; set++)
        {
            int count = Count(r, 4096);
            total += count;
            Require(total <= 8192, "LIMIT", "descriptor total too large");
            ResourceDescriptor[] ds = new ResourceDescriptor[count];
            for (int i = 0; i < count; i++)
                ds[i] = new(r.ReadInt32(), r.ReadInt32(), E<ResourceType>(r), Stages(r));
            sets[set] = new(Array.AsReadOnly(ds));
            count = Count(r, 4096);
            total += count;
            Require(total <= 8192, "LIMIT", "usage total too large");
            ResourceUsage[] us = new ResourceUsage[count];
            for (int i = 0; i < count; i++)
                us[i] = new(r.ReadInt32(), r.ReadInt32(), E<ResourceType>(r), Stages(r), Bool(r));
            uses[set] = new(Array.AsReadOnly(us));
        }
        ResourceLayout layout = new(Array.AsReadOnly(sets), Array.AsReadOnly(uses));
        return hasState ? new ShaderInfo(fragmentMap, layout, ReadState(r), fromCache) : new ShaderInfo(fragmentMap, layout, fromCache);
    }

    private static ResourceStages Stages(BinaryReader r)
    {
        int value = r.ReadInt32();
        Require(value > 0 && (value & ~63) == 0, "LAYOUT", "invalid stage mask before narrowing");
        return (ResourceStages)value;
    }

    internal static bool Bool(BinaryReader r)
    {
        byte value = r.ReadByte();
        Require(value <= 1, "METADATA", "invalid boolean");
        return value == 1;
    }
    // Zero is retained for dormant fields in a default GAL state; active legality belongs to Vulkan.
    private static T E<T>(BinaryReader r) where T : struct, Enum
    {
        int value = r.ReadInt32();
        T e = (T)Enum.ToObject(typeof(T), value);
        Require(Convert.ToInt32(e) == value && (value == 0 || Enum.IsDefined(e)), "METADATA", "unknown GAL enum value");
        return e;
    }
    private static void EWrite<T>(BinaryWriter w, T e) where T : struct, Enum
    {
        int value = Convert.ToInt32(e);
        Require(typeof(T) == typeof(PolygonModeMask) ? (value & ~7) == 0 : value == 0 || Enum.IsDefined(e),
            "METADATA", "unknown GAL enum value");
        w.Write(value);
    }
    private static void Finite(ColorF c) => Require(float.IsFinite(c.Red) && float.IsFinite(c.Green) &&
        float.IsFinite(c.Blue) && float.IsFinite(c.Alpha), "METADATA", "non-finite blend constant");
    private static void Color(BinaryWriter w, ColorF c)
    {
        Finite(c);
        w.Write(c.Red);
        w.Write(c.Green);
        w.Write(c.Blue);
        w.Write(c.Alpha);
    }
    private static ColorF Color(BinaryReader r)
    {
        ColorF c = new(r.ReadSingle(), r.ReadSingle(), r.ReadSingle(), r.ReadSingle());
        Finite(c);
        return c;
    }

    private static void WriteState(BinaryWriter w, ProgramPipelineState s)
    {
        w.Write(s.SamplesCount);
        for (int i = 0; i < 8; i++)
        {
            w.Write(s.AttachmentEnable[i]);
            EWrite(w, s.AttachmentFormats[i]);
        }
        w.Write(s.DepthStencilEnable);
        EWrite(w, s.DepthStencilFormat);
        w.Write(s.LogicOpEnable);
        EWrite(w, s.LogicOp);
        for (int i = 0; i < 8; i++)
        {
            BlendDescriptor b = s.BlendDescriptors[i];
            w.Write(b.Enable);
            Color(w, b.BlendConstant);
            EWrite(w, b.ColorOp);
            EWrite(w, b.ColorSrcFactor);
            EWrite(w, b.ColorDstFactor);
            EWrite(w, b.AlphaOp);
            EWrite(w, b.AlphaSrcFactor);
            EWrite(w, b.AlphaDstFactor);
            w.Write(s.ColorWriteMask[i]);
        }
        w.Write(s.VertexAttribCount);
        for (int i = 0; i < 32; i++)
        {
            VertexAttribDescriptor a = s.VertexAttribs[i];
            w.Write(a.BufferIndex);
            w.Write(a.Offset);
            w.Write(a.IsZero);
            EWrite(w, a.Format);
        }
        w.Write(s.VertexBufferCount);
        for (int i = 0; i < 32; i++)
        {
            BufferPipelineDescriptor b = s.VertexBuffers[i];
            w.Write(b.Enable);
            w.Write(b.Stride);
            w.Write(b.Divisor);
        }
        w.Write(s.DepthTest.TestEnable);
        w.Write(s.DepthTest.WriteEnable);
        EWrite(w, s.DepthTest.Func);
        StencilTestDescriptor t = s.StencilTest;
        w.Write(t.TestEnable);
        EWrite(w, t.FrontFunc);
        EWrite(w, t.FrontSFail);
        EWrite(w, t.FrontDpPass);
        EWrite(w, t.FrontDpFail);
        w.Write(t.FrontFuncRef);
        w.Write(t.FrontFuncMask);
        w.Write(t.FrontMask);
        EWrite(w, t.BackFunc);
        EWrite(w, t.BackSFail);
        EWrite(w, t.BackDpPass);
        EWrite(w, t.BackDpFail);
        w.Write(t.BackFuncRef);
        w.Write(t.BackFuncMask);
        w.Write(t.BackMask);
        EWrite(w, s.FrontFace);
        EWrite(w, s.CullMode);
        w.Write(s.CullEnable);
        EWrite(w, s.BiasEnable);
        w.Write(s.LineWidth);
        w.Write(s.DepthClampEnable);
        w.Write(s.RasterizerDiscard);
        EWrite(w, s.Topology);
        w.Write(s.PrimitiveRestartEnable);
        w.Write(s.PatchControlPoints);
        EWrite(w, s.DepthMode);
    }

    private static ProgramPipelineState ReadState(BinaryReader r)
    {
        ProgramPipelineState s = new();
        s.SamplesCount = r.ReadInt32();
        for (int i = 0; i < 8; i++)
        {
            s.AttachmentEnable[i] = Bool(r);
            s.AttachmentFormats[i] = E<Format>(r);
        }
        s.DepthStencilEnable = Bool(r);
        s.DepthStencilFormat = E<Format>(r);
        s.LogicOpEnable = Bool(r);
        s.LogicOp = E<LogicalOp>(r);
        for (int i = 0; i < 8; i++)
        {
            s.BlendDescriptors[i] = new(Bool(r), Color(r), E<BlendOp>(r), E<BlendFactor>(r), E<BlendFactor>(r),
                E<BlendOp>(r), E<BlendFactor>(r), E<BlendFactor>(r));
            s.ColorWriteMask[i] = r.ReadUInt32();
        }
        s.VertexAttribCount = r.ReadInt32();
        for (int i = 0; i < 32; i++)
            s.VertexAttribs[i] = new(r.ReadInt32(), r.ReadInt32(), Bool(r), E<Format>(r));
        s.VertexBufferCount = r.ReadInt32();
        for (int i = 0; i < 32; i++)
            s.VertexBuffers[i] = new(Bool(r), r.ReadInt32(), r.ReadInt32());
        s.DepthTest = new(Bool(r), Bool(r), E<CompareOp>(r));
        s.StencilTest = new(Bool(r), E<CompareOp>(r), E<StencilOp>(r), E<StencilOp>(r), E<StencilOp>(r),
            r.ReadInt32(), r.ReadInt32(), r.ReadInt32(), E<CompareOp>(r), E<StencilOp>(r), E<StencilOp>(r), E<StencilOp>(r),
            r.ReadInt32(), r.ReadInt32(), r.ReadInt32());
        s.FrontFace = E<FrontFace>(r);
        s.CullMode = E<Face>(r);
        s.CullEnable = Bool(r);
        int mask = r.ReadInt32();
        Require((mask & ~7) == 0, "METADATA", "invalid polygon mode mask");
        s.BiasEnable = (PolygonModeMask)mask;
        s.LineWidth = r.ReadSingle();
        s.DepthClampEnable = Bool(r);
        s.RasterizerDiscard = Bool(r);
        s.Topology = E<PrimitiveTopology>(r);
        s.PrimitiveRestartEnable = Bool(r);
        s.PatchControlPoints = r.ReadUInt32();
        s.DepthMode = E<DepthMode>(r);
        return s;
    }
}
