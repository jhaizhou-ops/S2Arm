// VUID-02750：texel buffer view 偏移必须满足 minTexelBufferOffsetAlignment（未对齐走对齐影子副本）。
// 修前红基准：旧代码 CreateView 直用未对齐偏移建 VkBufferView——
//   本文件引用的判定函数/缓存键/挂账队列在旧树上不可见，编译即红；修后语义逐项断言为绿。
// 时序修复（owner 复审①）负对照：绑定即挂账 / 恒直建 / 后台静默拷贝时，下列断言对应变红。
using Ryujinx.Graphics.Vulkan;
using System;
using System.Linq;
using System.Reflection;

namespace S2A.VvlTest
{
    static class Program
    {
        static int _fail;

        static void Check(bool cond, string name, string expect, string actual)
        {
            if (!cond)
            {
                _fail++;
                Console.WriteLine($"FAIL {name}：期望 {expect} → 真结果 {actual}");
            }
        }

        // ---- ③ texel 视图偏移：未满足设备对齐 → 走对齐影子副本 ----
        static void TestTexelAlign()
        {
            // 9000 实测 minTexelBufferOffsetAlignment=64；logcat 报违偏移 7152/240/6128/6640/10992/224。
            Check(BufferHolder.NeedsAlignedTexelCopy(7152, 64), "align.7152@64", "copy", "direct");
            Check(BufferHolder.NeedsAlignedTexelCopy(240, 64), "align.240@64", "copy", "direct");
            Check(BufferHolder.NeedsAlignedTexelCopy(6128, 64), "align.6128@64", "copy", "direct");
            Check(BufferHolder.NeedsAlignedTexelCopy(6640, 64), "align.6640@64", "copy", "direct");
            Check(BufferHolder.NeedsAlignedTexelCopy(10992, 64), "align.10992@64", "copy", "direct");
            Check(BufferHolder.NeedsAlignedTexelCopy(224, 64), "align.224@64", "copy", "direct");

            // 负对照：已对齐偏移 / 低对齐设备必须走原直建路径（不产生影子副本）。
            Check(!BufferHolder.NeedsAlignedTexelCopy(7168, 64), "align.7168@64", "direct", "copy");
            Check(!BufferHolder.NeedsAlignedTexelCopy(0, 64), "align.0@64", "direct", "copy");
            Check(!BufferHolder.NeedsAlignedTexelCopy(4096, 64), "align.4096@64", "direct", "copy");
            Check(!BufferHolder.NeedsAlignedTexelCopy(7152, 16), "align.7152@16", "direct", "copy");
            Check(!BufferHolder.NeedsAlignedTexelCopy(224, 16), "align.224@16", "direct", "copy");
            Check(!BufferHolder.NeedsAlignedTexelCopy(7, 1), "align.any@1", "direct", "copy");
            Check(!BufferHolder.NeedsAlignedTexelCopy(7, 0), "align.any@0", "direct", "copy");

            // 影子缓存键：同型相等（同 range 复用同一份影子），异型不等（不挤占其它转换缓存）。
            ICacheKey a = new AlignedTexelCopyCacheKey();
            ICacheKey b = new AlignedTexelCopyCacheKey();
            Check(a.KeyEqual(b) && b.KeyEqual(a), "align.key.same", "equal", "not-equal");
            ICacheKey other = new DrawCountCacheKey();
            Check(!a.KeyEqual(other), "align.key.other", "not-equal", "equal");
        }

