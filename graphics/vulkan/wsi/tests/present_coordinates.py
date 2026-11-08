#!/usr/bin/env python3
# 门禁手动：要传参数：--common-assembly 预构建 Ryujinx.Common.dll（门禁机没有固定路径）+ --dotnet / --output
"""Compile exact presentation-coordinate and helper UV blocks; no Vulkan driver required.

The production Present methods are not copied into a maintained test implementation:
this extracts their current arithmetic and the actual BlitColor arguments, failing
closed if the source boundary changes. It verifies coordinates, not rendered pixels.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import xml.etree.ElementTree as ET

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--android-window', required=True, type=Path)
parser.add_argument('--reference-root', required=True, type=Path)
parser.add_argument('--common-assembly', required=True, type=Path)
parser.add_argument('--dotnet', required=True, type=Path)
parser.add_argument('--output', required=True, type=Path)
args = parser.parse_args()
out = args.output.resolve()
out.mkdir(parents=True, exist_ok=False)
root = args.reference_root
files = [args.android_window, root / 'compat/tree/src/Ryujinx.Graphics.Vulkan/Window.cs',
         root / 'compat/tree/src/Ryujinx.Graphics.Vulkan/HelperShader.cs',
         root / 'compat/tree/src/Ryujinx.Graphics.GAL/ImageCrop.cs',
         root / 'compat/tree/src/Ryujinx.Graphics.GAL/Extents2D.cs']
(out / 'input-sha256.json').write_text(json.dumps({str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in files}, indent=2) + '\n')
android, upstream, helper = [p.read_text() for p in files[:3]]

def block(source, start, end):
    assert source.count(start) == 1, 'Production boundary changed: ' + start
    return source.split(start, 1)[1].split(end, 1)[0]

def extents(source):
    match = re.search(r'HelperShader\.BlitColor\([^;]*?(new Extents2D\([^)]*\)),\s*(new Extents2D\([^)]*\))', source)
    assert match, 'Actual final BlitColor arguments changed'
    return 'return (' + ', '.join(match.groups()) + ');'

android_body = 'int x0 = ' + block(android, '            int x0 = ', '            _renderer.HelperShader.BlitColor(')
# The touch rectangle is published after the lease/drain check (a revoked frame must not
# republish its stale generation/revision), so pull that statement from its own location.
touch_start = android.index('            bool switchRegion = ')
touch_end = android.index(');', android.index('s2a_android_game_touch_viewport(', touch_start)) + 2
android_body += '\n' + android[touch_start:touch_end].replace('\n            ', '\n    ') + '\n' + extents(android)
upstream_body = 'int srcX0, srcX1, srcY0, srcY1;' + block(upstream, '            int srcX0, srcX1, srcY0, srcY1;', '            if (ScreenCaptureRequested)')
upstream_body += 'float ratioX = ' + block(upstream, '            float ratioX = ', '            if (_scalingFilter != null)') + extents(upstream)
helper_method = helper.split('        public void BlitColor(', 1)[1].split('            using ScopedTemporaryBuffer buffer', 1)[0]
helper_body = 'region[0] = ' + block(helper_method, '            region[0] = ', '            using ScopedTemporaryBuffer buffer')
source = '''using System;
using Ryujinx.Graphics.GAL;
record Texture(int Width, int Height);
record Insets(int InsetLeft, int InsetTop, int InsetRight, int InsetBottom);
record TestLease(Insets State);
record Frame(ulong Generation);
record Touch(ulong Generation, int Left, int Top, int Width, int Height, int BufferWidth, int BufferHeight);
static class Program
{
    static int checks, cases;
    static Touch touch;
    static void s2a_android_game_touch_viewport(ulong generation, int left, int top,
        int width, int height, int bufferWidth, int bufferHeight) =>
        touch = new(generation, left, top, width, height, bufferWidth, bufferHeight);
    static void Check(bool ok, string message) { checks++; if (!ok) throw new Exception(message); }
    static (Extents2D src, Extents2D dst) Android(Texture source, ImageCrop crop, int _width, int _height, TestLease Lease)
    { var chain = new Texture(_width, _height); var frame = new Frame(42); touch = null; ANDROID_BODY }
    static (Extents2D src, Extents2D dst) Upstream(Texture view, ImageCrop crop, int _width, int _height)
    { UPSTREAM_BODY }
    static float[] Sample(Texture src, Extents2D srcRegion, Extents2D dstRegion)
    { Span<float> region = stackalloc float[4]; HELPER_BODY return region.ToArray(); }
    static bool Equal(Extents2D a, Extents2D b) => a.X1 == b.X1 && a.X2 == b.X2 && a.Y1 == b.Y1 && a.Y2 == b.Y2;
    static void Main()
    {
        foreach (var size in new[] { (1280, 720), (1920, 1080) })
        foreach (var target in new[] { (1280, 720), (1920, 1200), (3040, 1904), (1001, 733), (2800, 2000), (2000, 2800) })
        foreach (var inset in new[] { new Insets(0, 0, 0, 0), new Insets(23, 97, 41, 19) })
        foreach (var aspect in new[] { (16f, 9f), (4f, 3f) })
        foreach (bool stretch in new[] { false, true })
        foreach (bool cropped in new[] { false, true })
        foreach (bool flipX in new[] { false, true })
        foreach (bool flipY in new[] { false, true })
        {
            cases++;
            Texture src = new(size.Item1, size.Item2);
            ImageCrop crop = new(cropped ? 77 : 0, cropped ? size.Item1 - 13 : 0,
                cropped ? 33 : 0, cropped ? size.Item2 - 55 : 0, flipX, flipY, stretch, aspect.Item1, aspect.Item2);
            var actual = Android(src, crop, target.Item1, target.Item2, new TestLease(inset));
            var reference = Upstream(src, crop, target.Item1 - inset.InsetLeft - inset.InsetRight,
                target.Item2 - inset.InsetTop - inset.InsetBottom);
            Extents2D expected = new(reference.dst.X1 + inset.InsetLeft, reference.dst.Y1 + inset.InsetTop,
                reference.dst.X2 + inset.InsetLeft, reference.dst.Y2 + inset.InsetTop);
            Check(Equal(actual.src, reference.src), "Source crop changed");
            Check(Equal(actual.dst, expected), $"Final blit differs from upstream: FlipY={flipY}, Android Y={actual.dst.Y1}->{actual.dst.Y2}, expected={expected.Y1}->{expected.Y2}");
            Check(touch != null && touch.Generation == (aspect == (16f, 9f) ? 42ul : 0), "Touch must use the real frame generation only for the original Switch region");
            Check(touch.Left == Math.Min(actual.dst.X1, actual.dst.X2) && touch.Top == Math.Min(actual.dst.Y1, actual.dst.Y2) &&
                touch.Width == Math.Abs(actual.dst.X2 - actual.dst.X1) && touch.Height == Math.Abs(actual.dst.Y2 - actual.dst.Y1),
                "Touch rectangle must match the final blit including asymmetric insets and flips");
            Check(touch.BufferWidth == target.Item1 && touch.BufferHeight == target.Item2, "Touch buffer dimensions must use the logical swapchain extent");
            var uv = Sample(src, actual.src, actual.dst);
            var expectedUv = Sample(src, reference.src, reference.dst);
            for (int i = 0; i < 4; i++) Check(uv[i] == expectedUv[i], "HelperShader source UV differs from upstream");
            // Independent crop contract, also used by Metal cap_fs: the labelled source
            // corners exchange vertically iff FlipY, horizontally iff FlipX.
            float left = (float)(flipX ? actual.src.X2 : actual.src.X1) / src.Width;
            float right = (float)(flipX ? actual.src.X1 : actual.src.X2) / src.Width;
            float top = (float)(flipY ? actual.src.Y2 : actual.src.Y1) / src.Height;
            float bottom = (float)(flipY ? actual.src.Y1 : actual.src.Y2) / src.Height;
            Check(uv[0] == left && uv[1] == right, "Left/right source labels reversed");
            Check(uv[2] == top && uv[3] == bottom, "Top/bottom source labels reversed");
            Check(Math.Min(actual.dst.X1, actual.dst.X2) >= inset.InsetLeft && Math.Max(actual.dst.X1, actual.dst.X2) <= target.Item1 - inset.InsetRight, "Horizontal inset escaped");
            Check(Math.Min(actual.dst.Y1, actual.dst.Y2) >= inset.InsetTop && Math.Max(actual.dst.Y1, actual.dst.Y2) <= target.Item2 - inset.InsetBottom, "Vertical inset escaped");
        }
        Console.WriteLine($"PASS: {cases} present cases, {checks} coordinate/UV checks; exact source blocks compiled, GPU pixels NOT RUN.");
    }
}
'''.replace('ANDROID_BODY', android_body).replace('UPSTREAM_BODY', upstream_body).replace('HELPER_BODY', helper_body)
(out / 'Program.cs').write_text(source)
for p in files[3:]:
    shutil.copy2(p, out / p.name)
config = out / 'NuGet.Config'
config.write_text('<configuration><packageSources><clear /></packageSources></configuration>')
project = ET.Element('Project', Sdk='Microsoft.NET.Sdk')
props = ET.SubElement(project, 'PropertyGroup')
for key, value in {'OutputType': 'Exe', 'TargetFramework': 'net10.0'}.items():
    ET.SubElement(props, key).text = value
ET.SubElement(ET.SubElement(project, 'ItemGroup'), 'Reference', Include=str(args.common_assembly))
ET.ElementTree(project).write(out / 'PresentCoordinates.csproj', encoding='unicode')
for command, log in [([str(args.dotnet), 'build', str(out / 'PresentCoordinates.csproj'), '--configfile', str(config), '-v:q'], 'build.log'),
                     ([str(args.dotnet), str(out / 'bin/Debug/net10.0/PresentCoordinates.dll')], 'test.log')]:
    result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=60)
    (out / log).write_text(result.stdout)
    print(result.stdout, end='')
    if result.returncode:
        raise SystemExit(result.returncode)
