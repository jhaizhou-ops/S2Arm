package org.s2arm.android;
import android.app.Activity;
import android.app.AlertDialog;
import java.lang.reflect.Method;
public final class HostKeyboardLifecycleTest {
    static void check(boolean ok, String why) { if (!ok) throw new AssertionError(why); }
    static void show(HostKeyboard keyboard, long id) throws Exception {
        Method m=HostKeyboard.class.getDeclaredMethod("show", long.class, byte[].class);
        m.setAccessible(true); m.invoke(keyboard, id, new byte[0]);
    }
    public static void main(String[] args) throws Exception {
        HostKeyboard keyboard=new HostKeyboard(new Activity()); keyboard.resume();
        show(keyboard,1); AlertDialog.last.dismiss();
        check(NativeBridge.replies.size()==1 && NativeBridge.replies.get(0).equals("cancel"), "dismiss must complete pending request as cancel");
        show(keyboard,2); AlertDialog.last.cancel();
        check(NativeBridge.replies.size()==2 && NativeBridge.replies.get(1).equals("cancel"), "cancel followed by dismiss must reply exactly once");
        show(keyboard,3); AlertDialog.last.getButton(AlertDialog.BUTTON_POSITIVE).click();
        check(NativeBridge.replies.size()==3 && NativeBridge.replies.get(2).equals("ok"), "confirm followed by dismiss must reply exactly once");
        AlertDialog.throwOnShow=true; show(keyboard,4); AlertDialog.throwOnShow=false;
        check(NativeBridge.replies.size()==4 && NativeBridge.replies.get(3).equals("cancel"), "show failure must terminate pending request");
        show(keyboard,5); keyboard.pause();
        check(NativeBridge.detached==1 && NativeBridge.replies.size()==4, "pause detaches and must not reply to stale owner");
        System.out.println("HostKeyboard lifecycle: dismiss, cancel, confirm, failed show and pause passed");
    }
}
