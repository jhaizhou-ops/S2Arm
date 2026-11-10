using Ryujinx.Common.Logging;
using Ryujinx.Graphics.Nvdec.FFmpeg.H264;
using Ryujinx.Graphics.Video;
using System;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;

namespace Ryujinx.Graphics.Nvdec.Apple
{
    // H.264 硬件解码（苹果 VideoToolbox），替 FFmpeg 后端（S2Arm 不带 FFmpeg）。
    // 与 FFmpeg 后端同一约定：每次 Decode 交一帧的码流（Annex B），参数集按 nvdec 给的图像信息重建，当场出这一帧（解码序，不重排——
    // 游戏自己管参考帧与显示序）。解出的帧要 y420 三平面，面直接引用 VideoToolbox 的像素缓冲（锁住只读），交 SurfaceWriter 回写客体内存。
    // 稳态零托管分配：码流转写缓冲、参数集缓存按需扩容后复用；每帧只有 CoreMedia 的块 / 样本缓冲两个原生对象（用完即放）。
    // 只在 Host1x 线程上跑（nvdec 设备线程），不碰游戏线程。
    public sealed unsafe class VideoToolboxH264Decoder : IH264Decoder
    {
        public bool IsHardwareAccelerated => true;

        private const int WorkBufferSize = 0x200;
        private const uint PixelFormatY420 = 0x79343230;   // 'y420'：kCVPixelFormatType_420YpCbCr8Planar（视频范围，样本值原样）

        private readonly byte[] _workBuffer = new byte[WorkBufferSize];
        private byte[] _avcc = new byte[0x10000];          // 长度前缀格式的切片 NAL
        private byte[] _sps = Array.Empty<byte>();
        private byte[] _pps = Array.Empty<byte>();
        private int _spsLen, _ppsLen;

        private nint _format;    // CMVideoFormatDescriptionRef
        private nint _session;   // VTDecompressionSessionRef
        private readonly OutputSlot* _slot = (OutputSlot*)NativeMemory.AllocZeroed((nuint)sizeof(OutputSlot));
        private bool _failed;
        private long _frames;
        // S2Arm: iOS invalidates the hardware decode session while the app is in the background; after it the next frames fail, and a fresh
        // session decoding P frames without their references gives colour blocks (#495: one flash about 19 s after coming back). After a
        // failure the session is dropped and frames are skipped until the next IDR, repeating the last good picture meanwhile
        private bool _waitIdr;
        private nint _last;      // last good picture (CVPixelBuffer, retained)
        // S2Arm: samples decoded since the last IDR (length-prefixed, back to back). When the session goes away, a fresh one is fed this
        // run again (outputs dropped) and decodes the current frame at once, instead of waiting for the next IDR with a frozen picture
        // (#495: Silksong cutscene video stayed on one picture for seconds after 30 s in the background). Capped; over the cap, or with no IDR
        // seen yet, a failure falls back to waiting for the next IDR
        private const int GopCap = 16 << 20;
        private byte[] _gop = new byte[0x40000];
        private int[] _gopEnds = new int[64];
        private int _gopLen, _gopCount;
        private bool _gopValid;
        private bool _skipLogged;
        // S2Arm: 重建 SPS 的 max_num_ref_frames 决定 VideoToolbox 的 DPB 上限，必须与真实流一致（见 20261029 坑记录）：上限大于真实值时
        // 长流在 frame_num 回绕后参考错帧、整段解错而且一次都不报错。nvdec 元数据不带这个字段（上游恒 0），码流里通常也没有 SPS
        // （Tegra NVDEC 的参数集在 nvdec 命令里，不是 inbuf），所以前 8 帧里自己解 slice 头的 L0 active（SliceRefs），
        // 顺手探一下码流自带的 SPS；两条都拿不到才退回 nvdec 元数据的 active
        private int _refFrames;
        private int _spsFrames;
        private int _maxActive = -1;      // 探测窗口内 slice 报出的 L0 active 最大值（−1 = 还没读到）
        private int _overrideFrames;      // 窗口内真正带 override 的帧数（0 = 这些帧全靠 PPS 默认值 / 元数据）
        private int _sliceFailures;       // 窗口内解析失败的帧数
        private int _pendingRefFrames;    // 已定下但要等下一个 IDR 才切的目标值（中途换参数集会让 VideoToolbox 丢会话）
        private int _probeCount;
        // S2Arm: 前 8 帧每帧 slice 报出的 active（−1 = 该帧没有 override，−2 = 解析失败）。真机上 iOS 应用注入不了环境变量，
        // 开不了 S2A_NVDEC_DEBUG，所以这段序列必须进默认日志——真机定位全靠它
        private readonly int[] _activeSeq = new int[8];
        private int _activeSeqCount;
        // S2Arm: 诊断——S2A_NVDEC_DEBUG=1 时把前 8 帧的探测过程逐帧打出来（硬件给的 L0 active、累计最大、采用值、剩余轮次）。
        // 真机上「采用值一直不变」有两种原因（硬件不随 slice override / 这条流确实只用更少参考），只有逐帧值能分开
        private static readonly bool ProbeDebug = Environment.GetEnvironmentVariable("S2A_NVDEC_DEBUG") == "1";
        private int _probeLeft = 8;
        // S2Arm: diagnostic — S2A_VT_FAULT_FRAME=<n> invalidates the session (handle kept) after the n-th decoded picture, so the next frame
        // fails with kVTInvalidSessionErr exactly as after iOS background; lets the recovery path be exercised on a Mac
        private static readonly long FaultFrame = long.TryParse(Environment.GetEnvironmentVariable("S2A_VT_FAULT_FRAME"), out long f) ? f : -1;

