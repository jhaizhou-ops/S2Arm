using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;

namespace Ryujinx.Graphics.Gpu
{
    /// <summary>
    /// S2A：渲染线程托管分配按 GPFIFO 分派点拆账（S2A_ALLOC_TRACE=1，定位用；关着只有一次静态布尔判断）。
    /// 键：3D / 计算 / 2D 等类方法 = 子通道 &lt;&lt; 16 | 字节偏移；宏 = 0x10_0000 | 宏号；内联数据 = 0x20_0000 | 子通道；常量缓冲更新 = 0x30_0000；FlushUboDirty = 0x30_0001。
    /// 嵌套调用不重复计（只在最外层计）。每 20 秒打一次累计前 20（[分配·渲染] 行），口径同服务层 S2A_ALLOC_TRACE。
    /// </summary>
    public static class S2AAllocTrace
    {
        public static readonly bool On = Environment.GetEnvironmentVariable("S2A_ALLOC_TRACE") == "1";

        /// <summary>打点取值：本线程已分配字节</summary>
        public static long Now() => GC.GetAllocatedBytesForCurrentThread();

        private static readonly Dictionary<int, (long Bytes, long Calls)> _acc = new();
        private static int _depth;
        private static long _nextDump;

        private static readonly HashSet<(Type, int)> _seen = new();

        /// <summary>诊断用：某个（类型, 编号）第一次出现返回 true（只在 On 时调；值元组键，判重本身不分配）</summary>
        public static bool FirstSeen(Type t, int n) { lock (_seen) return _seen.Add((t, n)); }

        public static long Begin()
        {
            if (!On || _depth++ != 0)
            {
                return -1;
            }

            return Now();
        }

        public static void End(int key, long a0)
        {
            if (!On)
            {
                return;
            }

            _depth--;

            if (a0 < 0)
            {
                return;
            }

            long d = Now() - a0;

            Raw(key, d);

            long now = Stopwatch.GetTimestamp();

            if (now >= _nextDump)
            {
                if (_nextDump != 0)
                {
                    Dump();
                }

                _nextDump = now + Stopwatch.Frequency * 20;
            }
        }

        /// <summary>包含式段计数（不参与嵌套去重，与上面的分派点并列看）：0x40_0001 取命令（Fetch）、0x40_0002 Process 整段（含其中分派）、0x40_0003 RunDeferredActions、0x40_0004 免解读缓存录段；
        /// 0x40_000c 取图形程序合计、0x40_000d 查缓存 + 按需实化、0x40_000e 首次命中核对（现翻 = 合计 − 后两项；10-21 动森新内容首用时渲染线程分配定位）、
        /// 0x40_000f 按需实化整段、0x40_0010 其中建宿主程序（iPhone 独有：着色器包 / 离线库查找）。只在渲染线程（按需实化由查找触发）上调。</summary>
        public static void Raw(int key, long bytes)
        {
            if (bytes > 0)
            {
                lock (_acc)
                {
                    _acc.TryGetValue(key, out var v);
                    _acc[key] = (v.Bytes + bytes, v.Calls + 1);
                }
            }
        }

        /// <summary>分段记账：记 a 到现在本线程分配到 key（> 0 才记），a 挪到现在。a 由调用方在段首取 Mark()；On 关时什么都不做</summary>
        public static void Step(int key, ref long a)
        {
            if (!On)
            {
                return;
            }

            long t = Now();
            Raw(key, t - a);
            a = t;
        }

        /// <summary>段首取本线程已分配字节（On 关时 0）</summary>
        public static long Mark() => On ? Now() : 0;

        private static readonly string[] _rawNames = { "", "段·取命令 Fetch", "段·Process 整段（含分派）", "段·RunDeferredActions", "段·免解读缓存录段", "诊断·录段覆盖已有键", "诊断·段缓存满清空", "诊断·录段新键", "上屏·取帧回调", "上屏·找贴图 + 同步内存", "上屏·渲染器 Present", "上屏·释放回调", "着色器·取图形程序合计（快路径 + 查缓存 + 现翻）", "着色器·查缓存 + 按需实化", "着色器·首次命中核对", "着色器·按需实化整段（读缓存 + 解压 + 建宿主程序）", "着色器·按需实化里建宿主程序（渲染器 LoadProgramBinary：着色器包 / 离线库查找）",
            "绘制·提交绑定·存储缓冲 UpdateStorageBuffers", "绘制·提交绑定·贴图 TextureManager.CommitGraphicsBindings", "绘制·提交绑定·缓冲 BufferManager.CommitGraphicsBindings",
            "计算派发·前置（延迟绘制 + 刷常量缓冲 + 设常量缓冲）", "计算派发·取计算程序 + SetProgram", "计算派发·贴图池 + 存储缓冲描述", "计算派发·设绑定 + 提交绑定", "计算派发·下发 DispatchCompute",
            "2D 拷贝·找源贴图 FindOrCreateTexture", "2D 拷贝·Lift", "2D 拷贝·找目标贴图 FindOrCreateTexture", "2D 拷贝·CopyTo + SignalModified",
            "计算派发·其中 缓冲设绑定", "计算派发·其中 贴图设绑定", "计算派发·其中 贴图提交", "计算派发·其中 缓冲提交",
            "新建贴图·new Texture", "新建贴图·查重叠 / 视图兼容", "新建贴图·InitializeGroup", "新建贴图·InitializeData 整段", "新建贴图·重叠视图替换 + 同步",
            "贴图·建宿主贴图 Renderer.CreateTexture", "贴图同步·读内存 + 转格式 ConvertToHostCompatibleFormat", "贴图同步·上传 HostTexture.SetData",
            "新建缓冲·new Buffer", "新建缓冲·拷旧缓冲 + 继承修改范围", "新建缓冲·SynchronizeMemory", "新建缓冲·重建多段缓冲 + 通知",
            "DMA·目标区暂存（原 ToArray，现 ArrayPool）", "DMA·布局拷贝 + 写回客体内存",
            "贴图池·同步内存（描述符改写移出 + 短缓存登记）", "贴图池·取贴图未命中整段（含新建贴图）", "贴图池·短缓存命中后挂回池", "诊断·描述符重现统计",
            "贴图绑定·缓存命中 SynchronizeMemory", "贴图绑定·取采样器 samplerPool.Get", "贴图绑定·GetForBinding", "贴图绑定·贴图缓冲 CreateBuffer", "贴图绑定·贴图缓冲登记", "贴图绑定·取宿主贴图 / 采样器", "贴图绑定·SetTextureAndSampler",
            "贴图绑定·贴图数组 UpdateTextureArray", "贴图绑定·图像数组 UpdateImageArray", "贴图绑定·读句柄常量缓冲 UpdateCachedBuffer", "绘制·提交绑定·图像 CommitImageBindings 整段" };

