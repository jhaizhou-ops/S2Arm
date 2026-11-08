using System;
using System.Runtime.InteropServices;

// Test seam only. Production Runtime sees delegates with the same native ABI.
internal static class BackingAuthority
{
    [DllImport("s2a_backing_test")] internal static extern nint test_create();
    [DllImport("s2a_backing_test")] internal static extern void test_destroy(nint p);
    [DllImport("s2a_backing_test")] internal static extern ulong test_publish(nint p, ulong owner, int advance);
    [DllImport("s2a_backing_test")] internal static extern int test_decision(nint p, ulong owner);
    [DllImport("s2a_backing_test")] internal static extern void test_lifecycle(nint p, int foreground);
    [DllImport("s2a_backing_test")] internal static extern ulong test_shared_publish(nint p, ulong owner, int advance);
    [DllImport("s2a_backing_test")] internal static extern int test_shared_decision(nint p, ulong owner);
    [DllImport("s2a_backing_test")] internal static extern void test_shared_lifecycle(nint p, int foreground);
}
