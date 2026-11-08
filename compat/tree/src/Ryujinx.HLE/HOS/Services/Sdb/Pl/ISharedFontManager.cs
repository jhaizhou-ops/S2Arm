using Ryujinx.HLE.HOS.Ipc;
using Ryujinx.HLE.HOS.Kernel.Memory;
using Ryujinx.HLE.HOS.Services.Sdb.Pl.Types;
using Ryujinx.Horizon.Common;
using System;
using System.IO;

namespace Ryujinx.HLE.HOS.Services.Sdb.Pl
{
    [Service("pl:u")]
    [Service("pl:s")] // 9.0.0+
    class ISharedFontManager : IpcService
    {
        private int _fontSharedMemHandle;

        public ISharedFontManager(ServiceCtx context) { }

        [CommandCmif(0)]
        // RequestLoad(u32)
        public ResultCode RequestLoad(ServiceCtx context)
        {
#pragma warning disable IDE0059 // Remove unnecessary value assignment
            SharedFontType fontType = (SharedFontType)context.RequestData.ReadInt32();
#pragma warning restore IDE0059

            // We don't need to do anything here because we do lazy initialization
            // on SharedFontManager (the font is loaded when necessary).
            return ResultCode.Success;
        }

        [CommandCmif(1)]
        // GetLoadState(u32) -> u32
        public ResultCode GetLoadState(ServiceCtx context)
        {
#pragma warning disable IDE0059 // Remove unnecessary value assignment
            SharedFontType fontType = (SharedFontType)context.RequestData.ReadInt32();
#pragma warning restore IDE0059

            // 1 (true) indicates that the font is already loaded.
            // All fonts are already loaded.
            context.ResponseData.Write(1);

            return ResultCode.Success;
        }

        [CommandCmif(2)]
        // GetFontSize(u32) -> u32
        public ResultCode GetFontSize(ServiceCtx context)
        {
            SharedFontType fontType = (SharedFontType)context.RequestData.ReadInt32();

            context.ResponseData.Write(context.Device.System.SharedFontManager.GetFontSize(fontType));

            return ResultCode.Success;
        }

        [CommandCmif(3)]
        // GetSharedMemoryAddressOffset(u32) -> u32
        public ResultCode GetSharedMemoryAddressOffset(ServiceCtx context)
        {
            SharedFontType fontType = (SharedFontType)context.RequestData.ReadInt32();

            context.ResponseData.Write(context.Device.System.SharedFontManager.GetSharedMemoryAddressOffset(fontType));

            return ResultCode.Success;
        }

        [CommandCmif(4)]
        // GetSharedMemoryNativeHandle() -> handle<copy>
        public ResultCode GetSharedMemoryNativeHandle(ServiceCtx context)
        {
            context.Device.System.SharedFontManager.EnsureInitialized(context.Device.System.ContentManager);

            if (_fontSharedMemHandle == 0)
            {
                if (context.Process.HandleTable.GenerateHandle(context.Device.System.FontSharedMem, out _fontSharedMemHandle) != Result.Success)
                {
                    throw new InvalidOperationException("Out of handles!");
                }
            }

            context.Response.HandleDesc = IpcHandleDesc.MakeCopy(_fontSharedMemHandle);

            return ResultCode.Success;
        }

        [CommandCmif(5)]
        // GetSharedFontInOrderOfPriority(bytes<8, 1>) -> (u8, u32, buffer<unknown, 6>, buffer<unknown, 6>, buffer<unknown, 6>)
        public ResultCode GetSharedFontInOrderOfPriority(ServiceCtx context)
        {
#pragma warning disable IDE0059 // Remove unnecessary value assignment
            long languageCode = context.RequestData.ReadInt64();
#pragma warning restore IDE0059
            int loadedCount = 0;

            for (SharedFontType type = 0; type < SharedFontType.Count; type++)
            {
                uint offset = (uint)type * 4;

                if (!AddFontToOrderOfPriorityList(context, type, offset))
                {
                    break;
                }

                loadedCount++;
            }

            // The first return value is a boolean "fonts_are_loaded" flag (u8), not a count.
            // Some titles (e.g. newer SDK builds) validate it strictly against 1, so writing
            // the font count here (e.g. 6) makes them reject the result and spin re-opening pl:u.
            context.ResponseData.Write(1);
            context.ResponseData.Write(loadedCount);
            // context.ResponseData.Write((int)SharedFontType.Count);

            return ResultCode.Success;
        }

        [CommandCmif(6)] // 4.0.0+
        // GetSharedFontInOrderOfPriorityForSystem(bytes<8, 1>) -> (u8, u32, buffer<unknown, 6>, buffer<unknown, 6>, buffer<unknown, 6>)
        public ResultCode GetSharedFontInOrderOfPriorityForSystem(ServiceCtx context)
        {
            // TODO: Check the differencies with GetSharedFontInOrderOfPriority.

            return GetSharedFontInOrderOfPriority(context);
        }

        // S2Arm：Switch 2 SDK 的 pl:u 代理不再有 5 / 6（按优先级列字体），取内置字体改走 2000 / 2010（4 款 Switch 2 游戏 sdk 的
        //   nn::pl::sharedresource::detail::IPlatformSharedResourceManager 代理表：0–4、2000、2010、2100）。
        //   事实取自 Eden-NS2（GPL，代码自写）ns/platform_service_manager.cpp、ns/builtin_font.h：2000 回同一块字体共享内存与其长度；
        //   2010(u8 字体类型, b8 选项) 回 (b8 有无, 描述 {u8 类型, u8 标志 0, u16 保留, u32 偏移, u32 长度})，偏移 / 长度与命令 3 / 2 同口径，
        //   选项在真机模块里不被使用；类型越界或区域越出共享内存 → 无（描述全 0），命令本身成功
        [CommandCmif(2000)] // Switch 2
        // GetBuiltInFontSharedMemory() -> (u32 size, handle<copy>)
        public ResultCode GetBuiltInFontSharedMemory(ServiceCtx context)
        {
            ResultCode result = GetSharedMemoryNativeHandle(context);

            context.ResponseData.Write((uint)Horizon.FontSize);

            return result;
        }

