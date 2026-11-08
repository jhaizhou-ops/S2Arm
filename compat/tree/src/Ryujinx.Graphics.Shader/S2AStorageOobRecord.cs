namespace Ryujinx.Graphics.Shader
{
    /// <summary>
    /// S2A（F1）：全局访存越出宿主绑定窗口的记录缓冲合同（着色器写、渲染器在命令缓冲完成后读）。
    /// 每个宿主程序一段（渲染器按程序分配，描述符偏移选段），着色器只在越界分支里写：
    /// 计数用原子加；拿到旧值 0 的那次调用写首个越界的详情，最后写 <see cref="WordInfo"/>（带 <see cref="InfoValid"/>）。
    /// 绑定号固定在存储缓冲集合里所有阶段（5 × 16）与保留绑定（转计算 3 + 变换反馈模拟 4）之上，各阶段共用一个绑定。
    /// </summary>
    public static class S2AStorageOobRecord
    {
        /// <summary>存储缓冲描述符集合里的绑定号。</summary>
        public const int Binding = 96;

        /// <summary>越界调用次数（原子加，32 位回绕）。</summary>
        public const int WordCount = 0;

        /// <summary>首个越界：<see cref="InfoValid"/> | 访存类别 &lt;&lt; 28 | 阶段 &lt;&lt; 24 | 基址 cbuf 槽 &lt;&lt; 16 | 基址 cbuf 字偏移。</summary>
        public const int WordInfo = 1;

        /// <summary>首个越界：客体地址低 32 位。</summary>
        public const int WordAddressLow = 2;

        /// <summary>首个越界：相对宿主绑定窗口起点的字节偏移。</summary>
        public const int WordOffset = 3;

        /// <summary>首个越界：宿主绑定窗口长度（32 位字数，OpArrayLength）。</summary>
        public const int WordWindowLength = 4;

        /// <summary>首个越界：着色器读到的存储缓冲描述符（基址低 / 高 32 位、大小字），即基址 cbuf 位置起的 3 个字。</summary>
        public const int WordBaseLow = 5;
        public const int WordBaseHigh = 6;
        public const int WordSize = 7;

        /// <summary>首个越界：本阶段客体代码 XXHash128（Low 低 / 高 32 位，High 低 / 高 32 位），与翻译期【红】行同一段字节。</summary>
        public const int WordHash = 8;

        /// <summary>着色器写的字数。</summary>
        public const int Words = 12;

        public const uint InfoValid = 1u << 31;

        public const int KindShift = 28;
        public const int StageShift = 24;
        public const int CbSlotShift = 16;

        /// <summary>访存类别（<see cref="KindShift"/> 起 3 位）：单目标 / 多目标 × 读 / 写 / 原子。</summary>
        public const uint KindLoad = 0;
        public const uint KindStore = 1;
        public const uint KindAtomic = 2;
        public const uint KindMultiTarget = 4;
    }
}
