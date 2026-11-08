using System;
using NxGal;
using S2A.ShBake;

static void Check(bool condition, string message)
{
    if (!condition) throw new Exception(message);
}

var baseline = NxCaps.Build(TargetCaps.Parse(null));
Check(baseline.SupportsBc123Compression && baseline.SupportsBc45Compression && baseline.SupportsBc67Compression,
      "The existing default must retain BC compression.");
var a16 = NxCaps.Build(TargetCaps.Parse("30,32768"));
Check(!a16.SupportsBc123Compression && !a16.SupportsBc45Compression && !a16.SupportsBc67Compression,
      "A measured target without BC must use the runtime's uncompressed texture path.");
Check(a16.SupportsAstcCompression && a16.SupportsEtc2Compression && a16.SupportsR4G4B4A4Format,
      "Disabling BC must preserve the other measured format capabilities.");
Check(a16.MaximumComputeSharedMemorySize == 48 * 1024,
      "The Switch shared-memory budget must still use the existing spill policy.");
foreach (string invalid in new[] { "", "31", "31,32768,0", "32,32768", "-1,32768", "31,0", "31,2147483648", "31,x" })
{
    bool rejected = false;
    try { TargetCaps.Parse(invalid); } catch (ArgumentException) { rejected = true; }
    Check(rejected, "Invalid target capabilities must fail instead of silently selecting another device: " + invalid);
}
Console.WriteLine("Target capability regression checks passed.");
