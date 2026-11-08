using Ryujinx.Graphics.Shader.Translation;
using System;

namespace Ryujinx.Graphics.Shader
{
    [Flags]
    public enum AttributeType : byte
    {
        // Generic types.
        Float,
        Sint,
        Uint,
        Sscaled,
        Uscaled,

        // The vertex texel buffer view is a same-bit-width integer substitute for a format
        // the host does not support as uniform texel buffer; the fetch delivers raw bits and
        // the shader applies the semantic decode (see VertexToCompute).
        TexelDecode = 1 << 3,

        // An unrecognized attribute format uses the host's R32 fallback view.
        TexelInvalidFormat = 1 << 4,

        Packed = 1 << 6,
        PackedRgb10A2Signed = 1 << 7,
        AnyPacked = Packed | PackedRgb10A2Signed,
        BaseTypeMask = 0xff ^ TexelDecode ^ TexelInvalidFormat ^ Packed ^ PackedRgb10A2Signed,
    }

    static class AttributeTypeExtensions
    {
        extension(AttributeType type)
        {
            public AggregateType Aggregate =>
                (type & AttributeType.BaseTypeMask) switch
            {
                AttributeType.Float => AggregateType.FP32,
                AttributeType.Sint => AggregateType.S32,
                AttributeType.Uint => AggregateType.U32,
                _ => throw new ArgumentException($"Invalid attribute type \"{type}\"."),
            };

            public AggregateType AsAggregate(bool supportsScaledFormats) => (type & AttributeType.BaseTypeMask) switch
            {
                AttributeType.Float => AggregateType.FP32,
                AttributeType.Sint => AggregateType.S32,
                AttributeType.Uint => AggregateType.U32,
                AttributeType.Sscaled => supportsScaledFormats ? AggregateType.FP32 : AggregateType.S32,
                AttributeType.Uscaled => supportsScaledFormats ? AggregateType.FP32 : AggregateType.U32,
                _ => throw new ArgumentException($"Invalid attribute type \"{type}\"."),
            };
        }
    }
}
