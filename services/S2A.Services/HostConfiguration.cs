using Ryujinx.HLE.HOS.SystemState;
using Ryujinx.HLE.UI;
using Ryujinx.Memory;
using System;
using System.IO;

namespace S2A.Services
{
    // Resolved session values from a platform composition. This is not another
    // persisted configuration format; Android obtains these from BootSpec/HostApi.
    public sealed class HostConfiguration
    {
        public string GameDirectory { get; }
        public string StateDirectory { get; }
        // Optional platform-owned additions; legacy hosts retain their existing behavior.
        // SaveDirectory is persistent storage, never the destructive seed import source.
        public string SaveDirectory { get; }
        public Func<string> SystemLanguageTag { get; }
        public Func<long> MemoryFootprint { get; }
        public SystemLanguage Language { get; }
        public RegionCode Region { get; }
        public string TimeZone { get; }
        public bool Docked { get; }
        public IHostUIHandler UserInterface { get; }
        // Composition owns the backing choice; null preserves the default service memory.
        // The returned block transfers ownership to Switch, including disposal.
        public Func<ulong, MemoryBlock> ServiceMemoryFactory { get; }
        public ScreenshotJpegEncoder ScreenshotEncoder { get; }

        private static string ResolveExistingAncestors(string path, int depth = 0)
        {
            if (depth > 40) throw new IOException("Session path has too many directory links");
            string full = Path.GetFullPath(path);
            string root = Path.GetPathRoot(full);
            string current = root;
            foreach (string part in full[root.Length..].Split(Path.DirectorySeparatorChar, StringSplitOptions.RemoveEmptyEntries))
            {
                string candidate = Path.Combine(current, part);
                var info = new DirectoryInfo(candidate);
                if (info.LinkTarget != null)
                {
                    FileSystemInfo target = info.ResolveLinkTarget(true);
                    if (target == null || !target.Exists)
                        throw new IOException("Session path contains an unresolved directory link");
                    current = ResolveExistingAncestors(target.FullName, depth + 1);
                }
                else current = candidate;
            }
            return Path.GetFullPath(current);
        }

        public HostConfiguration(string gameDirectory, string stateDirectory,
            SystemLanguage language, RegionCode region, string timeZone, bool docked,
            IHostUIHandler userInterface, Func<ulong, MemoryBlock> serviceMemoryFactory = null,
            ScreenshotJpegEncoder screenshotEncoder = null, string saveDirectory = null,
            Func<string> systemLanguageTag = null, Func<long> memoryFootprint = null)
        {
            ArgumentException.ThrowIfNullOrEmpty(gameDirectory);
            ArgumentException.ThrowIfNullOrEmpty(stateDirectory);
            ArgumentException.ThrowIfNullOrEmpty(timeZone);
            ArgumentNullException.ThrowIfNull(userInterface);
            if (!Path.IsPathFullyQualified(gameDirectory) || !Path.IsPathFullyQualified(stateDirectory))
                throw new ArgumentException("Session paths must be absolute");
            if (!Enum.IsDefined(language) || !Enum.IsDefined(region))
                throw new ArgumentException("Unsupported session language or region");
            if (Path.IsPathRooted(timeZone) || timeZone.Split('/').AsSpan().Contains(".."))
                throw new ArgumentException("Invalid session time zone");
            GameDirectory = Path.GetFullPath(gameDirectory);
            StateDirectory = Path.GetFullPath(stateDirectory);
            if (saveDirectory != null && (!Path.IsPathFullyQualified(saveDirectory) || saveDirectory.Length == 0))
                throw new ArgumentException("Persistent save directory must be an absolute path", nameof(saveDirectory));
            SaveDirectory = saveDirectory == null ? null : Path.GetFullPath(saveDirectory);
            SystemLanguageTag = systemLanguageTag;
            MemoryFootprint = memoryFootprint;
            // Compare resolved existing ancestors: Android and macOS commonly
            // have legitimate symlinked parents, while a state symlink can point
            // back inside the supposedly immutable game directory. This validation
            // does not make subsequent opens safe against concurrent replacement.
            string realGame = ResolveExistingAncestors(GameDirectory);
            string realState = ResolveExistingAncestors(StateDirectory);
            StringComparison comparison = OperatingSystem.IsMacOS() || OperatingSystem.IsWindows()
                ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal;
            string trimmedGame = Path.TrimEndingDirectorySeparator(realGame);
            string gamePrefix = Path.EndsInDirectorySeparator(trimmedGame) ? trimmedGame : trimmedGame + Path.DirectorySeparatorChar;
            bool InsideGame(string resolved) =>
                string.Equals(Path.TrimEndingDirectorySeparator(realGame), Path.TrimEndingDirectorySeparator(resolved), comparison) ||
                resolved.StartsWith(gamePrefix, comparison);
            if (InsideGame(realState))
                throw new ArgumentException("Persistent session state must be outside immutable game data");
            if (SaveDirectory != null && InsideGame(ResolveExistingAncestors(SaveDirectory)))
                throw new ArgumentException("Persistent save directory must be outside immutable game data", nameof(saveDirectory));
            Language = language;
            Region = region;
            TimeZone = timeZone;
            Docked = docked;
            UserInterface = userInterface;
            ServiceMemoryFactory = serviceMemoryFactory;
            ScreenshotEncoder = screenshotEncoder;
        }
    }
}
