// 分辨率倍率创建操作的手写扩展；保留既有 CreateTexture 操作码和 TextureCreateInfo 的二进制布局。
using Ryujinx.Graphics.GAL;

namespace RyuJudge.GalRec
{
    public sealed partial class RecordingRenderer
    {
        public ITexture CreateTexture(TextureCreateInfo info, float resolutionScale)
        {
            if (_r == null) return _inner.CreateTexture(info, resolutionScale);
            var payload = _r.Begin();
            W.Blit(payload, info); W.F32(payload, resolutionScale);
            uint id = _r.NewId(); W.U32(payload, id);
            ITexture inner = _inner.CreateTexture(info, resolutionScale);
            var texture = new RecTexture(_r, inner, id);
            _r.Register(texture, ObjOps.CreateTextureScaled, payload);
            _r.Emit(ObjOps.CreateTextureScaled, payload);
            return texture;
        }
    }
}
