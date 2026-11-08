package android.util;

/**
 * 无设备门禁的 android.util.Log 桩：test.sh 的纯 Java javac 步没有 android.jar，
 * GameSession（ec6b2ef2f 起）引用了 Log.i/Log.w——桩成空实现让纯 Java 编译与
 * GameSessionTest/GameSessionAdmissionTest 继续在无 SDK 环境跑，真实行为由
 * 带 SDK 的 Gradle 构建与真机路径验证。签名与 android.util.Log 一致。
 */
public final class Log {
    private Log() {
    }

    public static int i(String tag, String msg) {
        return 0;
    }

    public static int w(String tag, String msg, Throwable tr) {
        return 0;
    }
}
