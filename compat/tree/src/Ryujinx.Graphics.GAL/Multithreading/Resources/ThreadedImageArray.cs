using Ryujinx.Graphics.GAL.Multithreading.Commands.ImageArray;
using Ryujinx.Graphics.GAL.Multithreading.Model;

namespace Ryujinx.Graphics.GAL.Multithreading.Resources
{
    /// <summary>
    /// Threaded representation of a image array.
    /// </summary>
    class ThreadedImageArray : IImageArray
    {
        private readonly ThreadedRenderer _renderer;
        public IImageArray Base;

        public ThreadedImageArray(ThreadedRenderer renderer)
        {
            _renderer = renderer;
        }

        private TableRef<T> Ref<T>(T reference)
        {
            return new TableRef<T>(_renderer, reference);
        }

        public unsafe void Dispose()
        {
            if (_renderer.S2ADiscardFrees)
            {
                return; // S2A：进程即将退出，下层对象不逐个释放（ThreadedRenderer.S2ADiscardFrees）
            }

            _renderer.New<ImageArrayDisposeCommand>()->Set(Ref(this));
            _renderer.QueueCommand();
        }

        public unsafe void SetImages(int index, ITexture[] images)
        {
            // S2A：图像数组复用开着（或在交替）时入队给私有副本（开时池里取，执行完在命令里归还；见 S2ATexArrReuse.ImgOn / ImgCopy），Gpu 层条目才能复用自己的数组
            _renderer.New<ImageArraySetImagesCommand>()->Set(Ref(this), index, Ref(S2ATexArrReuse.ImgCopy ? S2ATexArrReuse.Copy(images, S2ATexArrReuse.ImgOn) : images));
            _renderer.QueueCommand();
        }
    }
}
