using Ryujinx.Horizon.Common;
using Ryujinx.Horizon.Sdk.Sf;

namespace Ryujinx.Horizon.Sdk.Audio.Detail
{
    // S2Arm：Switch 2 的 aud:u（nn::audio 的统一入口）。SDK 先连 aud:u，再经命令 0 / 1 / 2 取音频输入 / 输出 / 渲染器三个管理对象——
    //   与 audin:u / audout:u / audren:u 注册的是同一份对象（同一组设备与会话表）。Pokopia 首帧后要它，没有就 Break 0xe15（2021-0007）。
    //   命令号来自 Eden-NS2 audio.cpp（GPL，只借事实，代码自写）
    partial class NativeAudioManager : IServiceObject
    {
        private readonly IAudioInManager _input;
        private readonly IAudioOutManager _output;
        private readonly IAudioRendererManager _renderer;

        public NativeAudioManager(IAudioInManager input, IAudioOutManager output, IAudioRendererManager renderer)
        {
            _input = input;
            _output = output;
            _renderer = renderer;
        }

        [CmifCommand(0)]
        public Result GetAudioInManager(out IAudioInManager manager)
        {
            manager = _input;

            return Result.Success;
        }

        [CmifCommand(1)]
        public Result GetAudioOutManager(out IAudioOutManager manager)
        {
            manager = _output;

            return Result.Success;
        }

        [CmifCommand(2)]
        public Result GetAudioRendererManager(out IAudioRendererManager manager)
        {
            manager = _renderer;

            return Result.Success;
        }
    }
}