        private struct OutputSlot
        {
            public nint ImageBuffer;   // 回调交来的 CVPixelBuffer（已 retain）
            public int Status;
        }

        public ISurface CreateSurface(int width, int height) => new VideoToolboxSurface(width, height);

        public bool Decode(ref H264PictureInfo pictureInfo, ISurface output, ReadOnlySpan<byte> bitstream)
        {
            if (_failed)
            {
                return false;
            }

            VideoToolboxSurface surface = (VideoToolboxSurface)output;

            // S2Arm: 前 8 帧两件事——读 slice 头的 num_ref_idx_l0_active_minus1（真机的 PictureInfo 那个字段不是这帧的 override 值，
            // 60fps 变体实测给 2，正是该变体 PPS 的 num_ref_idx_l0_default_active_minus1，而 slice 里写的是 3），
            // 以及找码流自带的 SPS（真机 inbuf 没有 SPS，这条通常不命中，命中就是真值）。
            // 两条都失败/不命中时必须看得见：今晚已经四次吃「兜底生效却静默」的亏（_waitIdr 无日志、refFrames > 0 才打、SPS 探测返回 0 无日志、采用=3 看不出是否更新）
            _probeCount++;

            SliceRefs.Result slice = default;
            bool probed = false;

            if (_probeLeft > 0)
            {
                _probeLeft--;
                probed = true;
                slice = SliceRefs.Parse(bitstream, in pictureInfo);

                // 本帧没有 override（IDR / I 帧，或 P 帧直接用 PPS 默认值）时先用元数据值占位，等价于旧读法
                int frameActive = (int)pictureInfo.NumRefIdxL0ActiveMinus1;

                if (_activeSeqCount < _activeSeq.Length)
                {
                    _activeSeq[_activeSeqCount++] = slice.Ok ? (slice.HasOverride ? slice.ActiveMinus1 : -1) : -2;
                }

                if (slice.Ok)
                {
                    if (slice.HasOverride)
                    {
                        frameActive = slice.ActiveMinus1;
                        _overrideFrames++;
                    }
                }
                else
                {
                    _sliceFailures++;

                    Logger.Error?.Print(LogClass.Nvdec, $"[红] slice header 解析失败（{slice.Error}），回落到 PictureInfo 值：第 {_probeCount}/8 帧 PictureInfo L0 active={pictureInfo.NumRefIdxL0ActiveMinus1}，累计最大={(_maxActive < 0 ? "无" : _maxActive.ToString())}");
                }

                if (frameActive > _maxActive)
                {
                    _maxActive = frameActive;
                }

                int spsFrames = SpsRefFrames.TryRead(bitstream);

                if (spsFrames > 0)
                {
                    _spsFrames = spsFrames;
                }
            }

            // S2Arm: 本实例还没出过图时，先等 IDR。没有参考帧的 P 帧 VideoToolbox 一定解不对：本机报 kVTVideoDecoderBadDataErr
            // (-12909)，别的系统版本可能不报错直接输出色块，两种情况都不该把帧交进去（交进去只会污染新会话）
            if (_last == 0 && !HasIdr(bitstream))
            {
                if (!_skipLogged)
                {
                    _skipLogged = true;
                    Logger.Info?.Print(LogClass.Nvdec, "VideoToolbox H.264：新会话首帧不是 IDR，先不收，等首个 IDR");
                }

                return false;
            }

            if (_waitIdr)
            {
                if (!HasIdr(bitstream))
                {
                    return RepeatLast(surface);
                }

                _waitIdr = false;
                Logger.Info?.Print(LogClass.Nvdec, "VideoToolbox H.264：等到 IDR，重建会话接着解");
            }

            // S2Arm: nvdec 元数据不带 max_num_ref_frames（上游 Types/H264/PictureInfo.cs 恒填 0），重建 SPS 原先写死 16。这个上限决定
            // VideoToolbox 的 DPB 大小：比真实值大时，frame_num 回绕后参考列表会取到回绕前的旧帧，P 帧整段解错而且一次都不报错
            // （丝之歌过场：真实值 4，写死 16 时 260 帧里 118 帧 PSNR 20–24；用真实值 4 时 260 帧全部与 FFmpeg 逐像素一致；
            // 折中的 8 仍留 88 帧错，所以必须用码流里的真实值）。SPS 只在每段视频开头出现一次，读到就缓存
            // 采用值每次真正变化都打一行：来源（码流 SPS / slice 头 override / 回落 PictureInfo）、窗口内 active 最大、
            // 用 override 的帧数、解析失败数、当前 PictureInfo 值。上一版把日志挂在「探到 SPS」或「探测轮次用尽」上，
            // 真机两行都没出现——兜底生效了却静默，所以这里改成变化时无条件打
            bool idr = HasIdr(bitstream);

            // 探到 SPS 用它（真值）；否则按「slice override 最大 + 1」，下限 3（保证首帧能解）
            int target = _spsFrames != 0 ? _spsFrames : (int)Math.Max(3, _maxActive + 1);
            string source = _spsFrames != 0
                ? "码流 SPS"
                : _overrideFrames > 0
                    ? "slice 头 override"
                    : "回落 PictureInfo";

            if (_pendingRefFrames != 0)
            {
                target = _pendingRefFrames;
            }

            if (target != _refFrames)
            {
                // 中途换参数集会让 VideoToolbox 判新 SPS 不可接受（CanAcceptFormatDescription 返回 0）→ 丢会话；而 UpdateParameterSets
                // 已经把 _gopValid 清空，失败后无法重放 → 整段重复上一张图（30fps 变体 3→9 实测 131 帧里 124 帧重复）。
                // 是否安全只看一件事：max_num_ref_frames 的 ue 编码长度变不变。3↔4 都是 5 bit，SPS 等长，实测 260 帧 0 冻结；
                // 3→9 是 5→7 bit，SPS 变长，实测整段冻结。变长的切换一律等 IDR（IDR 本身重建 GOP，切值不欠账）
                if (idr || _refFrames == 0 || UeBits(target) == UeBits(_refFrames))
                {
                    _refFrames = target;
                    _pendingRefFrames = 0;

                    Logger.Info?.Print(LogClass.Nvdec, $"Nvdec 参考帧：采用={_refFrames} 来源={source}（SPS={(_spsFrames == 0 ? "无" : _spsFrames.ToString())} 前 8 帧 slice active=[{ActiveSeq()}] 最大={(_maxActive < 0 ? "无" : _maxActive.ToString())} 用 override 的帧={_overrideFrames} 解析失败={_sliceFailures} 硬件 L0 active={pictureInfo.NumRefIdxL0ActiveMinus1} 第 {_probeCount} 帧 IDR={idr}）");
                }
                else if (_pendingRefFrames != target)
                {
                    _pendingRefFrames = target;

                    Logger.Info?.Print(LogClass.Nvdec, $"Nvdec 参考帧：待切 {_pendingRefFrames}（当前 {_refFrames}），等下一个 IDR 生效——中途换参数集会让 VideoToolbox 丢会话");
                }
            }

            // 探测窗口收尾无条件打一行：采用值可能在第 1 帧就定了、之后再没变化，那一行会错过整段序列；
            // 真机上判断「读数错在哪」需要的是这一行（硬件 L0 active 与 slice 值并列）
            if (probed && _probeLeft == 0)
            {
                Logger.Info?.Print(LogClass.Nvdec, $"Nvdec 参考帧探测结束：前 8 帧 slice active=[{ActiveSeq()}]（数字 = slice override 值，d = 该帧无 override，x = 解析失败）最大={(_maxActive < 0 ? "无" : _maxActive.ToString())} 硬件 L0 active={pictureInfo.NumRefIdxL0ActiveMinus1} 采用={_refFrames} 待切={(_pendingRefFrames == 0 ? "无" : _pendingRefFrames.ToString())} 解析失败={_sliceFailures}");
            }

            if (ProbeDebug && probed)
            {
                string seen = slice.Ok
                    ? slice.HasOverride ? slice.ActiveMinus1.ToString() : "无 override"
                    : $"解析失败（{slice.Error}）";

                Logger.Info?.Print(LogClass.Nvdec, $"Nvdec 探测 #{_probeCount}/8：硬件 L0 active={pictureInfo.NumRefIdxL0ActiveMinus1} slice L0 active={seen} 累计最大={_maxActive} 采用={_refFrames} 待切={(_pendingRefFrames == 0 ? "无" : _pendingRefFrames.ToString())} 剩余={_probeLeft}");
            }

            pictureInfo.NumRefFrames = (uint)_refFrames;

            ReadOnlySpan<byte> paramSets = SpsAndPpsReconstruction.Reconstruct(ref pictureInfo, _workBuffer);

            if (!UpdateParameterSets(paramSets))
            {
                return false;
            }

            int avccLen = ToAvcc(bitstream);

            if (avccLen == 0)
            {
                return false;
            }

            int st = Submit(_avcc, avccLen);

            if (st != 0 && (idr || _gopValid))
            {
                int failed = st;

                // 这一帧是 IDR：新会话直接重解；否则先重喂上一个 IDR 起的帧补齐参考
                if (idr ? Recreate() : Replay())
                {
                    st = Submit(_avcc, avccLen);
                }

                if (st == 0)
                {
                    Logger.Info?.Print(LogClass.Nvdec, $"VideoToolbox H.264：解码失败 {failed}（会话失效）后重建会话{(idr ? "，重解这一帧 IDR" : $"，重喂上一个 IDR 起的 {_gopCount} 帧")}接着解");
                }
            }

            if (st != 0)
            {
                Logger.Error?.Print(LogClass.Nvdec, $"VideoToolbox H.264 解码失败：{st}；丢掉会话，等下一个 IDR（其间重复上一张好图）");
                DestroySession();
                _gopValid = false;
                _waitIdr = true;

                return RepeatLast(surface);
            }

            Remember(idr, avccLen);

            nint img = _slot->ImageBuffer;
            _slot->ImageBuffer = 0;
            nint keep = CoreFoundation.CFRetain(img);   // 挂上面之后才认作上一张好图

            if (!surface.Attach(img))   // 引用转给面；不是 y420 三平面时面已放掉它
            {
                // 审计 P2-198：原先格式不符也回 true，空面被当成解出来的一帧。走同一条失败路径：丢会话、等下一个 IDR，其间重复上一张好图
                CoreFoundation.CFRelease(keep);
                Logger.Error?.Print(LogClass.Nvdec, "VideoToolbox H.264：出帧不是 y420 三平面；丢掉会话，等下一个 IDR（其间重复上一张好图）");
                DestroySession();
                _gopValid = false;
                _waitIdr = true;

                return RepeatLast(surface);
            }

            if (_last != 0)
            {
                CoreFoundation.CFRelease(_last);
            }

            _last = keep;

            if (_frames == FaultFrame)
            {
                VideoToolbox.VTDecompressionSessionInvalidate(_session);
                Logger.Info?.Print(LogClass.Nvdec, $"VideoToolbox H.264：诊断开关 S2A_VT_FAULT_FRAME，第 {_frames} 帧后作废会话（保留句柄）");
            }

            if (_frames++ == 0)
            {
                Logger.Info?.Print(LogClass.Nvdec, $"VideoToolbox H.264 首帧解出：{surface.Width}x{surface.Height}，亮度行距 {surface.Stride}，色度行距 {surface.UvStride}");
            }

            return true;
        }

