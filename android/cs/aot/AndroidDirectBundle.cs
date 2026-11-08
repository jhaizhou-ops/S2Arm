// Android 直连运行时补编入口（NativeAOT 导出，改 shim 的 dm_shader_miss / 前端 survey 调用）：
//   int s2a_direct_bundle_v1(const void *code, nuint code_len, const void *ctl, nuint ctl_len, int stage, const char *out_dir);
// stage 0 vs / 3 gs / 4 ps / 5 cs（NVN 号）；code = 机器码区（含 0x30 字节头），ctl = 0x880 控制段。
// 当前不再产出任何文件；统一生产链接通后由 compile_fn 结果落盘。失败返回非 0 并向 stderr 打一行【红】。同步，异常不跨 C 边界。
extern alias dsh;
using System;
using System.IO;
using System.Runtime.InteropServices;

namespace S2A.Android.Aot
{
    public static unsafe class AndroidDirectBundle
    {
        // 统一生产链待接：真实请求要由 SetShaders 快照 + Draw 状态的事实形成，再经已绑定的
        // s2a_direct_compile_fn 调用。这里不再用 DshVk 的 res.json 套一个 schema 名冒充统一结果。
        [UnmanagedCallersOnly(EntryPoint = "s2a_direct_bundle_v1")]
        public static int Compile(byte* code, nuint codeLen, byte* ctl, nuint ctlLen, int stage, byte* outDir, int flags)
        {
            _ = code; _ = codeLen; _ = ctl; _ = ctlLen; _ = stage; _ = outDir; _ = flags;
            Console.Error.WriteLine("【红】直连补编：统一生产链待接（compile_fn 请求构造未实现，未写任何产物）");
            return 2;
        }
    }
}
