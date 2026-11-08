package android.app;
import java.util.concurrent.CountDownLatch;
public class Activity {
    public boolean finishing, destroyed, queue;
    public volatile Runnable queued;
    public CountDownLatch posted = new CountDownLatch(1);
    public void runOnUiThread(Runnable r) { if (queue) { queued=r; posted.countDown(); } else r.run(); }
    public boolean isFinishing() { return finishing; }
    public boolean isDestroyed() { return destroyed; }
}
