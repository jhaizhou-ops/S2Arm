#!/usr/bin/env python3
"""#1474 launcher trampoline contract: real IconEntryActivity routing + manifest wiring.

Only Android boundary classes are stubbed; the activity under test is the real
source. Assertions cover: alive game -> bare Intent at GameActivity (existing
singleTask task comes forward, no session extras); dead -> LibraryActivity;
trampoline always finishes and never shows UI; the LAUNCHER filter moved off
LibraryActivity while GameActivity keeps excludeFromRecents.
"""
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
JAVA = ROOT / 'app/src/main/java'
ICON_ENTRY = JAVA / 'org/s2arm/android/IconEntryActivity.java'
MAIN_ACTIVITY = JAVA / 'org/s2arm/android/MainActivity.java'
MANIFEST = ROOT / 'app/src/main/AndroidManifest.xml'


def javac():
    found = subprocess.run(['bash', str(ROOT / 'tools/jdk17.sh')], capture_output=True, text=True)
    if found.returncode == 0 and found.stdout.strip():
        return Path(found.stdout.strip())
    which = shutil.which('javac')
    return Path(which) if which else None


JAVAC = javac()
JAVA_BIN = JAVAC.parent / 'java' if JAVAC is not None else None

STUBS = {
'android/os/Bundle.java': '''package android.os; public class Bundle {}''',
'android/content/Context.java': '''package android.content; public class Context {
 public Context getApplicationContext(){return this;} public String getPackageName(){return "fixture";} }''',
'android/content/Intent.java': '''package android.content; import java.util.*; public class Intent {
 public static final int FLAG_ACTIVITY_NEW_TASK=0x10000000;
 public Class<?> target; public int flags; public final Map<String,String> extras=new HashMap<>();
 public Intent(Context c,Class<?> t){target=t;} public Intent addFlags(int f){flags|=f;return this;}
 public Intent putExtra(String k,String v){extras.put(k,v);return this;}
 public Intent putExtra(String k,boolean v){extras.put(k,String.valueOf(v));return this;} }''',
'android/app/Activity.java': '''package android.app; import android.content.*; import android.os.Bundle;
 public class Activity extends Context {
  public static final java.util.List<Intent> started=new java.util.ArrayList<>();
  public static int finishes,contentViews;
  protected void onCreate(Bundle b){}
  public void startActivity(Intent i){started.add(i);}
  public void finish(){finishes++;}
  public void setContentView(android.view.View v){contentViews++;}
 }''',
'android/view/View.java': '''package android.view; public class View {}''',
# GameActivity is substituted only at the liveness boundary; its runningPid is the probe seam.
'org/s2arm/android/GameActivity.java': '''package org.s2arm.android; import android.content.Context;
 public class GameActivity { public static int pid; static int runningPid(Context c){return pid;}
 public static final String ICON_RESUME_EXTRA="s2arm.icon_resume"; }''',
'org/s2arm/android/LibraryActivity.java': '''package org.s2arm.android; public class LibraryActivity {}''',
'org/s2arm/android/IconEntryProbe.java': '''package org.s2arm.android;
import android.app.Activity; import android.content.Intent;
public class IconEntryProbe {
 static int checks;
 static void demand(boolean yes,String message){checks++;if(!yes)throw new AssertionError(message);}
 static void reset(){Activity.started.clear();Activity.finishes=0;Activity.contentViews=0;}
 public static void main(String[] args) {
  // 游戏存活：intent 指回 GameActivity——只带 icon_resume 控制 extra（isLaunch 为假、
  // 运行中实例按控制 intent 处理、替换库局不被 stopGame），singleTask 把原 task 带回前台。
  GameActivity.pid=4242; reset();
  new IconEntryActivity().onCreate(null);
  demand(Activity.started.size()==1,"alive game did not start exactly one activity");
  Intent game=Activity.started.get(0);
  demand(game.target==GameActivity.class,"alive game did not route to GameActivity");
  demand((game.flags&Intent.FLAG_ACTIVITY_NEW_TASK)!=0,"game route missing NEW_TASK");
  demand(game.extras.size()==1&&"true".equals(game.extras.get(GameActivity.ICON_RESUME_EXTRA)),
      "game route must carry only the icon_resume control extra (extras mint sessions or read as a plain launch)");
  demand(Activity.finishes==1,"trampoline did not finish after forwarding");
  demand(Activity.contentViews==0,"trampoline showed UI");
  // 无局：库页进自己的应用 task（跳板 taskAffinity="" 独占临时 task，不带 NEW_TASK 库页会落进去）。
  GameActivity.pid=0; reset();
  new IconEntryActivity().onCreate(null);
  demand(Activity.started.size()==1,"idle launch did not start exactly one activity");
  Intent library=Activity.started.get(0);
  demand(library.target==LibraryActivity.class,"idle launch did not route to LibraryActivity");
  demand((library.flags&Intent.FLAG_ACTIVITY_NEW_TASK)!=0,"library route missing NEW_TASK (would land in the trampoline task)");
  demand(Activity.finishes==1,"trampoline did not finish on idle route");
  // 暖启动口径：跳板每次都走 onCreate 全新路由，进程复活/重复点击同一结论。
  GameActivity.pid=7777; reset();
  new IconEntryActivity().onCreate(null);
  demand(Activity.started.get(0).target==GameActivity.class,"relaunch while alive lost the game route");
  demand(Activity.contentViews==0,"trampoline showed UI on relaunch");
  System.out.println("PASS icon entry routing: "+checks+" checks");
 } }''',
}

