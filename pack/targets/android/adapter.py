"""Android target adapter on the existing local job and oneclick pipeline."""
from __future__ import annotations

import json
import os
from pathlib import Path
import platform
import shutil
import tempfile

from pack.contracts.validate import ContractError, validate


def check_request(request):
    validate('request', request)
    if request.get('targetId') != 'android' or request.get('operation') != 'android':
        raise ContractError('Android 宿主目标只接受 targetId=android / operation=android。')
    if not all(request.get(k) for k in ('gameId', 'library', 'libraryId')):
        raise ContractError('Android 任务缺少游戏或游戏库身份。')
    system, arch = platform.system(), platform.machine()
    if (system, arch) not in {('Darwin', 'arm64'), ('Linux', 'x86_64'), ('Linux', 'aarch64')}:
        raise ContractError('Android 宿主目标需要 Apple Silicon Mac 或 Linux x64/arm64。')


def copy_selected(c, packages, stage):
    """Use the library's recorded source identities for this job's private input."""
    from core import Failure, clone, contained, digest
    seen = {}
    for item in packages:
        source = contained(c.library, c.library / item['path'])
        expected = item['sha256']
        if source in seen:
            if seen[source] != expected:
                raise Failure('游戏库中的同一文件身份不一致，请重新导入。', code='content_invalid')
            continue
        seen[source] = expected
        c.check()
        if digest(source, c.progress) != expected:
            raise Failure('托管游戏文件内容已变化，请重新导入。', code='content_invalid')
        destination = stage / source.name
        clone(source, destination)
        if digest(destination, c.progress) != expected:
            raise Failure('游戏文件复制后身份不符，请重试。', code='content_invalid')


def build(c):
    from core import Failure, contained
    from library import require_game, selected_packages
    from ipa import dotnet_sdk, oneclick_result
    from pack.targets.android.package import verify_manifest

    with c.lock('execution'):
        c.begin('检查游戏输入')
        gid = c.r.get('gameId') or ''
        game = next((g for g in c.catalog()['games'] if g['id'] == gid), None)
        if not game:
            raise Failure('游戏库里没有这款游戏。')
        require_game(c, game)
        home, exe = dotnet_sdk()
        if not exe:
            raise Failure('安卓出包需要 .NET 10 SDK，请先在设置中准备环境。', code='dotnet_sdk_missing')
        fonts = c.fonts_dir()
        if fonts is None:
            raise Failure('没有共享字体：指定含 .bfttf 文件的字体目录，或先安装 pack/fonts/requirements.txt 并运行 python3 pack/fonts/make_open_fonts.py <目录> 生成开源替代字体。')
        out = contained(c.library, c.library / 'Android' / gid)
        out.mkdir(parents=True, exist_ok=True)
        stage = Path(tempfile.mkdtemp(prefix='android-src-', dir=c.private))
        events = c.private / 'logs' / (c.task + '-android.events.jsonl')
        events.parent.mkdir(parents=True, exist_ok=True)
        events.write_text('')
        try:
            copy_selected(c, selected_packages(game), stage)
            c.begin('安卓出包')
            env = c.env()
            for name in tuple(env):
                if name.startswith('DOTNET_ROOT_'):
                    env.pop(name)
            env.update(DOTNET=str(exe), DOTNET_ROOT=str(home), DOTNET_MULTILEVEL_LOOKUP='0',
                       PATH=os.pathsep.join(dict.fromkeys([str(exe.parent), str(home), env['PATH']])))
            args = ['bash', c.engine / 'pack/oneclick/oneclick.sh', stage, '--target', 'android',
                    '--keys', c.keys, '--fonts', fonts, '--out', out, '--title-id', gid, '--events', events]
            if c.r.get('installSerial'):
                args += ['--install-serial', c.r['installSerial']]
            c.run(args, c.private / 'logs' / (c.task + '-android.log'), env=env)
            result = oneclick_result(events) or {}
            if not result.get('ok'):
                raise Failure('安卓出包没有报告本轮交付物。')
            apk = contained(out, Path(result['apk']))
            resources = contained(out, Path(result['pack']))
            ledger = contained(out, Path(result['artifact']))
            if apk.parent != resources.parent or ledger.parent != apk.parent:
                raise Failure('安卓交付物不在同一版本目录。')
            computed = verify_manifest(apk.parent, apk, resources, json.loads(ledger.read_text()))
            return dict(target='android', outputPath=str(apk.parent), apk=str(apk),
                        resources=str(resources), artifactManifest=computed)
        except (OSError, KeyError, ValueError, ContractError) as error:
            raise Failure('安卓交付物校验失败，请查看任务日志。', code='artifact_invalid') from error
        finally:
            shutil.rmtree(stage, ignore_errors=True)
