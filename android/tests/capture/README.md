# Screenshot provider regression

`run_tests.py` uses only existing tools and explicit output paths. It never downloads, restores packages, installs, starts an emulator, or accesses a device. Required arguments: `--jdk`, `--android-sdk`, `--ndk`, `--dotnet-root`, `--skia-managed` (the existing default SkiaSharp.dll), `--skia-native` (matching existing host library), and `--output`.

It tests packed premultiplied RGBA/ARGB and alpha round trips, dimensions/quality/overflow rejection, actual host-JVM JPEG over production JNI (colors, exceptions, null/malformed results, 100 calls from4 native threads and attachment ownership), Android Java/NDK compile, managed provider failures, Android missing-provider rejection, and9 byte-for-byte comparisons with the original default Skia encoding.

The host JPEG adapter is test-only Java ImageIO. Production uses `android.graphics.Bitmap`. Host checks and compilation do not prove Android Bitmap execution, an Android service IPC call, or gameplay; those need a separately authorized device run. The existing Android keyboard remains explicitly unsupported.

The official Android service build passes `S2AAndroidHost=true` globally because the SDK removes RuntimeIdentifier on some project-reference builds. Android assets must omit every Skia package and its dedicated implementation sources; default hosts retain the Skia codec/renderer. No change to the official APK library allowlist is required.

## Gate registration

The pure CapturePixelsTest pixel/alpha/parameter checks run automatically from android/test.sh with its existing JDK 17. The full JPEG/JNI/managed suite is separately registered in android/tests/gate_not_default.tsv because it requires explicit SDK/NDK/.NET and matching host Skia library paths. Passing the default pixel step does not establish full-suite, Android Bitmap, service IPC, or device results.
