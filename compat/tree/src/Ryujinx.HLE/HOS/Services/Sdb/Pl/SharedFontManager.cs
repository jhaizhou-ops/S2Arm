using LibHac.Common;
using LibHac.Fs;
using LibHac.Fs.Fsa;
using LibHac.FsSystem;
using LibHac.Ncm;
using LibHac.Tools.FsSystem;
using LibHac.Tools.FsSystem.NcaUtils;
using Microsoft.IO;
using Ryujinx.Common.Memory;
using Ryujinx.HLE.Exceptions;
using Ryujinx.HLE.FileSystem;
using Ryujinx.HLE.HOS.Kernel.Memory;
using Ryujinx.HLE.HOS.Services.Sdb.Pl.Types;
using System;
using System.Buffers.Binary;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;

namespace Ryujinx.HLE.HOS.Services.Sdb.Pl
{
    class SharedFontManager
    {
        private const uint FontKey = 0x06186249;
        private const uint BFTTFMagic = 0x18029a7f;

        private readonly Switch _device;
        private readonly SharedMemoryStorage _storage;

        private struct FontInfo
        {
            public int Offset;
            public int Size;

            public FontInfo(int offset, int size)
            {
                Offset = offset;
                Size = size;
            }
        }

        private Dictionary<SharedFontType, FontInfo> _fontData;
        private uint _fontEnd; // S2Arm：字体区已用长度（最后一个字体正文的末尾）

        public SharedFontManager(Switch device, SharedMemoryStorage storage)
        {
            _device = device;
            _storage = storage;
        }

        public void Initialize()
        {
            _fontData?.Clear();
            _fontData = null;

        }

        public void EnsureInitialized(ContentManager contentManager)
        {
            if (_fontData == null)
            {
                _storage.ZeroFill();

                uint fontOffset = 0;

                FontInfo CreateFont(string name)
                {
                    if (contentManager.TryGetFontTitle(name, out ulong fontTitle) && contentManager.TryGetFontFilename(name, out string fontFilename))
                    {
                        // S2Arm: no firmware NCAs; the same .bfttf files can come from a directory (S2AHooks.SharedFontDir)
                        if (S2AHooks.SharedFontDir != null)
                        {
                            string file = System.IO.Path.Combine(S2AHooks.SharedFontDir, fontFilename);

                            if (!File.Exists(file))
                            {
                                S2AHooks.Red?.Invoke($"共享字体：{name}（{fontTitle:x16}）缺 {fontFilename}");

                                throw new InvalidSystemResourceException($"{name} ({fontTitle:x16}) {fontFilename} not found in {S2AHooks.SharedFontDir}");
                            }

                            byte[] fileData;

                            using (FileStream fs = File.OpenRead(file))
                            {
                                fileData = DecryptFont(fs);
                            }

                            FontInfo fileInfo = new((int)fontOffset, fileData.Length);

                            WriteMagicAndSize(fontOffset, fileData.Length);

                            fontOffset += 8;

                            uint fileStart = fontOffset;

                            for (; fontOffset - fileStart < fileData.Length; fontOffset++)
                            {
                                _storage.GetRef<byte>(fontOffset) = fileData[fontOffset - fileStart];
                            }

                            return fileInfo;
                        }

                        string contentPath = contentManager.GetInstalledContentPath(fontTitle, StorageId.BuiltInSystem, NcaContentType.Data);
                        string fontPath = VirtualFileSystem.SwitchPathToSystemPath(contentPath);

                        if (!string.IsNullOrWhiteSpace(fontPath))
                        {
                            byte[] data;

                            using (IStorage ncaFileStream = new LocalStorage(fontPath, FileAccess.Read, FileMode.Open))
                            {
                                Nca nca = new(_device.System.KeySet, ncaFileStream);
                                IFileSystem romfs = nca.OpenFileSystem(NcaSectionType.Data, _device.System.FsIntegrityCheckLevel);

                                using UniqueRef<IFile> fontFile = new();

                                romfs.OpenFile(ref fontFile.Ref, ("/" + fontFilename).ToU8Span(), OpenMode.Read).ThrowIfFailure();

                                data = DecryptFont(fontFile.Get.AsStream());
                            }

                            FontInfo info = new((int)fontOffset, data.Length);

                            WriteMagicAndSize(fontOffset, data.Length);

                            fontOffset += 8;

                            uint start = fontOffset;

                            for (; fontOffset - start < data.Length; fontOffset++)
                            {
                                _storage.GetRef<byte>(fontOffset) = data[fontOffset - start];
                            }

                            return info;
                        }
                        else
                        {
                            if (!contentManager.TryGetSystemTitlesName(fontTitle, out string titleName))
                            {
                                titleName = "Unknown";
                            }

                            S2AHooks.Red?.Invoke($"共享字体：缺系统数据 {titleName}（{fontTitle:x16}）");

                            throw new InvalidSystemResourceException($"{titleName} ({fontTitle:x8}) system title not found! This font will not work, provide the system archive to fix this error.");
                        }
                    }
                    else
                    {
                        throw new ArgumentException($"Unknown font \"{name}\"!");
                    }
                }

                _fontData = new Dictionary<SharedFontType, FontInfo>
                {
                    { SharedFontType.JapanUsEurope,       CreateFont("FontStandard")                  },
                    { SharedFontType.SimplifiedChinese,   CreateFont("FontChineseSimplified")         },
                    { SharedFontType.SimplifiedChineseEx, CreateFont("FontExtendedChineseSimplified") },
                    { SharedFontType.TraditionalChinese,  CreateFont("FontChineseTraditional")        },
                    { SharedFontType.Korean,              CreateFont("FontKorean")                    },
                    { SharedFontType.NintendoEx,          CreateFont("FontNintendoExtended")          },
                };

                if (fontOffset > Horizon.FontSize)
                {
                    throw new InvalidSystemResourceException("The sum of all fonts size exceed the shared memory size. " +
                                                             $"Please make sure that the fonts don't exceed {Horizon.FontSize} bytes in total. (actual size: {fontOffset} bytes).");
                }

                _fontEnd = fontOffset;
            }
        }

