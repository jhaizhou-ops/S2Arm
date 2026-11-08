#!/usr/bin/env python3
"""Activity-level negative control of the runtime-library rejection (no Android SDK needed: source structure).

A launch can be rejected before native loading or after a mapped library fails verification. The
Activity must not make native calls in either case and instead shows the red "Startup failed" panel. This checks MainActivity's source: the load comes first,
the rejected branch returns before anything native is created, no SurfaceHolder callback is registered and
the touch pad is hidden, every lifecycle entry that reaches native code is behind the runtimeLoaded guard,
a later launch (singleTop onNewIntent) is checked against the library the process runs, and nothing but
NativeBridge.load loads the game runtime; the independent opt-in rewriter has one fixed library load.
"""
import re
import sys
import unittest
from pathlib import Path

JAVA = Path(__file__).resolve().parents[1] / "app/src/main/java/org/s2arm/android"
NATIVE_REACH = re.compile(r"\b(NativeBridge\.(?!loaded\(\)|clearStopListener|stopReason)\w+|TouchInputBridge\.\w+|hostKeyboard\.|"
                          r"frameRate\.|library\.|touchPad\.|clearInput\(|tryStartGame\(|requestDebugLifecycle\(|"
                          r"updateFrameRate\(|requestOrientation\(|publishInput\(|stopGame\()")


def body(source, signature):
    start = source.index(signature)
    open_at = source.index("{", start)
    depth = 0
    for i in range(open_at, len(source)):
        depth += {"{": 1, "}": -1}.get(source[i], 0)
        if depth == 0:
            return source[open_at + 1:i]
    raise AssertionError("unbalanced " + signature)