        [CommandCmif(2010)] // Switch 2
        // GetBuiltInFontData(u8 type, b8 option) -> (b8 available, nn::pl::BuiltInFontDescriptor)
        public ResultCode GetBuiltInFontData(ServiceCtx context)
        {
            byte type = context.RequestData.ReadByte();

            context.Device.System.SharedFontManager.EnsureInitialized(context.Device.System.ContentManager);

            uint offset = 0, size = 0;
            bool available = false;

            if (type < (byte)SharedFontType.Count)
            {
                offset = (uint)context.Device.System.SharedFontManager.GetSharedMemoryAddressOffset((SharedFontType)type);
                size = (uint)context.Device.System.SharedFontManager.GetFontSize((SharedFontType)type);
                available = size != 0 && offset <= (uint)Horizon.FontSize && size <= (uint)Horizon.FontSize - offset;
            }

            context.ResponseData.Write(available);
            context.ResponseData.Write((byte)0);
            context.ResponseData.Write((ushort)0);
            context.ResponseData.Write(available ? type : (byte)0);
            context.ResponseData.Write((byte)0);
            context.ResponseData.Write((ushort)0);
            context.ResponseData.Write(available ? offset : 0u);
            context.ResponseData.Write(available ? size : 0u);

            return ResultCode.Success;
        }

        // S2Arm：2100（switchbrew 名 OpenFont）。游戏把自己分配的缓冲建成传输内存递来（时之笛 main 0x3782c20：0x1300000 字节、0x1000 对齐；
        //   sdk nn::pl::RequestLoadNxFont 0x5a3ab0 建传输内存时自己只留读权限），服务把 Nx（Switch 1）共享字体写进去，回 IFontService 按类型取偏移 / 长度。
        //   线上格式（sdk 发送助手 0x5a5220）：非域、复制句柄 1 个、数据 u8 @0（时之笛恒 0，含义不知道）、u32 长度 @4（sdk 恒传 0x1300000）；回出对象。sdk 失败即 AbortImpl。
        //   传输内存里的排法客户端不直接读，只按 IFontService 回的偏移取：这里照共享内存的排法写（每个字体 8 字节头 + 解密后的 TTF 正文），偏移与命令 3 同口径。
        //   首字节非 0、句柄不是传输内存、字体放不下：真机回什么不知道，报红
        [CommandCmif(2100)] // Switch 2
        // RequestLoadNxFont(u8, u32 size, handle<copy, transfer_memory>) -> object<nn::pl::sharedresource::detail::IFontService>
        public ResultCode RequestLoadNxFont(ServiceCtx context)
        {
            byte mode = context.RequestData.ReadByte();
            context.RequestData.BaseStream.Seek(3, SeekOrigin.Current);
            uint size = context.RequestData.ReadUInt32();
            int handle = context.Request.HandleDesc.ToCopy[0];

            try
            {
                if (mode != 0)
                {
                    throw new NotImplementedException($"pl:u 2100 RequestLoadNxFont：首字节 {mode} 的含义不知道（时之笛恒传 0）");
                }

                KTransferMemory transferMemory = context.Process.HandleTable.GetObject<KTransferMemory>(handle)
                    ?? throw new NotImplementedException($"pl:u 2100 RequestLoadNxFont：句柄 0x{handle:X} 不是传输内存，真机回什么不知道");

                SharedFontManager fonts = context.Device.System.SharedFontManager;
                ReadOnlySpan<byte> region = fonts.GetFontRegion();

                if (size > transferMemory.Size || (ulong)region.Length > size)
                {
                    throw new NotImplementedException($"pl:u 2100 RequestLoadNxFont：请求长 0x{size:X}、传输内存长 0x{transferMemory.Size:X}、字体共 0x{region.Length:X}，放不下时真机回什么不知道");
                }

                context.Memory.Write(transferMemory.Address, region);

                MakeObject(context, new IFontService(fonts));
            }
            finally
            {
                context.Device.System.KernelContext.Syscall.CloseHandle(handle);
            }

            return ResultCode.Success;
        }

        private bool AddFontToOrderOfPriorityList(ServiceCtx context, SharedFontType fontType, uint offset)
        {
            ulong typesPosition = context.Request.ReceiveBuff[0].Position;
            ulong typesSize = context.Request.ReceiveBuff[0].Size;

            ulong offsetsPosition = context.Request.ReceiveBuff[1].Position;
            ulong offsetsSize = context.Request.ReceiveBuff[1].Size;

            ulong fontSizeBufferPosition = context.Request.ReceiveBuff[2].Position;
            ulong fontSizeBufferSize = context.Request.ReceiveBuff[2].Size;

            if (offset + 4 > (uint)typesSize ||
                offset + 4 > (uint)offsetsSize ||
                offset + 4 > (uint)fontSizeBufferSize)
            {
                return false;
            }

            context.Memory.Write(typesPosition + offset, (int)fontType);
            context.Memory.Write(offsetsPosition + offset, context.Device.System.SharedFontManager.GetSharedMemoryAddressOffset(fontType));
            context.Memory.Write(fontSizeBufferPosition + offset, context.Device.System.SharedFontManager.GetFontSize(fontType));

            return true;
        }
    }
}
