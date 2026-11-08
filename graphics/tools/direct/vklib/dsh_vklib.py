#!/usr/bin/env python3
# 出包 Vulkan 库工具 dsh_vklib 的启动器（#783 接线，取法同 translator/dsh_batch.py）：从仓库源码按需编 S2A.DshVkLib 到 <仓库>/build/dsh_vklib（dotnet 增量编），
#   dotnet 用安卓构建同一份 SDK（android/cs/build.sh --print-dotnet：S2A_ANDROID_DOTNET → 私有固定 SDK，全新机器按它的校验先引导装好；#783 合入线 11-03 答 ③），不另抄查找顺序；
#   拿 dsh_batch 同一把锁 build/dsh_batch/.lock（两边都编 S2A.Dsh 工程、共用它的 obj/）；SPIRV-Cross 命令行按仓库内源码 graphics/third_party/spirv_cross 编到
#   build/spirv-cross-cli/<源码摘要>/（与 Metal 出库进程内用的 spvc_inproc.py 同一份源码、同一组编译参数，不用 Homebrew 那份）。
#   python3 dsh_vklib.py fp                       → 打印 Vulkan 侧指纹的源码部分 VkFp.V（dotnet msbuild -t:VkFpPrint，只求值不编；pack/stage_direct.sh 安卓目标进键）。
#                                                    完整指纹 VkLib.Fp 还带翻译器指纹 Xfp（dsh_vklib --fp），那部分的输入都在 direct.tsv「入」里、已由阶段键带进，键里不必再算
#   python3 dsh_vklib.py build <dsh_vklib 参数…>  → 编好再以这些参数执行（--pkg / --profile / --out / --nxgal / [--work]；--spirv-cross 由本启动器补）
# 本文件在 vklib/ 下，改它 VkFp 就变（VkFp.targets 收 vklib/ 全部文件）。
import fcntl, hashlib, os, re, subprocess, sys
HERE = os.path.dirname(os.path.abspath(__file__)); ROOT = os.path.abspath(os.path.join(HERE, '..', '..', '..', '..'))
PROJ = os.path.join(HERE, 'S2A.DshVkLib.csproj'); OUT = os.path.join(ROOT, 'build', 'dsh_vklib')
LOCK = os.path.join(ROOT, 'build', 'dsh_batch', '.lock')
XSRC = os.path.join(ROOT, 'graphics', 'third_party', 'spirv_cross')
UNITS = ['main', 'spirv_cross', 'spirv_cfg', 'spirv_parser', 'spirv_cross_parsed_ir', 'spirv_glsl', 'spirv_msl', 'spirv_hlsl', 'spirv_cpp', 'spirv_reflect', 'spirv_cross_util']
FLAGS = ['-O2', '-std=c++14']   # 同 spvc_inproc.py FLAGS（它另加 -fPIC 编成库）


def red(msg):
    sys.exit('[RED] ' + msg)


def dotnet():
    r = subprocess.run(['bash', os.path.join(ROOT, 'android', 'cs', 'build.sh'), '--print-dotnet'], capture_output=True, text=True)
    out = r.stdout.strip().splitlines()
    if r.returncode or not out or not os.access(out[-1], os.X_OK):
        red('no .NET SDK from the Android build (android/cs/build.sh --print-dotnet): ' + (r.stdout + r.stderr).strip()[-400:])
    os.environ.update(DOTNET_CLI_TELEMETRY_OPTOUT='1', DOTNET_NOLOGO='1', DOTNET_SYSTEM_GLOBALIZATION_INVARIANT='1')   # 同 build.sh：安卓构建镜像没有 ICU
    return out[-1]


def fp():
    r = subprocess.run([dotnet(), 'msbuild', PROJ, '-t:VkFpPrint', '-nologo'], capture_output=True, text=True)
    m = re.search(r'^\s*VKFP=([0-9a-f]{16})\s*$', r.stdout, re.M)
    if r.returncode or not m: red('VkFpPrint gave no fingerprint: ' + (r.stdout + r.stderr).strip()[-400:])
    return m.group(1)


def spirv_cross():
    h = hashlib.sha256()
    for n in sorted(os.listdir(XSRC)):
        p = os.path.join(XSRC, n)
        if os.path.isfile(p) and n.endswith(('.cpp', '.hpp', '.h')): h.update(n.encode() + b'\0' + open(p, 'rb').read() + b'\0')
    h.update(' '.join(FLAGS).encode())
    d = os.path.join(ROOT, 'build', 'spirv-cross-cli', h.hexdigest()[:16]); exe = os.path.join(d, 'spirv-cross')
    if os.access(exe, os.X_OK): return exe
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, '.lock'), 'w') as lf:
        fcntl.flock(lf, fcntl.LOCK_EX)
        if os.access(exe, os.X_OK): return exe
        tmp = exe + '.tmp-%d' % os.getpid()
        r = subprocess.run([os.environ.get('CXX', 'c++'), *FLAGS, '-I' + XSRC, *[os.path.join(XSRC, u + '.cpp') for u in UNITS], '-o', tmp], capture_output=True, text=True)
        if r.returncode: red('in-tree SPIRV-Cross does not build: ' + (r.stdout + r.stderr).strip()[-600:])
        os.replace(tmp, exe)
    return exe


def build():
    dn = dotnet(); os.makedirs(os.path.dirname(LOCK), exist_ok=True)
    with open(LOCK, 'w') as lf:
        fcntl.flock(lf, fcntl.LOCK_EX)
        r = subprocess.run([dn, 'build', PROJ, '-c', 'Release', '-o', OUT, '-nodeReuse:false', '-v', 'q', '-p:UseSharedCompilation=false'], capture_output=True, text=True)
    if r.returncode: red('dsh_vklib does not build: ' + (r.stdout + r.stderr).strip()[-800:])
    return [dn, os.path.join(OUT, 'dsh_vklib.dll')]


if __name__ == '__main__':
    if sys.argv[1:] == ['fp']:
        print(fp())
    elif sys.argv[1:2] == ['build']:
        cmd = build() + sys.argv[2:] + ['--spirv-cross', spirv_cross()]
        os.execv(cmd[0], cmd)
    else:
        sys.exit('usage: dsh_vklib.py fp | build <dsh_vklib args…>')