class ActivityRejection(unittest.TestCase):
    source = (JAVA / "MainActivity.java").read_text(encoding="utf-8")

    def native_views(self):
        """App View classes whose callbacks reach native code (the 9000 crash: TouchPadView.onSizeChanged ->
        relayout -> TouchInputBridge.touchViewportRevoke while the library was not loaded)."""
        views = {}
        for path in sorted(JAVA.glob("*.java")):
            text = path.read_text(encoding="utf-8")
            if re.search(r"class \w+ extends \w*View\b", text) and re.search(r"\b(NativeBridge|TouchInputBridge)\.\w+\(", text):
                views[path.stem] = text
        return views

    def test_crash_path_is_real(self):
        pad = self.native_views()["TouchPadView"]
        self.assertIn("relayout();", body(pad, "protected void onSizeChanged("))
        self.assertIn("revokeGameViewport()", body(pad, "private void relayout()"))
        self.assertIn("TouchInputBridge.touchViewportRevoke()", body(pad, "void revokeGameViewport()"))

    def test_load_first_and_rejected_branch_returns_before_native(self):
        on_create = body(self.source, "public void onCreate(Bundle state)")
        load = on_create.index("loadRuntime(getIntent())")
        reject = on_create.index("if (!runtimeLoaded) {")
        branch = body(on_create, "if (!runtimeLoaded) {")
        self.assertIn("return;", branch)
        self.assertIn('status.setText("Startup failed: "', branch)
        self.assertLess(load, reject)
        for created in ("new HostKeyboard", "new GameLibrary", "registerInputDeviceListener", "NativeBridge.createGame",
                        "requestOrientation(getIntent())", "updateTouchPad()"):
            self.assertGreater(on_create.index(created), reject, created + " must come after the rejection return")
        before = on_create[:reject]
        loaded_only = body(before, "if (runtimeLoaded) {")
        views = self.native_views()
        self.assertTrue({"TouchPadView", "FrameRateOverlay"} <= set(views), set(views))
        for view in views:
            with self.subTest(view):
                outside = before.replace(loaded_only, "")
                self.assertNotIn(f"new {view}(", outside, f"{view} is created even when the library is rejected")
        # Everything else before the return is UI; the insets listener runs on a rejected Activity too, so its
        # uses of the native views are null-guarded and publishSurface is host-guarded.
        rest = before.replace(loaded_only, "")
        for use in re.finditer(r"(touchPad|frameRate)\.\w+\(", rest):
            line = rest[rest.rfind("\n", 0, use.start()) + 1:rest.find("\n", use.start())]
            self.assertIn(f"if ({use.group(1)} != null)", line, line.strip())
        offenders = [m.group(0) for m in NATIVE_REACH.finditer(rest) if not m.group(0).startswith(("touchPad.", "frameRate."))]
        self.assertEqual(offenders, [], "native-reaching calls before the rejection return")
        self.assertRegex(body(self.source, "private void publishSurface()"), r"^\s*if \(host == 0")

    def test_no_surface_callback_when_rejected(self):
        lines = [line.strip() for line in self.source.splitlines() if "addCallback(this)" in line]
        self.assertEqual(len(lines), 1, lines)
        self.assertTrue(lines[0].startswith("if (runtimeLoaded) surface.getHolder().addCallback(this);"), lines[0])

    def test_lifecycle_entries_are_guarded(self):
        for signature in ("protected void onResume()", "protected void onPause()", "protected void onNewIntent(",
                          "protected void onActivityResult("):
            with self.subTest(signature):
                text = body(self.source, signature)
                guard = re.search(r"runtimeLoaded", text)
                first = NATIVE_REACH.search(text)
                self.assertIsNotNone(guard, signature + " has no runtimeLoaded guard")
                if first:
                    self.assertLess(guard.start(), first.start(), signature + ": " + first.group(0) + " before the guard")

    def test_later_launch_is_bound_to_the_loaded_library(self):
        text = body(self.source, "protected void onNewIntent(")
        check = text.index("selectedBy(requested)")
        self.assertIn("cold start needed", text)
        first = NATIVE_REACH.search(text[text.index("if (!runtimeLoaded) {") + len("if (!runtimeLoaded) {"):])
        self.assertIsNotNone(first)
        self.assertLess(check, text.index("consoleModeFromIntent"), "binding check precedes the intent's controls")

    def test_control_intents_are_the_ones_onnewintent_handles(self):
        """A control intent (only CONTROL_EXTRAS) keeps a running development session; every extra the running
        Activity reads in onNewIntent's handlers must be a control, and a cold-start extra must not be."""
        start = self.source.index("CONTROL_EXTRAS = new java.util.HashSet<>(")
        declared = set(re.findall(r'"(s2arm\.[a-z_]+)"', self.source[start:self.source.index("));", start)]))
        read = set()
        for handler in ("private void requestOrientation(", "private void requestDebugLifecycle(", "private void updateFrameRate(",
                        "private void updateGamepadMapping("):
            read |= set(re.findall(r'"(s2arm\.[a-z_]+)"', body(self.source, handler)))
        # Extras may be named by a constant inside a handler, as the mapping preference is.
        constants = dict(re.findall(r'private static final String (\w+) = "(s2arm\.[a-z_]+)";', self.source))
        mapping = body(self.source, "private void updateGamepadMapping(")
        read |= {value for name, value in constants.items() if re.search(r"\b" + name + r"\b", mapping)}
        self.assertEqual(declared, read)
        self.assertNotIn("s2arm.dev_runtime", declared)
        self.assertNotIn("s2arm.console_mode", declared)
        text = body(self.source, "protected void onNewIntent(")
        self.assertIn("RuntimeLibrary.isLaunch(", text)
        self.assertRegex(text, r"if \(launch && !NativeBridge\.loaded\(\)\.selectedBy\(requested\)\)")

    def test_single_load_entry(self):
        loads = {}
        for path in sorted(JAVA.glob("*.java")):
            calls = re.findall(r"System\.load(?:Library)?\([^;]*\)", path.read_text(encoding="utf-8"))
            if calls:
                loads[path.name] = calls
        self.assertEqual(set(loads), {"NativeBridge.java", "NativeRewriter.java"})
        self.assertEqual(loads["NativeRewriter.java"], ['System.loadLibrary("s2arm_rewriter")'])
        bridge = body((JAVA / "NativeBridge.java").read_text(encoding="utf-8"), "static synchronized void load(")
        self.assertEqual(len(re.findall(r"System\.load(Library)?\(", bridge)), 2)
        self.assertEqual(len(loads["NativeBridge.java"]), 2)



if __name__ == "__main__":
    sys.exit(unittest.main())
