using Ryujinx.Graphics.GAL;

namespace Ryujinx.Graphics.Gpu.Engine.Threed.ComputeDraw
{
    static class VtgAsComputeGeometryOutput
    {
        // Generic GS shader uses instance * vertexCount + primitive as its output slot.
        public static (int Slots, int Vertices, int Indices) Layout(int vertexCount, int instances, int primitives, int maxOutput, int verticesPerPrimitive, int invocations)
        {
            checked
            {
                int slots = instances > 0 && primitives > 0 ? (instances - 1) * vertexCount + primitives : 0;
                int vertices = slots * maxOutput * invocations;
                int indices = slots * (maxOutput + maxOutput / verticesPerPrimitive) * invocations;
                return (slots, vertices, indices);
            }
        }

        public static void ClearAndDispatch(IPipeline pipeline, BufferRange indices, int x, int y, int z)
        {
            if (indices.Size != 0)
            {
                pipeline.ClearBuffer(indices.Handle, indices.Offset, indices.Size, uint.MaxValue);
            }
            pipeline.DispatchCompute(x, y, z);
        }
    }
}