        private void WriteMagicAndSize(ulong offset, int size)
        {
            const int Key = 0x49621806;

            int encryptedSize = BinaryPrimitives.ReverseEndianness(size ^ Key);

            _storage.GetRef<int>(offset + 0) = (int)BFTTFMagic;
            _storage.GetRef<int>(offset + 4) = encryptedSize;
        }

        public int GetFontSize(SharedFontType fontType)
        {
            EnsureInitialized(_device.System.ContentManager);

            return _fontData[fontType].Size;
        }

        public int GetSharedMemoryAddressOffset(SharedFontType fontType)
        {
            EnsureInitialized(_device.System.ContentManager);

            return _fontData[fontType].Offset + 8;
        }

        // S2Arm：pl:u 2100 RequestLoadNxFont 把字体区 [0, 已用长度) 原样写进游戏递来的传输内存：每个字体 8 字节头 + 解密后的正文，
        //   正文偏移 / 长度与 GetSharedMemoryAddressOffset / GetFontSize 同口径
        public ReadOnlySpan<byte> GetFontRegion()
        {
            EnsureInitialized(_device.System.ContentManager);

            return MemoryMarshal.CreateReadOnlySpan(ref _storage.GetRef<byte>(0), (int)_fontEnd);
        }

        private byte[] DecryptFont(Stream bfttfStream)
        {
            static uint KXor(uint data) => data ^ FontKey;

            using BinaryReader reader = new(bfttfStream);
            using RecyclableMemoryStream ttfStream = MemoryStreamManager.Shared.GetStream();
            using BinaryWriter output = new(ttfStream);

            if (KXor(reader.ReadUInt32()) != BFTTFMagic)
            {
                throw new InvalidDataException("Error: Input file is not in BFTTF format!");
            }

            bfttfStream.Position += 4;

            for (int i = 0; i < (bfttfStream.Length - 8) / 4; i++)
            {
                output.Write(KXor(reader.ReadUInt32()));
            }

            return ttfStream.ToArray();
        }
    }
}
