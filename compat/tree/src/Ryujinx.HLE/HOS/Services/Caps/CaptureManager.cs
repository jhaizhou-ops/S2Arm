using Ryujinx.Common.Logging;
using Ryujinx.Common.Memory;
using Ryujinx.HLE.HOS.Services.Caps.Types;
using System;
using System.Globalization;
using System.IO;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Security.Cryptography;

namespace Ryujinx.HLE.HOS.Services.Caps
{
    internal class CaptureManager
    {
        public CaptureManager(Switch device)
        {
            _ = device;
        }
        private readonly string _sdCardPath = FileSystem.VirtualFileSystem.GetSdCardPath();

        private uint _shimLibraryVersion;

        private const int ScreenshotWidth = 1280;
        private const int ScreenshotHeight = 720;
        private const int ScreenshotBytesPerPixel = 4;
        private const int ScreenshotDataSize = ScreenshotWidth * ScreenshotHeight * ScreenshotBytesPerPixel; // 0x384000

        public ResultCode SetShimLibraryVersion(ServiceCtx context)
        {
            ulong shimLibraryVersion = context.RequestData.ReadUInt64();
#pragma warning disable IDE0059 // Remove unnecessary value assignment
            ulong appletResourceUserId = context.RequestData.ReadUInt64();
#pragma warning restore IDE0059

            // TODO: Service checks if the pid is present in an internal list and returns ResultCode.BlacklistedPid if it is.
            //       The list contents needs to be determined.

            ResultCode resultCode = ResultCode.OutOfRange;

            if (shimLibraryVersion != 0)
            {
                if (_shimLibraryVersion == shimLibraryVersion)
                {
                    resultCode = ResultCode.Success;
                }
                else if (_shimLibraryVersion != 0)
                {
                    resultCode = ResultCode.ShimLibraryVersionAlreadySet;
                }
                else if (shimLibraryVersion == 1)
                {
                    resultCode = ResultCode.Success;

                    _shimLibraryVersion = 1;
                }
            }

            return resultCode;
        }

        // S2Arm: the screenshot is read straight from game memory (a span), not copied into a managed array first
        public unsafe ResultCode SaveScreenShot(
            ReadOnlySpan<byte> screenshotData,
            ulong appletResourceUserId,
            ulong titleId,
            out ApplicationAlbumEntry applicationAlbumEntry)
        {
            // S2Arm: this is a full implementation (JPEG into the SD album, ApplicationAlbumEntry back), not a stub; logged as one it was counted
            //   in the census stub tally and read as the cause of the Zumba share Break (11-03)
            Logger.Info?.Print(LogClass.ServiceCaps, "SaveScreenShot", new
            {
                appletResourceUserId,
                titleId,
                screenshotDataLength = screenshotData.Length,
            });

            applicationAlbumEntry = default;

            if (screenshotData.Length == 0)
            {
                return ResultCode.NullInputBuffer;
            }

            if (screenshotData.Length < ScreenshotDataSize)
            {
                Logger.Warning?.PrintMsg(
                    LogClass.ServiceCaps,
                    $"Invalid screenshot buffer size 0x{screenshotData.Length:X}; expected at least 0x{ScreenshotDataSize:X}.");

                return ResultCode.NullInputBuffer;
            }

            DateTime currentDateTime = DateTime.Now;

            applicationAlbumEntry = new ApplicationAlbumEntry()
            {
                Size = (ulong)Unsafe.SizeOf<ApplicationAlbumEntry>(),
                TitleId = titleId,
                AlbumFileDateTime = new AlbumFileDateTime()
                {
                    Year = (ushort)currentDateTime.Year,
                    Month = (byte)currentDateTime.Month,
                    Day = (byte)currentDateTime.Day,
                    Hour = (byte)currentDateTime.Hour,
                    Minute = (byte)currentDateTime.Minute,
                    Second = (byte)currentDateTime.Second,
                    UniqueId = 0,
                },
                AlbumStorage = AlbumStorage.Sd,
                ContentType = ContentType.Screenshot,
                Padding = new Array5<byte>(),
                Unknown0x1f = 1,
            };

            // NOTE: The hex hash is a HMAC-SHA256 (first 32 bytes) using a hardcoded secret key over the titleId, we can simulate it by hashing the titleId instead.
            string hash = Convert.ToHexString(SHA256.HashData(BitConverter.GetBytes(titleId)))[..0x20];

            string folderPath = Path.Combine(
                _sdCardPath,
                "Nintendo",
                "Album",
                currentDateTime.Year.ToString("0000", CultureInfo.InvariantCulture),
                currentDateTime.Month.ToString("00", CultureInfo.InvariantCulture),
                currentDateTime.Day.ToString("00", CultureInfo.InvariantCulture));

            string filePath = GenerateFilePath(folderPath, applicationAlbumEntry, currentDateTime, hash);

            _ = Directory.CreateDirectory(folderPath);

            // S2Arm: UniqueId is one byte. Once every id of this second is taken it wrapped back to 0 and this loop never ended (the game thread hung
            // in SaveScreenShot). Try each id once; with none free the album cannot hold another capture for this second.
            // AlbumFileCountLimit is capsrv's nearest result (ResultNames 0x32CE); the code hardware returns in this exact case is not verified.
            int tries = 1;

            while (File.Exists(filePath))
            {
                if (tries++ > byte.MaxValue)
                {
                    return ResultCode.AlbumFileCountLimit;
                }

                applicationAlbumEntry.AlbumFileDateTime.UniqueId++;
                filePath = GenerateFilePath(folderPath, applicationAlbumEntry, currentDateTime, hash);
            }

            byte[] jpeg;
            try
            {
                jpeg = ScreenshotEncoding.Encode(screenshotData[..ScreenshotDataSize], ScreenshotWidth, ScreenshotHeight, 80);
            }
            catch (ScreenshotBitmapAllocationException)
            {
                return ResultCode.InvalidArgument;
            }
            using FileStream file = File.OpenWrite(filePath);
            file.Write(jpeg);

            return ResultCode.Success;
        }

        private string GenerateFilePath(string folderPath, ApplicationAlbumEntry applicationAlbumEntry, DateTime currentDateTime, string hash)
        {
            string fileName = $"{currentDateTime:yyyyMMddHHmmss}{applicationAlbumEntry.AlbumFileDateTime.UniqueId:00}-{hash}.jpg";

            return Path.Combine(folderPath, fileName);
        }
    }
}
