using Ryujinx.HLE.HOS.Services.Sdb.Pl.Types;
using System;

namespace Ryujinx.HLE.HOS.Services.Sdb.Pl
{
    // S2Arm：Switch 2 nn::pl::sharedresource::detail::IFontService，pl:u 2100 RequestLoadNxFont 回出的对象：按类型回 Nx（Switch 1）共享字体在游戏传输内存里的偏移 / 长度。
    //   线上格式取自塞尔达时之笛（0400486024DEC000）sdk 客户端代理：命令 0 与 pl:u 2010 共用同一个发送助手（0x5a4f40），格式相同；
    //   命令 1 与 pl:u 2020 共用发送助手 0x5a5070。客户端 nn::pl::GetBuiltInFontData(BuiltInFontDataNx*, …)（0x5a3bb0）把地址算成「传输内存首址 + 描述里的偏移」
    class IFontService : IpcService
    {
        private readonly uint[] _offsets = new uint[(int)SharedFontType.Count];
        private readonly uint[] _sizes = new uint[(int)SharedFontType.Count];

        // 偏移 / 长度在写传输内存的同一时刻取下（之后共享字体管理器换局重建也不影响这块已写好的内存）
        public IFontService(SharedFontManager fonts)
        {
            for (SharedFontType type = 0; type < SharedFontType.Count; type++)
            {
                _offsets[(int)type] = (uint)fonts.GetSharedMemoryAddressOffset(type);
                _sizes[(int)type] = (uint)fonts.GetFontSize(type);
            }
        }

        [CommandCmif(0)]
        // GetBuiltInFontData(u8 type, b8 option) -> (b8 available, nn::pl::BuiltInFontDescriptor {u8 type, u8 flags, u16, u32 offset, u32 size})
        public ResultCode GetBuiltInFontData(ServiceCtx context)
        {
            byte type = context.RequestData.ReadByte();

            // 客户端 GetBuiltInFontDataSet(Nx)（0x5a3c7c）把条数截到 7，比共享字体 6 类多一类（Ounce 版 0x5a391c 截到 6）；第 7 类是什么、真机对没有的类型回什么，都不知道
            if (type >= _offsets.Length)
            {
                throw new NotImplementedException($"pl IFontService 0 GetBuiltInFontData：Nx 字体类型 {type} 我方没有（只有共享字体 0–5），真机回什么不知道");
            }

            context.ResponseData.Write(true);
            context.ResponseData.Write((byte)0);
            context.ResponseData.Write((ushort)0);
            context.ResponseData.Write(type);
            context.ResponseData.Write((byte)0);
            context.ResponseData.Write((ushort)0);
            context.ResponseData.Write(_offsets[type]);
            context.ResponseData.Write(_sizes[type]);

            return ResultCode.Success;
        }

        [CommandCmif(1)]
        // GetBuiltInFontDataSet(u64 language_code, b8 option, buffer<u8 type, 5> types, buffer<descriptor, 6> out) -> (b8 available, s32 count)
        public ResultCode GetBuiltInFontDataSet(ServiceCtx context)
        {
            throw new NotImplementedException("pl IFontService 1 GetBuiltInFontDataSet：按语言码与入参类型表挑选、排序字体的规则不知道");
        }
    }
}
