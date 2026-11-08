using Ryujinx.Graphics.GAL.Multithreading.Model;
using Ryujinx.Graphics.GAL.Multithreading.Resources;
using System.Linq;

namespace Ryujinx.Graphics.GAL.Multithreading.Commands.ImageArray
{
    struct ImageArraySetImagesCommand : IGALCommand, IGALCommand<ImageArraySetImagesCommand>
    {
        public readonly CommandType CommandType => CommandType.ImageArraySetImages;
        private TableRef<ThreadedImageArray> _imageArray;
        private int _index;
        private TableRef<ITexture[]> _images;

        public void Set(TableRef<ThreadedImageArray> imageArray, int index, TableRef<ITexture[]> images)
        {
            _imageArray = imageArray;
            _index = index;
            _images = images;
        }

        public static void Run(ref ImageArraySetImagesCommand command, ThreadedRenderer threaded, IRenderer renderer)
        {
            ThreadedImageArray imageArray = command._imageArray.Get(threaded);
            if (S2ATexArrReuse.ImgOn)
            {
                // 开着时入队那份一定是私有副本（ThreadedImageArray.SetImages：ImgOn ⊂ ImgCopy；交替翻相位时同贴图数组的论证）：原地换成底层对象、交下去，下游同步拷走后清空归还
                ITexture[] a = command._images.Get(threaded);
                for (int i = 0; i < a.Length; i++) a[i] = ((ThreadedTexture)a[i])?.Base;
                imageArray.Base.SetImages(command._index, a);
                S2ATexArrReuse.Return(a);
                return;
            }

            ITexture[] images = command._images.Get(threaded);
            S2ATexArrReuse.DiagAdd(3, images.Length);
            imageArray.Base.SetImages(command._index, images.Select(texture => ((ThreadedTexture)texture)?.Base).ToArray());
        }
    }
}
