package android.app;
import android.view.Window;
import android.view.WindowManager;
import android.widget.Button;
import android.widget.EditText;
public class AlertDialog {
    public interface Listener { void run(AlertDialog d); }
    public interface Click { void run(AlertDialog d, int which); }
    public static final int BUTTON_POSITIVE=-1;
    public static volatile AlertDialog last;
    public static volatile java.util.concurrent.CountDownLatch shown = new java.util.concurrent.CountDownLatch(1);
    public static boolean throwOnShow;
    private Listener cancel, dismiss, show;
    private Click negative, positiveClick;
    private Button positive=new Button();
    public void setCanceledOnTouchOutside(boolean b) {}
    public void setOnCancelListener(Listener l) { cancel=l; }
    public void setOnDismissListener(Listener l) { dismiss=l; }
    public void setOnShowListener(Listener l) { show=l; }
    public void show() { if (throwOnShow) throw new WindowManager.BadTokenException(); if (show!=null) show.run(this); shown.countDown(); }
    public void dismiss() { if (dismiss!=null) dismiss.run(this); }
    public void cancel() { if (cancel!=null) cancel.run(this); dismiss(); }
    public void positive() { if (positiveClick!=null) positiveClick.run(this, -1); dismiss(); }
    public void negative() { if (negative!=null) negative.run(this, -2); dismiss(); }
    public Button getButton(int b) { return positive; }
    public Window getWindow() { return new Window(); }
    public static class Builder {
        private final AlertDialog d=new AlertDialog();
        public Builder(Activity a) {} public Builder setTitle(String s) { return this; }
        public Builder setMessage(String s) { return this; } public Builder setView(EditText e) { return this; }
        public Builder setPositiveButton(String s, Click c) { d.positiveClick=c; return this; }
        public Builder setNegativeButton(String s, Click c) { d.negative=c; return this; }
        public AlertDialog create() { last=d; return d; }
    }
}