        // 提交一个样本、同步等出帧：0 = 成功（像素缓冲在 _slot），否则提交 / 回调状态（没出帧记 -1）。失败时不留像素缓冲
        private int Submit(byte[] data, int len, int offset = 0)
        {
            if (_session == 0 && !CreateSession())
            {
                return -1;
            }

            int st;

            fixed (byte* p = data)
            {
                nint block = 0, sample = 0;
                st = CoreMedia.CMBlockBufferCreateWithMemoryBlock(0, p + offset, (nuint)len, CoreFoundation.AllocatorNull, null, 0, (nuint)len, 0, &block);

                if (st == 0)
                {
                    nuint size = (nuint)len;
                    st = CoreMedia.CMSampleBufferCreateReady(0, block, _format, 1, 0, null, 1, &size, &sample);
                }

                if (st == 0)
                {
                    _slot->ImageBuffer = 0;
                    _slot->Status = -1;
                    uint info;
                    st = VideoToolbox.VTDecompressionSessionDecodeFrame(_session, sample, 0, _slot, &info);

                    if (st == 0)
                    {
                        VideoToolbox.VTDecompressionSessionWaitForAsynchronousFrames(_session);
                        st = _slot->Status != 0 ? _slot->Status : _slot->ImageBuffer == 0 ? -1 : 0;
                    }
                }

                if (sample != 0)
                {
                    CoreFoundation.CFRelease(sample);
                }

                if (block != 0)
                {
                    CoreFoundation.CFRelease(block);
                }
            }

            if (st != 0 && _slot->ImageBuffer != 0)
            {
                CoreFoundation.CFRelease(_slot->ImageBuffer);
                _slot->ImageBuffer = 0;
            }

            return st;
        }