# Edge: bare intent into a cached :game process whose activity was already reaped.
# Real GameActivity + real GameSession compile here; only the Android boundary and
# the superclass are stubbed (stub dir precedes app sources on -sourcepath).
EDGE_STUBS = {
'android/os/Bundle.java': '''package android.os; public class Bundle {}''',
'android/content/Context.java': '''package android.content; public class Context {
 public <T> T getSystemService(Class<T> c){return null;} public String getPackageName(){return "fixture";}
 public Context getApplicationContext(){return this;} }''',
'android/content/Intent.java': '''package android.content; import java.util.*; public class Intent {
 public static final int FLAG_ACTIVITY_NEW_TASK=0x10000000;
 public Class<?> target; public int flags; public final Map<String,String> values=new HashMap<>();
 public Intent(Context c,Class<?> t){target=t;} public Intent addFlags(int f){flags|=f;return this;}
 public Intent putExtra(String k,String v){values.put(k,v);return this;}
 public Intent putExtras(android.os.Bundle b){return this;} public android.os.Bundle getExtras(){return null;}
 public String getStringExtra(String k){return values.get(k);} public boolean hasExtra(String k){return values.containsKey(k);}
 public boolean getBooleanExtra(String k,boolean d){return values.containsKey(k)?Boolean.parseBoolean(values.get(k)):d;} }''',
'android/app/ActivityManager.java': '''package android.app; public class ActivityManager {
 public java.util.List<RunningAppProcessInfo> getRunningAppProcesses(){return null;}
 public static class RunningAppProcessInfo { public String processName; public int pid; } }''',
'android/app/Activity.java': '''package android.app; import android.content.Context;
 public class Activity extends Context { }''',
'org/s2arm/android/MainActivity.java': '''package org.s2arm.android;
 public class MainActivity extends android.app.Activity { }''',
# Only Android stat wiring is substituted: call the real fingerprint's host NIO
# fallback, retaining production session/fingerprint validation paths.
'org/s2arm/android/AndroidFileStamp.java': '''package org.s2arm.android; import java.io.*; import java.lang.reflect.*;
public class AndroidFileStamp {
 public static GameFingerprint.Stamp read(File f) throws IOException {
  try { Method m=GameFingerprint.class.getDeclaredMethod("nioStat",File.class); m.setAccessible(true);
   return (GameFingerprint.Stamp)m.invoke(null,f);
  } catch(InvocationTargetException e) { if(e.getCause() instanceof IOException)throw (IOException)e.getCause();throw new IOException(e.getCause());
  } catch(ReflectiveOperationException e) {throw new IOException(e);} }
 public static void probe(File f) throws IOException {read(f);} }''',
'org/s2arm/android/IconEdgeProbe.java': '''package org.s2arm.android;
import android.content.Context; import android.content.Intent;
public class IconEdgeProbe {
 static int checks;
 static void demand(boolean yes,String message){checks++;if(!yes)throw new AssertionError(message);}
 public static void main(String[] args) {
  Context ctx=new Context();
  Intent bare=new Intent(ctx,GameActivity.class);
  demand(!GameSession.running(),"virgin :game process reported a live session");
  demand(GameActivity.libraryRoute(bare,false),"no-title + no live session must route to library");
  demand(!GameActivity.libraryRoute(bare,true),"no-title + live session must keep red screen");
  Intent titled=new Intent(ctx,GameActivity.class).putExtra(GameActivity.TITLE_EXTRA,"0100000000ABCDEF");
  demand(!GameActivity.libraryRoute(titled,false),"titled launch must not route to library");
  demand(!GameActivity.libraryRoute(titled,true),"titled relaunch must not route to library");
  System.out.println("PASS idle cached-process launch: "+checks+" checks");
 } }''',
}


def activity_block(manifest, name):
    match = re.search(r'<activity android:name="\.' + name + r'"[^>]*(?:/>|>.*?</activity>)', manifest, re.S)
    return match.group(0) if match else ''


def manifest_checks(test, manifest):
    entry = activity_block(manifest, 'IconEntryActivity')
    test.assertIn('action.MAIN', entry)
    test.assertIn('category.LAUNCHER', entry)
    test.assertIn('NoDisplay', entry)
    test.assertIn('noHistory', entry)
    # #1515 复审：taskAffinity="" 让跳板独占临时 task——每次点图标都新建跳板、都路由；
    # 与库页同 taskAffinity 时系统 START_TASK_TO_FRONT 直接带回库页 task，跳板不跑。
    test.assertIn('taskAffinity=""', entry)
    test.assertIn('excludeFromRecents="true"', entry)
    library = activity_block(manifest, 'LibraryActivity')
    test.assertNotIn('action.MAIN', library)
    test.assertNotIn('LAUNCHER', library)
    game = activity_block(manifest, 'GameActivity')
    test.assertIn('excludeFromRecents="true"', game)
    test.assertIn('android:process=":game"', game)
    test.assertIn('singleTask', game)


