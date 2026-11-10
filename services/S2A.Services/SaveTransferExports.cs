using System;
using System.Runtime.InteropServices;
using System.Text;

namespace S2A.Services;

public static unsafe class SaveTransferExports
{
    /// <summary>The caller owns the returned UTF-8 buffer and must call
    /// S2A_SaveTransferFree. Calls must be serialized with Host.Boot.</summary>
    [UnmanagedCallersOnly(EntryPoint = "S2A_SaveTransfer")]
    public static nint Run(byte* json)
    {
        try
        {
            lock (SaveTransfer.HostGate)
            {
            // 先解出请求（取不到时为 null）读宿主语言，「游戏已在运行」这类拒绝也按它出中 / 英文（#316）；空请求 / 超长请求读不到语言，按中文
            string request = null;
            int length = 0;
            if (json != null)
            {
                while (length <= (8 << 20) && json[length] != 0) length++;
                if (length <= (8 << 20)) request = new UTF8Encoding(false, true).GetString(new ReadOnlySpan<byte>(json, length));
            }
            SaveTransfer.UseLanguage(request ?? "");
            string response;
            if (SaveTransfer.HostStarted || Host.Device != null) response = SaveTransfer.Error("save_running", SaveTransfer.T("请在启动游戏前管理存档。", "Manage saves before starting the game."));
            else if (json == null) response = SaveTransfer.Error("save_invalid", SaveTransfer.T("存档请求为空。", "The save request is empty."));
            else if (request == null) response = SaveTransfer.Error("save_invalid", SaveTransfer.T("存档请求过大。", "The save request is too large."));
            else response = SaveTransfer.Execute(request);
            return Allocate(response);
            }
        }
        catch (Exception)
        {
            // No managed exception may unwind through the C ABI.
            return Allocate(SaveTransfer.English ? "{\"ok\":false,\"error\":{\"code\":\"save_internal\",\"message\":\"The save bridge failed.\"}}"
                                                 : "{\"ok\":false,\"error\":{\"code\":\"save_internal\",\"message\":\"存档桥接失败。\"}}");
        }
    }
    private static nint Allocate(string response)
    {
        byte* result = null;
        try
        {
            int size = Encoding.UTF8.GetByteCount(response);
            result = (byte*)NativeMemory.Alloc((nuint)size + 1);
            if (result == null) return 0;
            Encoding.UTF8.GetBytes(response, new Span<byte>(result, size));
            result[size] = 0;
            return (nint)result;
        }
        catch (Exception)
        {
            NativeMemory.Free(result);
            return 0;
        }
    }
    [UnmanagedCallersOnly(EntryPoint = "S2A_SaveTransferFree")]
    public static void Free(nint value) => NativeMemory.Free((void*)value);

    /// <summary>本进程里可写存档没走原子提交的原因，位或累计（11-01 全量审计 P2-13；值见 Ryujinx.HLE.FileSystem.S2ASaveDataFileSystemCreator.NonAtomic*）：
    /// 0 = 到目前为止都走原子提交；1 平台没登记宿主目录原语；2 存档所在的卷做不了克隆 / 原子交换（如游戏库放在 exFAT / 网络盘上）；4 卷可以、但某次挂载准备工作目录失败。
    /// 非 0 时这些存档退回 LibHac 逐字节复制，保存中途强退可能留下写了一半的档，界面据此提示「当前磁盘不能安全保存，请把游戏库挪到本机磁盘」。
    /// 任意线程随时可调、不阻塞、不分配；游戏第一次挂载存档（通常在开局几秒内）后才有意义，界面按需轮询，值只增不减。
    /// C 侧声明：int S2A_SaveAtomicState(void)（未链服务层时按弱符号 / dlsym 判空）</summary>
    [UnmanagedCallersOnly(EntryPoint = "S2A_SaveAtomicState")]
    public static int SaveAtomicState() => Ryujinx.HLE.FileSystem.S2ASaveDataFileSystemCreator.NonAtomic;
}