        private bool Recreate()
        {
            DestroySession();

            return CreateSession();
        }

        // 新会话重喂上一个 IDR 起解过的帧，出的图丢掉；全部成功才算接上
        private bool Replay()
        {
            if (!Recreate())
            {
                return false;
            }

            for (int i = 0, start = 0; i < _gopCount; start = _gopEnds[i++])
            {
                if (Submit(_gop, _gopEnds[i] - start, start) != 0)
                {
                    return false;
                }

                CoreFoundation.CFRelease(_slot->ImageBuffer);
                _slot->ImageBuffer = 0;
            }

            return true;
        }

        // 解成功的样本记进「上一个 IDR 起」的序列：IDR 重新开始；没见过 IDR 或超上限就不记（失败时退回等 IDR）
        private void Remember(bool idr, int len)
        {
            if (idr)
            {
                _gopLen = _gopCount = 0;
                _gopValid = true;
            }

            if (!_gopValid)
            {
                return;
            }

            if (_gopLen + len > GopCap)
            {
                _gopValid = false;
                return;
            }

            if (_gopLen + len > _gop.Length)
            {
                Array.Resize(ref _gop, Math.Max(_gop.Length * 2, _gopLen + len));
            }

            if (_gopCount == _gopEnds.Length)
            {
                Array.Resize(ref _gopEnds, _gopEnds.Length * 2);
            }

            Buffer.BlockCopy(_avcc, 0, _gop, _gopLen, len);
            _gopLen += len;
            _gopEnds[_gopCount++] = _gopLen;
        }

