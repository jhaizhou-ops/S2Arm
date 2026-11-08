package org.s2arm.android;
import java.util.ArrayList;
import java.nio.charset.StandardCharsets;
public class NativeBridge {
    static ArrayList<String> replies=new ArrayList<>();
    static int detached;
    static long attachHostUi() { return 7; }
    static void detachHostUi(long id) { detached++; }
    static byte[] takeHostUi(long id, long[] output) { return null; }
    static int completeHostUi(long owner, long id, byte[] response) { replies.add(new String(response, StandardCharsets.UTF_8)); return 0; }
}
