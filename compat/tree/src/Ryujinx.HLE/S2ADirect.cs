using System.Runtime.InteropServices;

namespace Ryujinx.HLE
{
    /// <summary>
    /// S2A：双轨直连模式（docs/设计_直连架构.md §12.1 / §12.2）。直连模式下游戏的 NVN 由直连图形层接管，Ryujinx 这边剩下的 nvdrv / vi 调用
    /// 只回「没东西可画」：GPFIFO 提交直接成功、不执行（栅栏当场到达），vi 取到的帧直接放回、不出图。
    /// 模式由原生层 s2a_gfx_mode()（0 通用 / 1 直连）给出，起局判定一次；主程序没有这个导出（Ryujinx 自己的测试、没带直连的构建）按通用走
    /// </summary>
    public static unsafe class S2ADirect
    {
        public static bool On { get; private set; } = Probe();

        public static void BeginSession() => On = Probe();

        /// <summary>直连图形层给一段客体内存（NVN 内存池）开 nvmap 句柄，返回句柄号（nvnTextureGetNvRmSurfaceNVX 用）</summary>
        public static int NvMapFromGuest(ulong address, uint size) => HOS.Services.Nv.NvDrvServices.NvMap.NvMapDeviceFile.S2AFromGuest(address, size);

        private static bool Probe()
        {
            if (!NativeLibrary.TryGetExport(NativeLibrary.GetMainProgramHandle(), "s2a_gfx_mode", out nint f))
            {
                return false;
            }

            return ((delegate* unmanaged<int>)f)() == 1;
        }
    }
}
