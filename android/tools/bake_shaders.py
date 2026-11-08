#!/usr/bin/env python3
"""安卓出包·离线 Vulkan 着色器包烘焙阶段（#1574）：

  bake_shaders.py <make_pack 包目录> --root <产物根> --profile <设备导出的 profile.json>
      --out <新工作目录> [--extract <已有抽取目录>] [--ref <Ryujinx 参考缓存目录>]…
      [-j N] [--dotnet <dotnet 路径>] [--spirv-val <spirv-val 路径>]

输出根 = <out>/pack（vulkan/generic/<profileKey>/{manifest.json, profile.json, shcache/}），
与 attach_shaders.py / assets/game/shaders.zip 读的形态一致；抽取、程序表与日志留在 <out>/ 下。
摘要写 <out>/bake.json 并打印末行（pack、profileKey、files、bytes）；包里没有可抽的着色器时
pack 为 null——调用方据此跳过挂接与资产打包，不生成空包。

为什么放在出包期而不是 refresh 的共享着色器阶段（pack/stages/shaders.sh）：离线包 manifest
绑定的是「安装 revision 的内容身份」（ShaderPackLayout.GameContentRoot = index.tsv 去掉
shaders/ 行，modules/ 行不装进资源包）。这个身份要等 make_pack 写出 index.tsv 才存在，
refresh 阶段拿不到包，烘焙只能放在出包期。共享流水线的每一环原样复用：抽取
（extract/s2x 复用或 graphics/tools/shbake/nxsh_extract.py）、各程序表读取器与
S2A_PROG_TABLE / S2A_PAIR_TABLE / S2A_NO_ALPHA_VARIANTS 开关（与 graphics/tools/shader_pack.sh
同一套条件）、烘焙器（S2A.ShBake bake --vulkan-profile）、挂接（attach_shaders.py）与
内容身份（direct_library.index_content_root）；本文件只做安卓出包期的接线。

profile 只能来自真机导出（运行时在 S2A_SHADER_PROFILE_OUT 下写真实 profile，见
graphics/vulkan/cache/README.md 与 android/docs/autonomous-game-run.md §4 P2）：
host 不能猜设备能力，没有 profile 不出包，不伪造命中。
"""
import argparse, hashlib, json, os, re, shutil, subprocess, sys
from pathlib import Path

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, '..', '..'))
sys.path.insert(0, HERE)
import direct_library   # noqa: E402  内容身份只有这一份实现（安装 revision 的 GameContentRoot 同值）

INDEX = 'index.tsv'
MANIFEST = 'manifest.json'
ARTIFACT = 'game-build-artifact.json'
SHBAKE = os.path.join(REPO, 'graphics/tools/shbake')
HELPER_TIMEOUT = 900   # 同 shader_pack.sh 各辅助步的 TIMEOUT_BIN 900


def _red(message):
    sys.exit('【红】' + message)


