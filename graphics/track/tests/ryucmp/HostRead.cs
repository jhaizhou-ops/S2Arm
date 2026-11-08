// 宿主读 GPU 改过、还没回写的页（帧率能耗线 10-22，对应 PhysicalMemory.S2ASignalReadForTexture）：
// 同一 4 KB 上一个缓冲句柄（GPU 改过：注册了回写动作，回写把 GPU 侧 0xEF 写进内存）和一个贴图句柄（贴图同步读的就是它自己）。
// 新做法：读前按读发跟踪事件、豁免贴图句柄 → 缓冲先回写、读到 GPU 新值 0xEF，贴图自己的动作不触发（否则贴图同步里回写自己）。
// 旧做法（改前贴图同步直接读内存，靠缺页兜底；我方宿主读缺页不回写）：读到内存旧值 0xCD。旧做法必须读不到新值，作反证。
using Ryujinx.Memory.Tracking;
using System;

static class HostRead {
    const int Buffer = 1, Texture = 2;
    static int fail, count;
    static void Expect(string name, long want, long got) { count++; bool ok = want == got; if (!ok) fail++; Console.WriteLine($"{name,-48} 期望 {want,-6} → 真结果 {got,-6} {(ok ? "✓" : "✗")}"); }
    public static int Run() {
        const ulong bas = 0x10000000;
        foreach (bool track in new[] { false, true }) {
            byte[] mem = new byte[0x2000]; Array.Fill(mem, (byte)0xcd);
            var t = new MemoryTracking(new ModelVmm(bas, 2), 0x1000);
            int bufFlush = 0, texFlush = 0;
            var buf = t.BeginTracking(bas + 0x1000, 0x1000, Buffer); buf.RegisterAction((a, s) => { bufFlush++; Array.Fill(mem, (byte)0xef, 0x1000, 0x1000); });
            var tex = t.BeginTracking(bas + 0x1000, 0x1000, Texture); tex.RegisterAction((a, s) => texFlush++);
            if (track) t.VirtualMemoryEvent(bas + 0x1000, 0x1000, false, precise: false, exemptId: Texture);
            byte got = mem[0x1010];
            string w = track ? "新做法（读前按读发事件、豁免贴图）" : "旧做法（直接读）";
            Expect($"宿主读 {w}：读到的值", track ? 0xef : 0xcd, got);
            Expect($"宿主读 {w}：缓冲回写次数", track ? 1 : 0, bufFlush);
            Expect($"宿主读 {w}：贴图自己的动作次数", 0, texFlush);
        }
        Console.WriteLine($"宿主读单测：{count} 项，失败 {fail}");
        return fail;
    }
}
