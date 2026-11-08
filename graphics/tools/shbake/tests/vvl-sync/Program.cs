// VUID-00332：描述符范围上限与不足报红计数。
using Ryujinx.Graphics.GAL;
using Ryujinx.Graphics.Gpu;
using Ryujinx.Graphics.Gpu.Shader;
using Ryujinx.Graphics.Shader;
using Ryujinx.Graphics.Vulkan;
using Silk.NET.Vulkan;
using System;
using System.Collections.Generic;
using System.Linq;
using System.Reflection;
using AccessFlags = Silk.NET.Vulkan.AccessFlags;
using PipelineStageFlags = Silk.NET.Vulkan.PipelineStageFlags;
using ShaderStage = Ryujinx.Graphics.Shader.ShaderStage;

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

        // ---- ③ SYNC：写入被记录 → loadOp 屏障发出且 dst 含读 ----
        static void TestSync()
        {
            var s = new TextureStorage.LastAccessState();

            // 新图未写过：loadOp 不需屏障（无写可读）。
            Check(!s.NeedsLoadOpBarrier, "sync.fresh", "false", s.NeedsLoadOpBarrier.ToString());

            // 布局迁移写完（InitialTransition 标记）：必须发屏障。
            s.RecordWrite(AccessFlags.MemoryWriteBit, PipelineStageFlags.AllCommandsBit);
            Check(s.NeedsLoadOpBarrier, "sync.transition", "true", s.NeedsLoadOpBarrier.ToString());

            // 彩色附件 loadOp 目标访问必须同时有 WRITE|READ（loadOp=LOAD 读旧内容）。
            AccessFlags dst = TextureStorage.LastAccessState.LoadOpDstAccess(depthStencil: false);
            Check(dst.HasFlag(AccessFlags.ColorAttachmentReadBit)
                && dst.HasFlag(AccessFlags.ColorAttachmentWriteBit), "sync.dst.color",
                "CA_READ|CA_WRITE", dst.ToString());

            AccessFlags dstDs = TextureStorage.LastAccessState.LoadOpDstAccess(depthStencil: true);
            Check(dstDs.HasFlag(AccessFlags.DepthStencilAttachmentReadBit)
                && dstDs.HasFlag(AccessFlags.DepthStencilAttachmentWriteBit), "sync.dst.ds",
                "DS_READ|DS_WRITE", dstDs.ToString());

            // 消费后：写态变为附件写、读清零。附件写仍是写 —— 下次 loadOp 仍需 RAW 屏障
            //   （与改前 _lastModificationAccess=CA_WRITE 语义一致：store 后 load 要排序）。
            s.MarkAttachmentWrite(depthStencil: false, clearReads: true);
            Check(s.WriteAccess == AccessFlags.ColorAttachmentWriteBit
                && s.WriteStage == PipelineStageFlags.ColorAttachmentOutputBit
                && s.ReadAccess == AccessFlags.None
                && s.NeedsLoadOpBarrier, "sync.consume",
                "CAW@CAO/读清零/仍需屏障", $"{s.WriteAccess}@{s.WriteStage}|{s.ReadAccess}");

            // 上传写（CmdCopyBufferToImage 标记）后：屏障被需要且源含 TransferWrite。
            var t = new TextureStorage.LastAccessState();
            t.RecordWrite(AccessFlags.TransferWriteBit, PipelineStageFlags.TransferBit);
            Check(t.NeedsLoadOpBarrier && (t.WriteAccess & AccessFlags.TransferWriteBit) != 0, "sync.copy",
                "TW@Transfer/需屏障", $"{t.WriteAccess}@{t.WriteStage}");
        }

        static int Main()
        {
            TestSync();
            Console.WriteLine(_fail == 0 ? "期望 → 真结果：全过" : $"失败 {_fail} 条");
            return _fail;
        }
    }
}
