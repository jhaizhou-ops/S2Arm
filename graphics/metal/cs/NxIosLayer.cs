// iOS：渲染循环起来时把出图层挂到 App 壳根视图（C 端 gal_ios_layer.m）
using Ryujinx.Graphics.GAL;
using System;
using System.Runtime.InteropServices;

namespace NxGal
{
    static partial class N
    {
        [DllImport(Lib)] public static extern int nxgal_window_attach_ios();
        [DllImport(Lib)] public static extern void nxgal_window_attach_failed_ios();
    }
    public sealed class IosLayerAttachException : InvalidOperationException
    {
        internal IosLayerAttachException() : base("iOS 出图层没挂上（见上一行 [gal]），停止渲染初始化") { }
    }
    public static class NxIosLayer
    {
        public static void Attach(IRenderer r)
        {
            if (N.nxgal_window_attach_ios() != 0) throw new IosLayerAttachException();
        }
        // Keep the attach exception inside managed code, before the render loop
        // crosses its unmanaged thread entry. Other renderer failures retain
        // their existing handling.
        public static bool TryAttach(IRenderer r)
        {
            try { Attach(r); return true; }
            catch (IosLayerAttachException e)
            {
                Console.Error.WriteLine($"[gal] 【红】渲染初始化停止：{e}");
                N.nxgal_window_attach_failed_ios();
                return false;
            }
        }
    }
}
