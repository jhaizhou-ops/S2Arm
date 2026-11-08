#!/usr/bin/env python3
# 门禁手动：APP 测试壳的离线 fake-adb 结果校验回归；仅显式运行，不接设备门禁。
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""Offline fake-adb validation of readback checks; never touches a device."""
import os
from pathlib import Path
import subprocess
import tempfile

RUNNER = Path(__file__).resolve().parents[1] / "run.sh"
FAKE = r'''#!/usr/bin/env python3
import os,sys
from pathlib import Path
args=sys.argv[1:];case=os.environ['FAKE_CASE'];entry=os.environ['FAKE_ENTRY']
with open(os.environ['FAKE_CALLS'],'a') as f:f.write(' '.join(args)+'\n')
if args[2:5]==['shell','am','instrument']:
 path='/data/user/0/org.s2arm.probe.savecommit.moongrant/files/'+entry+'-123'
 if case=='wrong-suite':path=path.replace('/Managed-','/Native-')
 if case=='wrong-package':path=path.replace('.moongrant/','.other/')
 if case=='unsafe-path':path+=';echo_bad'
 print('INSTRUMENTATION_RESULT: run_directory='+path)
 print('INSTRUMENTATION_RESULT: suite='+entry)
 if case!='missing-terminal':
  print('INSTRUMENTATION_RESULT: harness_state='+('EXCEPTION' if case=='java-exception' else 'JNI_RETURNED'))
  print('INSTRUMENTATION_RESULT: wrapper_return_code='+('7' if case=='wrapper-failure' else '0'))
  print('INSTRUMENTATION_CODE: '+('0' if case in ('java-exception','cancelled') else '-1'))
 if case=='java-exception':print('INSTRUMENTATION_RESULT: exception=Cannot persist own test evidence')
 if case=='aborted':print('INSTRUMENTATION_ABORTED: process crashed')
 if case=='failed':print('INSTRUMENTATION_FAILED: process crashed')
 if case=='duplicate-terminal':print('INSTRUMENTATION_CODE: -1')
elif args[2:4]==['shell','run-as']:
 name=args[-1].rsplit('/',1)[-1]
 if name=='status.txt':
  sha=('b' if case=='wrong-source' else 'a')*40
  domain='shell' if case=='wrong-domain' else 'untrusted_app'
  print('source_commit='+sha+'\nstate=RETURNED\nsuite_return_code=0\nselinux=u:r:'+domain+':s0')
  if case=='cleanup-error':print('state=CLEANUP_ERROR')
 elif name=='stdout.log':
  print('savecommit managed: '+('20' if case=='short-count' else '21')+' checks, 0 failures')
else:sys.exit(2)
'''
with tempfile.TemporaryDirectory(prefix="savecommit-runner-unit-") as temporary:
    root = Path(temporary)
    adb = root / "fake-adb"
    adb.write_text(FAKE)
    adb.chmod(0o700)
    cases = [("native", "ok", 0), ("managed", "ok", 0)]
    cases += [("managed", case, 1) for case in (
        "wrong-suite", "wrong-package", "unsafe-path", "wrong-source",
        "wrong-domain", "cleanup-error", "short-count", "java-exception",
        "missing-terminal", "cancelled", "wrapper-failure", "aborted", "failed", "duplicate-terminal")]
    for index, (suite, case, expected) in enumerate(cases):
        calls = root / f"calls-{index}"
        environment = dict(os.environ, ADB=str(adb), ANDROID_SERIAL="synthetic-no-device",
                           RUN_DIR=str(root / f"result-{index}"), EXPECTED_SOURCE_ID="a" * 40,
                           FAKE_CASE=case, FAKE_ENTRY=suite.title(), FAKE_CALLS=str(calls))
        result = subprocess.run(["bash", str(RUNNER), suite], env=environment,
                                capture_output=True, text=True, timeout=10)
        assert result.returncode == expected, (suite, case, result.returncode, result.stdout, result.stderr)
        if case in ("wrong-suite", "wrong-package", "unsafe-path"):
            assert "run-as" not in calls.read_text(), "Unexpected readback after path refusal"
        print(f"PASS {suite}/{case}: exit {result.returncode}")
    # One-variable negative control: remove only the managed count guard in a copy.
    source = RUNNER.read_text()
    start = source.index('    if [ "$entry" = Managed ]')
    end = source.index('    cat "$RUN_DIR/', start)
    broken = root / "run-without-count.sh"
    broken.write_text(source[:start] + source[end:])
    environment.update(RUN_DIR=str(root / "negative"), FAKE_CASE="short-count")
    result = subprocess.run(["bash", str(broken), "managed"], env=environment,
                            capture_output=True, text=True, timeout=10)
    assert result.returncode == 0, "Negative control did not reproduce false success"
    print("PASS effective negative control: missing count guard falsely accepts 20/21")
    # Remove only the new Java/framework guard: a failed Java terminal state must
    # become a false success again even though all native evidence is successful.
    start = source.index('    # Require framework and Java completion')
    end = source.index('    # Never equate adb/am exit zero', start)
    broken = root / "run-without-terminal.sh"
    broken.write_text(source[:start] + source[end:])
    environment.update(RUN_DIR=str(root / "negative-terminal"), FAKE_CASE="java-exception")
    result = subprocess.run(["bash", str(broken), "managed"], env=environment,
                            capture_output=True, text=True, timeout=10)
    assert result.returncode == 0, "Terminal negative control did not reproduce false success"
    print("PASS effective negative control: missing terminal guard falsely accepts Java exception")
print(f"PASS {len(cases)} fake-adb cases and two effective negative controls; no device execution")