        // ---- 修①：写回账时序——一个源 holder、两个未对齐写视图的 owner 场景 ----
        // 修前红基准：旧代码绑定即挂「待回写」，同一更新里第二个视图的 CreateView flush
        // 会提前消费第一笔账（影子还没被 GPU 写就拷回源）。修后：绑定→记录之间不可取账。
        static void TestWritebackTiming()
        {
            AlignedTexelWritebackQueue<object> q = new();
            object shadowA = new(), shadowB = new();

            // 两个未对齐写视图按描述符更新顺序各自挂账——同影子重复挂账去重。
            Check(q.Arm(shadowA, 7152, 240), "wb.arm.first", "true", "false");
            Check(!q.Arm(shadowA, 7152, 240), "wb.arm.dedup", "false", "true");
            Check(q.Arm(shadowB, 10992, 224), "wb.arm.second", "true", "false");

            // 关键断言：第二个 CreateView 的 flush（TakeArmed）此时必须取不到账——
            // 修前（单表直挂）这里会取走 shadowA 的旧数据。修后为绿。
            Check(q.TakeArmed() == null, "wb.bind-no-flush", "空", "有账被提前取走");
            Check(q.HasAny && !q.HasArmed, "wb.pending-only", "pending", "armed");

            // draw/dispatch 记录完成 → promote → 两笔账按序生效、一次落完。
            Check(q.Promote(_ => true) == null, "wb.promote.nodrop", "无丢弃", "有丢弃");
            var armed = q.TakeArmed();
            Check(armed?.Count == 2, "wb.armed.count", "2", (armed?.Count ?? -1).ToString());
            Check(armed != null
                && ReferenceEquals(armed[0].Shadow, shadowA)
                && ReferenceEquals(armed[1].Shadow, shadowB)
                && armed[0].SrcOffset == 7152
                && armed[1].SrcOffset == 10992, "wb.armed.order", "A@7152,B@10992", "不符");
            Check(q.TakeArmed() == null && !q.HasAny, "wb.armed.drained", "清空", "有余账");

            // pending 期间影子被逐出缓存（源被写过）→ promote 丢弃该账，
            // 不能拿死影子的旧数据盖源里的新数据。
            object dead = new();
            q.Arm(dead, 6128, 64);
            var dropped = q.Promote(_ => false);
            Check(dropped?.Count == 1 && ReferenceEquals(dropped[0].Shadow, dead),
                "wb.promote.drop-dead", "丢弃死影子账", "仍生效/丢失");
            Check(!q.HasAny, "wb.after-drop", "清空", "有余账");

            // armed 与新 pending 互不干扰：armed 先落、pending 后 promote。
            object s1 = new(), s2 = new();
            q.Arm(s1, 100, 16);
            q.Promote(_ => true);
            q.Arm(s2, 200, 16);
            var first = q.TakeArmed();
            Check(first?.Count == 1 && ReferenceEquals(first[0].Shadow, s1), "wb.mix.armed", "只落 s1", "不符");
            Check(q.HasAny, "wb.mix.pending-left", "s2 仍挂", "丢账");
            var rest = q.TakeAll();
            Check(rest?.Count == 1 && ReferenceEquals(rest[0].Shadow, s2), "wb.mix.takeall", "s2 收尸", "不符");
        }