def _log(command, name, out_dir, env, timeout=HELPER_TIMEOUT):
    """跑共享流水线的辅助步：输出写 <out>/<name>.log，失败报红带上末行。"""
    try:
        result = subprocess.run(command, env=env, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        _red(f'{name} 超过 {timeout} 秒未完成')
    log = Path(out_dir, f'{name}.log')
    log.write_text((result.stdout or '') + (result.stderr or ''), encoding='utf-8')
    if result.returncode:
        tail = log.read_text(encoding='utf-8', errors='replace').strip().splitlines()
        _red(f'{name} 失败（rc={result.returncode}，{log}）：{tail[-1] if tail else "no output"}')
    return result


def _rows_text(extract_dir):
    rows_path = Path(extract_dir, 'rows.tsv')
    if not rows_path.is_file():
        _red(f'抽取目录 {extract_dir} 没有 rows.tsv')
    return rows_path.read_text(encoding='utf-8', errors='replace')


def package_content_root(package):
    """绑定用的内容身份：index 去掉 shaders/ 与 modules/ 行的规范哈希（安装 revision 同值）。"""
    with open(os.path.join(package, MANIFEST), encoding='utf-8') as stream:
        manifest = json.load(stream)
    if manifest.get('version') != 2:
        _red(f'{package}: manifest.json is not version 2')
    index_path = os.path.join(package, INDEX)
    with open(index_path, 'rb') as stream:
        raw = stream.read()
    if hashlib.sha256(raw).hexdigest() != manifest.get('index_sha256'):
        _red(f'{package}: index.tsv does not match manifest.json')
    return direct_library.index_content_root(direct_library.read_index(index_path))


def package_title(package):
    try:
        artifact = json.loads(Path(package, ARTIFACT).read_text(encoding='utf-8'))
    except (OSError, ValueError) as error:
        _red(f'{package}: {ARTIFACT} 读不出：{error}')
    title = artifact.get('titleId')
    if not isinstance(title, str) or not direct_library.TITLE_ID.fullmatch(title):
        _red(f'{package}: {ARTIFACT} titleId 无效：{title}')
    return title.upper()


def resolve_dotnet(env):
    """与 APK 构建同一份固定 SDK（cs/build.sh 的解析 / 引导），不用 PATH 上随手捡的版本。"""
    result = subprocess.run(['bash', os.path.join(REPO, 'android/cs/build.sh'),
                             '--print-dotnet'], env=env, capture_output=True, text=True)
    if result.returncode:
        tail = (result.stderr or result.stdout).strip().splitlines()
        _red('固定 .NET SDK 解析失败：' + (tail[-1] if tail else 'no output'))
    lines = [line.strip() for line in result.stdout.splitlines() if line.strip()]
    if not lines:
        _red('固定 .NET SDK 解析没有给出 dotnet 路径')
    return lines[-1]


def copy_tree(source, destination):
    """克隆已有抽取结果（extract/s2x → <out>/extract）；mac 用 copyfile clone 省盘。"""
    if sys.platform == 'darwin':
        result = subprocess.run(['cp', '-cR', str(source), str(destination)],
                                capture_output=True, text=True)
        if not result.returncode:
            return
    shutil.copytree(source, destination)


def extract_shaders(root, destination, env):
    """抽着色器只做一次（10-25 jhz）：抽取阶段出过 <产物根>/extract/s2x（有 ok）就复用，
    否则 nxsh_extract 现场抽（romfs + aoc/*/ + exefs/main，同 shader_pack.sh）。"""
    staged = Path(root, 'extract', 's2x')
    staged_rows = staged / 'rows.tsv'
    if Path(root, 'extract', 'ok').is_file() and staged_rows.is_file() and staged_rows.stat().st_size:
        copy_tree(staged, destination)
        return
    romfs, main = Path(root, 'romfs'), Path(root, 'exefs', 'main')
    if not romfs.is_dir() or not main.is_file():
        _red(f'产物根 {root} 没有 romfs/ 或 exefs/main')
    aoc_root = Path(root, 'aoc')
    aocs = sorted(str(p) for p in aoc_root.iterdir() if p.is_dir()) if aoc_root.is_dir() else []
    command = [sys.executable, os.path.join(SHBAKE, 'nxsh_extract.py'),
               str(destination), str(romfs), *aocs, '--nso', str(main)]
    _log(command, 'nxsh_extract', Path(destination).parent, env)


def program_tables(root, extract_dir, out_dir, env):
    """shader_pack.sh ①b/①b'/①c 的同一套程序表：条件 grep rows.tsv、同样工具、同样输出键——
    返回烘焙时要带的 S2A_* 环境开关。认不出 = 本款不适用、不出表（同主干口径）。"""
    rows = _rows_text(extract_dir)
    romfs, main, exefs = str(Path(root, 'romfs')), str(Path(root, 'exefs', 'main')), str(Path(root, 'exefs'))
    produced = {}

    def tool(name, out_name, command):
        target = Path(out_dir, out_name)
        _log([sys.executable, os.path.join(SHBAKE, name), *command],
             out_name.split('.')[0], out_dir, env)
        return target if target.is_file() and target.stat().st_size else None

    if '@shad' in rows:
        produced['pair'] = tool('exe_programs.py', 'programs_exe.tsv',
                                [main, str(Path(extract_dir, 'rows.tsv')),
                                 str(Path(out_dir, 'programs_exe.tsv'))])
    table_parts = []
    if 'shadernx.cache@zs' in rows:
        table_parts.append(tool('rdhs_programs.py', 'programs_rdhs.tsv',
                                [str(Path(extract_dir, 'rows.tsv')), romfs,
                                 '-o', str(Path(out_dir, 'programs_rdhs.tsv')), '--stat', '--vs-only']))
    table_parts.append(tool('file_pairs.py', 'programs_files.tsv',
                            [str(Path(extract_dir, 'rows.tsv')),
                             str(Path(out_dir, 'programs_files.tsv'))]))
    if '@ue0x' in rows:
        table_parts.append(tool('ue_programs.py', 'programs_ue.tsv',
                                [str(Path(extract_dir, 'rows.tsv')), romfs, main,
                                 '-o', str(Path(out_dir, 'programs_ue.tsv'))]))
    if 'staticshadernx.cache@zs' in rows:
        table_parts.append(tool('red_static_programs.py', 'programs_red.tsv',
                                [main, str(Path(extract_dir, 'rows.tsv')), romfs,
                                 '-o', str(Path(out_dir, 'programs_red.tsv'))]))
    if re.search(r'^nso:[^@]*@adj0x', rows, re.M):
        table_parts.append(tool('exe_shtab_programs.py', 'programs_shtab.tsv',
                                [main, str(Path(extract_dir, 'rows.tsv')),
                                 '-o', str(Path(out_dir, 'programs_shtab.tsv'))]))

    switches = {}
    merged = Path(out_dir, 'programs_table.tsv')
    parts = [part for part in table_parts if part]
    if parts:
        with open(merged, 'w', encoding='utf-8', newline='\n') as stream:
            for part in parts:
                stream.write(part.read_text(encoding='utf-8'))
        if any(line.strip() and not line.startswith('#') for line in merged.read_text().splitlines()):
            switches['S2A_PROG_TABLE'] = str(merged)
    if produced.get('pair'):
        switches['S2A_PAIR_TABLE'] = str(produced['pair'])

    try:
        result = subprocess.run([sys.executable, os.path.join(SHBAKE, 'nvn_uses.py'), exefs],
                                env=env, capture_output=True, text=True, timeout=600)
        Path(out_dir, 'nvn_uses.log').write_text(result.stderr or '', encoding='utf-8')
        uses = json.loads(result.stdout) if not result.returncode else {}
    except (subprocess.TimeoutExpired, ValueError):
        uses = {}
    Path(out_dir, 'nvn_uses.json').write_text(json.dumps(uses), encoding='utf-8')
    if uses.get('ok') and uses.get('SetAlphaTest') == 0:
        switches['S2A_NO_ALPHA_VARIANTS'] = '1'   # 游戏不设透明测试：不出「开」变体（同共享口径）
    return switches


def program_rows(extract_dir):
    return [line for line in _rows_text(extract_dir).splitlines()
            if line and not line.startswith('#')]


def build_shbake(env, dotnet):
    binary = os.path.join(REPO, 'build/shbake/S2A.ShBake')
    if os.access(binary, os.X_OK):
        return binary
    project = os.path.join(SHBAKE, 'S2A.ShBake.csproj')
    result = subprocess.run([dotnet, 'build', project, '-c', 'Release', '-nologo'],
                            env=env, capture_output=True, text=True)
    if result.returncode or not os.access(binary, os.X_OK):
        tail = (result.stderr + result.stdout).strip().splitlines()
        _red('S2A.ShBake 编译失败：' + (tail[-1] if tail else 'no output'))
    return binary


def profile_pack(pack_out):
    generic = Path(pack_out, 'vulkan', 'generic')
    if not generic.is_dir():
        return None, None
    profiles = sorted(name for name in os.listdir(generic)
                      if (generic / name / MANIFEST).is_file())
    if len(profiles) != 1:
        _red(f'{pack_out}: vulkan/generic/ 下应恰有一个 <profileKey>/manifest.json，实得 {len(profiles)} 个')
    return str(generic / profiles[0]), profiles[0]


def bake(package, root, profile, out, extract_dir=None, refs=(), jobs=None, dotnet=None, spirv_val=None):
    package = os.path.abspath(package)
    root = os.path.abspath(root)
    out = os.path.abspath(out)
    if os.path.lexists(out):
        _red(f'输出目录已存在：{out}（新目录才收本阶段产物，不覆盖旧证据）')
    if not os.path.isfile(profile):
        _red(f'--profile 读不到：{profile}（要真机 S2A_SHADER_PROFILE_OUT 导出的 profile.json，不能手写）')
    for ref in refs:
        if not os.path.isdir(ref):
            _red(f'--ref 不是目录：{ref}')
    content_root = package_content_root(package)
    title = package_title(package)
    env = dict(os.environ, DOTNET_gcServer='1', DOTNET_GCHeapHardLimit='0x200000000')
    os.makedirs(out)
    if extract_dir is None:
        extract_dir = os.path.join(out, 'extract')
        extract_shaders(root, extract_dir, env)
    rows = program_rows(extract_dir)
    if not rows:
        summary = {'pack': None, 'reason': '抽取 0 支着色器：本款没有可离线翻译的程序'}
        Path(out, 'bake.json').write_text(json.dumps(summary, ensure_ascii=False) + '\n',
                                          encoding='utf-8')
        print(json.dumps(summary, ensure_ascii=False))
        return summary
    env.update(program_tables(root, extract_dir, out, env))
    binary = build_shbake(env, dotnet or resolve_dotnet(env))
    pack_out = os.path.join(out, 'pack')
    command = [binary, 'bake', extract_dir, pack_out, '--title', title,
               '--vulkan-profile', os.path.abspath(profile), '--content-root', content_root,
               '-j', str(jobs or os.cpu_count() or 1)]
    for ref in refs:
        command += ['--ref', os.path.abspath(ref)]
    if spirv_val:
        command += ['--spirv-val', spirv_val]
    result = subprocess.run(command, env=env)   # 烘焙可能跑很久：输出直通终端，进度可见
    if result.returncode:
        _red(f'S2A.ShBake 烘焙失败（rc={result.returncode}）')
    pack_dir, key = profile_pack(pack_out)
    if pack_dir is None:
        _red(f'S2A.ShBake 退出 0 但没有 vulkan/generic/ 产出：{pack_out}')
    manifest = json.loads(Path(pack_dir, MANIFEST).read_text(encoding='utf-8'))
    if manifest.get('contentRoot') != content_root:
        _red(f'烘焙产物的 contentRoot（{manifest.get("contentRoot")}）与包内容身份（{content_root}）不符')
    files = [(os.path.relpath(p, pack_out).replace(os.sep, '/'), p.stat().st_size)
             for p in sorted(Path(pack_out).rglob('*')) if p.is_file()]
    summary = {'pack': pack_out, 'profileKey': key, 'programs': len(rows),
               'contentRoot': content_root, 'files': len(files),
               'bytes': sum(size for _, size in files)}
    Path(out, 'bake.json').write_text(json.dumps(summary, ensure_ascii=False) + '\n',
                                      encoding='utf-8')
    print(json.dumps(summary, ensure_ascii=False))
    return summary


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('package')
    parser.add_argument('--root', required=True, help='刷新产物根（romfs / exefs/main / aoc）')
    parser.add_argument('--profile', required=True, help='真机导出的 Vulkan 翻译 profile.json')
    parser.add_argument('--out', required=True, help='新工作目录（<out>/pack 是挂接输入）')
    parser.add_argument('--extract', help='已有抽取目录（rows.tsv + src/*.pk）；缺省优先复用 '
                                          '<root>/extract/s2x，再不行现场抽')
    parser.add_argument('--ref', action='append', default=[], help='Ryujinx 参考缓存目录，可多次')
    parser.add_argument('-j', '--jobs', type=int)
    parser.add_argument('--dotnet', help='dotnet 路径；缺省用 cs/build.sh 解析的固定 SDK')
    parser.add_argument('--spirv-val', help='spirv-val 路径（逐支 SPIR-V 校验，建议给）')
    args = parser.parse_args()
    try:
        bake(args.package, args.root, args.profile, args.out, extract_dir=args.extract,
             refs=args.ref, jobs=args.jobs, dotnet=args.dotnet, spirv_val=args.spirv_val)
    except (OSError, KeyError, ValueError, json.JSONDecodeError) as error:
        _red('离线着色器阶段失败：' + str(error))
    return 0


if __name__ == '__main__':
    sys.exit(main())
