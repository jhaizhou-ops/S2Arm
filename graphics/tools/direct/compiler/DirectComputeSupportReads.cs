// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
using Ryujinx.Graphics.Shader;
using System;
using System.Collections.Generic;
using System.Linq;
using System.Runtime.InteropServices;

namespace S2A.DirectCompiler
{
    // Actual byte reads from the heterogeneous std140 SupportBuffer. Layout comes
    // from SPIR-V types/decorations, not from c0's struct { vec4 data[N]; } ABI.
    // null means unproved; [] means there are no loads from the target descriptor.
    public static class DirectComputeSupportReads
    {
        private static bool Declaration(int op) => op is 3 or 4 or 5 or 6 or 7 or 8 or 10 or 11 or 14 or 15 or 16 or 17 or 43 or 59 or 71 or 72
            || (op >= 19 && op <= 39);

        public static int[][] Analyze(ReadOnlySpan<byte> spv, int set, int binding, int requiredSize)
            => Analyze(spv, set, binding, requiredSize, out _);

        public static int[][] Analyze(ReadOnlySpan<byte> spv, int set, int binding, int requiredSize,
            out (string Name, int Offset, int Stride, int Count, int ElementBytes)[] scaleRanges)
        {
            scaleRanges = null;
            if (spv.Length < 20 || (spv.Length & 3) != 0 || requiredSize <= 0) return null;
            ReadOnlySpan<uint> w = MemoryMarshal.Cast<byte, uint>(spv);
            if (w[0] != 0x07230203) return null;
            var instructions = new List<uint[]>();
            var types = new Dictionary<uint, uint[]>();
            var constants = new Dictionary<uint, (uint Type, uint Value)>();
            var bindings = new Dictionary<uint, uint>();
            var sets = new Dictionary<uint, uint>();
            var strides = new Dictionary<uint, uint>();
            var offsets = new Dictionary<(uint Type, uint Member), uint>();
            var variables = new Dictionary<uint, uint[]>();
            for (int i = 5; i < w.Length;)
            {
                int n = (int)(w[i] >> 16), op = (int)(w[i] & 65535);
                if (n == 0 || n > w.Length - i) return null;
                uint[] a = w.Slice(i, n).ToArray(); instructions.Add(a);
                if (op == 71 && n == 4)
                {
                    if (a[2] == 33) bindings[a[1]] = a[3];
                    if (a[2] == 34) sets[a[1]] = a[3];
                    if (a[2] == 6) strides[a[1]] = a[3];
                }
                if (op == 72 && n == 5 && a[3] == 35) offsets[(a[1], a[2])] = a[4];
                if (op >= 19 && op <= 33 && n >= 2) types[a[1]] = a;
                if (op == 43 && n == 4) constants[a[2]] = (a[1], a[3]);
                if (op == 59 && n >= 4) variables[a[2]] = a;
                i += n;
            }
            bool Type(uint id, int op, int length, out uint[] t) => types.TryGetValue(id, out t) &&
                (t[0] & 65535) == op && (length == 0 || t.Length == length);
            bool Index(uint id, out uint value)
            {
                value = 0;
                if (!constants.TryGetValue(id, out var c) || !Type(c.Type, 21, 4, out var t) || t[2] != 32) return false;
                value = c.Value; return true;
            }
            int Size(uint id)
            {
                if (Type(id, 21, 4, out var t) && t[2] == 32 || Type(id, 22, 3, out t) && t[2] == 32) return 4;
                if (Type(id, 23, 4, out t) && t[3] >= 2 && t[3] <= 4 &&
                    ((Type(t[2], 21, 4, out var s) && s[2] == 32) || (Type(t[2], 22, 3, out s) && s[2] == 32))) return (int)t[3] * 4;
                return 0; // Whole arrays/structures, matrices and unsupported widths remain unknown.
            }
            uint[] roots = variables.Keys.Where(id => bindings.GetValueOrDefault(id, uint.MaxValue) == (uint)binding &&
                sets.GetValueOrDefault(id, uint.MaxValue) == (uint)set).ToArray();
            if (roots.Length == 0) return Array.Empty<int[]>();
            if (roots.Length != 1) return null;
            uint root = roots[0]; var variable = variables[root];
            if (variable[3] != 2 || !Type(variable[1], 32, 4, out var rootPointer) || rootPointer[2] != 2 ||
                !Type(rootPointer[3], 30, 0, out _)) return null;
            // The registry intentionally omits legacy members. Match public CPU layout
            // offsets against actual GPU member types instead of inventing registry entries.
            bool ScaleArray(int offset)
            {
                if (!Type(rootPointer[3], 30, 0, out var structure)) return false;
                uint[] members = Enumerable.Range(0, structure.Length - 2).Select(i => (uint)i)
                    .Where(i => offsets.TryGetValue((rootPointer[3], i), out uint at) && at == offset).ToArray();
                if (members.Length != 1) return false;
                uint memberType = structure[2 + (int)members[0]];
                return Type(memberType, 28, 4, out var array) && Type(array[2], 22, 3, out var element) &&
                    element[2] == sizeof(float) * 8 && Index(array[3], out uint count) && count == SupportBuffer.RenderScaleMaxCount &&
                    strides.TryGetValue(memberType, out uint stride) && stride == SupportBuffer.FieldSize &&
                    offset >= 0 && (long)offset + (long)(count - 1) * stride + sizeof(float) <= requiredSize;
            }
            if (ScaleArray(SupportBuffer.GraphicsRenderScaleOffset) && ScaleArray(SupportBuffer.RenderScaleYOffset))
                scaleRanges = new[]
                {
                    ("render_scale", SupportBuffer.GraphicsRenderScaleOffset, SupportBuffer.FieldSize, SupportBuffer.RenderScaleMaxCount, sizeof(float)),
                    ("render_scale_y", SupportBuffer.RenderScaleYOffset, SupportBuffer.FieldSize, SupportBuffer.RenderScaleMaxCount, sizeof(float)),
                };
            var pointers = new Dictionary<uint, (int Offset, int Size, uint Type)>();
            foreach (uint[] a in instructions)
            {
                int op = (int)(a[0] & 65535);
                if ((op != 65 && op != 66) || a.Length < 4 || a[3] != root) continue;
                if (a.Length < 5) return null;
                uint type = rootPointer[3]; long offset = 0;
                for (int j = 4; j < a.Length; j++)
                {
                    if (!Index(a[j], out uint index) || !types.TryGetValue(type, out var t)) return null;
                    switch (t[0] & 65535)
                    {
                        case 30: // Struct members may have unrelated types and explicit offsets.
                            if (index >= t.Length - 2 || !offsets.TryGetValue((type, index), out uint memberOffset)) return null;
                            offset += memberOffset; type = t[2 + (int)index]; break;
                        case 28:
                            if (t.Length != 4 || !Index(t[3], out uint count) || index >= count ||
                                !strides.TryGetValue(type, out uint stride) || stride == 0 ||
                                index > (requiredSize - offset) / stride) return null;
                            offset += (long)index * stride; type = t[2]; break;
                        case 23:
                            if (t.Length != 4 || index >= t[3] || Size(t[2]) != 4) return null;
                            offset += (long)index * 4; type = t[2]; break;
                        default: return null;
                    }
                    if (offset < 0 || offset > requiredSize) return null;
                }
                int size = Size(type);
                if (size == 0 || offset + size > requiredSize ||
                    !Type(a[1], 32, 4, out var resultPointer) || resultPointer[2] != 2 || resultPointer[3] != type) return null;
                pointers[a[2]] = ((int)offset, size, type);
            }
            var reads = new SortedSet<(int Offset, int Size)>();
            // Audit only after all pointers are collected: forward Phi/calls/copies
            // cannot hide a pointer escape. Unused access chains do not imply reads.
            foreach (uint[] a in instructions)
            {
                int op = (int)(a[0] & 65535);
                if (op == 65 || op == 66)
                {
                    if (a.Length >= 4 && pointers.ContainsKey(a[3])) return null;
                }
                else if (op == 61 && a.Length >= 4 && pointers.TryGetValue(a[3], out var range))
                {
                    if (a[1] != range.Type) return null;
                    reads.Add((range.Offset, range.Size));
                }
                else if (op == 59 && a.Length >= 5 && (a[4] == root || pointers.ContainsKey(a[4]))) return null;
                else if (!Declaration(op))
                    for (int j = 1; j < a.Length; j++)
                        if (a[j] == root || pointers.ContainsKey(a[j])) return null;
            }
            return reads.Select(r => new[] { r.Offset, r.Size }).ToArray();
        }
    }
}