@unittest.skipIf(JAVAC is None, '需要 JDK 17（android/tools/jdk17.sh）')
class IconEntryTest(unittest.TestCase):

    def run_contract(self, force_library=False):
        manifest = MANIFEST.read_text(encoding='utf-8')
        manifest_checks(self, manifest)
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp)
            (base / 'classes').mkdir()
            sources = []
            for name, code in STUBS.items():
                path = base / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(code, encoding='utf-8')
                sources.append(str(path))
            source = ICON_ENTRY
            if force_library:
                mutant = base / 'org/s2arm/android/IconEntryActivity.java'
                text = source.read_text(encoding='utf-8')
                original = 'gamePid != 0'
                self.assertEqual(text.count(original), 1)
                mutant.write_text(text.replace(original, 'false && gamePid != 0'), encoding='utf-8')
                source = mutant
            compiled = subprocess.run(
                [str(JAVAC), '-encoding', 'UTF-8', '-d', str(base / 'classes'), str(source), *sources],
                capture_output=True, text=True)
            self.assertEqual(compiled.returncode, 0, compiled.stderr)
            return subprocess.run(
                [str(JAVA_BIN), '-cp', str(base / 'classes'), 'org.s2arm.android.IconEntryProbe'],
                capture_output=True, text=True, timeout=20)

    def test_alive_routes_to_game_task_idle_to_library(self):
        result = self.run_contract()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('PASS icon entry routing', result.stdout)

    def test_library_first_route_negative_control(self):
        # 撤守卫：跳板恒走库页 → 存活路由断言必须红（库页先上正是 #1474 的裁局通道）。
        result = self.run_contract(force_library=True)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('alive game did not route to GameActivity', result.stderr)

    def run_edge_contract(self, drop_session_check=False):
        # 接线断言（源码口径）：onCreate 在 admission 红屏前先问 libraryRoute，且传的是
        # 真实的 GameSession.running()；转库页动作 = startActivity(LibraryActivity) + finish。
        main = MAIN_ACTIVITY.read_text(encoding='utf-8')
        self.assertEqual(main.count('GameActivity.libraryRoute(getIntent(), GameSession.running())'), 1)
        # 空实例转库页必须 NEW_TASK：不带会落进 excludeFromRecents 的 :game task（#1515 复审口径）。
        self.assertEqual(main.count('startActivity(new android.content.Intent(this, LibraryActivity.class)\n                    .addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK))'), 1)
        # 跳板控制 extra 必须在 CONTROL_EXTRAS：否则 bare intent 被 isLaunch 当起局、替换库局被 stopGame。
        controls = main[main.index('CONTROL_EXTRAS'):main.index('));', main.index('CONTROL_EXTRAS'))]
        self.assertIn('GameActivity.ICON_RESUME_EXTRA', controls)
        self.assertLess(main.index('libraryRoute(getIntent()'), main.index('Game admission failed'))
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp)
            (base / 'classes').mkdir()
            sources = []
            for name, code in EDGE_STUBS.items():
                path = base / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(code, encoding='utf-8')
                sources.append(str(path))
            activity = JAVA / 'org/s2arm/android/GameActivity.java'
            if drop_session_check:
                mutant = base / 'org/s2arm/android/GameActivity.java'
                text = activity.read_text(encoding='utf-8')
                original = 'intent.getStringExtra(TITLE_EXTRA) == null && !sessionRunning'
                self.assertEqual(text.count(original), 1)
                mutant.write_text(text.replace(original, 'intent.getStringExtra(TITLE_EXTRA) == null'), encoding='utf-8')
                activity = mutant
            session = JAVA / 'org/s2arm/android/GameSession.java'
            compiled = subprocess.run(
                [str(JAVAC), '-encoding', 'UTF-8', '-d', str(base / 'classes'),
                 '-sourcepath', str(base) + ':' + str(JAVA),
                 str(activity), str(session), *sources],
                capture_output=True, text=True)
            self.assertEqual(compiled.returncode, 0, compiled.stderr)
            return subprocess.run(
                [str(JAVA_BIN), '-cp', str(base / 'classes'), 'org.s2arm.android.IconEdgeProbe'],
                capture_output=True, text=True, timeout=20)

    def test_idle_cached_process_routes_to_library(self):
        result = self.run_edge_contract()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('PASS idle cached-process launch', result.stdout)

    def test_idle_route_session_check_negative_control(self):
        # 撤守卫：不看会话状态就转库页 → 活会话被错投库页，断言必须红。
        result = self.run_edge_contract(drop_session_check=True)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('no-title + live session must keep red screen', result.stderr)


if __name__ == '__main__':
    unittest.main(verbosity=2)
