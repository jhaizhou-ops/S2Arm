#!/usr/bin/env python3
"""Device-free deployment contract; Activity/runtime behavior is exercised by instrumentation."""
from pathlib import Path
import sys
import subprocess
import xml.etree.ElementTree as ET

def check(path):
    a = '{http://schemas.android.com/apk/res/android}'
    root = ET.parse(path).getroot()
    application = root.find('./application')
    assert application is not None, 'manifest must have an application'
    assert application.attrib.get(a+'appCategory') == 'game', 'application appCategory must be literal game'
    activities = {node.attrib[a+'name']: node for node in root.findall('./application/activity')}
    game = activities['.GameActivity']
    for key, value in {'process': ':game', 'exported': 'false', 'launchMode': 'singleTask',
                       'taskAffinity': '${applicationId}.game', 'excludeFromRecents': 'true'}.items():
        assert game.attrib.get(a+key) == value, f'GameActivity {key} must be {value}'
    launchers = [name for name, node in activities.items() if any(
        c.attrib.get(a+'name') == 'android.intent.category.LAUNCHER' for c in node.findall('./intent-filter/category'))]
    assert launchers == ['.IconEntryActivity'], 'the launcher must be the headless trampoline (#1474)'
    entry = activities['.IconEntryActivity']
    assert entry.attrib.get(a+'theme') == '@android:style/Theme.NoDisplay', 'trampoline must never show UI'
    assert entry.attrib.get(a+'noHistory') == 'true', 'trampoline must not stay in recents/back stack'
    assert entry.attrib.get(a+'taskAffinity') == '', 'trampoline must own a private task or repeated icon taps skip it (#1515)'
    assert entry.attrib.get(a+'excludeFromRecents') == 'true', 'trampoline task must never appear in recents'
    assert '.MainActivity' in activities, 'retain the compatibility/diagnostic entry'

if __name__ == '__main__':
    check(sys.argv[1] if len(sys.argv)>1 else Path(__file__).parents[1]/'app/src/main/AndroidManifest.xml')
    repo = Path(__file__).resolve().parents[2]
    entry = repo/'android/tests/t_game_session_lifecycle.py'
    registry = (repo/'tools/contrib_layer2.tsv').read_text()
    assert 'GameSessionLifecycleInstrumentation' in registry and entry.name in registry, 'lifecycle layer-2 command must be registered'
    r = subprocess.run([sys.executable, str(entry)], capture_output=True, text=True)
    assert r.returncode == 2 and 'INCOMPLETE' in r.stdout, 'missing device/private inputs must remain incomplete'
    assert 'GameSessionLifecycleInstrumentation' in entry.read_text(), 'registered entry must invoke the lifecycle runner'
    instrument = (repo/'android/app/src/androidTest/java/org/s2arm/android/GameSessionLifecycleInstrumentation.java').read_text()
    assert instrument.count('play(title);') == 2 and 'getUiAutomation()' in instrument, 'cold/resume must click actual Library Play'
    assert 'putExtra(GameActivity.REVISION_EXTRA,true), title)' not in instrument, 'no internal launch bypass for positive lifecycle'
    assert 'backgroundAndResume(context,pid,title,"cold startup",false)' in instrument and 'backgroundAndResume(context,pid,title,"running guest " + cycle,cycle == 1)' in instrument, 'test bootstrap and steady-state Library/HOME background'
    assert 'cycle < 3' in instrument and 'presents(context,pid) >= 30' in instrument, 'repeat steady-state after actual presents'
    assert 'awaitLive(context,pid,' in instrument and 'game-lifecycle-test.tsv' in instrument, 'record phase boundaries and fail immediately on admitted PID death'
    assert 'KEYCODE_HOME' in instrument and 'CATEGORY_HOME' not in instrument, 'HOME must use key injection, independent of a resolved HOME Activity'
    assert instrument.index('SessionLogEvidence.capture(') < instrument.index('SessionExitEvidence.requireClean('), 'persist current PID host evidence before the clean-exit assertion'
    assert 'SessionExitEvidence.select(' in instrument and 'getProcessStateSummary()' in instrument and 'getTimestamp()' in instrument, 'exit selection must bind current PID/start summary/time'
    assert '.get(0)' not in instrument and 'getHistoricalProcessExitReasons(context.getPackageName(),pid,1)' not in instrument, 'a previous same-PID record cannot complete the wait'
    assert 'presents(context,pid) > 0' in instrument and 'presents(context,pid) > before' in instrument, 'worker-accepted is insufficient: real presents must resume'
    activity = (repo/'android/app/src/main/java/org/s2arm/android/MainActivity.java').read_text()
    assert 'lastLifecyclePresent = NativeBridge.gamePresentCount()' in activity and 'count > lastLifecyclePresent' in activity, 'present receipt must observe a new native counter value'
    assert 'setProcessStateSummary(birth.summary())' in activity and 'game-process-' in activity, 'debug lifecycle receipt must bind the exact process birth into exit metadata'
    native = (repo/'android/native/bridge.cpp').read_text()
    start = native.index('Java_org_s2arm_android_NativeBridge_gamePresentCount(')
    end = native.index('#endif', start)
    body = native[start:end]
    assert body.index('status.last_phase < S2A_RUNTIME_GUEST_RUNNING') < body.index('s2a_android_services_present_count()'), 'diagnostics cannot initialize NativeAOT before native startup'
    print('Game process manifest: PASS (static only; PID/Surface/exit need instrumentation)')