        // 前 8 帧 slice active 序列，一帧一个字符：数字 = 该帧 slice 的 override 值，d = 该帧没有 override（用 PPS 默认值），x = 解析失败
        private string ActiveSeq()
        {
            if (_activeSeqCount == 0)
            {
                return "无";
            }

            // 逗号分隔：与前一版日志里 [2,0,0,1,3,2,0,1] 的写法一致，判读时能一眼数出帧数（连写成一串会数错）
            char[] chars = new char[_activeSeqCount * 2 - 1];

            for (int i = 0; i < _activeSeqCount; i++)
            {
                if (i != 0)
                {
                    chars[i * 2 - 1] = ',';
                }

                chars[i * 2] = _activeSeq[i] switch
                {
                    -1 => 'd',
                    -2 => 'x',
                    _ => (char)('0' + _activeSeq[i]),
                };
            }

            return new string(chars);
        }

        // max_num_ref_frames 在 SPS 里是 ue(v)：编码长度 = 2·floor(log2(v+1)) + 1
        private static int UeBits(int value)
        {
            long n = (long)value + 1;
            int bits = 1;

            while (n > 1)
            {
                n >>= 1;
                bits += 2;
            }

            return bits;
        }

        private bool RepeatLast(VideoToolboxSurface surface)
        {
            if (_last == 0)
            {
                return false;
            }

            return surface.Attach(CoreFoundation.CFRetain(_last));
        }

        private static bool HasIdr(ReadOnlySpan<byte> annexB)
        {
            int pos = 0;

            while (NextNal(annexB, ref pos, out ReadOnlySpan<byte> nal))
            {
                if (nal.Length > 0 && (nal[0] & 0x1F) == 5)
                {
                    return true;
                }
            }

            return false;
        }

