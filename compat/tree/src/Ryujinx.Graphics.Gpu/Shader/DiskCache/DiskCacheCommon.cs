using Ryujinx.Common.Logging;
using System.IO;

namespace Ryujinx.Graphics.Gpu.Shader.DiskCache
{
    /// <summary>
    /// Common disk cache utility methods.
    /// </summary>
    static class DiskCacheCommon
    {
        // Diagnostic output is opt-in on every platform; cache behavior is unchanged.
        internal static readonly bool S2ACacheDiagnostics = System.Environment.GetEnvironmentVariable("S2A_SHADER_CACHE_DIAG") == "1";

        /// <summary>
        /// Opens a file for read or write.
        /// </summary>
        /// <param name="basePath">Base path of the file (should not include the file name)</param>
        /// <param name="fileName">Name of the file</param>
        /// <param name="writable">Indicates if the file will be read or written</param>
        /// <returns>File stream</returns>
        public static FileStream OpenFile(string basePath, string fileName, bool writable, int bufferSize = 4096)
        {
            string fullPath = Path.Combine(basePath, fileName);

            FileMode mode;
            FileAccess access;

            if (writable)
            {
                mode = FileMode.OpenOrCreate;
                access = FileAccess.ReadWrite;
            }
            else
            {
                mode = FileMode.Open;
                access = FileAccess.Read;
            }

            try
            {
                // Lazy readers remain open while the single background writer appends records.
                // Writers publish TOC entries only after their data is flushed.
                return new FileStream(fullPath, mode, access, writable ? FileShare.Read : FileShare.ReadWrite, bufferSize);
            }
            catch (IOException ioException)
            {
                Logger.Error?.Print(LogClass.Gpu, $"Could not access file \"{fullPath}\". {ioException.Message}");

                throw new DiskCacheLoadException(DiskCacheLoadResult.NoAccess);
            }
        }

        /// <summary>
        /// Gets the compression algorithm that should be used when writing the disk cache.
        /// </summary>
        /// <returns>Compression algorithm</returns>
        public static CompressionAlgorithm GetCompressionAlgorithm()
        {
            return CompressionAlgorithm.Brotli;
        }
    }
}