        // 3D 状态更新各组（StateUpdateTracker 按 StateUpdater 构造时的登记顺序编组号；改登记顺序要同步这张表，只影响拆账名字）
        private static readonly string[] _stateNames = { "VertexBufferState", "VertexAttribState", "BlendState", "FaceState", "StencilTestState", "DepthTestState", "TessellationState",
            "ViewportTransform", "LogicOpState", "DepthClampState", "PolygonMode", "DepthBiasState", "PrimitiveRestartState", "LineState", "RtColorMask", "RasterizerState", "ScissorState",
            "TfBufferState", "UserClipState", "AlphaTestState", "SamplerPoolState", "TexturePoolState", "PointState", "IndexBufferState", "MultisampleState", "EarlyZState", "ShaderState",
            "RenderTargetState" };

        private static string Name(int key) => (key >> 20) switch
        {
            0 => $"方法 子通道 {key >> 16} 偏移 0x{key & 0xffff:x}",
            1 => $"宏 {key & 0xffff}",
            2 => $"内联数据 子通道 {key & 0xffff}",
            4 => (key & 0xff) < _rawNames.Length ? _rawNames[key & 0xff] : $"段 0x{key & 0xff:x}",
            5 => $"3D 状态更新·组 {key & 0xff} {((key & 0xff) < _stateNames.Length ? _stateNames[key & 0xff] : "?")}",
            6 => (key & 0xff) switch
            {
                0xff => "宏引擎·离线编",
                0xfe => "宏引擎·解释器",
                _ => $"宏引擎·HLE {(Engine.MME.MacroHLEFunctionName)(key & 0xff)}",
            },
            7 => (key & 0xff) switch
            {
                1 => "资源·描述符池数组与写跟踪",
                2 => "资源·缓冲构造与写跟踪",
                3 => "资源·贴图组初始化与写跟踪",
                4 => "资源·贴图上传布局转换与格式解码",
                _ => $"资源·{key & 0xff}",
            },
            _ => key == 0x30_0000 ? "常量缓冲更新" : "FlushUboDirty",
        };

        // 按 GC 间隔拆账（S2A_ALLOC_TRACE=1；NxFrames 每打一行 [gc] 由 Compose 接线调一次）：本次与上次 GC 之间渲染线程各分派项的分配增量，≥ 64 KB 的全列
        private static readonly Dictionary<int, long> _gcSnap = new();

        public static string SinceLastGc()
        {
            if (!On)
            {
                return null;
            }

            lock (_acc)
            {
                List<(int Key, long D)> items = new();
                long total = 0;
                foreach (KeyValuePair<int, (long Bytes, long Calls)> kv in _acc)
                {
                    long d = kv.Value.Bytes - (_gcSnap.TryGetValue(kv.Key, out long s) ? s : 0);
                    _gcSnap[kv.Key] = kv.Value.Bytes;
                    if (d > 0)
                    {
                        items.Add((kv.Key, d));
                        if (kv.Key >> 20 < 4)
                        {
                            total += d;
                        }
                    }
                }

                System.Text.StringBuilder sb = new($"[分配·GC间隔·渲染] GPFIFO 分派 {total / 1024} KB");
                foreach ((int k, long d) in items.OrderByDescending(x => x.D))
                {
                    if (d < 65536)
                    {
                        break;
                    }

                    sb.Append($"\n[分配·GC间隔·渲染]   {Name(k)}：{d / 1024} KB");
                }

                return sb.ToString();
            }
        }

        private static void Dump()
        {
            // 段、状态组、宏引擎与资源子项都是包含式计数，不重复进入分派累计。
            long total = _acc.Where(kv => kv.Key >> 20 < 4).Sum(kv => kv.Value.Bytes);
            Console.Error.WriteLine($"[分配·渲染] GPFIFO 分派累计 {total} B（前 20，字节 / 有分配的调用次数）：");

            // 全打不截断（截断后没出现的键会被读成 0）
            foreach (var kv in _acc.OrderByDescending(kv => kv.Value.Bytes))
            {
                Console.Error.WriteLine($"[分配·渲染]   {Name(kv.Key)}：{kv.Value.Bytes} B / {kv.Value.Calls} 次");
            }
        }
    }
}
