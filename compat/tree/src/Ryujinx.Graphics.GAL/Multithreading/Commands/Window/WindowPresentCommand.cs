using Ryujinx.Graphics.GAL.Multithreading.Model;
using Ryujinx.Graphics.GAL.Multithreading.Resources;
using System;

namespace Ryujinx.Graphics.GAL.Multithreading.Commands.Window
{
    struct WindowPresentCommand : IGALCommand, IGALCommand<WindowPresentCommand>
    {
        public readonly CommandType CommandType => CommandType.WindowPresent;
        private TableRef<ThreadedTexture> _texture;
        private ImageCrop _crop;
        private TableRef<Action> _swapBuffersCallback;

        public void Set(TableRef<ThreadedTexture> texture, ImageCrop crop, TableRef<Action> swapBuffersCallback)
        {
            _texture = texture;
            _crop = crop;
            _swapBuffersCallback = swapBuffersCallback;
        }

        public static void Run(ref WindowPresentCommand command, ThreadedRenderer threaded, IRenderer renderer)
        {
            threaded.SignalFrame();
            renderer.Window.Present(command._texture.Get(threaded)?.Base, command._crop, command._swapBuffersCallback.Get(threaded));
            // S2A（Android 拆线程）：下层 Present 正常返回后在渲染线程上通知宿主（出图计数 / 帧读数归渲染线程）；没登记 = 原样
            threaded.S2AAfterPresent?.Invoke();
        }
    }
}
