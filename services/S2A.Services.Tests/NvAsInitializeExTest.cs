using Ryujinx.HLE.HOS.Services.Nv.NvDrvServices;
using Ryujinx.HLE.HOS.Services.Nv.NvDrvServices.NvHostAsGpu;
using Ryujinx.HLE.HOS.Services.Nv.NvDrvServices.NvHostAsGpu.Types;

namespace S2A.Services.Tests
{
    public static unsafe partial class Program
    {
        // nvhost-as InitializeEx（nvservices AllocAsEx）定 GPU 地址空间的两个区间，GetVaRegions 照它报（10-29 脑锻炼带 CUDA：要的区间远大于写死的
        //   12 GiB 小页 / 112 GiB 大页，读回后空指针崩，直连 / 通用都崩）。期望照 nvservices（yuzu nvhost_as_gpu VM 常量）手算：
        //   ① 全 0 = 现在的缺省：小页 [4 GiB, 16 GiB)、大页 [16 GiB, 128 GiB)、大页 64 KiB
        //   ② 只给大页 128 KiB：起点 = 128 KiB << 10 = 128 MiB，分界 16 GiB，终点 128 GiB
        //   ③ 显式范围 [128 MiB, 16 GiB, 512 GiB) + 大页 128 KiB：照给的
        //   ④ 大页 32 KiB / 0x30000（不是 2 的幂）：InvalidInput ⑤ 终点过 1 TiB（GPU 页表 40 位）：InvalidInput
        private static void NvAsInitializeExTest()
        {
            string Run(uint big, ulong start, ulong split, ulong end)
            {
                InitializeExArguments a = new() { BigPageSize = big, VaRangeStart = start, VaRangeSplit = split, VaRangeEnd = end };
                NvInternalResult r = NvHostAsGpuDeviceFile.S2AAddressSpace(a, out var small, out var large, out uint page);
                return r != NvInternalResult.Success ? r.ToString() : $"0x{small.Start:x}-0x{small.Limit:x} / 0x{large.Start:x}-0x{large.Limit:x} / 0x{page:x}";
            }

            Check("nvhost-as InitializeEx ① 全 0 保持缺省区间", "0x100000000-0x400000000 / 0x400000000-0x2000000000 / 0x10000", Run(0, 0, 0, 0));
            Check("nvhost-as InitializeEx ② 只给大页 128 KiB", "0x8000000-0x400000000 / 0x400000000-0x2000000000 / 0x20000", Run(0x20000, 0, 0, 0));
            Check("nvhost-as InitializeEx ③ 显式范围到 512 GiB", "0x8000000-0x400000000 / 0x400000000-0x8000000000 / 0x20000", Run(0x20000, 0x8000000, 1UL << 34, 1UL << 39));
            Check("nvhost-as InitializeEx ④ 大页 32 KiB / 0x30000", "InvalidInput / InvalidInput", $"{Run(0x8000, 0, 0, 0)} / {Run(0x30000, 0, 0, 0)}");
            Check("nvhost-as InitializeEx ⑤ 终点过 1 TiB", "InvalidInput", Run(0x20000, 0x8000000, 1UL << 34, 1UL << 41));
        }
    }
}
