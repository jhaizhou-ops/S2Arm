package org.s2arm.android;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Paths;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * VulkanDirectChoice（#274）：intent 取值三态、错值拒绝、缺省不是手动直连，取值与 native direct_choice.h 同值。
 * 用法：java org.s2arm.android.VulkanDirectChoiceTest <android/native/direct_choice.h>
 */
public final class VulkanDirectChoiceTest {
    private static void check(boolean condition, String what) {
        if (!condition) throw new AssertionError(what);
    }
    private static void rejects(Object value) {
        try {
            VulkanDirectChoice.parse(value);
        } catch (IllegalArgumentException expected) {
            return;
        }
        throw new AssertionError("accepted bad value " + value);
    }
    public static void main(String[] args) throws Exception {
        check(VulkanDirectChoice.parse(Boolean.TRUE) == VulkanDirectChoice.DIRECT, "true → direct");
        check(VulkanDirectChoice.parse(Boolean.FALSE) == VulkanDirectChoice.GENERIC, "false → generic");
        check(VulkanDirectChoice.parse("auto") == VulkanDirectChoice.AUTO, "\"auto\" → auto");
        for (Object bad : new Object[] {null, "AUTO", "true", "direct", "", 1, 2L}) rejects(bad);
        // 缺省只能是通用或 AUTO：手动直连当缺省会让没有描述的包起局就报红
        check(VulkanDirectChoice.DEFAULT == VulkanDirectChoice.GENERIC || VulkanDirectChoice.DEFAULT == VulkanDirectChoice.AUTO,
              "default must be generic or auto");
        check(VulkanDirectChoice.name(VulkanDirectChoice.AUTO).equals("auto"), "name");
        // 与 native 同值：读 direct_choice.h 的 enum
        String header = new String(Files.readAllBytes(Paths.get(args[0])), StandardCharsets.UTF_8);
        String[][] pairs = {{"GENERIC", "0"}, {"DIRECT", "1"}, {"AUTO", "2"}};
        int[] java = {VulkanDirectChoice.GENERIC, VulkanDirectChoice.DIRECT, VulkanDirectChoice.AUTO};
        for (int i = 0; i < pairs.length; i++) {
            Matcher m = Pattern.compile("S2A_VK_CHOICE_" + pairs[i][0] + "\\s*=\\s*(\\d+)").matcher(header);
            check(m.find(), "native constant S2A_VK_CHOICE_" + pairs[i][0] + " missing");
            check(Integer.parseInt(m.group(1)) == java[i], "S2A_VK_CHOICE_" + pairs[i][0] + " differs from Java");
        }
        System.out.println("VulkanDirectChoice: ok");
    }
}
