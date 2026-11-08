#!/usr/bin/env python3
# 门禁手动：真机生命周期测试需已安装的匹配游戏包、私有 revision 与设备租约；设备验收单独运行
"""Layer-2 S0 lifecycle gate. Requires an installed game runtime and privately imported revision.

Build the matching test APK with -Ps2arm.testRunner=org.s2arm.android.GameSessionLifecycleInstrumentation.
Never installs/replaces the game APK. Missing device/private inputs is INCOMPLETE (exit 2), never PASS.
"""
import argparse
import json
import re
import sys
import time
from pathlib import Path

RUNNER = 'org.s2arm.android.GameSessionLifecycleInstrumentation'


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--serial')
    p.add_argument('--package')
    p.add_argument('--title-id')
    p.add_argument('--content-root')
    p.add_argument('--artifact-sha256')
    p.add_argument('--test-apk', type=Path)
    p.add_argument('--device-tools', type=Path, default=Path('/tmp/sgm-s2arm-games/tools'))
    p.add_argument('--out', type=Path)
    a = p.parse_args()
    required = (a.serial, a.package, a.title_id, a.content_root, a.artifact_sha256, a.test_apk, a.out)
    if not all(required):
        print('INCOMPLETE: explicit device, installed package/title/contentRoot/artifact SHA, matching test APK and fresh --out required')
        return 2
    if not (re.fullmatch(r'org\.s2arm\.(android|game\.t[0-9a-f]{16})', a.package)
            and re.fullmatch(r'[0-9A-F]{16}', a.title_id)
            and re.fullmatch(r'sha256-[0-9a-f]{64}', a.content_root)
            and re.fullmatch(r'[0-9a-f]{64}', a.artifact_sha256)):
        p.error('invalid identity')
    if not a.test_apk.is_file() or not (a.device_tools / 'lease.py').is_file():
        print('INCOMPLETE: missing signed test APK or canonical lease tooling')
        return 2
    # Existing output is evidence; refuse to overwrite it.
    a.out.mkdir(parents=True, exist_ok=False)
    sys.path.insert(0, str(a.device_tools))
    from lease import Lease
    from common import Adb
    report = {'passed': False, 'runner': RUNNER, 'package': a.package, 'titleId': a.title_id,
              'contentRoot': a.content_root, 'artifactSha256': a.artifact_sha256, 'device': a.serial}
    with Lease(a.serial, task='S0 lifecycle layer-2') as lease:
        adb = Adb(a.serial, lease)

        def residual():
            packages = [x[8:].strip() for x in adb.text('pm list packages org.s2arm.game').splitlines() if x.startswith('package:')]
            packages = sorted(set(packages + [a.package]))
            games = adb.text('pidof ' + ' '.join(x for pkg in packages for x in (pkg, pkg + ':game')), allowed=(0, 1)).strip()
            records = adb.text('pidof screenrecord', allowed=(0, 1)).strip()
            return games, records

        # Anything already running is not ours. Keep the lease, request coordination, never kill it.
        while any(residual()):
            print('NOT ZERO before S0: retaining canonical lease; notify device coordinator; existing processes are not owned', flush=True)
            time.sleep(5)
        started = False
        try:
            current = json.loads(adb.text(f'run-as {a.package} cat files/games/{a.title_id}/current.json'))
            if current['contentRoot'] != a.content_root or current['artifactSha256'] != a.artifact_sha256:
                raise RuntimeError('installed private revision does not match the frozen layer-2 inputs')
            adb.run(['install', '-r', str(a.test_apk)], timeout=120)
            started = True
            output = adb.run(['shell', 'am', 'instrument', '-w', '-r', '-e', 'titleId', a.title_id,
                              a.package + '.test/' + RUNNER], timeout=600).decode(errors='replace')
            (a.out / 'instrumentation.log').write_text(output)
            report['passed'] = 'INSTRUMENTATION_RESULT: passed=true' in output and 'INSTRUMENTATION_FAILED' not in output
        except Exception as error:
            report['error'] = str(error)
        finally:
            if started:
                game_before = adb.text(f'pidof {a.package}:game', allowed=(0, 1)).strip()
                report['forced_game_cleanup'] = bool(game_before)
                # Instrumentation's finally first requests normal retirement. A remaining child is a FAIL.
                if game_before:
                    report['passed'] = False
                adb.shell(f'am force-stop {a.package}', allowed=None)
            while True:
                games, records = residual()
                report.update(game_processes_after=games or None, screenrecord_after=records or None,
                              lease_holder_pid=lease.info['pid'])
                (a.out / 'result.json').write_text(json.dumps(report, indent=2) + '\n')
                if not games and not records:
                    break
                print('NOT ZERO: retaining canonical lease; notify device coordinator; no reboot/no foreign kill', flush=True)
                time.sleep(5)
    print('PASS' if report['passed'] else 'FAIL', a.out / 'result.json')
    return 0 if report['passed'] else 1


if __name__ == '__main__':
    sys.exit(main())