        // ---- 修①②③：调用关系钉死（IL 级负对照，不是只测零件）----
        static void TestWiring()
        {
            // 恒直建负对照：CreateView 必须经对齐判定并走影子路径——
            // 把 NeedsAlignedTexelCopy 调用删掉/恒 true，本条红。
            CheckCalls("wire.createview.align", typeof(BufferHolder), "CreateView",
                "NeedsAlignedTexelCopy", "FlushAlignedTexelWrites", "Copy", "CreateViewDirect");

            // 写视图绑定必须挂账（TextureBuffer.GetBufferView → ArmAlignedTexelWriteback）。
            CheckCalls("wire.getbufferview.arm", typeof(TextureBuffer), "GetBufferView", "ArmAlignedTexelWriteback");

            // 每个 draw/dispatch 记录完成后必须 promote——漏一个，绑定账永不生效。
            Type pb = typeof(PipelineBase);
            foreach (string m in new[]
            {
                "Draw", "DrawIndexed", "DrawIndirect", "DrawIndexedIndirect",
                "DrawIndirectCount", "DrawIndexedIndirectCount",
                "DispatchCompute", "DispatchComputeIndirect",
            })
            {
                CheckCalls($"wire.promote.{m}", pb, m, "PromotePendingAlignedTexelWritebacks");
            }

            // 主动落账点：EndRenderPass 与两个 Recreate——下一个 draw/dispatch 前必须有口子。
            CheckCalls("wire.flush.endrenderpass", pb, "EndRenderPass", "FlushArmedAlignedTexelWritebacks");
            CheckCalls("wire.flush.recreate.gfx", pb, "RecreateGraphicsPipelineIfNeeded", "FlushArmedAlignedTexelWritebacks");
            CheckCalls("wire.flush.recreate.compute", pb, "RecreateComputePipelineIfNeeded", "FlushArmedAlignedTexelWritebacks");

            // 修②负对照：后台等待路径不得再取账/清缓存/上后台池静默拷贝——加回任何一条即红。
            CheckNoCalls("wire.bg.no-side-effect", typeof(BufferHolder), "FlushAlignedTexelWritesAndWait",
                "TakeArmed", "ClearRange", "Copy", "Rent", "get_BackgroundResources");

            // 挂账必须经队列（pending），不能直接对 List 动手。
            CheckCalls("wire.arm.queue", typeof(BufferHolder), "ArmAlignedTexelWriteback", "Arm");
            CheckCalls("wire.flush.queue", typeof(BufferHolder), "FlushAlignedTexelWrites", "TakeArmed");
            CheckCalls("wire.promote.queue", typeof(BufferHolder), "PromoteAlignedTexelWritebacks", "Promote");
        }

        // 在 caller 的 IL 里找 call/callvirt（0x28/0x6F）+ 4 字节元数据令牌指向目标方法名。
        // 不按指令边界走：扫到 opcode 字节就解后面 4 字节；真实调用必然命中，
        // 操作数字节凑巧解成同名方法在事实上不可能。
        static bool IlCallsName(MethodInfo caller, string calleeName)
        {
            byte[] il = caller.GetMethodBody()?.GetILAsByteArray();
            if (il == null)
            {
                return false;
            }

            for (int i = 0; i + 4 < il.Length; i++)
            {
                if (il[i] != 0x28 && il[i] != 0x6F)
                {
                    continue;
                }

                int token = il[i + 1] | (il[i + 2] << 8) | (il[i + 3] << 16) | (il[i + 4] << 24);
                MethodBase m;
                try
                {
                    m = caller.Module.ResolveMethod(token);
                }
                catch
                {
                    continue;
                }

                if (m != null && m.Name == calleeName)
                {
                    return true;
                }
            }

            return false;
        }

        static void CheckCalls(string name, Type type, string method, params string[] callees)
        {
            var sites = type
                .GetMethods(BindingFlags.Public | BindingFlags.NonPublic | BindingFlags.Instance | BindingFlags.Static)
                .Where(m => m.Name == method)
                .ToArray();
            Check(sites.Length > 0, $"{name}.exists", $"方法 {method} 存在", "找不到");

            foreach (string callee in callees)
            {
                Check(sites.Any(m => IlCallsName(m, callee)), $"{name}.{callee}",
                    $"IL 里调 {callee}", $"{sites.Length} 个重载均未调");
            }
        }

        static void CheckNoCalls(string name, Type type, string method, params string[] banned)
        {
            var sites = type
                .GetMethods(BindingFlags.Public | BindingFlags.NonPublic | BindingFlags.Instance | BindingFlags.Static)
                .Where(m => m.Name == method)
                .ToArray();
            Check(sites.Length > 0, $"{name}.exists", $"方法 {method} 存在", "找不到");

            foreach (string callee in banned)
            {
                Check(!sites.Any(m => IlCallsName(m, callee)), $"{name}.no-{callee}",
                    $"IL 不调 {callee}", "调了");
            }
        }

        static int Main()
        {
            TestTexelAlign();
            TestWritebackTiming();
            TestWiring();
            Console.WriteLine(_fail == 0 ? "期望 → 真结果：全过" : $"失败 {_fail} 条");
            return _fail;
        }
    }
}
