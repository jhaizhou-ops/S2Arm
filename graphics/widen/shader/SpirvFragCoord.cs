// 通用宽屏 · 片元坐标回到客体坐标：新翻译器的 x 除 render_scale[0]、y 除 render_scale_y[0]。
// GPU 写入原分辨率倍率 r，包装层只把 x 组合成 r·k，y 始终按 r；在这里识别两轴用法，不移除新布局的 y 除法。
// 旧 1x 录像仍把 y 除数换成 1，保持原宽屏改写；磁盘缓存由 CodeGenVersion 隔离，不会把旧布局用于新游戏局。
// 识别按数据流打标签：从 gl_FragCoord 第 1 分量取出的值、从 support_buffer 第 renderScaleMember 个成员第 0 个元素取出的值，
// 经 OpStore / OpLoad（函数局部变量中转）、OpCopyObject 传递；OpFDiv(甲, 乙) 甲是 y、乙是缩放 → 乙换成常量 1.0。
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace S2Arm.Gfx.Widen
{
    public static class SpirvFragCoord
    {
        const int OpConstant = 43, OpFunction = 54, OpVariable = 59, OpLoad = 61, OpStore = 62, OpAccessChain = 65, OpInBoundsAccessChain = 66, OpDecorate = 71, OpCopyObject = 83, OpFDiv = 136, OpTypeFloat = 22;
        const int DecBuiltIn = 11, DecBinding = 33, BuiltInFragCoord = 15, StorageUniform = 2;
        const byte TagNone = 0, TagFragY = 1, TagScale = 2, TagFragX = 3, TagScaleY = 4;

        /// <summary>识别新布局的 y 除法、改旧布局的 y 除数。yPatched = 识别 / 修改处数；xUses = x 除横向倍率的处数。</summary>
        public static byte[] PatchY(byte[] spv, int renderScaleMember, out int yPatched, out int xUses)
        {
            yPatched = xUses = 0;
            if (spv == null || spv.Length < 20 || (spv.Length & 3) != 0) return spv;
            uint[] w = MemoryMarshal.Cast<byte, uint>(spv).ToArray();
            if (w[0] != 0x07230203) return spv;
            uint fragCoord = 0, one = 0;
            var floatTypes = new HashSet<uint>(); var consts = new Dictionary<uint, uint>(); var binding0 = new HashSet<uint>(); var uniforms = new HashSet<uint>();
            for (int i = 5; i < w.Length;)
            {
                int n = (int)(w[i] >> 16), op = (int)(w[i] & 0xffff);
                if (n == 0 || i + n > w.Length) return spv;
                if (op == OpDecorate && n >= 4 && w[i + 2] == DecBuiltIn && w[i + 3] == BuiltInFragCoord) fragCoord = w[i + 1];
                else if (op == OpDecorate && n >= 4 && w[i + 2] == DecBinding && w[i + 3] == 0) binding0.Add(w[i + 1]);
                else if (op == OpTypeFloat && n >= 3 && w[i + 2] == 32) floatTypes.Add(w[i + 1]);
                else if (op == OpConstant && n == 4) { consts[w[i + 2]] = w[i + 3]; if (one == 0 && floatTypes.Contains(w[i + 1]) && w[i + 3] == 0x3f800000) one = w[i + 2]; }
                else if (op == OpVariable && n >= 4 && w[i + 3] == StorageUniform) uniforms.Add(w[i + 2]);
                i += n;
            }
            uniforms.IntersectWith(binding0);   // support_buffer = 绑定 0 的 Uniform 变量
            if (fragCoord == 0 || uniforms.Count == 0) return spv;
            var tag = new Dictionary<uint, byte>();   // 值或指针 → 标签
            var needOne = new List<int>();   // 旧布局 y 除法、模块里没有常量 1.0：先记下除数位置，扫完补一个常量再填（原先静默不改，画面上下错位）
            for (int i = 5; i < w.Length;)
            {
                int n = (int)(w[i] >> 16), op = (int)(w[i] & 0xffff);
                switch (op)
                {
                    case OpAccessChain: case OpInBoundsAccessChain:
                        if (n == 5 && w[i + 3] == fragCoord && consts.TryGetValue(w[i + 4], out uint c)) { if (c == 1) tag[w[i + 2]] = TagFragY; else if (c == 0) tag[w[i + 2]] = TagFragX; }
                        else if (n == 6 && uniforms.Contains(w[i + 3]) && consts.TryGetValue(w[i + 4], out uint m) && m == (uint)renderScaleMember && consts.TryGetValue(w[i + 5], out uint e) && e == 0) tag[w[i + 2]] = TagScale;
                        else if (n == 6 && uniforms.Contains(w[i + 3]) && consts.TryGetValue(w[i + 4], out uint my) && my == WidenShaders.RenderScaleYMember && consts.TryGetValue(w[i + 5], out uint ey) && ey == 0) tag[w[i + 2]] = TagScaleY;
                        break;
                    case OpLoad:
                        if (n >= 4 && tag.TryGetValue(w[i + 3], out byte t)) tag[w[i + 2]] = t;
                        break;
                    case OpStore:
                        if (n >= 3) { if (tag.TryGetValue(w[i + 2], out byte t2)) tag[w[i + 1]] = t2; else tag.Remove(w[i + 1]); }
                        break;
                    case OpCopyObject:
                        if (n >= 4 && tag.TryGetValue(w[i + 3], out byte t3)) tag[w[i + 2]] = t3;
                        break;
                    case OpFDiv:
                        if (n == 5 && tag.TryGetValue(w[i + 4], out byte d) && tag.TryGetValue(w[i + 3], out byte a))
                        {
                            if (a == TagFragY && d == TagScaleY) yPatched++; // 新翻译器已按纵向分辨率倍率读取，保持除法。
                            else if (a == TagFragY && d == TagScale) { if (one != 0) w[i + 4] = one; else needOne.Add(i + 4); yPatched++; } // 旧录像 / 旧测试语料 1x 路径
                            else if (a == TagFragX && d == TagScale) xUses++;
                        }
                        break;
                }
                i += n;
            }
            if (needOne.Count > 0)
            {
                uint ft = 0; foreach (uint f in floatTypes) { ft = f; break; }
                if (ft == 0) { yPatched -= needOne.Count; needOne.Clear(); }   // 没有 32 位浮点类型就造不出 1.0：这几处不算改过
                else
                {
                    uint id = w[3]; w[3] = id + 1;   // 新编号 = 原 bound
                    foreach (int at in needOne) w[at] = id;
                    int ins = 5; while (ins < w.Length && (int)(w[ins] & 0xffff) != OpFunction) ins += (int)(w[ins] >> 16);   // 插在第一个函数定义之前（常量区末尾）
                    var o = new List<uint>(w.Length + 4); o.AddRange(w.AsSpan(0, ins).ToArray()); o.AddRange(new uint[] { 4u << 16 | OpConstant, ft, id, 0x3f800000 }); o.AddRange(w.AsSpan(ins).ToArray());
                    w = o.ToArray();
                }
            }
            return yPatched > 0 ? MemoryMarshal.AsBytes(w.AsSpan()).ToArray() : spv;
        }
    }
}
