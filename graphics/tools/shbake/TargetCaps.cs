using System;
using System.Globalization;

namespace S2A.ShBake
{
    // Same two fields as nxgal_device_caps: format bits, shared-memory bytes.
    // Keep the existing target when no measured device override is supplied.
    internal static class TargetCaps
    {
        internal static ulong[] Parse(string value)
        {
            if (value == null) return new ulong[] { 31, 32768, 0, 0 };
            string[] fields = value.Split(',');
            if (fields.Length != 2 ||
                !ulong.TryParse(fields[0].Trim(), NumberStyles.None, CultureInfo.InvariantCulture, out ulong formats) ||
                !ulong.TryParse(fields[1].Trim(), NumberStyles.None, CultureInfo.InvariantCulture, out ulong shared) ||
                (formats & ~31UL) != 0 || shared == 0 || shared > int.MaxValue)
            {
                throw new ArgumentException("S2A_TARGET_DEVICE_CAPS requires format bits (0..31),shared-memory bytes (1..2147483647).");
            }
            return new ulong[] { formats, shared, 0, 0 };
        }
    }
}
