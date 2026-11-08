package org.s2arm.android;

import android.app.Activity;
import android.content.Intent;
import android.os.Bundle;

/**
 * LAUNCHER 跳板（#1474）：无界面——库页不先上来，excludeFromRecents 的 :game task
 * 就不会因「先切到库页 task」被系统当可回收裁掉（GameActivity.onDestroy →
 * stopGame("activity destroyed")，就是把局裁丢的那条日志）。
 *   游戏存活（:game 进程在）→ 直接把已有 GameActivity task 带回前台；
 *   游戏不在 → 照常进库页。本 activity 永远立即 finish，不进任何返回栈/最近任务。
 */
public final class IconEntryActivity extends Activity {
    @Override protected void onCreate(Bundle state) {
        super.onCreate(state);
        // 探活只看 :game 进程：GameResume 收条要到会话 READY 才发布，等收条会把
        // 还在进局的进行中之局错投到库页；进程退出是原生 _exit，pid 窗口极短。
        startActivity(route(this, GameActivity.runningPid(this)));
        finish();
    }

    /** 存活→指回 GameActivity：只带控制 extra（ICON_RESUME 在 CONTROL_EXTRAS，isLaunch
     *  为假、运行中实例按控制 intent 处理，不会被当起局 stopGame），singleTask + 自有
     *  taskAffinity 把它所在 task 整体带回前台（同一局、同 PID）；不在→库页。
     *  两条都带 NEW_TASK：本 activity taskAffinity="" 独占临时 task，库页要回自己的
     *  应用 task；分离出来让宿主测试直接断言路由结果。 */
    static Intent route(android.content.Context context, int gamePid) {
        if (gamePid != 0) {
            return new Intent(context, GameActivity.class)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                .putExtra(GameActivity.ICON_RESUME_EXTRA, true);
        }
        return new Intent(context, LibraryActivity.class).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
    }
}