        // 参数集变了才重建格式描述；会话不收新格式就重建会话
        private bool UpdateParameterSets(ReadOnlySpan<byte> annexB)
        {
            ReadOnlySpan<byte> sps = default, pps = default;
            int pos = 0;

            while (NextNal(annexB, ref pos, out ReadOnlySpan<byte> nal))
            {
                switch (nal[0] & 0x1F)
                {
                    case 7: sps = nal; break;
                    case 8: pps = nal; break;
                }
            }

            if (sps.IsEmpty || pps.IsEmpty)
            {
                Logger.Error?.Print(LogClass.Nvdec, "VideoToolbox H.264：重建的参数集缺 SPS / PPS");
                return false;
            }

            if (_format != 0 && sps.SequenceEqual(_sps.AsSpan(0, _spsLen)) && pps.SequenceEqual(_pps.AsSpan(0, _ppsLen)))
            {
                // S2Arm: the session may have been dropped after a failure while the parameter sets stayed the same
                return _session != 0 || CreateSession();
            }

            Store(ref _sps, ref _spsLen, sps);
            Store(ref _pps, ref _ppsLen, pps);
            _gopValid = false;   // 参数集换了，旧序列不能再重喂；下一个 IDR 重新开始记

            nint format;
            int st;

            fixed (byte* ps = _sps, pp = _pps)
            {
                byte** ptrs = stackalloc byte*[2] { ps, pp };
                nuint* sizes = stackalloc nuint[2] { (nuint)_spsLen, (nuint)_ppsLen };
                st = CoreMedia.CMVideoFormatDescriptionCreateFromH264ParameterSets(0, 2, ptrs, sizes, 4, &format);
            }

            if (st != 0)
            {
                Logger.Error?.Print(LogClass.Nvdec, $"VideoToolbox H.264：参数集建格式描述失败 {st}");
                return false;
            }

            if (_session != 0 && VideoToolbox.VTDecompressionSessionCanAcceptFormatDescription(_session, format) == 0)
            {
                DestroySession();
            }

            if (_format != 0)
            {
                CoreFoundation.CFRelease(_format);
            }

            _format = format;

            return _session != 0 || CreateSession();
        }

        private bool CreateSession()
        {
            nint attrs = CoreFoundation.CFDictionaryCreateMutable(0, 1, CoreFoundation.TypeDictionaryKeyCallBacks, CoreFoundation.TypeDictionaryValueCallBacks);
            uint fmt = PixelFormatY420;
            nint num = CoreFoundation.CFNumberCreate(0, 3 /* kCFNumberSInt32Type */, &fmt);
            CoreFoundation.CFDictionarySetValue(attrs, CoreVideo.PixelBufferPixelFormatTypeKey, num);
            CoreFoundation.CFRelease(num);

            OutputCallbackRecord cb = new() { Callback = &OnOutput, RefCon = 0 };
            nint session;
            int st = VideoToolbox.VTDecompressionSessionCreate(0, _format, 0, attrs, &cb, &session);
            CoreFoundation.CFRelease(attrs);

            if (st != 0)
            {
                Logger.Error?.Print(LogClass.Nvdec, $"VideoToolbox H.264：建解码会话失败 {st}");
                _failed = true;   // 设备不支持 / 参数不合法：不反复重试刷日志
                return false;
            }

            _session = session;

            return true;
        }

        [UnmanagedCallersOnly]
        private static void OnOutput(nint decoderRefCon, nint frameRefCon, int status, uint infoFlags, nint imageBuffer, CMTime pts, CMTime duration)
        {
            OutputSlot* slot = (OutputSlot*)frameRefCon;
            slot->Status = status;

            if (status == 0 && imageBuffer != 0)
            {
                slot->ImageBuffer = CoreFoundation.CFRetain(imageBuffer);
            }
        }

        // Annex B（3 / 4 字节起始码）→ 4 字节大端长度前缀；参数集与分隔符 NAL 不进样本（参数集在格式描述里）
        private int ToAvcc(ReadOnlySpan<byte> annexB)
        {
            int pos = 0, len = 0;

            while (NextNal(annexB, ref pos, out ReadOnlySpan<byte> nal))
            {
                int type = nal[0] & 0x1F;

                if (type is 7 or 8 or 9)
                {
                    continue;
                }

                if (len + 4 + nal.Length > _avcc.Length)
                {
                    Array.Resize(ref _avcc, Math.Max(_avcc.Length * 2, len + 4 + nal.Length));
                }

                _avcc[len] = (byte)(nal.Length >> 24);
                _avcc[len + 1] = (byte)(nal.Length >> 16);
                _avcc[len + 2] = (byte)(nal.Length >> 8);
                _avcc[len + 3] = (byte)nal.Length;
                nal.CopyTo(_avcc.AsSpan(len + 4));
                len += 4 + nal.Length;
            }

            return len;
        }

        // 取下一个 NAL（去掉起始码与尾随的零字节）
        internal static bool NextNal(ReadOnlySpan<byte> data, ref int pos, out ReadOnlySpan<byte> nal)
        {
            nal = default;
            int start = FindStartCode(data, pos);

            if (start < 0)
            {
                pos = data.Length;
                return false;
            }

            int next = FindStartCode(data, start);
            int end = next < 0 ? data.Length : next - 3;

            while (end > start && data[end - 1] == 0)
            {
                end--;
            }

            pos = next < 0 ? data.Length : next - 3;

            if (end <= start)
            {
                return NextNal(data, ref pos, out nal);
            }

            nal = data[start..end];

            return true;
        }

