// 直连程序的按阶段落盘：编译器输出（program.json）→ <control 键>.program.json。
// 离线出库（打包工具）与运行时现编（dm_shader_miss）共用这一份；不读游戏文件、不建 GPU 设备。
// 布局与 d2r-mobile 的 pack_game_shaders.py / 本仓 tests 的 .xgs 一致：
//   头 8×u32（magic/version/nvn_stage/binding_count/input_count/c1_bytes/spirv_bytes/0）
//   + binding_count × xbg_shader_binding（8×u32）+ input_count × u32（顶点输入位置）
//   + c1 字节 + SPIR-V。
// 绑定映射沿用旧 d2r 引擎导入时与 direct_c2_xgs.py（已随引擎删除）对拍过的单 set 方案：support 固定 0，其余按编译结果顺序 1..N；
// 顶点输入位置从 SPIR-V 的 Input+Location 装饰取，不再写死 [0]。
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text.Json;

namespace S2A.DirectCompiler
{
    public static class DirectBundle
    {
        public const uint Magic = 0x31534758;
        const uint SupportBytes = 2608;   // SupportLayout requiredSize；与引擎 support binding 的 bytes 一致
        // Vulkan descriptor types / engine sources (xbg_game.h)
        const uint TypeCombinedImageSampler = 1, TypeUniformBuffer = 6;
        const uint SourceSupport = 1, SourceUniform = 2, SourceTexture = 7;
        static readonly Dictionary<string, int> StageNo = new() { ["vs"] = 0, ["hs"] = 1, ["ds"] = 2, ["gs"] = 3, ["fs"] = 4, ["ps"] = 4, ["cs"] = 5 };

        public sealed class Bundle
        {
            public string Stage, Key;
            public byte[] Program;   // 编译器完整结果（s2a-direct-program-v1），按阶段键落盘
        }

        /// <summary>按阶段拆出 (control 键, 完整 program 结果)。不再生成 XGS：新后端消费 s2a-direct-program-v1。</summary>
        public static List<Bundle> Build(byte[] programJson, IReadOnlyDictionary<string, byte[]> controls)
        {
            using JsonDocument document = JsonDocument.Parse(programJson);
            JsonElement content = document.RootElement.GetProperty("content");
            JsonElement stages = content.GetProperty("stages");
            var result = new List<Bundle>();
            foreach (JsonElement stage in stages.EnumerateArray())
            {
                string name = stage.GetProperty("stage").GetString();
                if (!controls.TryGetValue(name, out byte[] control) || control == null || control.Length != 0x880)
                    throw new DirectCompileException("MISSING_FACT", $"control section for stage {name} must be 0x880 bytes");
                byte[] spirv = Convert.FromBase64String(stage.GetProperty("spirv").GetString());
                if (spirv.Length < 20 || BitConverter.ToUInt32(spirv, 0) != 0x07230203)
                    throw new DirectCompileException("UNSUPPORTED_PROGRAM", $"{name}: compiler output is not SPIR-V");
                result.Add(new Bundle
                {
                    Stage = name,
                    Key = Convert.ToHexStringLower(Sha256.HashData(control.AsSpan(0, 0x880)))[..16],
                    Program = programJson,
                });
            }
            return result;
        }
    }
}
