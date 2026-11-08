namespace Ryujinx.Graphics.GAL.Multithreading.Commands.Buffer
{
    /// <summary>S2A：缓冲写入，数据在上传租约里（ThreadedRenderer.SetBufferData 环形池放不下时用，原先 ToArray 新分配）</summary>
    struct BufferS2ASetDataCommand : IGALCommand, IGALCommand<BufferS2ASetDataCommand>
    {
        public readonly CommandType CommandType => CommandType.BufferS2ASetData;
        private BufferHandle _buffer;
        private int _offset;
        private S2AUploadLease _lease;

        public void Set(BufferHandle buffer, int offset, S2AUploadLease lease)
        {
            _buffer = buffer;
            _offset = offset;
            _lease = lease;
        }

        public static void Run(ref BufferS2ASetDataCommand command, ThreadedRenderer threaded, IRenderer renderer)
        {
            renderer.S2ASetBufferData(threaded.Buffers.MapBuffer(command._buffer), command._offset, command._lease);
        }
    }
}