        // 返回起始码 00 00 01 之后第一个字节的位置；没有则 −1
        private static int FindStartCode(ReadOnlySpan<byte> data, int from)
        {
            for (int i = from; i + 2 < data.Length; i++)
            {
                if (data[i] == 0 && data[i + 1] == 0 && data[i + 2] == 1)
                {
                    return i + 3;
                }
            }

            return -1;
        }

        private static void Store(ref byte[] dst, ref int len, ReadOnlySpan<byte> src)
        {
            if (dst.Length < src.Length)
            {
                dst = new byte[src.Length];
            }

            src.CopyTo(dst);
            len = src.Length;
        }

        private void DestroySession()
        {
            if (_session != 0)
            {
                VideoToolbox.VTDecompressionSessionInvalidate(_session);
                CoreFoundation.CFRelease(_session);
                _session = 0;
            }
        }

        public void Dispose()
        {
            DestroySession();

            if (_last != 0)
            {
                CoreFoundation.CFRelease(_last);
                _last = 0;
            }

            if (_format != 0)
            {
                CoreFoundation.CFRelease(_format);
                _format = 0;
            }

            NativeMemory.Free(_slot);
        }
    }

    // 解出的一帧：引用 VideoToolbox 的像素缓冲（只读锁住），下一次解进这个面或面被丢弃时放掉
    sealed unsafe class VideoToolboxSurface : ISurface
    {
        private nint _buffer;
        private byte* _y, _u, _v;
        private int _stride, _uvStride;

        public VideoToolboxSurface(int width, int height)
        {
            Width = width;
            Height = height;
        }

        public Plane YPlane => new((nint)_y, _stride * Height);
        public Plane UPlane => new((nint)_u, _uvStride * UvHeight);
        public Plane VPlane => new((nint)_v, _uvStride * UvHeight);

        public FrameField Field => FrameField.Progressive;

        public int Width { get; private set; }
        public int Height { get; private set; }
        public int Stride => _stride;
        public int UvWidth => (Width + 1) >> 1;
        public int UvHeight => (Height + 1) >> 1;
        public int UvStride => _uvStride;

        // 接管 buffer 的一份引用；不是 y420 三平面时放掉它、面保持空，回 false（调用方走解码失败路径，审计 P2-198）
        public bool Attach(nint buffer)
        {
            Release();

            if (CoreVideo.CVPixelBufferGetPixelFormatType(buffer) != 0x79343230 || CoreVideo.CVPixelBufferGetPlaneCount(buffer) != 3)
            {
                Logger.Error?.Print(LogClass.Nvdec, $"VideoToolbox H.264：出帧像素格式 {CoreVideo.CVPixelBufferGetPixelFormatType(buffer):X8} 不是 y420 三平面");
                CoreFoundation.CFRelease(buffer);
                return false;
            }

            CoreVideo.CVPixelBufferLockBaseAddress(buffer, 1 /* kCVPixelBufferLock_ReadOnly */);
            _buffer = buffer;
            Width = (int)CoreVideo.CVPixelBufferGetWidth(buffer);
            Height = (int)CoreVideo.CVPixelBufferGetHeight(buffer);
            _y = (byte*)CoreVideo.CVPixelBufferGetBaseAddressOfPlane(buffer, 0);
            _u = (byte*)CoreVideo.CVPixelBufferGetBaseAddressOfPlane(buffer, 1);
            _v = (byte*)CoreVideo.CVPixelBufferGetBaseAddressOfPlane(buffer, 2);
            _stride = (int)CoreVideo.CVPixelBufferGetBytesPerRowOfPlane(buffer, 0);
            _uvStride = (int)CoreVideo.CVPixelBufferGetBytesPerRowOfPlane(buffer, 1);

            return true;
        }

        private void Release()
        {
            if (_buffer != 0)
            {
                CoreVideo.CVPixelBufferUnlockBaseAddress(_buffer, 1);
                CoreFoundation.CFRelease(_buffer);
                _buffer = 0;
                _y = _u = _v = null;
                _stride = _uvStride = 0;
            }
        }

        public void Dispose() => Release();
    }

    [StructLayout(LayoutKind.Sequential)]
    struct CMTime
    {
        public long Value;
        public int Timescale;
        public uint Flags;
        public long Epoch;
    }

