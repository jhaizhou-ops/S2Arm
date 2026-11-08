// 片元输出「按整数位写」的静态判定（ShaderBake 5d，10-24 总指挥：出包不试跑、玩家首遇零现编——不再等冷局撞上整数目标才按观测补变体）。
// Ryujinx 翻译（FragmentOutputTypes 全浮点时）往输出写整数类型的值会先 OpBitcast 成浮点再存（CodeGen/Spirv/Instructions.cs 存输出时按输出类型转）；
// 游戏画进整数目标（R32Uint、RGBA32Uint…）的片元着色器，写出的就是整数运算的结果。所以「某个输出位置收到的值来自 int → float 的 OpBitcast」= 这个位置按整数位写，
// 出包时给它补一份该位置 Uint 的变体（同直连离线链 dmsh_build.py fs_uint 判 as_type<float>(…) 写输出）。只认这个形状：浮点运算算出来的值照旧只有浮点版
using System;
using System.Buffers.Binary;
using System.Collections.Generic;

namespace S2A.ShBake
{
    static class FoutStatic
    {
        const int OpTypeInt = 21, OpTypeFloat = 22, OpTypeVector = 23, OpTypeArray = 28, OpTypePointer = 32, OpConstant = 43, OpFunction = 54, OpStore = 62, OpAccessChain = 65, OpInBoundsAccessChain = 66,
            OpDecorate = 71, OpCompositeConstruct = 80, OpBitcast = 124, OpVariable = 59;
        const uint DecLocation = 30, DecBuiltIn = 11, StorageOutput = 3;

        /// <summary>片元 SPIR-V 里按整数位写的输出位置（位 n = Location n）；认不出 SPIR-V 返回 0</summary>
        public static uint IntWrittenTargets(byte[] spv)
        {
            if (spv == null || spv.Length < 20 || (spv.Length & 3) != 0 || BinaryPrimitives.ReadUInt32LittleEndian(spv) != 0x07230203) return 0;
            int n = spv.Length / 4;
            uint W(int i) => BinaryPrimitives.ReadUInt32LittleEndian(spv.AsSpan(4 * i));
            var types = new HashSet<uint>(); var intTypes = new HashSet<uint>(); var floatTypes = new HashSet<uint>(); var ptrTo = new Dictionary<uint, uint>(); var varType = new Dictionary<uint, uint>(); var typeOf = new Dictionary<uint, uint>();
            var loc = new Dictionary<uint, int>(); var builtin = new HashSet<uint>(); var outVars = new HashSet<uint>(); var chainBase = new Dictionary<uint, uint>();
            var bitcastOf = new Dictionary<uint, uint>(); var parts = new Dictionary<uint, uint[]>(); var stores = new List<(uint ptr, uint val)>();
            bool inFn = false;
            for (int i = 5; i < n;)
            {
                uint w0 = W(i); int len = (int)(w0 >> 16), op = (int)(w0 & 0xffff);
                if (len == 0 || i + len > n) break;
                switch (op)
                {
                    case OpTypeInt: types.Add(W(i + 1)); intTypes.Add(W(i + 1)); break;
                    case OpTypeFloat: types.Add(W(i + 1)); floatTypes.Add(W(i + 1)); break;
                    case OpTypeVector: types.Add(W(i + 1)); if (intTypes.Contains(W(i + 2))) intTypes.Add(W(i + 1)); if (floatTypes.Contains(W(i + 2))) floatTypes.Add(W(i + 1)); break;
                    case OpTypeArray when len >= 4: types.Add(W(i + 1)); if (floatTypes.Contains(W(i + 2))) floatTypes.Add(W(i + 1)); break;
                    case OpTypePointer when len >= 4: types.Add(W(i + 1)); ptrTo[W(i + 1)] = W(i + 3); break;
                    case >= 19 and <= 39: types.Add(W(i + 1)); break;   // 其余 OpType*（含指针）：结果 id 在第 1 字
                    case OpDecorate when len >= 4: if (W(i + 2) == DecLocation) loc[W(i + 1)] = (int)W(i + 3); else if (W(i + 2) == DecBuiltIn) builtin.Add(W(i + 1)); break;
                    case OpVariable when len >= 4: if (W(i + 3) == StorageOutput) { outVars.Add(W(i + 2)); varType[W(i + 2)] = W(i + 1); } break;
                    case OpFunction: inFn = true; break;
                    case OpStore when len >= 3: stores.Add((W(i + 1), W(i + 2))); break;
                    case OpAccessChain or OpInBoundsAccessChain when len >= 4: chainBase[W(i + 2)] = W(i + 3); break;
                }
                if (op == OpBitcast && len >= 4) bitcastOf[W(i + 2)] = W(i + 3);
                if (op == OpCompositeConstruct && len >= 3) { var c = new uint[len - 3]; for (int k = 0; k < c.Length; k++) c[k] = W(i + 3 + k); parts[W(i + 2)] = c; }
                // 结果类型（第 1 字是已声明的类型 id 的指令：函数体里的值指令、常量）——判 OpBitcast 的操作数是不是整数
                if (len >= 3 && (op == OpConstant || inFn) && op != OpStore && types.Contains(W(i + 1))) typeOf[W(i + 2)] = W(i + 1);
                i += len;
            }
            bool IntBits(uint v, int depth)
            {
                if (bitcastOf.TryGetValue(v, out uint src) && typeOf.TryGetValue(src, out uint t) && intTypes.Contains(t)) return true;
                if (depth < 2 && parts.TryGetValue(v, out var cs)) foreach (uint c in cs) if (IntBits(c, depth + 1)) return true;
                return false;
            }
            uint mask = 0;
            foreach (var (ptr, val) in stores)
            {
                uint v = chainBase.TryGetValue(ptr, out uint b) ? b : ptr;
                if (!outVars.Contains(v) || builtin.Contains(v) || !loc.TryGetValue(v, out int l) || l < 0 || l >= 8) continue;
                // 只看浮点输出：已是整数类型的输出（Uint 变体本身）存进去的 int → uint 位转换是正常的整数写，不是「浮点输出按整数位写」（10-25 马车8 对拍：6611 支 Uint 变体被误计）
                if (!varType.TryGetValue(v, out uint pt) || !ptrTo.TryGetValue(pt, out uint vt) || !floatTypes.Contains(vt)) continue;
                if (IntBits(val, 0)) mask |= 1u << l;
            }
            return mask;
        }
    }
}