    [StructLayout(LayoutKind.Sequential)]
    unsafe struct OutputCallbackRecord
    {
        public delegate* unmanaged<nint, nint, int, uint, nint, CMTime, CMTime, void> Callback;
        public nint RefCon;
    }

    static unsafe partial class CoreFoundation
    {
        private const string Lib = "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation";

        [LibraryImport(Lib)] public static partial void CFRelease(nint obj);
        [LibraryImport(Lib)] public static partial nint CFRetain(nint obj);
        [LibraryImport(Lib)] public static partial nint CFDictionaryCreateMutable(nint allocator, nint capacity, nint keyCallBacks, nint valueCallBacks);
        [LibraryImport(Lib)] public static partial void CFDictionarySetValue(nint dict, nint key, nint value);
        [LibraryImport(Lib)] public static partial nint CFNumberCreate(nint allocator, nint type, void* value);

        // 数据符号：回调表取地址，常量对象取变量里的值
        private static readonly nint _handle = NativeLibrary.Load(Lib);
        public static readonly nint TypeDictionaryKeyCallBacks = NativeLibrary.GetExport(_handle, "kCFTypeDictionaryKeyCallBacks");
        public static readonly nint TypeDictionaryValueCallBacks = NativeLibrary.GetExport(_handle, "kCFTypeDictionaryValueCallBacks");
        public static readonly nint AllocatorNull = *(nint*)NativeLibrary.GetExport(_handle, "kCFAllocatorNull");
    }

    static unsafe partial class CoreMedia
    {
        private const string Lib = "/System/Library/Frameworks/CoreMedia.framework/CoreMedia";

        [LibraryImport(Lib)]
        public static partial int CMVideoFormatDescriptionCreateFromH264ParameterSets(nint allocator, nuint count, byte** ptrs, nuint* sizes, int nalHeaderLength, nint* format);

        [LibraryImport(Lib)]
        public static partial int CMBlockBufferCreateWithMemoryBlock(nint allocator, void* memory, nuint blockLength, nint blockAllocator, void* customSource, nuint offset, nuint dataLength, uint flags, nint* block);

        [LibraryImport(Lib)]
        public static partial int CMSampleBufferCreateReady(nint allocator, nint block, nint format, nint numSamples, nint numTimings, void* timings, nint numSizes, nuint* sizes, nint* sample);
    }

    static unsafe partial class VideoToolbox
    {
        private const string Lib = "/System/Library/Frameworks/VideoToolbox.framework/VideoToolbox";

        [LibraryImport(Lib)]
        public static partial int VTDecompressionSessionCreate(nint allocator, nint format, nint decoderSpec, nint imageAttrs, OutputCallbackRecord* callback, nint* session);

        [LibraryImport(Lib)]
        public static partial int VTDecompressionSessionDecodeFrame(nint session, nint sample, uint flags, void* frameRefCon, uint* infoFlags);

        [LibraryImport(Lib)]
        public static partial int VTDecompressionSessionWaitForAsynchronousFrames(nint session);

        [LibraryImport(Lib)]
        public static partial byte VTDecompressionSessionCanAcceptFormatDescription(nint session, nint format);

        [LibraryImport(Lib)]
        public static partial void VTDecompressionSessionInvalidate(nint session);
    }

    static unsafe partial class CoreVideo
    {
        private const string Lib = "/System/Library/Frameworks/CoreVideo.framework/CoreVideo";

        [LibraryImport(Lib)] public static partial int CVPixelBufferLockBaseAddress(nint buffer, ulong flags);
        [LibraryImport(Lib)] public static partial int CVPixelBufferUnlockBaseAddress(nint buffer, ulong flags);
        [LibraryImport(Lib)] public static partial nint CVPixelBufferGetBaseAddressOfPlane(nint buffer, nuint plane);
        [LibraryImport(Lib)] public static partial nuint CVPixelBufferGetBytesPerRowOfPlane(nint buffer, nuint plane);
        [LibraryImport(Lib)] public static partial nuint CVPixelBufferGetWidth(nint buffer);
        [LibraryImport(Lib)] public static partial nuint CVPixelBufferGetHeight(nint buffer);
        [LibraryImport(Lib)] public static partial nuint CVPixelBufferGetPlaneCount(nint buffer);
        [LibraryImport(Lib)] public static partial uint CVPixelBufferGetPixelFormatType(nint buffer);

        private static readonly nint _handle = NativeLibrary.Load(Lib);
        public static readonly nint PixelBufferPixelFormatTypeKey = *(nint*)NativeLibrary.GetExport(_handle, "kCVPixelBufferPixelFormatTypeKey");
    }
}
